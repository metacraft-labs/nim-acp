import std/json

type
  AcpError* = object of CatchableError
  ContentBlockKind* = enum
    cbText = "text"
    cbImage = "image"
    cbAudio = "audio"
    cbResource = "resource"
  ContentBlock* = object
    kind*: ContentBlockKind
    text*: string
    uri*: string
    mimeType*: string
    data*: string
  ClientInfo* = object
    name*: string
    version*: string
  ClientCapabilities* = object
    streaming*: bool
    images*: bool
    audio*: bool
    resources*: bool
    permissions*: bool
  AgentCapabilities* = object
    streaming*: bool
    text*: bool
    images*: bool
    audio*: bool
    resources*: bool
    permissions*: bool
    terminal*: bool
    filesystemRead*: bool
    filesystemWrite*: bool
  InitializeRequest* = object
    protocolVersion*: int
    clientInfo*: ClientInfo
    clientCapabilities*: ClientCapabilities
  InitializeResponse* = object
    protocolVersion*: int
    agentCapabilities*: AgentCapabilities
    rawMeta*: JsonNode
  NewSessionRequest* = object
    cwd*: string
    mcpServers*: seq[string]
  NewSessionResponse* = object
    sessionId*: string
  StopReason* = enum
    srEndTurn = "end_turn"
    srCancelled = "cancelled"
    srMaxTokens = "max_tokens"
    srError = "error"
  PromptRequest* = object
    sessionId*: string
    prompt*: seq[ContentBlock]
  PromptResponse* = object
    sessionId*: string
    stopReason*: StopReason
  SessionUpdateKind* = enum
    sukAgentMessageChunk = "agent_message_chunk"
    sukAgentThoughtChunk = "agent_thought_chunk"
    sukToolCall = "tool_call"
    sukToolCallUpdate = "tool_call_update"
    sukStatus = "status"
    sukPermissionRequest = "permission_request"
    sukCustom = "custom"
  SessionUpdate* = object
    sessionId*: string
    kind*: SessionUpdateKind
    content*: ContentBlock
    status*: string
    toolCallId*: string
    title*: string
    rawInput*: string
    rawOutput*: string
    permission*: PermissionRequest
    raw*: JsonNode
  PermissionOption* = object
    id*: string
    title*: string
    kind*: string
  PermissionRequest* = object
    id*: string
    sessionId*: string
    title*: string
    options*: seq[PermissionOption]
  AcpTransportKind* = enum
    atkCustom = "custom"
    atkNativeStdio = "native-stdio"
    atkBrowserMessagePort = "browser-message-port"
    atkInMemory = "in-memory"
  AcpConnectConfig* = object
    kind*: AcpTransportKind
    command*: string
    args*: seq[string]
    endpointName*: string
  CancelNotification* = object
    sessionId*: string
    meta*: JsonNode

proc textBlock*(text: string): ContentBlock =
  ContentBlock(kind: cbText, text: text)

proc imageBlock*(uri: string; mimeType = ""): ContentBlock =
  ContentBlock(kind: cbImage, uri: uri, mimeType: mimeType)

proc resourceBlock*(uri: string; mimeType = ""): ContentBlock =
  ContentBlock(kind: cbResource, uri: uri, mimeType: mimeType)

proc `$`*(reason: StopReason): string =
  case reason
  of srEndTurn: "end_turn"
  of srCancelled: "cancelled"
  of srMaxTokens: "max_tokens"
  of srError: "error"

proc parseStopReason*(value: string): StopReason =
  case value
  of "cancelled": srCancelled
  of "max_tokens": srMaxTokens
  of "error": srError
  else: srEndTurn

proc `$`*(kind: ContentBlockKind): string =
  case kind
  of cbText: "text"
  of cbImage: "image"
  of cbAudio: "audio"
  of cbResource: "resource"

proc contentBlockToJson*(item: ContentBlock): JsonNode =
  result = %*{"type": $item.kind}
  case item.kind
  of cbText:
    result["text"] = %item.text
  of cbImage, cbAudio, cbResource:
    if item.uri.len > 0: result["uri"] = %item.uri
    if item.mimeType.len > 0: result["mimeType"] = %item.mimeType
    if item.data.len > 0: result["data"] = %item.data

proc contentBlockFromJson*(node: JsonNode): ContentBlock =
  let kind = node{"type"}.getStr("text")
  case kind
  of "image": result.kind = cbImage
  of "audio": result.kind = cbAudio
  of "resource", "resource_link": result.kind = cbResource
  else: result.kind = cbText
  result.text = node{"text"}.getStr("")
  result.uri = node{"uri"}.getStr("")
  result.mimeType = node{"mimeType"}.getStr("")
  result.data = node{"data"}.getStr("")
