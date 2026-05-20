import std/json
import std/tables
import nim_acp/[jsonrpc, types]

when not defined(js):
  import std/[locks, options, os, osproc, streams, strutils, times]

type
  AcpTransport* = ref object of RootObj
  NativeStdioAcpTransport* = ref object of AcpTransport
    command*: string
    args*: seq[string]
    defaultTimeoutMs*: int
    when not defined(js):
      process: Process
      stdinStream: Stream
      stdoutStream: Stream
      readBuffer: string
      pendingResponses: Table[string, string]
      pendingNotifications: seq[string]
      writeLock: Lock
      closed: bool
  BrowserMessagePortAcpTransport* = ref object of AcpTransport
    endpointName*: string

type
  AcpServerError* = object of AcpError
    code*: int
    data*: JsonNode
  AcpTransportClosedError* = object of AcpError
  AcpTransportCapabilities* = object
    kind*: AcpTransportKind
    requestResponse*: bool
    notifications*: bool
    eventDrain*: bool
  AcpRoundTrip* = proc(request: string): string {.closure.}
  AcpNotify* = proc(notification: string) {.closure.}
  AcpDrain* = proc(): seq[string] {.closure.}
  SessionUpdateHandler* = proc(update: SessionUpdate) {.closure.}
  AcpClient* = object
    roundTrip*: AcpRoundTrip
    notify*: AcpNotify
    drainNotifications*: AcpDrain
    subscriptions*: Table[string, seq[SessionUpdateHandler]]
    nextId*: int

method send*(transport: AcpTransport; request: string): string {.base.} =
  raise newException(AcpError, "AcpTransport.send is not implemented")

method sendNotification*(transport: AcpTransport; notification: string) {.base.} =
  raise newException(AcpError, "AcpTransport.sendNotification is not implemented")

method drain*(transport: AcpTransport): seq[string] {.base.} =
  @[]

method capabilities*(transport: AcpTransport): AcpTransportCapabilities {.base.} =
  AcpTransportCapabilities(kind: atkCustom, requestResponse: true)

method capabilities*(transport: NativeStdioAcpTransport): AcpTransportCapabilities =
  AcpTransportCapabilities(kind: atkNativeStdio, requestResponse: true,
    notifications: true, eventDrain: true)

