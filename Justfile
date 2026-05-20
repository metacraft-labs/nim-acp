alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src"

build: build-native build-js

build-native:
    nim c {{paths}} tests/test_acp.nim
    nim c {{paths}} tests/test_send_with_stream.nim
    nim c --threads:on {{paths}} tests/test_inject_prompt.nim

build-js:
    nim js {{paths}} tests/test_acp.nim

test: test-native test-js

test-native:
    nim c -r {{paths}} tests/test_acp.nim
    nim c -r {{paths}} tests/test_send_with_stream.nim
    nim c -r --threads:on {{paths}} tests/test_inject_prompt.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_acp.nim

lint: lint-nim lint-nix

lint-nim:
    nim check {{paths}} tests/test_acp.nim
    nim check {{paths}} tests/test_send_with_stream.nim
    nim check --threads:on {{paths}} tests/test_inject_prompt.nim

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
