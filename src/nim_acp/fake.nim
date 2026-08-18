import std/json
import std/tables
import nim_acp/[client, jsonrpc, types]

type
  FakePromptTurn* = object
    updates*: seq[JsonNode]
    stopReason*: string
    errorMessage*: string
  FakeAcpTransport* = ref object of AcpTransport
    initialized*: bool
    sessions*: seq[string]
    notifications*: seq[string]
    receivedNotifications*: seq[string]
    nextSession*: int
    turns*: seq[FakePromptTurn]
    nextTurn*: int
    cancelledSessions*: seq[string]
    supportsLoadSession*: bool
      ## Whether this fake advertises the optional ``loadSession``
      ## capability.  Settable so a test can exercise the *client's*
      ## refusal path — no real agent can be asked to withhold a
      ## capability on demand.  Defaults to true, because an agent that
      ## can replay sessions is the interesting case.
    transcripts*: Table[string, seq[JsonNode]]
      ## Per-session history, the way a real agent persists its own.
      ## Populated by ``session/new`` (empty), appended to by
      ## ``session/prompt``, and replayed by ``session/load``.  A session
      ## id with no entry here is *unknown* — which is how a pruned
      ## session is simulated.
    loadedSessions*: seq[string]
      ## Every session id this fake was asked to load, in order.  Lets a
      ## test assert that a request did (or, for the capability check,
      ## did **not**) reach the wire.

proc messageChunk*(text: string): JsonNode =
  %*{
    "sessionUpdate": "agent_message_chunk",
    "content": {"type": "text", "text": text}
  }

proc thoughtChunk*(text: string): JsonNode =
  %*{
    "sessionUpdate": "agent_thought_chunk",
    "content": {"type": "text", "text": text}
  }

proc toolCall*(id, title, rawInput: string): JsonNode =
  %*{
    "sessionUpdate": "tool_call",
    "toolCallId": id,
    "title": title,
    "rawInput": rawInput
  }

proc toolCallUpdate*(id, status, rawOutput: string): JsonNode =
  %*{
    "sessionUpdate": "tool_call_update",
    "toolCallId": id,
    "status": status,
    "rawOutput": rawOutput
  }

proc statusUpdate*(status: string): JsonNode =
  %*{"sessionUpdate": "status", "status": status}

proc promptTurn*(updates: seq[JsonNode]; stopReason = "end_turn";
    errorMessage = ""): FakePromptTurn =
  FakePromptTurn(updates: updates, stopReason: stopReason, errorMessage: errorMessage)

proc defaultTurn(response: string): FakePromptTurn =
  promptTurn(@[
    thoughtChunk("planning"),
    toolCall("tool-1", "Inspect workspace", """{"cmd":"ls"}"""),
    toolCallUpdate("tool-1", "completed", "src tests"),
    messageChunk(response),
    statusUpdate("completed")
  ])

proc newFakeAcpTransport*(scriptedResponse = "fake response"): FakeAcpTransport =
  FakeAcpTransport(nextSession: 1, turns: @[defaultTurn(scriptedResponse)],
    supportsLoadSession: true,
    transcripts: initTable[string, seq[JsonNode]]())

proc newFakeAcpTransport*(turns: seq[FakePromptTurn]): FakeAcpTransport =
  FakeAcpTransport(nextSession: 1, turns: turns,
    supportsLoadSession: true,
    transcripts: initTable[string, seq[JsonNode]]())

proc scriptSession*(transport: FakeAcpTransport; sessionId: string;
    updates: seq[JsonNode]) =
  ## Give the fake a session it already holds, without that session
  ## having been started or prompted through this client.
  ##
  ## This is the shape ``session/load`` exists for: a conversation that
  ## happened *earlier*, in another process, which a later client wants
  ## to read.  Without it a load test could only ever replay a session it
  ## had just created, which is the uninteresting half of the feature.
  transport.transcripts[sessionId] = updates

proc pruneSession*(transport: FakeAcpTransport; sessionId: string) =
  ## Forget a session the fake holds, simulating an agent that has aged
  ## its history out.  A subsequent ``session/load`` answers "unknown
  ## session", which is what the reference-not-resolvable path needs.
  transport.transcripts.del(sessionId)

