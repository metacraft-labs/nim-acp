# nim-acp

ACP protocol model and deterministic test transports for Nim.

Commands:

- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:

- `src/nim_acp/types.nim`: protocol data types.
- `src/nim_acp/jsonrpc.nim`: JSON-RPC encoding, decoding, and newline framing helpers. A wire number read into an `int` goes through `wireInt32`, held to the 32-bit range `int` has under JS, never through std/json's `getInt` or `.int`, which raise a RangeDefect there on a wider value; a JSON-RPC `id` goes through `idText`, which keeps an integer id's full text, because an id is an identity that clamping would merge.
- `src/nim_acp/client.nim`: typed client operations over pluggable transports.
- `src/nim_acp/fake.nim`: deterministic fake ACP agent transport.

Do not import IsoNim Editor or CodeTracer modules here. Keep public APIs reusable by both.
