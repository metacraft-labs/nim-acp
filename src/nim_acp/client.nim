import std/json
import std/tables
import nim_acp/[jsonrpc, types]

when not defined(js):
  import std/[locks, options, os, osproc, streams, strutils, times]
  when defined(posix):
    import std/posix

type
  AcpTransport* = ref object of RootObj
  NativeStdioAcpTransport* = ref object of AcpTransport
    command*: string
    args*: seq[string]
    ## ``defaultTimeoutMs`` is retained as a backwards-compatible alias
    ## for :field:`idleTimeoutMs`.  Reads return the idle timeout; writes
    ## via the legacy ``defaultTimeoutMs`` parameter on
    ## :proc:`newNativeStdioAcpTransport` are interpreted as idle
    ## timeouts.  Prefer :field:`idleTimeoutMs` / :field:`hardDeadlineMs`
    ## in new code — see the follow-up-1 design note.
    defaultTimeoutMs*: int
    idleTimeoutMs*: int
      ## Maximum *silence* tolerated between frames before
      ## :proc:`pumpUntil` raises ``AcpError "no response for ..."``.
      ## The idle timer resets every time any frame (response OR
      ## notification) arrives, so a long-running stream that emits a
      ## chunk every few seconds keeps the connection alive
      ## indefinitely.  Default: 60 s — generous enough that a
      ## momentarily-slow agent doesn't trip it, tight enough that a
      ## truly hung child surfaces within a minute.
    hardDeadlineMs*: int
      ## Wall-clock cap on a single ``pumpUntil`` call regardless of
      ## stream activity.  Guards against runaway sessions that emit
      ## frames forever (e.g. an agent stuck in an infinite tool-call
      ## loop).  When exceeded, :proc:`pumpUntil` raises
      ## ``AcpError "wall-clock timeout exceeded ..."`` so the caller
      ## can distinguish "stuck silently" (idle) from "stuck loudly"
      ## (hard).  Default: 30 minutes.
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
  AcpNotificationCallback* = proc(notification: string) {.closure, gcsafe.}
    ## Synchronous per-frame callback invoked by
    ## :proc:`sendWithStream` for each server-initiated notification
    ## received while waiting for a matching response.  ``notification``
    ## is the raw NDJSON frame (one complete JSON-RPC object).  The
    ## callback runs on the same thread as the reader loop, so it must
    ## not block on anything that depends on additional ACP frames
    ## arriving (that would deadlock).
  AcpStreamRoundTrip* = proc(request: string;
                             onNotification: AcpNotificationCallback): string
                       {.closure.}
    ## Streaming round-trip variant: same contract as :type:`AcpRoundTrip`
    ## but fires ``onNotification`` for every notification frame that
    ## arrives before the matching response.  Transports that don't
    ## support progressive delivery (e.g. fake/in-memory) may invoke the
    ## callback for buffered notifications after the response — but the
    ## *return value* remains the response frame.
  SessionUpdateHandler* = proc(update: SessionUpdate) {.closure.}
  AcpClient* = object
    roundTrip*: AcpRoundTrip
    streamRoundTrip*: AcpStreamRoundTrip
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

method sendWithStream*(transport: AcpTransport; request: string;
    onNotification: AcpNotificationCallback): string {.base.} =
  ## Default implementation: fall back to the buffered :proc:`send` and
  ## (after the response arrives) replay any buffered notifications by
  ## invoking ``onNotification`` for each.  Transports that can stream
  ## (e.g. :type:`NativeStdioAcpTransport`) override this to deliver
  ## notifications progressively as frames arrive.
  result = transport.send(request)
  if onNotification == nil:
    return
  for frame in transport.drain():
    onNotification(frame)

method capabilities*(transport: AcpTransport): AcpTransportCapabilities {.base.} =
  AcpTransportCapabilities(kind: atkCustom, requestResponse: true)

method capabilities*(transport: NativeStdioAcpTransport): AcpTransportCapabilities =
  AcpTransportCapabilities(kind: atkNativeStdio, requestResponse: true,
    notifications: true, eventDrain: true)

