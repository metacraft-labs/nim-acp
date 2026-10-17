"""Read one exact Nix role from measured flat-v3 and wrapped-v4 JSON receipts.

Nix 2.34 wraps derivations and uses store basenames in typed path fields:
https://nix.dev/manual/nix/2.34/protocols/json/derivation/
Unknown formats and contradictory identities fail; receipt bytes stay unchanged.
"""

import json
from pathlib import Path
import re
import sys


_STORE_NAME = re.compile(r"[0123456789abcdfghijklmnpqrsvwxyz]{32}-[^/\s]+")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def store_name(path):
    require(isinstance(path, str) and path.startswith("/nix/store/"), "Expected absolute store path")
    name = path.removeprefix("/nix/store/")
    require(_STORE_NAME.fullmatch(name) is not None, "Malformed store path")
    return name


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON object key")
        result[key] = value
    return result


def read_derivation(receipt, expected_drv, expected_output, expected_system):
    """Return the retained body only after exact selected-role checks."""
    drv_name = store_name(expected_drv)
    require(drv_name.endswith(".drv"), "Expected derivation path")
    output_name = store_name(expected_output)
    require(expected_system in ("x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"), "Unsupported native system")
    with Path(receipt).open("rb") as stream:
        data = stream.read(16 * 1024 * 1024 + 1)
    require(len(data) <= 16 * 1024 * 1024, "Oversized derivation receipt")
    document = json.loads(data, object_pairs_hook=unique_object)
    require(isinstance(document, dict), "Derivation receipt must be an object")
    wrapped = "version" in document or "derivations" in document
    if wrapped:
        require(set(document) == {"version", "derivations"}, "Unknown derivation envelope fields")
        require(type(document["version"]) is int and document["version"] == 4, "Unsupported derivation envelope version")
        derivations = document["derivations"]
        require(isinstance(derivations, dict) and set(derivations) == {drv_name}, "Selected version-4 derivation identity mismatch")
        body = derivations[drv_name]
        require(isinstance(body, dict) and type(body.get("version")) is int and body["version"] == 4, "Unsupported derivation body version")
    else:
        require(set(document) in ({expected_drv}, {drv_name}), "Selected legacy derivation identity mismatch")
        body = next(iter(document.values()))
        require(isinstance(body, dict) and type(body.get("version")) is int and body["version"] == 3, "Unsupported flat derivation body version")
    require(body.get("system") == expected_system, "Derivation native system mismatch")
    outputs = body.get("outputs")
    require(isinstance(outputs, dict) and set(outputs) == {"out"}, "Expected exact single out role")
    output = outputs["out"]
    require(isinstance(output, dict) and set(output) == {"path"}, "Expected input-addressed output")
    require(output["path"] == output_name if wrapped else output["path"] in (expected_output, output_name), "Derivation output identity mismatch")
    require(isinstance(body.get("env"), dict), "Missing derivation environment")
    return body


def source_path(receipt, expected_drv, expected_output, expected_system):
    """Select the exact source; the caller still verifies its realized NAR."""
    source = read_derivation(receipt, expected_drv, expected_output, expected_system)["env"].get("src")
    store_name(source)
    return source


if __name__ == "__main__":
    require(len(sys.argv) == 5, "Expected receipt, exact drv, exact output and native system")
    print(source_path(*sys.argv[1:]))
