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
