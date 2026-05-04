import std/json
import unittest
import nim_acp

suite "nim-acp":
  test "connect wraps reusable transport abstractions":
    let fake = newFakeAcpTransport()
    var client = connect(AcpConnectConfig(kind: atkInMemory), fake)
    let response = client.initialize(InitializeRequest(protocolVersion: 1))
    check response.agentCapabilities.streaming
    check fake.capabilities().notifications

  test "agent_client_acp_initialize_negotiates_capabilities":
    let fake = newFakeAcpTransport()
    var client = newAcpClient(fake)
    let response = client.initialize(InitializeRequest(
      protocolVersion: 1,
      clientInfo: ClientInfo(name: "test-client", version: "0.1.0"),
      clientCapabilities: ClientCapabilities(streaming: true, resources: true)))
    check response.protocolVersion == 1
    check response.agentCapabilities.streaming
    check response.agentCapabilities.resources
    check response.agentCapabilities.filesystemRead

  test "agent_client_prompt_turn_streams_updates":
    let fake = newFakeAcpTransport(@[
      promptTurn(@[
        thoughtChunk("checking repository"),
        toolCall("tool-1", "Run tests", """{"cmd":"just test"}"""),
        toolCallUpdate("tool-1", "completed", "2 passed"),
        messageChunk("hello from fake"),
        statusUpdate("completed")
      ])
    ])
    var client = newAcpClient(fake)
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    let session = client.startSession(NewSessionRequest(cwd: "/tmp/project"))
    var subscribed: seq[SessionUpdateKind] = @[]
    client.subscribeUpdates(session.sessionId, proc(update: SessionUpdate) =
      subscribed.add update.kind)
    let prompt = client.sendPrompt(PromptRequest(
      sessionId: session.sessionId,
      prompt: @[textBlock("hello")]))
    check prompt.stopReason == srEndTurn
    let updates = client.drainUpdates()
    check updates.len == 5
    check updates[0].kind == sukAgentThoughtChunk
    check updates[1].kind == sukToolCall
    check updates[1].toolCallId == "tool-1"
    check updates[2].kind == sukToolCallUpdate
    check updates[2].status == "completed"
    check updates[3].kind == sukAgentMessageChunk
    check updates[3].content.text == "hello from fake"
    check updates[4].kind == sukStatus
    check subscribed == @[sukAgentThoughtChunk, sukToolCall, sukToolCallUpdate,
      sukAgentMessageChunk, sukStatus]

  test "cancel is sent as ACP notification without JSON-RPC id":
    let fake = newFakeAcpTransport(@[
      promptTurn(@[messageChunk("working")], stopReason = "cancelled")
    ])
    var client = newAcpClient(fake)
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    let session = client.startSession(NewSessionRequest(cwd: "/tmp/project"))
    client.cancel(session.sessionId)
    check fake.receivedNotifications.len == 1
    let note = parseJson(fake.receivedNotifications[0])
    check note["jsonrpc"].getStr() == "2.0"
    check note["method"].getStr() == "session/cancel"
    check not note.hasKey("id")
    check note["params"]["sessionId"].getStr() == session.sessionId

    let updates = client.drainUpdates()
    check updates.len == 1
    check updates[0].kind == sukToolCallUpdate
    check updates[0].status == "cancelled"

  test "fake adapter scripts stop reasons and errors":
    var client = newAcpClient(newFakeAcpTransport(@[
      promptTurn(@[messageChunk("hit limit")], stopReason = "max_tokens"),
      promptTurn(@[], errorMessage = "agent failed")
    ]))
    let session = client.startSession(NewSessionRequest(cwd: "/tmp/project"))
    let limited = client.sendPrompt(PromptRequest(sessionId: session.sessionId, prompt: @[textBlock("one")]))
    check limited.stopReason == srMaxTokens
    expect AcpError:
      discard client.sendPrompt(PromptRequest(sessionId: session.sessionId, prompt: @[textBlock("two")]))
