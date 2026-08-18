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
    loadSession*: bool
      ## The agent can re-open a session it already holds and replay its
      ## whole conversation — the protocol's ``session/load``.  It is
      ## optional in ACP (see
      ## https://agentclientprotocol.com/protocol/session-setup#loading-sessions),
      ## so a client MUST check this before issuing the request: an agent
      ## that does not advertise it will answer "method not found", which
      ## is a far worse diagnostic than the client's own refusal.
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
  LoadSessionRequest* = object
    ## Parameters of the protocol's ``session/load``: the session to
    ## re-open, plus the same workspace context ``session/new`` takes —
    ## an agent resolves a session against a working directory and the
    ## MCP servers it was configured with, so a session recorded in one
    ## workspace is not silently replayed against another.
    sessionId*: string
    cwd*: string
    mcpServers*: seq[string]
  LoadSessionResponse* = object
    ## What a completed ``session/load`` yielded.
    ##
    ## ``updates`` is the *whole* replayed conversation, in the order the
    ## agent emitted it.  The protocol delivers a load as a burst of
    ## ordinary ``session/update`` notifications followed by the response,
    ## so a loaded session and a live turn produce the same values and a
    ## caller renders them with one code path.  An empty ``updates`` for a
    ## request that did **not** raise means the agent genuinely holds an
    ## empty session — it is not how a failure is reported.
    sessionId*: string
    updates*: seq[SessionUpdate]
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
