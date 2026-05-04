#!/usr/bin/env bash
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
nim js -r "$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"
set -e

if grep -Eq '\[(FAILED|ABORTED)\]|AssertionDefect|Check failed|Test failed|FAILED:' "$log"; then
  echo "nim_js_test_gate_failed: failing unittest sentinel found" >&2
  exit 1
fi

if [[ "$status" -ne 0 ]]; then
  echo "nim_js_test_gate_failed: nim js exited with $status" >&2
  exit "$status"
fi

if ! grep -Eq '\[OK\]' "$log"; then
  echo "nim_js_test_gate_failed: no passing unittest sentinel found" >&2
  exit 1
fi

echo "nim_js_test_gate_ok"