when not defined(js):
  const DefaultNativeStdioTimeoutMs* = 30_000

  proc newNativeStdioAcpTransport*(command: string; args: seq[string] = @[];
      defaultTimeoutMs = DefaultNativeStdioTimeoutMs): NativeStdioAcpTransport =
    ## Spawn ``command args...`` and prepare a newline-delimited JSON-RPC
    ## pipe pair on its stdin/stdout. ``ISONIM_ACP_AGENT_CMD`` overrides
    ## ``command`` when set, to make CI and tests redirectable without
    ## recompiling.
    var resolvedCommand = command
    let envOverride = getEnv("ISONIM_ACP_AGENT_CMD")
    if envOverride.len > 0:
      resolvedCommand = envOverride
    if resolvedCommand.len == 0:
      raise newException(AcpError,
        "NativeStdioAcpTransport requires a non-empty command")
    let resolved =
      if fileExists(resolvedCommand): resolvedCommand
      else: findExe(resolvedCommand)
    if resolved.len == 0:
      raise newException(AcpError,
        "NativeStdioAcpTransport: command not found on PATH: " &
        resolvedCommand)
    var process: Process
    try:
      process = startProcess(resolved, args = args,
        options = {poUsePath})
    except OSError as e:
      raise newException(AcpError,
        "NativeStdioAcpTransport: failed to spawn '" & resolved &
        "': " & e.msg)
    result = NativeStdioAcpTransport(
      command: resolved,
      args: args,
      defaultTimeoutMs: defaultTimeoutMs,
      process: process,
      stdinStream: process.inputStream(),
      stdoutStream: process.outputStream())
    initLock(result.writeLock)

  proc childAlive(transport: NativeStdioAcpTransport): bool =
    transport.process != nil and transport.process.running

  proc readByte(transport: NativeStdioAcpTransport): Option[char] =
    ## Non-blocking-ish single byte read. ``streams.readData`` returns 0
    ## either on EOF or when the pipe is momentarily empty; we
    ## disambiguate by checking ``running``.
    var ch: char
    let n = transport.stdoutStream.readData(addr ch, 1)
    if n == 1:
      some ch
    else:
      none(char)

  proc tryExtractFrame(transport: NativeStdioAcpTransport): Option[string] =
    let idx = transport.readBuffer.find('\n')
    if idx < 0:
      return none(string)
    let line = transport.readBuffer[0 ..< idx]
    transport.readBuffer.delete(0 .. idx)
    some line

  proc pumpUntil(transport: NativeStdioAcpTransport; matchId: string;
      timeoutMs: int): string =
    ## Read frames until one with ``matchId`` arrives or the timeout
    ## elapses. Non-matching frames are sorted into pending tables. If
    ## ``matchId`` is empty, only drain currently-available bytes.
    let deadline = epochTime() + (timeoutMs / 1000)
    while true:
      # First serve any pre-buffered matching response.
      if matchId.len > 0 and transport.pendingResponses.hasKey(matchId):
        return transport.pendingResponses[matchId]
      # Try to extract a complete frame from the buffer.
      let maybeFrame = transport.tryExtractFrame()
      if maybeFrame.isSome:
        let line = maybeFrame.get
        if line.len == 0:
          continue
        var parsed: JsonNode
        try:
          parsed = parseJson(line)
        except JsonParsingError:
          # Tolerate noise (banner lines etc.) without dying — ACP
          # servers should only emit framed JSON-RPC, but be lenient.
          continue
        if parsed.hasKey("id") and (parsed.hasKey("result") or
            parsed.hasKey("error")):
          let frameId = parsed["id"]
          let frameIdText =
            if frameId.kind == JString: frameId.getStr()
            elif frameId.kind == JInt: $frameId.getInt()
            else: $frameId
          if matchId.len > 0 and frameIdText == matchId:
            return line
          transport.pendingResponses[frameIdText] = line
        else:
          # Notification or server-initiated request — buffer for drain.
          transport.pendingNotifications.add line
        continue
      # Buffer empty; read more bytes.
      if not transport.childAlive() and transport.readBuffer.len == 0:
        # Drain whatever the pipe still has buffered.
        var residual = transport.stdoutStream.readAll()
        if residual.len > 0:
          transport.readBuffer.add residual
          continue
        raise newException(AcpTransportClosedError,
          "ACP child '" & transport.command & "' exited before completing the request")
      if matchId.len == 0:
        # ``drain``-style call: stop once the buffer is empty.
        return ""
      if epochTime() > deadline:
        raise newException(AcpError,
          "ACP request timed out after " & $timeoutMs & "ms (id=" & matchId & ")")
      # Try to read one chunk; fall back to a small sleep when stdout
      # is momentarily empty.
      let byte = transport.readByte()
      if byte.isSome:
        transport.readBuffer.add byte.get
      else:
        sleep(5)

  proc writeFrame(transport: NativeStdioAcpTransport; payload: string) =
    if transport.closed or not transport.childAlive():
      raise newException(AcpTransportClosedError,
        "ACP child '" & transport.command & "' is not running")
    acquire(transport.writeLock)
    try:
      transport.stdinStream.write(payload)
      transport.stdinStream.write("\n")
      transport.stdinStream.flush()
    finally:
      release(transport.writeLock)

  proc extractRequestId(payload: string): string =
    let node = parseJson(payload)
    if not node.hasKey("id"):
      return ""
    let idNode = node["id"]
    case idNode.kind
    of JString: idNode.getStr()
    of JInt: $idNode.getInt()
    else: $idNode

  method send*(transport: NativeStdioAcpTransport; request: string): string =
    let id = extractRequestId(request)
    if id.len == 0:
      raise newException(AcpError,
        "NativeStdioAcpTransport.send requires a JSON-RPC request with an id")
    transport.writeFrame(request)
    transport.pumpUntil(id, transport.defaultTimeoutMs)

  method sendNotification*(transport: NativeStdioAcpTransport;
      notification: string) =
    transport.writeFrame(notification)

  method drain*(transport: NativeStdioAcpTransport): seq[string] =
    # Best-effort drain of any pending frames buffered since the last call.
    if transport.process != nil and (transport.childAlive() or
        transport.readBuffer.len > 0):
      try:
        discard transport.pumpUntil("", 0)
      except AcpTransportClosedError:
        discard
    result = transport.pendingNotifications
    transport.pendingNotifications.setLen(0)

  proc close*(transport: NativeStdioAcpTransport) =
    ## Shut down the child. Idempotent.
    if transport == nil or transport.closed:
      return
    transport.closed = true
    if transport.process == nil:
      return
    try:
      if transport.childAlive():
        try:
          # Closing stdin signals graceful EOF to most ACP agents
          # (claude-code-acp included).
          transport.stdinStream.close()
        except CatchableError:
          discard
        # Give the child a moment to exit cleanly before SIGTERM.
        let deadline = epochTime() + 1.0
        while transport.childAlive() and epochTime() < deadline:
          sleep(20)
        if transport.childAlive():
          try: transport.process.terminate() except CatchableError: discard
        discard transport.process.waitForExit(timeout = 2_000)
    except CatchableError:
      discard
    try: transport.process.close() except CatchableError: discard
    deinitLock(transport.writeLock)