when not defined(js):
  const
    DefaultNativeStdioTimeoutMs* = 300_000
      ## Default *idle* timeout in milliseconds — i.e. the longest
      ## stretch of silence ``pumpUntil`` tolerates between frames
      ## before declaring the child unresponsive.  Bumped from the
      ## historical 30 s wall-clock value because real reviews
      ## legitimately stream tokens for 60–300 s; the previous default
      ## was tripping mid-review.  The follow-up-1 review then bumped
      ## it again from 60 s to 5 min because image-heavy ACP prompts
      ## (e.g. design-review with seven captures) commonly take 60–120 s
      ## to produce their first frame on slow back-ends and would
      ## otherwise trip a fresh stacked timeout.  Five minutes of pure
      ## silence really does indicate a hang; anything shorter risks
      ## killing legitimate workloads.  Callers that need a tighter
      ## probe still pass an explicit ``idleTimeoutMs`` (or the legacy
      ## ``defaultTimeoutMs`` alias) — see follow-up-1 design note.
    DefaultNativeStdioHardDeadlineMs* = 1_800_000
      ## Default *hard* wall-clock deadline — 30 minutes — that bounds
      ## a single ``pumpUntil`` regardless of whether frames are still
      ## arriving.  Guards against an agent stuck emitting noise
      ## forever from masking a logical hang.

  proc newNativeStdioAcpTransport*(command: string; args: seq[string] = @[];
      defaultTimeoutMs = -1;
      idleTimeoutMs = DefaultNativeStdioTimeoutMs;
      hardDeadlineMs = DefaultNativeStdioHardDeadlineMs):
        NativeStdioAcpTransport =
    ## Spawn ``command args...`` and prepare a newline-delimited JSON-RPC
    ## pipe pair on its stdin/stdout. ``ISONIM_ACP_AGENT_CMD`` overrides
    ## ``command`` when set, to make CI and tests redirectable without
    ## recompiling.
    ##
    ## *Timeout semantics — follow-up 1.*  Two thresholds bound the
    ## read loop:
    ##
    ##   * ``idleTimeoutMs`` — maximum silence between frames.  The
    ##     internal idle timer resets each time the child emits
    ##     anything (response OR notification), so a long-running
    ##     streaming review that emits a token every few seconds runs
    ##     to completion.  When the gap exceeds the timeout,
    ##     ``pumpUntil`` raises
    ##     ``AcpError "no response for <N> ms"``.
    ##   * ``hardDeadlineMs`` — wall-clock cap on a single ``pumpUntil``
    ##     call.  Even with an active stream, exceeding this bound
    ##     raises ``AcpError "wall-clock timeout exceeded ..."``.
    ##
    ## *Backwards compatibility.*  The legacy ``defaultTimeoutMs``
    ## parameter is still accepted; when given a non-negative value it
    ## is interpreted as ``idleTimeoutMs`` (the new semantics) — this
    ## is the "Option (c)" path from the follow-up brief.  Existing
    ## callers continue to compile and now benefit automatically from
    ## the idle-reset behaviour.
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
    let effectiveIdle =
      if defaultTimeoutMs >= 0: defaultTimeoutMs else: idleTimeoutMs
    result = NativeStdioAcpTransport(
      command: resolved,
      args: args,
      defaultTimeoutMs: effectiveIdle,
      idleTimeoutMs: effectiveIdle,
      hardDeadlineMs: hardDeadlineMs,
      process: process,
      stdinStream: process.inputStream(),
      stdoutStream: process.outputStream())
    when defined(posix):
      # Make the child's stdout fd non-blocking so :proc:`readByte`
      # returns control to the read loop on every poll quantum.  The
      # idle/hard-deadline checks in :proc:`pumpUntil` would otherwise
      # never get a chance to fire when the child stops emitting bytes
      # (the read would block until EOF or the next byte arrives).
      let fd = outputHandle(process)
      let flags = fcntl(fd, F_GETFL, 0)
      if flags >= 0:
        discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    initLock(result.writeLock)

  proc childAlive(transport: NativeStdioAcpTransport): bool =
    transport.process != nil and transport.process.running

  proc readByte(transport: NativeStdioAcpTransport): Option[char] =
    ## Single-byte read.
    ##
    ## On POSIX we issue a raw ``read(2)`` against the child's stdout fd
    ## (which the constructor flipped to ``O_NONBLOCK``).  This is the
    ## difference that lets :proc:`pumpUntil` honour the idle timeout
    ## while the child is silent: a blocking ``fread`` via the wrapping
    ## ``FileStream`` would park the thread until the next byte or EOF
    ## arrived, defeating the deadline checks entirely.  EAGAIN /
    ## EWOULDBLOCK return ``none(char)``; the loop polls and re-checks
    ## the deadlines.
    when defined(posix):
      var ch: char
      let fd = outputHandle(transport.process)
      let n = posix.read(fd.cint, addr ch, 1)
      if n == 1:
        return some ch
      # n == 0 → EOF (child closed stdout); n < 0 with EAGAIN/EWOULDBLOCK
      # → momentarily nothing to read.  In both cases return ``none`` and
      # let the caller's timeout / childAlive logic decide what to do.
      return none(char)
    else:
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
      idleTimeoutMs: int; hardDeadlineMs: int = -1;
      onNotification: AcpNotificationCallback = nil): string =
    ## Read frames until one with ``matchId`` arrives, the idle timer
    ## expires, or the hard wall-clock deadline elapses. Non-matching
    ## frames are sorted into pending tables. If ``matchId`` is empty,
    ## only drain currently-available bytes.
    ##
    ## *Idle timer.*  The idle timer is reset every time the child
    ## emits any frame — response or notification.  A stream that
    ## delivers a chunk every few seconds keeps the connection alive
    ## indefinitely.  Crossing ``idleTimeoutMs`` of silence raises
    ## ``AcpError "no response for <N> ms"``.
    ##
    ## *Hard deadline.*  Independent of idle, ``hardDeadlineMs``
    ## bounds the entire ``pumpUntil`` call.  When negative, the
    ## transport's :field:`hardDeadlineMs` is used; the distinct
    ## ``AcpError "wall-clock timeout exceeded ..."`` lets callers
    ## tell "stuck silently" from "stuck loudly".
    ##
    ## When ``onNotification`` is non-nil, each notification frame is
    ## passed to the callback *synchronously* before the response is
    ## returned.  The notification is ALSO appended to
    ## ``pendingNotifications`` so :proc:`drain` keeps working — the
    ## callback is additive, not replacing the buffered drain.
    let effectiveHardMs =
      if hardDeadlineMs >= 0: hardDeadlineMs
      else: transport.hardDeadlineMs
    let start = epochTime()
    let hardDeadline = start + (effectiveHardMs / 1000)
    var lastFrameAt = start
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
          # Treat noise as activity so the idle timer doesn't trip
          # on a chatty child that occasionally prints non-JSON.
          lastFrameAt = epochTime()
          continue
        # Real frame: reset the idle timer.
        lastFrameAt = epochTime()
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
          # Notification or server-initiated request — buffer for drain
          # AND fire the streaming callback if installed.
          transport.pendingNotifications.add line
          if onNotification != nil:
            try:
              onNotification(line)
            except CatchableError:
              # Callback exceptions are silently swallowed: a misbehaving
              # consumer must not break the reader loop.
              discard
        continue
      # Buffer empty; read more bytes.
      if not transport.childAlive() and transport.readBuffer.len == 0:
        # Drain whatever the pipe still has buffered.  On POSIX we read
        # the raw fd in a loop (the wrapping FileStream's fread caches
        # are bypassed by our non-blocking readByte path, so an
        # ``stdoutStream.readAll`` after exit might not see the bytes
        # the kernel still has queued).
        when defined(posix):
          var residualBuf = ""
          while true:
            var ch: char
            let fd = outputHandle(transport.process)
            let n = posix.read(fd.cint, addr ch, 1)
            if n <= 0: break
            residualBuf.add ch
          if residualBuf.len > 0:
            transport.readBuffer.add residualBuf
            continue
        else:
          var residual = transport.stdoutStream.readAll()
          if residual.len > 0:
            transport.readBuffer.add residual
            continue
        raise newException(AcpTransportClosedError,
          "ACP child '" & transport.command & "' exited before completing the request")
      if matchId.len == 0:
        # ``drain``-style call: stop once the buffer is empty.
        return ""
      let now = epochTime()
      if now > hardDeadline:
        raise newException(AcpError,
          "ACP request: wall-clock timeout exceeded (" &
          $effectiveHardMs & " ms, id=" & matchId & ")")
      let idleElapsedMs = int((now - lastFrameAt) * 1000)
      if idleElapsedMs > idleTimeoutMs:
        raise newException(AcpError,
          "ACP request: no response for " & $idleTimeoutMs &
          " ms (id=" & matchId & ")")
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
    transport.pumpUntil(id, transport.idleTimeoutMs,
                        transport.hardDeadlineMs)

  method sendWithStream*(transport: NativeStdioAcpTransport;
      request: string;
      onNotification: AcpNotificationCallback): string =
    ## Streaming variant of :proc:`send`.  Writes the request frame and
    ## reads frames back from the child, invoking ``onNotification``
    ## *synchronously* for each notification before the matching
    ## response arrives.  Notifications are also appended to
    ## ``pendingNotifications`` so existing :proc:`drain` consumers keep
    ## seeing the same frames.
    let id = extractRequestId(request)
    if id.len == 0:
      raise newException(AcpError,
        "NativeStdioAcpTransport.sendWithStream requires a JSON-RPC request with an id")
    transport.writeFrame(request)
    transport.pumpUntil(id, transport.idleTimeoutMs,
                        transport.hardDeadlineMs,
                        onNotification = onNotification)

  method sendNotification*(transport: NativeStdioAcpTransport;
      notification: string) =
    transport.writeFrame(notification)

  method drain*(transport: NativeStdioAcpTransport): seq[string] =
    # Best-effort drain of any pending frames buffered since the last call.
    if transport.process != nil and (transport.childAlive() or
        transport.readBuffer.len > 0):
      try:
        # ``matchId == ""`` returns as soon as the buffer is empty; the
        # idle/hard timeouts are unreachable in that branch but pass
        # the transport's configured defaults anyway for symmetry.
        discard transport.pumpUntil("", transport.idleTimeoutMs,
                                    transport.hardDeadlineMs)
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

  method sendWithStream*(transport: NativeStdioAcpTransport;
      request: string;
      onNotification: AcpNotificationCallback): string =
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

