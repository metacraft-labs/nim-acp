## Coverage for the ACP ``session/load`` method (RV-6).
##
## ``session/load`` is how a client re-opens a conversation the agent
## already holds: the agent replays the whole session as ordinary
## ``session/update`` notifications and then answers the request.  It is
## the mechanism CodeTracer's DeepReview uses to show "what the agent
## actually did" for a review dataset that names the session which
## produced it — the transcript is never copied into the dataset, only
## referenced, so it is fetched from the agent on demand.
##
## *Test double justification (workspace policy: every mock must be
## justified in the test file's header).*  These cases drive
## :type:`FakeAcpTransport` from ``nim_acp/fake.nim`` rather than a
## hand-rolled mock or a real agent process.
##
##   * A **real** ACP agent is not usable here: spawning ``claude-code-acp``
##   or ``codex-acp`` needs credentials, network and minutes per case, and
##   no real agent can be made to prune a session or to *withhold* the
##   ``loadSession`` capability on demand — which is exactly what two of
##   these cases must observe.
##   * The fake is the project's **sanctioned seam**: it is shipped library
##   code (``src/nim_acp/fake.nim``), it speaks the real wire format
##   through the real :proc:`decodeRequest` / :proc:`encodeNotification`
##   framing, and every other suite in this repo already drives the client
##   through it.  Nothing about the client under test is stubbed: the
##   request encoding, the capability bookkeeping, the notification decode
##   path and the error mapping are all the production ones.  Only the
##   *agent* is simulated, which is the boundary this repo does not own.
##
## The counterpart coverage on the real wire lives in
## ``tests/test_native_stdio_acp_transport.nim`` in ``nim-agents`` (the
## transport) and in the ``codex-acp`` smoke test; this file owns the
## protocol semantics.

import std/json
import std/strutils
import unittest
import nim_acp

