# Native concurrent injection and drain can crash

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-03 |
| Observed in | nim-acp @ `314e58407390e4e42264800f5377ae226851e1af` |
| Area | `src/nim_acp/client.nim` injection queue; `tests/test_inject_prompt.nim` |

## Observed

The unchanged `test_concurrent_inject_take_thread_safe` crashed under Nim
2.2.4, ORC and native threads. The original full `just test` exited 1 after
23 native passing outcomes; this test and the JS half did not complete.
Its producer injects 1,000 messages while another thread drains the same
transport, then checks the complete union and exact FIFO order.

The concurrent traces report:

```text
producerThread → injectUserMessage
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
consumerThread → takeQueuedInjections → tables.hasKey → hashcommon.rawGet
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
```

One isolated diagnostic importing pristine committed ACP source reproduced
these traces, exit -11. It preserved the original concurrency helpers,
1,000-message count and all union/FIFO assertions, compiling with ORC and
threads plus address-sanitizer/frame-pointer instrumentation. Nim's signal
handler intercepted the fault; no ASan memory-error report identified the
crashing interleaving. This reproduction imports no IsoNim source.

## Expected

The public documentation of `injectUserMessage`, `takeQueuedInjections` and
`peekQueuedInjections` in [client.nim](../src/nim_acp/client.nim) promises
native thread safety, FIFO delivery and an atomic drain. The original
[test](../tests/test_inject_prompt.nim),
`test_concurrent_inject_take_thread_safe`, should finish without a crash and
retain every injected message exactly once, in producer order.

A stronger formal threading specification is **Not specified. Proposed:**
define safe concurrent first use, reference lifetime and completion signalling
before choosing a synchronization design. The related consumer specification,
`isonim-specs/spec/isonim-editor.md`, section “Library hook: injectPrompt”,
requires pending input to survive until a turn boundary; it is not the owner
of this library defect.

## Evidence

From a workspace with this exact ACP revision and the normal Repro development
environment, run the original target (no test filtering or modified memory
manager):

```sh
cd nim-acp
repro exec -- just test
```

The measured full invocation used Repro 0.1.4 and exited 1 in 17.566057s.
This is a concurrency failure, so a passing invocation alone does not disprove
it. Do not ignore the test, reduce its 1,000 messages or replace FIFO assertions.
Local sealed evidence: `/tmp/eac-m7-login-guidance-review/HANDOFF.md` and
`/tmp/eac-m7-acp-injection-investigation/HANDOFF.md`; the original repository
test above is the durable reproduction, rather than those temporary files.

Before filing, fetched the manifest-declared mainline `dev` at
`adefc2177f8fc76ad1e80f6e9501a818fe518d3d` into an isolated worktree. Its
complete injection-queue region and entire injection test are byte-identical
to the measured revision; unrelated launch arguments/session metadata differ.
**No fresh mainline test execution is claimed.** No matching open or deleted
issue, upstream-bug, status or milestone record exists in the searched owning
repository history; this is its first `issues/` record.

## Suggested direction

Unsynchronized lazy queue publication is visible in `ensureInjectionQueue`.
Generated C from the measured ORC build acquires/releases managed queue
references outside the payload lock, with non-atomic reference-count updates.
The test also reads/writes `producerDone` without synchronization. These are
observed unsafe boundaries and distinct hypotheses, not proof of the specific
crashing interleaving. Investigate publication, lifetime and test signalling;
preserve and strengthen the original integration assertions in a separately
reviewed correction.

## Related

IsoNim's chat selects nim-agents `abkHarbor` and the Harbor REST API;
`injectPrompt`, `takeQueuedInjections` and `peekQueuedInjections` reject that
backend. The crash independently reproduces without the editor UI and remains
an unresolved ACP suite failure, not an all-suite-green exception.
