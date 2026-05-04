import std/json
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
  FakeAcpTransport(nextSession: 1, turns: @[defaultTurn(scriptedResponse)])

proc newFakeAcpTransport*(turns: seq[FakePromptTurn]): FakeAcpTransport =
  FakeAcpTransport(nextSession: 1, turns: turns)

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
          "filesystem": {"readTextFile": true, "writeTextFile": false}
        },
        "_meta": {"fake": true}
      }
    })
  of "session/new":
    let sessionId = "fake-session-" & $transport.nextSession
    inc transport.nextSession
    transport.sessions.add sessionId
    $(%*{"jsonrpc": "2.0", "id": req.id, "result": {"sessionId": sessionId}})
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