method sendWithStream*(transport: BrowserMessagePortAcpTransport;
    request: string; onNotification: AcpNotificationCallback): string =
  raise newException(AcpError, "browser message-port ACP host integration is not attached")

method sendNotification*(transport: BrowserMessagePortAcpTransport; notification: string) =
  raise newException(AcpError, "browser message-port ACP host integration is not attached")

proc newAcpClient*(transport: AcpTransport): AcpClient =
  AcpClient(
    roundTrip: proc(request: string): string = transport.send(request),
    streamRoundTrip: proc(request: string;
                          onNotification: AcpNotificationCallback): string =
      transport.sendWithStream(request, onNotification),
    notify: proc(notification: string) = transport.sendNotification(notification),
    drainNotifications: proc(): seq[string] = transport.drain(),
    subscriptions: initTable[string, seq[SessionUpdateHandler]](),
    nextId: 1)

proc newAcpClient*(roundTrip: AcpRoundTrip; drain: AcpDrain = nil;
    notify: AcpNotify = nil;
    streamRoundTrip: AcpStreamRoundTrip = nil): AcpClient =
  AcpClient(
    roundTrip: roundTrip,
    streamRoundTrip: streamRoundTrip,
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

proc sendPromptStreaming*(client: var AcpClient; req: PromptRequest;
    onUpdate: SessionUpdateHandler): PromptResponse =
  ## Streaming variant of :proc:`sendPrompt`.  Decodes each
  ## ``session/update`` notification on-the-fly and invokes ``onUpdate``
  ## with the typed :type:`SessionUpdate` *before* the response arrives,
  ## then returns the same :type:`PromptResponse` :proc:`sendPrompt`
  ## would have returned.  Falls back to the buffered round-trip when
  ## the underlying transport doesn't expose a streaming hook (in which
  ## case ``onUpdate`` fires after the response, by way of
  ## ``drainUpdates``).
  var blocks = newJArray()
  for item in req.prompt:
    blocks.add contentBlockToJson(item)
  let frame = encodeRequest(JsonRpcRequest(
    id: client.requestId(),
    rpcMethod: "session/prompt",
    params: %*{"sessionId": req.sessionId, "prompt": blocks}))
  let snapshot = client
  var rawResponse: string
  if client.streamRoundTrip != nil:
    let notificationCb: AcpNotificationCallback =
      proc(raw: string) {.gcsafe.} =
        try:
          let note = decodeNotification(raw)
          if note.rpcMethod == "session/update":
            let update = updateFromJson(note.params)
            {.cast(gcsafe).}:
              snapshot.dispatch(update)
              if onUpdate != nil:
                onUpdate(update)
        except CatchableError:
          discard
    rawResponse = client.streamRoundTrip(frame, notificationCb)
  else:
    rawResponse = client.roundTrip(frame)
    # Best-effort fallback: drain any buffered notifications and fire
    # the callback after the response — preserves ordering even though
    # delivery is not progressive on this transport.
    if onUpdate != nil and client.drainNotifications != nil:
      for raw in client.drainNotifications():
        try:
          let note = decodeNotification(raw)
          if note.rpcMethod == "session/update":
            let update = updateFromJson(note.params)
            client.dispatch(update)
            onUpdate(update)
        except CatchableError:
          discard
  let response = decodeResponse(rawResponse)
  response.raiseIfError()
  PromptResponse(
    sessionId: response.result{"sessionId"}.getStr(req.sessionId),
    stopReason: parseStopReason(response.result{"stopReason"}.getStr("end_turn")))
