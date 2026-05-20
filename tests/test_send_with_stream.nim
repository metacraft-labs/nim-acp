## Streaming ``sendWithStream`` tests.
##
## The streaming primitive on :type:`NativeStdioAcpTransport` must:
##   1. fire the per-frame callback synchronously, in order, BEFORE the
##      matching response is returned;
##   2. preserve buffered-drain compatibility — frames delivered to the
##      callback also land in ``pendingNotifications`` so existing
##      callers of :proc:`drain`/``drainNotifications`` keep seeing
##      them;
##   3. behave like :proc:`send` when no notifications precede the
##      response.
##
## We exercise these properties against a stdio child that ``printf``s
## a scripted JSON-RPC stream, so the transport sees real pipe I/O
## (not an in-memory fake which doesn't model framing the same way).

import std/[json, os, strutils, times]
import unittest
import nim_acp

const NotificationFrame = """{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"CHUNK"}}}}"""

proc writeChildScript(path: string; body: string) =
  ## Drop a tiny shell child at ``path`` that ignores stdin and emits
  ## the lines listed in ``body`` on stdout (one ``printf`` per line so
  ## the framing stays under our control).
  writeFile(path, "#!/bin/sh\n" & body & "\n")
  let p = path
  discard execShellCmd("chmod +x " & p)

proc spawnStreamingChild(numNotifications: int; perChunkDelayMs: int = 0):
    NativeStdioAcpTransport =
  ## Spawn a stdio child that emits ``numNotifications`` notification
  ## frames followed by a single response with id "1".
  let dir = getTempDir() / ("acp_stream_test_" & $epochTime())
  createDir(dir)
  let scriptPath = dir / "child.sh"
  var body = "# wait for at least one input line so writeFrame's send-then-read pattern works\n"
  body.add "read line\n"
  for i in 0 ..< numNotifications:
    body.add "printf '%s\\n' '" & NotificationFrame & "'\n"
    if perChunkDelayMs > 0:
      body.add "sleep " & $(perChunkDelayMs.float / 1000.0) & "\n"
  body.add "printf '%s\\n' '" & """{"jsonrpc":"2.0","id":"1","result":{"sessionId":"s","stopReason":"end_turn"}}""" & "'\n"
  writeChildScript(scriptPath, body)
  result = newNativeStdioAcpTransport(scriptPath, defaultTimeoutMs = 10_000)

