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
## concurrency promise.

when defined(js):
  {.error: "Inject-prompt tests are native-only.".}

import std/[atomics, os, times]
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
#  Concurrency-test scaffolding.  Producer threads share one transport
#  with one draining consumer thread.  Every thread waits on ``start``
#  so they hit the fresh transport together: that is what exercises
#  concurrent first use, when no queue exists yet.  The consumer keeps
#  draining until every producer has finished, then one final take
#  collects whatever landed after its previous take.
#
#  Threads reach the shared state through a ``ptr`` to an object on the
#  test's stack, so no thread copies the transport ``ref`` (that copy
#  would itself be a cross-thread reference-count update).  All
#  cross-thread signalling goes through atomics with explicit ordering.
# --------------------------------------------------------------------------- #

type
  Exchange = object
    transport: AcpTransport
    sessionId: string
    producers: int
    perProducer: int
    start: Atomic[bool]
    producersDone: Atomic[int]
    drained: seq[string]
      ## Written only by the consumer thread; read after it is joined.
  ProducerArgs = object
    exchange: ptr Exchange
    id: int

proc messageText(producers, id, i: int): string =
  ## A single producer sends ``msg-<i>``, as the original test did; with
  ## several, each message also names its producer.
  if producers == 1: "msg-" & $i
  else: "p" & $id & "-msg-" & $i

proc awaitStart(exchange: ptr Exchange) =
  while not exchange.start.load(moAcquire):
    cpuRelax()

proc producerThread(args: ProducerArgs) {.thread.} =
  let exchange = args.exchange
  awaitStart(exchange)
  # Method dispatch is not provably GC-safe to the compiler; these calls
  # only borrow the transport and touch no global state.
  {.cast(gcsafe).}:
    for i in 0 ..< exchange.perProducer:
      exchange.transport.injectUserMessage(exchange.sessionId,
        messageText(exchange.producers, args.id, i))
  discard exchange.producersDone.fetchAdd(1, moRelease)

proc consumerThread(exchange: ptr Exchange) {.thread.} =
  awaitStart(exchange)
  while true:
    # Read the completion count BEFORE draining.  The acquire load
    # pairs with each producer's release increment, so once it reports
    # every producer done, the take below sees all of their injections
    # and nothing can be left behind after the loop ends.
    let finished = exchange.producersDone.load(moAcquire) ==
      exchange.producers
    {.cast(gcsafe).}:
      for entry in exchange.transport.takeQueuedInjections(
          exchange.sessionId):
        exchange.drained.add entry.text
    if finished:
      break

proc runExchange(producers, perProducer: int): seq[string] =
  ## Run one exchange on a fresh transport and return everything the
  ## consumer drained, in drain order.
  var exchange = Exchange(transport: newStubTransport(),
    sessionId: "sid-concurrent", producers: producers,
    perProducer: perProducer)
  var producerThreads = newSeq[Thread[ProducerArgs]](producers)
  var consumer: Thread[ptr Exchange]
  for id in 0 ..< producers:
    createThread(producerThreads[id], producerThread,
      ProducerArgs(exchange: addr exchange, id: id))
  createThread(consumer, consumerThread, addr exchange)
  exchange.start.store(true, moRelease)
  joinThreads(producerThreads)
  joinThread(consumer)
  # Nothing may remain queued once the consumer has seen every producer
  # finish.
  doAssert exchange.transport.peekQueuedInjections(exchange.sessionId).len == 0
  exchange.drained

proc checkExchange(drained: seq[string]; producers, perProducer: int) =
  ## Every message arrives exactly once, and each producer's messages
  ## arrive in that producer's order.  The length check plus an exact
  ## per-producer subsequence leaves no room for a loss or a duplicate.
  check drained.len == producers * perProducer
  for id in 0 ..< producers:
    var next = 0
    for text in drained:
      if next < perProducer and text == messageText(producers, id, next):
        inc next
    check next == perProducer

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
    let drained = runExchange(producers = 1, perProducer = 1000)
    check drained.len == 1000
    # FIFO per producer thread: msg-0, msg-1, ... msg-999.
    for i in 0 ..< min(drained.len, 1000):
      check drained[i] == "msg-" & $i

  test "test_concurrent_inject_take_stress":
    ## The exchange above, repeated on fresh transports.  A single run
    ## of a racy queue passes often enough to hide the race; repeating
    ## it also exercises queue creation and destruction every round.
    for round in 0 ..< 25:
      checkExchange(runExchange(producers = 1, perProducer = 1000),
        producers = 1, perProducer = 1000)

  test "test_concurrent_first_use_keeps_every_message":
    ## Four producers inject into a transport that has no queue yet,
    ## released together, while a consumer drains.  If concurrent first
    ## use could build two queues, the injections that went into the
    ## discarded one would be lost.
    for round in 0 ..< 25:
      checkExchange(runExchange(producers = 4, perProducer = 250),
        producers = 4, perProducer = 250)

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