method capabilities*(transport: FakeAcpTransport): AcpTransportCapabilities =
  AcpTransportCapabilities(
    kind: atkInMemory,
    requestResponse: true,
    notifications: true,
    eventDrain: true)

method send*(transport: FakeAcpTransport; request: string): string =
  let req = decodeRequest(request)
  case req.rpcMethod
  of "initialize":
    transport.initialized = true
    $(%*{
      "jsonrpc": "2.0",
      "id": req.id,
      "result": {
        "protocolVersion": req.params{"protocolVersion"}.getInt(1),
        "agentCapabilities": {
          "streaming": true,
          "text": true,
          "images": true,
          "resources": true,
          "permissions": true,
          "terminal": true,
          "filesystem": {"readTextFile": true, "writeTextFile": false},
          "loadSession": transport.supportsLoadSession
        },
        "_meta": {"fake": true}
      }
    })
  of "session/new":
    let sessionId = "fake-session-" & $transport.nextSession
    inc transport.nextSession
    transport.sessions.add sessionId
    # A brand-new session is *known* but empty; ``session/load`` must be
    # able to tell that from a session that was never created.
    transport.transcripts[sessionId] = @[]
    $(%*{"jsonrpc": "2.0", "id": req.id, "result": {"sessionId": sessionId}})
  of "session/load":
    let sessionId = req.params{"sessionId"}.getStr("")
    if not transport.supportsLoadSession:
      # What a real agent without the capability answers.  The client is
      # expected never to get here (it checks the handshake first); the
      # arm exists so a client that skipped the check is still refused.
      return $(%*{"jsonrpc": "2.0", "id": req.id, "error": {
        "code": -32601, "message": "method not found: session/load"}})
    if not transport.transcripts.hasKey(sessionId):
      return $(%*{"jsonrpc": "2.0", "id": req.id, "error": {
        "code": -32602,
        "message": "unknown session: " & sessionId}})
    transport.loadedSessions.add sessionId
    for update in transport.transcripts[sessionId]:
      transport.notifications.add encodeNotification(JsonRpcNotification(
        rpcMethod: "session/update",
        params: %*{"sessionId": sessionId, "update": update}))
    # ACP's session/load result is null: the replay *is* the payload.
    $(%*{"jsonrpc": "2.0", "id": req.id, "result": newJNull()})
  of "session/prompt":
    let sessionId = req.params{"sessionId"}.getStr("")
    if transport.nextTurn >= transport.turns.len:
      return $(%*{"jsonrpc": "2.0", "id": req.id, "error": {"code": -32000, "message": "no fake prompt turn scripted"}})
    let turn = transport.turns[transport.nextTurn]
    inc transport.nextTurn
    if turn.errorMessage.len > 0:
      return $(%*{"jsonrpc": "2.0", "id": req.id, "error": {"code": -32000, "message": turn.errorMessage}})
    for update in turn.updates:
      transport.notifications.add encodeNotification(JsonRpcNotification(
        rpcMethod: "session/update",
        params: %*{"sessionId": sessionId, "update": update}))
    # Remember the turn so a later ``session/load`` can replay it, the
    # way a real agent persists the conversation it just had.
    if not transport.transcripts.hasKey(sessionId):
      transport.transcripts[sessionId] = @[]
    for update in turn.updates:
      transport.transcripts[sessionId].add update
    $(%*{
      "jsonrpc": "2.0",
      "id": req.id,
      "result": {"sessionId": sessionId, "stopReason": turn.stopReason}
    })
  else:
    $(%*{"jsonrpc": "2.0", "id": req.id, "error": {"code": -32601, "message": "method not found"}})

method sendNotification*(transport: FakeAcpTransport; notification: string) =
  transport.receivedNotifications.add notification
  let note = decodeNotification(notification)
  if note.rpcMethod == "session/cancel":
    let sessionId = note.params{"sessionId"}.getStr("")
    transport.cancelledSessions.add sessionId
    let params = %*{
      "sessionId": sessionId,
      "update": {
        "sessionUpdate": "tool_call_update",
        "toolCallId": "cancelled-by-client",
        "status": "cancelled",
        "rawOutput": "client requested cancellation"
      }
    }
    transport.notifications.add encodeNotification(JsonRpcNotification(
      rpcMethod: "session/update",
      params: params))

method drain*(transport: FakeAcpTransport): seq[string] =
  result = transport.notifications
  transport.notifications = @[]
