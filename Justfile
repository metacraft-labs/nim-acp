alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src"

# The injection queue is shared across threads, and its soundness depends on
# the memory manager: refc gives every thread a private heap, orc shares one.
# The toolchain's default is orc, but consumers build refc too (CodeTracer's
# `ct` binary does), so the threaded test runs under both, named explicitly.
# Each mm gets its own binary and nimcache: config.nims keys the nimcache by
# module, not by mm, so the two builds would otherwise share one directory.
inject-refc := "--mm:refc --threads:on -o:tests/test_inject_prompt_refc --nimcache:.nimcache/tests/test_inject_prompt_refc_d"
inject-orc := "--mm:orc --threads:on -o:tests/test_inject_prompt_orc --nimcache:.nimcache/tests/test_inject_prompt_orc_d"

build: build-native build-js

build-native:
    nim c {{paths}} tests/test_acp.nim
    nim c {{paths}} tests/test_session_load.nim
    nim c {{paths}} tests/test_send_with_stream.nim
    nim c {{inject-refc}} {{paths}} tests/test_inject_prompt.nim
    nim c {{inject-orc}} {{paths}} tests/test_inject_prompt.nim
    nim c {{paths}} tests/test_nimcache_is_worktree_local.nim

build-js:
    nim js {{paths}} tests/test_acp.nim
    nim js {{paths}} tests/test_session_load.nim

test: test-native test-js

test-native:
    nim c -r {{paths}} tests/test_acp.nim
    nim c -r {{paths}} tests/test_session_load.nim
    nim c -r {{paths}} tests/test_send_with_stream.nim
    nim c -r {{inject-refc}} {{paths}} tests/test_inject_prompt.nim
    nim c -r {{inject-orc}} {{paths}} tests/test_inject_prompt.nim
    nim c -r {{paths}} tests/test_nimcache_is_worktree_local.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_acp.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_session_load.nim

lint: lint-nim lint-nix

lint-nim:
    nim check {{paths}} tests/test_acp.nim
    nim check {{paths}} tests/test_session_load.nim
    nim check {{paths}} tests/test_send_with_stream.nim
    nim check --mm:refc --threads:on {{paths}} tests/test_inject_prompt.nim
    nim check --mm:orc --threads:on {{paths}} tests/test_inject_prompt.nim
    nim check {{paths}} tests/test_nimcache_is_worktree_local.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_acp.nim src/nim_acp/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_acp.nimble
    printf "%s\n" "{{version}}" > VERSION

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh
    bash tests/test_dev_shell_linked_worktree.sh
