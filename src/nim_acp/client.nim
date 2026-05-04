import std/json
import std/tables
import nim_acp/[jsonrpc, types]

type
  AcpTransport* = ref object of RootObj
  NativeStdioAcpTransport* = ref object of AcpTransport
    command*: string
    args*: seq[string]
  BrowserMessagePortAcpTransport* = ref object of AcpTransport
    endpointName*: string
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

method send*(transport: NativeStdioAcpTransport; request: string): string =
  raise newException(AcpError, "native stdio ACP host integration is not attached")

method sendNotification*(transport: NativeStdioAcpTransport; notification: string) =
  raise newException(AcpError, "native stdio ACP host integration is not attached")

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
      newAcpClient(NativeStdioAcpTransport(command: config.command, args: config.args))
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