suite "nim-acp session/load":
  test "acp_session_load_round_trips_a_recorded_transcript":
    ## The load path replays the session the agent holds, in order, as
    ## typed :type:`SessionUpdate` values — the same shape a live prompt
    ## turn produces, so a caller renders a loaded session and a live one
    ## with one code path.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-history-1", @[
      thoughtChunk("recalling the plan"),
      toolCall("tool-7", "Run tests", """{"cmd":"just test"}"""),
      toolCallUpdate("tool-7", "completed", "12 passed"),
      messageChunk("I fixed the parser and collected a review."),
      statusUpdate("completed")
    ])

    var client = newAcpClient(fake)
    let init = client.initialize(InitializeRequest(protocolVersion: 1))
    check init.agentCapabilities.loadSession

    var streamed: seq[SessionUpdateKind] = @[]
    let loaded = client.loadSession(LoadSessionRequest(
      sessionId: "session-history-1",
      cwd: "/tmp/project"), proc(update: SessionUpdate) =
        streamed.add update.kind)

    check loaded.sessionId == "session-history-1"
    check loaded.updates.len == 5
    check loaded.updates[0].kind == sukAgentThoughtChunk
    check loaded.updates[0].content.text == "recalling the plan"
    check loaded.updates[1].kind == sukToolCall
    check loaded.updates[1].toolCallId == "tool-7"
    check loaded.updates[1].title == "Run tests"
    check loaded.updates[2].kind == sukToolCallUpdate
    check loaded.updates[2].status == "completed"
    check loaded.updates[3].kind == sukAgentMessageChunk
    check loaded.updates[3].content.text ==
      "I fixed the parser and collected a review."
    check loaded.updates[4].kind == sukStatus
    # Every replayed update carries the session it belongs to, so a
    # caller holding several loaded sessions cannot mix them up.
    for update in loaded.updates:
      check update.sessionId == "session-history-1"
    check streamed == @[sukAgentThoughtChunk, sukToolCall, sukToolCallUpdate,
      sukAgentMessageChunk, sukStatus]

  test "acp_session_load_replays_a_session_this_client_prompted":
    ## A session started and prompted through the ordinary path is
    ## loadable afterwards: the fake records what it emitted, the way a
    ## real agent persists its own history.
    let fake = newFakeAcpTransport("done")
    var client = newAcpClient(fake)
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    let session = client.startSession(NewSessionRequest(cwd: "/tmp/project"))
    discard client.sendPrompt(PromptRequest(
      sessionId: session.sessionId, prompt: @[textBlock("hello")]))
    # Drain the live turn's notifications so nothing is left buffered;
    # the load below must produce the transcript on its own.
    check client.drainUpdates().len == 5

    let loaded = client.loadSession(LoadSessionRequest(
      sessionId: session.sessionId, cwd: "/tmp/project"))
    check loaded.updates.len == 5
    check loaded.updates[3].content.text == "done"

  test "acp_session_load_subscribers_receive_the_replayed_updates":
    ## ``subscribeUpdates`` handlers registered for the session fire for a
    ## load exactly as they do for a live turn.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-sub", @[messageChunk("replayed")])
    var client = newAcpClient(fake)
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    var seen: seq[string] = @[]
    client.subscribeUpdates("session-sub", proc(update: SessionUpdate) =
      seen.add update.content.text)
    discard client.loadSession(LoadSessionRequest(sessionId: "session-sub"))
    check seen == @["replayed"]

  test "acp_session_load_is_refused_when_the_agent_does_not_advertise_it":
    ## The capability check.  An agent that does not advertise
    ## ``loadSession`` is refused *by the client*, with a distinct
    ## exception type, rather than being sent a request it would answer
    ## with "method not found" — so a caller can tell "this agent cannot
    ## replay sessions" from "this session is gone".
    let fake = newFakeAcpTransport()
    fake.supportsLoadSession = false
    fake.scriptSession("session-history-1", @[messageChunk("unreachable")])
    var client = newAcpClient(fake)
    let init = client.initialize(InitializeRequest(protocolVersion: 1))
    check not init.agentCapabilities.loadSession

    expect AcpSessionLoadUnsupportedError:
      discard client.loadSession(LoadSessionRequest(
        sessionId: "session-history-1"))
    # Refused before the wire: the agent never saw a session/load.
    check fake.loadedSessions.len == 0

  test "acp_session_load_requires_a_negotiated_handshake":
    ## Without ``initialize`` the client has no capabilities to check, and
    ## says so rather than guessing.  This is a caller error, not an
    ## unresolvable session, so it is a plain :type:`AcpError`.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-history-1", @[messageChunk("unreachable")])
    var client = newAcpClient(fake)
    var raised = ""
    try:
      discard client.loadSession(LoadSessionRequest(
        sessionId: "session-history-1"))
    except AcpSessionLoadUnsupportedError:
      raised = "unsupported"
    except AcpError as e:
      raised = e.msg
    check raised.len > 0
    check raised != "unsupported"
    check raised.contains("initialize")

  test "acp_session_load_surfaces_the_agent_error_for_an_unknown_session":
    ## A pruned / unknown session is the agent's answer, not the client's
    ## guess: the JSON-RPC error is raised rather than swallowed into an
    ## empty transcript, which would read as "the agent did nothing".
    let fake = newFakeAcpTransport()
    var client = newAcpClient(fake)
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    var message = ""
    try:
      discard client.loadSession(LoadSessionRequest(sessionId: "session-gone"))
    except AcpError as e:
      message = e.msg
    check message.contains("session-gone")

  test "acp_session_load_request_carries_the_protocol_parameters":
    ## The request is the protocol's: ``sessionId``, ``cwd`` and
    ## ``mcpServers`` on ``session/load``.  Asserted on the raw frame so a
    ## rename in the encoder cannot pass silently.
    var seenFrames: seq[string] = @[]
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-params", @[messageChunk("ok")])
    var client = newAcpClient(proc(request: string): string =
      seenFrames.add request
      fake.send(request),
      drain = proc(): seq[string] = fake.drain())
    discard client.initialize(InitializeRequest(protocolVersion: 1))
    discard client.loadSession(LoadSessionRequest(
      sessionId: "session-params",
      cwd: "/work/repo",
      mcpServers: @["mcp-a"]))

    let frame = parseJson(seenFrames[^1])
    check frame["method"].getStr() == "session/load"
    check frame["params"]["sessionId"].getStr() == "session-params"
    check frame["params"]["cwd"].getStr() == "/work/repo"
    check frame["params"]["mcpServers"][0].getStr() == "mcp-a"
    check fake.loadedSessions == @["session-params"]
