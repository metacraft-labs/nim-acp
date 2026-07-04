## Reprobuild project file for nim-acp.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** ``nim-acp`` is a
## pure-Nim leaf library — the Agent Client Protocol (ACP) data model,
## JSON-RPC framing, typed client, and deterministic fake / native-stdio
## transports. Its ``src/`` tree imports only the Nim stdlib and its own
## submodules (``src/nim_acp/{types,jsonrpc,client,fake}.nim`` under the
## ``src/nim_acp.nim`` umbrella); nothing under ``src/`` or ``tests/``
## imports a workspace sibling. The ``--path:../nim-everywhere/src`` that
## the repo's ``Justfile`` passes is the patched-Nim distribution's own
## stdlib search root (part of the toolchain floor), not a build
## dependency on the ``nim-everywhere`` *repo* — no nim-acp module
## resolves a symbol from it. So the ``uses:`` block is just the
## toolchain floor and there is no ``uses: "<sibling>"`` edge.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` /
## ``codetracer-trace-format-nim/repro.nim`` /
## ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the toolchain floor via ``uses:`` so consumers that depend
##   on this repo (via ``uses: "nim_acp"``) pick up the same floor the
##   nimble file's ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library nim_acp`` — the importable surface is the
##   ``src/`` tree the ``Justfile`` puts on ``--path`` (``--path:src``).
##   Consumers ``import nim_acp`` (the umbrella at ``src/nim_acp.nim``)
##   or the submodules under ``src/nim_acp/`` directly.
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template", exactly as reprobuild's own ``repro.nim`` does
##   it. The BUILD halves collect into ``test-builds`` and the EXECUTE
##   halves into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure.
##
## **``--path:src``.** nim-acp has NO ``config.nims`` / ``nim.cfg`` — the
## module search path (``--path:src``) is supplied by the repo's
## ``Justfile`` (``paths := "--path:src ..."``), not a repo-local Nim
## config. A bare ``nim c tests/test_acp.nim`` therefore fails with
## ``cannot open file: nim_acp``. So every BUILD edge below passes
## ``paths = @["src"]`` explicitly, which ``buildNimUnittest.build``
## forwards as ``--path:src`` (mirroring the ``nim.c`` typed-tool's
## ``paths`` flag). ``src`` is also declared as an ``extraInput`` so the
## engine's monitor tracks the transitively imported ``src/nim_acp/``
## modules and rebuilds when any of them change.
##
## **Per-test platform gating.** All three test files run on this Linux
## host; the corpus mirrors what the repo's own ``just test-native``
## would run:
##
##   * ``test_acp.nim`` — imports ``std/json``, ``unittest``, ``nim_acp``.
##     No OS gate; exercises the in-memory ``newFakeAcpTransport`` and the
##     typed client. Portable native test; runs everywhere. (The repo
##     also compiles it under ``nim js`` in ``just build-js``, but the
##     two-edge template compiles the native binary — the same native
##     ``nim c -r`` the ``test-native`` task runs.)
##   * ``test_inject_prompt.nim`` — opens with
##     ``when defined(js): {.error: "Inject-prompt tests are
##     native-only.".}``; imports ``std/[os, times, locks]`` and spawns a
##     POSIX ``/bin/sh`` child (``execShellCmd`` / ``getTempDir``), and
##     uses ``createThread``/``joinThread`` (the repo compiles it
##     ``--threads:on``). Native + threaded; runs on this Linux host.
##   * ``test_send_with_stream.nim`` — no ``when defined`` gate, but
##     drives a ``NativeStdioAcpTransport`` (defined ``when not
##     defined(js)`` in ``src/nim_acp/client.nim``) against a POSIX
##     ``/bin/sh`` child that ``printf``s a scripted JSON-RPC stream
##     (``read``/``printf``/``sleep``). Native/POSIX; runs on this Linux
##     host.
##
## None of the three is Windows- or macOS-only, so all three keep a
## runnable edge on Linux. ``buildNimUnittest.build`` defaults
## ``threadsOn = true``, so every binary compiles ``--threads:on`` (the
## Justfile only spells it out for ``test_inject_prompt``; it is harmless
## for the other two).
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on
## ``PATH``, so the weak-local PATH resolver is the right default.
## Without it ``repro build`` refuses to run with "typed tool
## provisioning is required for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed tool used by every test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
import ct_test_nim_unittest

type
  AcpTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

const portableTestSpecs: seq[AcpTestSpec] = @[
  # All three tests compile + run to exit 0 on this Linux host (native).
  # ``test_acp`` has no OS gate; ``test_inject_prompt`` is native-only
  # (``when defined(js): {.error.}``) and threaded; ``test_send_with_stream``
  # drives the native-only POSIX stdio transport. None is Win/macOS-only.
  AcpTestSpec(source: "tests/test_acp.nim",
    binary: "build/test-bin/test_acp"),
  AcpTestSpec(source: "tests/test_inject_prompt.nim",
    binary: "build/test-bin/test_inject_prompt"),
  AcpTestSpec(source: "tests/test_send_with_stream.nim",
    binary: "build/test-bin/test_send_with_stream"),
]

package nim_acp:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below); ``gcc`` is the C back-end ``nim c`` shells out to.
    # Mirrors the nimble file's ``requires "nim >= 2.0.0"`` (the nix dev
    # shell supplies Nim 2.2.x).
    "nim >=2.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree the ``Justfile`` puts on
  # ``--path`` is importable when this package is consumed via
  # ``uses: "nim_acp"``. The umbrella is ``src/nim_acp.nim``; consumers
  # may also import the submodules under ``src/nim_acp/`` directly.
  library nim_acp

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per test file. BUILD
    # halves collect into ``test-builds`` (compile-only verification);
    # EXECUTE halves collect into ``test`` so ``repro test`` /
    # ``repro build test`` materialise the runnable closure (each execute
    # edge transitively depends on its build edge).
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      # ``paths = @["src"]`` supplies the ``--path:src`` the repo's
      # ``Justfile`` passes (nim-acp has no ``config.nims``); ``src`` is
      # an ``extraInput`` so the monitor tracks the transitively imported
      # ``src/nim_acp/`` modules.
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = @["src"],
        actionId = "nim_acp.test_build." & stem,
        extraInputs = @["src", "nim_acp.nimble"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already
      # owns the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (mirrors reprobuild's
      # ``repro.nim`` two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "nim_acp.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in portableTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
