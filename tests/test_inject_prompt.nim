## Inject-prompt primitive tests (CMP-M3b).
##
## ``injectUserMessage`` queues a user message on the underlying
## :type:`AcpTransport`, keyed by session id, so the daemon's
## auto-tick loop can fold it into the next ``session/prompt`` turn.
## The queue is FIFO, isolated per session, and thread-safe — the
## HTTP handler thread that injects races the worker thread that
## drains.
##
## These tests exercise the contract from the base-class default
## (which :type:`NativeStdioAcpTransport` inherits unchanged) and the
## concurrency promise. The minimal transport stub isolates these default
## queue methods because no wire request is part of their contract; the
## inheritance boundary is separately exercised through a real child agent.

when defined(js):
  {.error: "Inject-prompt tests are native-only.".}

import std/[os, times, locks, atomics]
import unittest
import nim_acp

# --------------------------------------------------------------------------- #
#  Helpers — a minimal transport stub we can poke directly, plus a
#  spawned-child handle for the inheritance smoke test.
# --------------------------------------------------------------------------- #

type
  StubTransport = ref object of AcpTransport
    # No fields needed; the injection queue lives on the base class.

method send(transport: StubTransport; request: string): string =
  ""

proc newStubTransport(): StubTransport =
  StubTransport()

proc writeChildScript(path: string; body: string) =
  writeFile(path, "#!/bin/sh\n" & body & "\n")
  when not defined(windows):
    discard execShellCmd("chmod +x " & path)

proc newChildTransport(scriptPath: string;
    idleTimeoutMs = DefaultNativeStdioTimeoutMs;
    hardDeadlineMs = DefaultNativeStdioHardDeadlineMs):
      NativeStdioAcpTransport =
  when defined(windows):
    newNativeStdioAcpTransport("bash", @[scriptPath],
      idleTimeoutMs = idleTimeoutMs,
      hardDeadlineMs = hardDeadlineMs)
  else:
    newNativeStdioAcpTransport(scriptPath,
      idleTimeoutMs = idleTimeoutMs,
      hardDeadlineMs = hardDeadlineMs)

proc spawnFakeAcpAgent(): NativeStdioAcpTransport =
  ## Spawn a no-op stdio child so we can verify the inherited default
  ## methods work end-to-end on the concrete
  ## :type:`NativeStdioAcpTransport` without actually exchanging any
  ## ACP frames.  The child just blocks on stdin so the parent's
  ## ``close()`` exit path is exercised cleanly.
  let dir = getTempDir() / ("acp_inject_smoke_" & $epochTime())
  createDir(dir)
  let scriptPath = dir / "child.sh"
  let body =
    "# Block forever waiting on input; the injection-queue API does\n" &
    "# not actually talk to the child for CMP-M3b, so this stub is fine.\n" &
    "cat > /dev/null\n"
  writeChildScript(scriptPath, body)
  newChildTransport(scriptPath, idleTimeoutMs = 30_000,
                    hardDeadlineMs = 60_000)

# --------------------------------------------------------------------------- #
#  Concurrency-test scaffolding.  Two threads share a single transport;
#  one injects 1000 entries, the other repeatedly drains.  At the end
#  we drain whatever's left and check the union equals the producer's
#  output exactly.
# --------------------------------------------------------------------------- #

type
  SharedDrainedEntry = object
    bytes: pointer
    length: int
  ConcurrencyState = object
    transport: AcpTransport
    sessionId: string
    iterations: int
    producerDone: Atomic[bool]
    drained: ptr UncheckedArray[SharedDrainedEntry]
    drainedCount: int
    drainedLock: Lock

var sharedState: ConcurrencyState

proc retainDrainedText(text: string) =
  doAssert sharedState.drainedCount < sharedState.iterations
  let index = sharedState.drainedCount
  let bytes = allocShared(max(1, text.len))
  if bytes == nil: raise newException(OutOfMemDefect, "Drain result allocation failed")
  if text.len > 0: copyMem(bytes, unsafeAddr text[0], text.len)
  sharedState.drained[index] = SharedDrainedEntry(bytes: bytes, length: text.len)
  inc sharedState.drainedCount

proc drainedText(index: int): string =
  let entry = sharedState.drained[index]
  result = newString(entry.length)
  if entry.length > 0: copyMem(addr result[0], entry.bytes, entry.length)