else:
  method send*(transport: NativeStdioAcpTransport; request: string): string =
    raise newException(AcpError,
      "native stdio ACP transport is not available on JS")

  method sendNotification*(transport: NativeStdioAcpTransport;
      notification: string) =
    raise newException(AcpError,
      "native stdio ACP transport is not available on JS")

method capabilities*(transport: BrowserMessagePortAcpTransport): AcpTransportCapabilities =
  AcpTransportCapabilities(kind: atkBrowserMessagePort, requestResponse: true,
    notifications: true, eventDrain: true)

method send*(transport: BrowserMessagePortAcpTransport; request: string): string =
  raise newException(AcpError, "browser message-port ACP host integration is not attached")

method sendNotification*(transport: BrowserMessagePortAcpTransport; notification: string) =
  raise newException(AcpError, "browser message-port ACP host integration is not attached")

proc newAcpClient*(transport: AcpTransport): AcpClient =
  AcpClient(
    roundTrip: proc(request: string): string = transport.send(request),
    notify: proc(notification: string) = transport.sendNotification(notification),
    drainNotifications: proc(): seq[string] = transport.drain(),
    subscriptions: initTable[string, seq[SessionUpdateHandler]](),
    nextId: 1)

proc newAcpClient*(roundTrip: AcpRoundTrip; drain: AcpDrain = nil;
    notify: AcpNotify = nil): AcpClient =
  AcpClient(
    roundTrip: roundTrip,
    notify: notify,
    drainNotifications: drain,
    subscriptions: initTable[string, seq[SessionUpdateHandler]](),
    nextId: 1)

proc connect*(config: AcpConnectConfig; transport: AcpTransport = nil): AcpClient =
  case config.kind
  of atkCustom, atkInMemory:
    if transport == nil:
      raise newException(AcpError, "connect requires an AcpTransport for custom/in-memory ACP connections")
    newAcpClient(transport)
  of atkNativeStdio:
    when defined(js):
      raise newException(AcpError, "native stdio ACP transport is not available on JS")
    else:
      newAcpClient(newNativeStdioAcpTransport(config.command, config.args))
  of atkBrowserMessagePort:
    when defined(js):
      newAcpClient(BrowserMessagePortAcpTransport(endpointName: config.endpointName))
    else:
      raise newException(AcpError, "browser message-port ACP transport is only available on JS")

proc requestId(client: var AcpClient): string =
  result = $client.nextId
  inc client.nextId

proc parseCapabilities(node: JsonNode): AgentCapabilities =
  AgentCapabilities(
    streaming: node{"streaming"}.getBool(false),
    text: node{"text"}.getBool(true),
    images: node{"images"}.getBool(false),
    audio: node{"audio"}.getBool(false),
    resources: node{"resources"}.getBool(false) or node{"resourceLinks"}.getBool(false),
    permissions: node{"permissions"}.getBool(false),
    terminal: node{"terminal"}.getBool(false),
    filesystemRead: node{"filesystem"}{"readTextFile"}.getBool(false),
    filesystemWrite: node{"filesystem"}{"writeTextFile"}.getBool(false))