suite "sendWithStream":

  test "test_send_with_stream_fires_callback_before_response":
    let transport = spawnStreamingChild(3, perChunkDelayMs = 100)
    var seen: seq[string] = @[]
    var seenTimes: seq[float] = @[]
    let start = epochTime()
    let cb: AcpNotificationCallback = proc(raw: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        seen.add raw
        seenTimes.add (epochTime() - start)
    let resp = transport.sendWithStream(
      """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""",
      cb)
    let total = epochTime() - start
    check seen.len == 3
    for s in seen:
      check s.contains("session/update")
    # Three callbacks separated by ~100 ms apart must precede the response.
    check seenTimes[0] < total
    check seenTimes[2] < total
    # The third callback should fire roughly 200 ms after the first.
    check seenTimes[2] - seenTimes[0] >= 0.15
    let respNode = parseJson(resp)
    check respNode{"id"}.getStr("") == "1"
    check respNode{"result"}{"stopReason"}.getStr("") == "end_turn"
    transport.close()

  test "test_send_with_stream_falls_back_to_send_semantics":
    let transport = spawnStreamingChild(0)
    var calls = 0
    let cb: AcpNotificationCallback = proc(raw: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
    let resp = transport.sendWithStream(
      """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""",
      cb)
    check calls == 0
    check parseJson(resp){"result"}{"stopReason"}.getStr("") == "end_turn"
    transport.close()

  test "test_send_with_stream_preserves_drain_compat":
    let transport = spawnStreamingChild(2)
    var streamed: seq[string] = @[]
    let cb: AcpNotificationCallback = proc(raw: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        streamed.add raw
    discard transport.sendWithStream(
      """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""",
      cb)
    let drained = transport.drain()
    check streamed.len == 2
    check drained.len == 2
    # Same frames in the same order in both.
    for i in 0 ..< streamed.len:
      check streamed[i] == drained[i]
    transport.close()

# --------------------------------------------------------------------------- #
#  Follow-up 1 — idle vs hard timeouts.
#
#  These tests exercise the contract documented on
#  :proc:`newNativeStdioAcpTransport` and the rewritten
#  :proc:`pumpUntil`: the idle timer resets on each frame, while the
#  hard wall-clock deadline bounds the whole call.
# --------------------------------------------------------------------------- #

proc spawnSilentChild(): NativeStdioAcpTransport =
  ## A child that reads one line then sleeps indefinitely without ever
  ## writing a response or notification frame.  Used to trip the idle
  ## timeout deterministically.
  let dir = getTempDir() / ("acp_silent_test_" & $epochTime())
  createDir(dir)
  let scriptPath = dir / "child.sh"
  let body =
    "read line\n" &
    "sleep 30\n"
  writeChildScript(scriptPath, body)
  result = newNativeStdioAcpTransport(scriptPath,
    idleTimeoutMs = 500, hardDeadlineMs = 30_000)

proc spawnIdleResetChild(): NativeStdioAcpTransport =
  ## A child that emits 5 notification frames at 1500 ms gaps, then a
  ## response.  With the previous wall-clock semantics (1000 ms total
  ## budget) the second frame would never arrive; under the idle-reset
  ## semantics the whole stream is delivered.
  let dir = getTempDir() / ("acp_idle_reset_test_" & $epochTime())
  createDir(dir)
  let scriptPath = dir / "child.sh"
  var body = "read line\n"
  for _ in 0 ..< 5:
    body.add "printf '%s\\n' '" & NotificationFrame & "'\n"
    body.add "sleep 1.5\n"
  body.add "printf '%s\\n' '" & """{"jsonrpc":"2.0","id":"1","result":{"sessionId":"s","stopReason":"end_turn"}}""" & "'\n"
  writeChildScript(scriptPath, body)
  # ``idleTimeoutMs = 2500`` so each 1500 ms gap stays within budget;
  # the wall-clock total is ~7500 ms which would have tripped any
  # historical single-deadline check around 5–6 s.
  result = newNativeStdioAcpTransport(scriptPath,
    idleTimeoutMs = 2500, hardDeadlineMs = 30_000)

proc spawnNoisyForeverChild(): NativeStdioAcpTransport =
  ## A child that emits a notification frame every ~50 ms and never
  ## sends a response.  Used to verify the hard deadline fires even
  ## when the stream is active.
  let dir = getTempDir() / ("acp_noisy_forever_test_" & $epochTime())
  createDir(dir)
  let scriptPath = dir / "child.sh"
  let body =
    "read line\n" &
    "while true; do\n" &
    "  printf '%s\\n' '" & NotificationFrame & "'\n" &
    "  sleep 0.05\n" &
    "done\n"
  writeChildScript(scriptPath, body)
  result = newNativeStdioAcpTransport(scriptPath,
    idleTimeoutMs = 10_000, hardDeadlineMs = 1000)

suite "idle vs hard timeouts (follow-up 1)":

  test "test_idle_timeout_resets_on_frame":
    ## 5 notifications at 1.5 s gaps with a 2.5 s idle budget: all 5
    ## must arrive and the response must come back normally.  Under the
    ## pre-follow-up wall-clock semantics this would have failed at
    ## frame 2 (cumulative ~3 s elapsed > 1 s budget).
    let transport = spawnIdleResetChild()
    var seen = 0
    let cb: AcpNotificationCallback = proc(raw: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        inc seen
    let start = epochTime()
    let resp = transport.sendWithStream(
      """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""",
      cb)
    let elapsed = epochTime() - start
    check seen == 5
    check parseJson(resp){"id"}.getStr("") == "1"
    # We legitimately spent ≥ 5 × 1.5 s ≈ 7.5 s streaming chunks; this
    # would have been impossible with a 1 s wall-clock budget.
    check elapsed > 6.0
    transport.close()

  test "test_idle_timeout_fires_after_silence":
    ## A child that goes silent after ack-reading the request must
    ## trip the idle timeout within ~idleTimeoutMs and raise an
    ## AcpError whose message contains "no response".
    let transport = spawnSilentChild()
    let start = epochTime()
    expect AcpError:
      try:
        discard transport.send(
          """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""")
      except AcpError as e:
        check e.msg.contains("no response")
        # Should trip ~0.5 s after start; allow generous slack for the
        # 5 ms inner sleep.
        let elapsed = epochTime() - start
        check elapsed < 2.0
        raise
    transport.close()

  test "test_hard_deadline_fires_even_with_active_stream":
    ## Frames arrive every ~50 ms forever; the hard deadline is
    ## 1000 ms, so even though the idle timer is constantly reset,
    ## the wall-clock cap must trigger and raise an AcpError whose
    ## message mentions "wall-clock".
    let transport = spawnNoisyForeverChild()
    let start = epochTime()
    expect AcpError:
      try:
        discard transport.send(
          """{"jsonrpc":"2.0","id":"1","method":"session/prompt","params":{}}""")
      except AcpError as e:
        check e.msg.contains("wall-clock")
        let elapsed = epochTime() - start
        # Should be close to 1.0 s; allow up to 2.5 s for slow CI hosts.
        check elapsed >= 0.9 and elapsed < 2.5
        raise
    transport.close()