proc producerThread() {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    for i in 0 ..< sharedState.iterations:
      sharedState.transport.injectUserMessage(
        sharedState.sessionId, "msg-" & $i)

proc consumerThread() {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    while true:
      let batch = sharedState.transport.takeQueuedInjections(
        sharedState.sessionId)
      if batch.len > 0:
        acquire(sharedState.drainedLock)
        for entry in batch:
          retainDrainedText(entry.text)
        release(sharedState.drainedLock)
      if sharedState.producerDone.load(moAcquire):
        # Producer is done — one final drain to capture anything that
        # landed between the last take and the producerDone flip.
        let tail = sharedState.transport.takeQueuedInjections(
          sharedState.sessionId)
        if tail.len > 0:
          acquire(sharedState.drainedLock)
          for entry in tail:
            retainDrainedText(entry.text)
          release(sharedState.drainedLock)
        break

# --------------------------------------------------------------------------- #
#  Suite.
# --------------------------------------------------------------------------- #

suite "injectUserMessage queue":

  test "test_inject_then_take_returns_queued_text":
    ## Three injections into the same session arrive in FIFO order;
    ## the second take returns @[] (queue was drained atomically).
    let transport = newStubTransport()
    transport.injectUserMessage("sid", "hello")
    transport.injectUserMessage("sid", "world")
    transport.injectUserMessage("sid", "!")
    let drained = transport.takeQueuedInjections("sid")
    check drained.len == 3
    check drained[0].text == "hello"
    check drained[1].text == "world"
    check drained[2].text == "!"
    let second = transport.takeQueuedInjections("sid")
    check second.len == 0

  test "test_inject_isolated_per_session":
    ## Injections into different session ids don't cross-contaminate.
    let transport = newStubTransport()
    transport.injectUserMessage("sid-a", "a1")
    transport.injectUserMessage("sid-a", "a2")
    transport.injectUserMessage("sid-b", "b1")
    let a = transport.takeQueuedInjections("sid-a")
    let b = transport.takeQueuedInjections("sid-b")
    check a.len == 2
    check a[0].text == "a1"
    check a[1].text == "a2"
    check b.len == 1
    check b[0].text == "b1"
    # Unknown session id returns empty.
    check transport.takeQueuedInjections("sid-unknown").len == 0

  test "test_peek_does_not_drain":
    ## peek returns the same entries take would, but the queue stays
    ## intact across repeated peeks; only take drains.
    let transport = newStubTransport()
    transport.injectUserMessage("sid", "x")
    transport.injectUserMessage("sid", "y")
    let peek1 = transport.peekQueuedInjections("sid")
    let peek2 = transport.peekQueuedInjections("sid")
    check peek1.len == 2
    check peek2.len == 2
    check peek1[0].text == "x"
    check peek1[1].text == "y"
    let drained = transport.takeQueuedInjections("sid")
    check drained.len == 2
    let peekAfter = transport.peekQueuedInjections("sid")
    check peekAfter.len == 0

  test "test_concurrent_inject_take_thread_safe":
    ## Two threads — one producing, one consuming — exchange 1000
    ## messages.  Final drained sequence must equal the producer's
    ## output in FIFO order with no duplicates and no losses.
    sharedState = ConcurrencyState(
      transport: newStubTransport(),
      sessionId: "sid-concurrent",
      iterations: 1000,
      drained: cast[ptr UncheckedArray[SharedDrainedEntry]](
        allocShared0(1000 * sizeof(SharedDrainedEntry))))
    doAssert sharedState.drained != nil
    defer:
      for index in 0 ..< sharedState.drainedCount:
        deallocShared(sharedState.drained[index].bytes)
      deallocShared(sharedState.drained)
      sharedState.drained = nil
      sharedState.drainedCount = 0
    initLock(sharedState.drainedLock)
    sharedState.producerDone.store(false, moRelease)
    var producer: Thread[void]
    var consumer: Thread[void]
    createThread(producer, producerThread)
    createThread(consumer, consumerThread)
    # Join through an independent descriptor containing only the immutable
    # exported OS handle; the running thread clears its own core/dataFn.
    joinThread(Thread[void](sys: producer.sys))
    sharedState.producerDone.store(true, moRelease)
    joinThread(Thread[void](sys: consumer.sys))
    deinitLock(sharedState.drainedLock)
    check sharedState.drainedCount == sharedState.iterations
    # FIFO per producer thread: msg-0, msg-1, ... msg-999.
    for i in 0 ..< sharedState.iterations:
      check drainedText(i) == "msg-" & $i

  test "test_injections_survive_producer_exit_with_caller_owned_snapshots":
    sharedState = ConcurrencyState(transport: newStubTransport(),
      sessionId: "retained-after-producer", iterations: 3)
    var producer: Thread[void]
    createThread(producer, producerThread)
    joinThread(Thread[void](sys: producer.sys))
    # All native queued storage was allocated by a producer that has exited.
    var first = sharedState.transport.peekQueuedInjections(sharedState.sessionId)
    check first.len == 3
    for index in 0 ..< first.len:
      check first[index].text == "msg-" & $index
    first[0].text[0] = 'X'
    let retained = sharedState.transport.takeQueuedInjections(sharedState.sessionId)
    check retained.len == 3
    for index in 0 ..< retained.len:
      check retained[index].text == "msg-" & $index
    check sharedState.transport.takeQueuedInjections(sharedState.sessionId).len == 0
    sharedState.transport.injectUserMessage("binary\0session", "")
    sharedState.transport.injectUserMessage("other", "keep")
    sharedState.transport.injectUserMessage("binary\0session", "a\0b")
    let binary = sharedState.transport.takeQueuedInjections("binary\0session")
    check binary.len == 2
    check binary[0].text == ""
    check binary[1].text == "a\0b"
    check sharedState.transport.takeQueuedInjections("other")[0].text == "keep"
    # Destruction must also safely release undrained producer-owned payloads.
    sharedState.transport = newStubTransport()
    createThread(producer, producerThread)
    joinThread(Thread[void](sys: producer.sys))
    let beforeDestroy = sharedState.transport.peekQueuedInjections(sharedState.sessionId)
    sharedState.transport = nil
    check beforeDestroy.len == 3
    for index in 0 ..< beforeDestroy.len:
      check beforeDestroy[index].text == "msg-" & $index

  test "test_inject_default_method_works_on_native_stdio_transport":
    ## :type:`NativeStdioAcpTransport` inherits the default queue
    ## methods unchanged — verify the dispatch resolves and FIFO
    ## semantics still hold for the concrete type.
    let transport = spawnFakeAcpAgent()
    try:
      transport.injectUserMessage("sid-native", "first")
      transport.injectUserMessage("sid-native", "second")
      let peek = transport.peekQueuedInjections("sid-native")
      check peek.len == 2
      check peek[0].text == "first"
      check peek[1].text == "second"
      # Native timestamps are populated.
      check peek[0].receivedAt > 0.0
      check peek[1].receivedAt >= peek[0].receivedAt
      let drained = transport.takeQueuedInjections("sid-native")
      check drained.len == 2
      check transport.peekQueuedInjections("sid-native").len == 0
    finally:
      transport.close()