proc initialize*(client: var AcpClient; req: InitializeRequest): InitializeResponse =
  let params = %*{
    "protocolVersion": req.protocolVersion,
    "clientInfo": {"name": req.clientInfo.name, "version": req.clientInfo.version},
    "clientCapabilities": {
      "streaming": req.clientCapabilities.streaming,
      "images": req.clientCapabilities.images,
      "audio": req.clientCapabilities.audio,
      "resources": req.clientCapabilities.resources,
      "permissions": req.clientCapabilities.permissions
    }
  }
  let response = decodeResponse(client.roundTrip(encodeRequest(JsonRpcRequest(
    id: client.requestId(), rpcMethod: "initialize", params: params))))
  response.raiseIfError()
  InitializeResponse(
    protocolVersion: response.result{"protocolVersion"}.getInt(1),
    agentCapabilities: parseCapabilities(response.result{"agentCapabilities"}),
    rawMeta: response.result{"_meta"})

proc startSession*(client: var AcpClient; req: NewSessionRequest): NewSessionResponse =
  let response = decodeResponse(client.roundTrip(encodeRequest(JsonRpcRequest(
    id: client.requestId(),
    rpcMethod: "session/new",
    params: %*{"cwd": req.cwd, "mcpServers": req.mcpServers}))))
  response.raiseIfError()
  NewSessionResponse(sessionId: response.result{"sessionId"}.getStr(""))

proc sendPrompt*(client: var AcpClient; req: PromptRequest): PromptResponse =
  var blocks = newJArray()
  for item in req.prompt:
    blocks.add contentBlockToJson(item)
  let response = decodeResponse(client.roundTrip(encodeRequest(JsonRpcRequest(
    id: client.requestId(),
    rpcMethod: "session/prompt",
    params: %*{"sessionId": req.sessionId, "prompt": blocks}))))
  response.raiseIfError()
  PromptResponse(
    sessionId: response.result{"sessionId"}.getStr(req.sessionId),
    stopReason: parseStopReason(response.result{"stopReason"}.getStr("end_turn")))

proc cancel*(client: var AcpClient; sessionId: string) =
  if client.notify == nil:
    raise newException(AcpError, "ACP transport does not support notifications")
  client.notify(encodeNotification(JsonRpcNotification(
    rpcMethod: "session/cancel",
    params: %*{"sessionId": sessionId})))

proc updateFromJson*(node: JsonNode): SessionUpdate =
  let update = node{"update"}
  let kindText = update{"sessionUpdate"}.getStr("custom")
  result.sessionId = node{"sessionId"}.getStr("")
  result.raw = node
  case kindText
  of "agent_message_chunk":
    result.kind = sukAgentMessageChunk
    result.content = contentBlockFromJson(update{"content"})
  of "agent_thought_chunk":
    result.kind = sukAgentThoughtChunk
    result.content = contentBlockFromJson(update{"content"})
  of "tool_call":
    result.kind = sukToolCall
    result.toolCallId = update{"toolCallId"}.getStr("")
    result.title = update{"title"}.getStr("")
    result.rawInput = update{"rawInput"}.getStr("")
  of "tool_call_update":
    result.kind = sukToolCallUpdate
    result.toolCallId = update{"toolCallId"}.getStr("")
    result.rawOutput = update{"rawOutput"}.getStr("")
    result.status = update{"status"}.getStr("")
  of "status":
    result.kind = sukStatus
    result.status = update{"status"}.getStr("")
  of "permission_request":
    result.kind = sukPermissionRequest
    result.permission = PermissionRequest(
      id: update{"id"}.getStr(""),
      sessionId: result.sessionId,
      title: update{"title"}.getStr(""))
    for option in update{"options"}.items:
      result.permission.options.add PermissionOption(
        id: option{"id"}.getStr(""),
        title: option{"title"}.getStr(""),
        kind: option{"kind"}.getStr(""))
  else:
    result.kind = sukCustom

proc subscribeUpdates*(client: var AcpClient; sessionId: string;
    handler: SessionUpdateHandler) =
  if not client.subscriptions.hasKey(sessionId):
    client.subscriptions[sessionId] = @[]
  client.subscriptions[sessionId].add handler

proc dispatch(client: AcpClient; update: SessionUpdate) =
  if client.subscriptions.hasKey(update.sessionId):
    for handler in client.subscriptions[update.sessionId]:
      handler(update)

proc drainUpdates*(client: AcpClient): seq[SessionUpdate] =
  if client.drainNotifications == nil:
    return @[]
  for frame in client.drainNotifications():
    let notification = decodeNotification(frame)
    if notification.rpcMethod == "session/update":
      let update = updateFromJson(notification.params)
      client.dispatch(update)
      result.add update
