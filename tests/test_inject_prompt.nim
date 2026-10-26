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
#  with one draining consumer, which is the main thread itself.  Every
#  thread waits on ``start`` so they hit the fresh transport together:
#  that is what exercises concurrent first use, when no queue exists
#  yet.  The consumer keeps draining until every producer has
#  finished, then one final take collects whatever landed after its
#  previous take.
#
#  The consumer runs on the main thread, not on a worker, so that the
#  ``drained`` seq it builds lives on the heap of the thread that reads
#  it afterwards.  Under ``--mm:refc`` every thread has a private heap
#  and a thread's heap pages are unmapped when it exits, so a seq
#  grown on a joined worker would be read from freed memory.  The
#  producers allocate only their own message strings, which the queue
#  copies into shared memory before the producer exits.
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

proc drainUntilProducersDone(exchange: ptr Exchange): seq[string] =
  ## The consumer loop, run on the calling (main) thread while the
  ## producers run on workers.  Returns everything drained, in drain
  ## order.
  while true:
    # Read the completion count BEFORE draining.  The acquire load
    # pairs with each producer's release increment, so once it reports
    # every producer done, the take below sees all of their injections
    # and nothing can be left behind after the loop ends.
    let finished = exchange.producersDone.load(moAcquire) ==
      exchange.producers
    for entry in exchange.transport.takeQueuedInjections(
        exchange.sessionId):
      result.add entry.text
    if finished:
      break

proc runExchange(producers, perProducer: int): seq[string] =
  ## Run one exchange on a fresh transport and return everything the
  ## consumer drained, in drain order.
  var exchange = Exchange(transport: newStubTransport(),
    sessionId: "sid-concurrent", producers: producers,
    perProducer: perProducer)
  var producerThreads = newSeq[Thread[ProducerArgs]](producers)
  for id in 0 ..< producers:
    createThread(producerThreads[id], producerThread,
      ProducerArgs(exchange: addr exchange, id: id))
  exchange.start.store(true, moRelease)
  result = drainUntilProducersDone(addr exchange)
  joinThreads(producerThreads)
  # Nothing may remain queued once the consumer has seen every producer
  # finish.
  doAssert exchange.transport.peekQueuedInjections(exchange.sessionId).len == 0

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
#  Exited-producer scaffolding.  A producer thread injects and then
#  EXITS before anyone takes.  Under ``--mm:refc`` a thread's heap pages
#  are unmapped when the thread exits (``deallocOsPages`` in
#  ``threadProcWrapStackFrame``), so a queue that kept anything on the
#  producer's heap -- a table bucket array, a key, a seq or string
#  buffer -- would hand the taker freed memory.  The texts are long
#  and distinct so a surviving but overwritten buffer cannot pass for
#  the original.
# --------------------------------------------------------------------------- #

type
  ExitedProducerArgs = object
    transport: ptr AcpTransport
    sessionId: ptr string
    id: int
    count: int

proc exitedProducerText(id, i: int): string =
  result = "exited-p" & $id & "-msg-" & $i & "-"
  for k in 0 ..< 64 + i mod 64:
    result.add char(ord('a') + (id + i + k) mod 26)

proc exitedProducerThread(args: ExitedProducerArgs) {.thread.} =
  # See ``producerThread`` on the cast.
  {.cast(gcsafe).}:
    for i in 0 ..< args.count:
      args.transport[].injectUserMessage(args.sessionId[],
        exitedProducerText(args.id, i))

proc injectFromExitedThread(transport: AcpTransport; sessionId: string;
    id, count: int) =
  ## Inject ``count`` messages from a fresh thread and return only once
  ## that thread has exited.
  var thread: Thread[ExitedProducerArgs]
  createThread(thread, exitedProducerThread, ExitedProducerArgs(
    transport: unsafeAddr transport, sessionId: unsafeAddr sessionId,
    id: id, count: count))
  joinThread(thread)

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

  test "test_injections_outlive_the_producer_thread":
    ## Two producer threads, each the only one to touch its session,
    ## inject and exit before the main thread looks.  The first of them
    ## is also the queue's first user, so it is the thread that creates
    ## the queue.  Every text must still read back intact, in order, and
    ## the queue must keep working for a later inject from the main
    ## thread into a session a dead thread created.
    const count = 200
    let transport = newStubTransport()
    injectFromExitedThread(transport, "sid-exited-a", id = 0, count = count)
    injectFromExitedThread(transport, "sid-exited-b", id = 1, count = count)
    # Churn the main thread's heap so memory a dead thread used to hold
    # is likely to be handed out again before the reads below.
    var churn: seq[string]
    for i in 0 ..< 2_000:
      churn.add exitedProducerText(7, i)
    let peeked = transport.peekQueuedInjections("sid-exited-a")
    check peeked.len == count
    for i in 0 ..< min(peeked.len, count):
      check peeked[i].text == exitedProducerText(0, i)
    transport.injectUserMessage("sid-exited-a", "from-main")
    let a = transport.takeQueuedInjections("sid-exited-a")
    check a.len == count + 1
    for i in 0 ..< min(a.len, count):
      check a[i].text == exitedProducerText(0, i)
    if a.len == count + 1:
      check a[count].text == "from-main"
    let b = transport.takeQueuedInjections("sid-exited-b")
    check b.len == count
    for i in 0 ..< min(b.len, count):
      check b[i].text == exitedProducerText(1, i)
    check transport.peekQueuedInjections("sid-exited-a").len == 0
    check transport.peekQueuedInjections("sid-exited-b").len == 0
    check churn.len == 2_000

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
