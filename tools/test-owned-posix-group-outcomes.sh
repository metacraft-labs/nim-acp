#!/usr/bin/env bash
set -euo pipefail
# Additive native controls; the original ACP suites remain required.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
output=$(mktemp -d "${TMPDIR:-/tmp}/acp-native-group-controls.XXXXXXXX")
trap 'rm -rf -- "$output"' EXIT
cc -std=c11 -Wall -Wextra -pthread -Isrc/nim_acp tests/native/owned_posix_group_outcome_control.c -o "$output/control"
status=0
"$output/control" unknown-mode || status=$?
[[ $status == 64 ]]
for mode in zombie live-term live-kill; do
  "$output/control" "$mode"
done
if [[ $(uname -s) == Darwin ]]; then
  # Only TERM/KILL denial is injected; the surviving process and final probes are real.
  "$output/control" denied-live-injected
fi
