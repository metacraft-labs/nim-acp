## Protocol dispatch tests use the shipped fake ACP peer / controlled raw-wire
## round trip only at the external agent boundary. This makes metadata, errors
## and capability variants deterministic; request encoding/client behavior stay
## production. Real stdio/HTTP/provider role delivery and inference are covered
## by the IsoNim editor integration and explicit real-authoring acceptance gate.
import std/json
import unittest
import nim_acp

suite "nim-acp":
  test "base injection queues preserve FIFO and sessions on this backend":
    let transport = newFakeAcpTransport()
    let independent = newFakeAcpTransport()
    check transport.peekQueuedInjections("session-a").len == 0
    check transport.takeQueuedInjections("session-a").len == 0
    transport.injectUserMessage("session-a", "first")
    transport.injectUserMessage("", "empty-session")
    transport.injectUserMessage("session-b", "other")
    transport.injectUserMessage("session-a", "")
    transport.injectUserMessage("session-a", "binary\0payload")
    independent.injectUserMessage("session-a", "independent")
    let preview = transport.peekQueuedInjections("session-a")
    check preview.len == 3
    check preview[0].text == "first"
    check preview[1].text == ""
    check preview[2].text == "binary\0payload"
    let drained = transport.takeQueuedInjections("session-a")
    check drained.len == 3
    check drained[0].text == "first"
    check drained[1].text == ""
    check drained[2].text == "binary\0payload"
    check transport.peekQueuedInjections("session-a").len == 0
    check transport.takeQueuedInjections("session-a").len == 0
    let other = transport.takeQueuedInjections("session-b")
    check other.len == 1
    check other[0].text == "other"
    let emptySession = transport.takeQueuedInjections("")
    check emptySession.len == 1
    check emptySession[0].text == "empty-session"
    let separate = independent.takeQueuedInjections("session-a")
    check separate.len == 1
    check separate[0].text == "independent"

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


suite "session/new provider metadata":
  test "exact optional metadata survives production request encoding":
    var observed: JsonNode
    var client = newAcpClient(proc(request: string): string =
      observed = parseJson(request)
      $(%* {"jsonrpc": "2.0", "id": observed["id"], "result": {"sessionId": "metadata-session"}}))
    let metadata = %* {"systemPrompt": {"append": "Role guidance\nUnicode Ω"}, "providerExtension": {"keep": true}}
    let session = client.startSession(NewSessionRequest(cwd: "/project", mcpServers: @["server"], meta: metadata))
    check session.sessionId == "metadata-session"
    check observed["method"].getStr == "session/new"
    check observed["params"]["cwd"].getStr == "/project"
    check observed["params"]["mcpServers"][0].getStr == "server"
    check observed["params"]["_meta"] == metadata

  test "legacy callers omit metadata and send no extra user turn":
    var calls = 0
    var observed: JsonNode
    var client = newAcpClient(proc(request: string): string =
      inc calls
      observed = parseJson(request)
      $(%* {"jsonrpc": "2.0", "id": observed["id"], "result": {"sessionId": "legacy-session"}}))
    discard client.startSession(NewSessionRequest(cwd: "/project"))
    check calls == 1
    check observed["method"].getStr == "session/new"
    check not observed["params"].hasKey("_meta")
