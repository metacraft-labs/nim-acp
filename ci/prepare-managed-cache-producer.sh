#!/usr/bin/env bash
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
own_root="$(git rev-parse --show-toplevel)"
own_sha="$(git rev-parse HEAD)"
test "$PWD" = "$own_root"
test "$own_sha" = "$GITHUB_SHA"
test -z "$(git status --porcelain=v1 --untracked-files=no)"
test "$ACP_ATTIC_CACHE" = metacraft-private-infrastructure
test "$ACP_ATTIC_ENDPOINT" = https://cache.metacraft-labs.com/
test "$ACP_ATTIC_SUBSTITUTER" = https://cache.metacraft-labs.com/metacraft-private-infrastructure
case "$ACP_ATTIC_PUBLIC_KEY" in metacraft-private-infrastructure:*) ;; *) exit 64 ;; esac
receipt="$(mktemp -d "$RUNNER_TEMP/acp-managed-constructor-cache.XXXXXXXXXX")"
printf 'receipt_path=%s\n' "$receipt" >> "$GITHUB_OUTPUT"
mkdir -m 700 "$receipt/private-config"
printf 'config_directory=%s\n' "$receipt/private-config" >> "$GITHUB_OUTPUT"
ref="git+file://$own_root?rev=$own_sha&shallow=1"
python_output="$(nix build --no-link --print-out-paths --no-update-lock-file "$ref#ci-receipt-python")"
python="$python_output/bin/python3"
test -x "$python"
printf 'python_executable=%s\n' "$python" >> "$GITHUB_OUTPUT"
attic_output="$(nix build --no-link --print-out-paths --no-update-lock-file "$ref#ci-attic-client")"
test -x "$attic_output/bin/attic"
printf 'attic_executable=%s/bin/attic\n' "$attic_output" >> "$GITHUB_OUTPUT"
printf '%s/bin\n' "$attic_output" >> "$GITHUB_PATH"
nix build --no-link --json --no-update-lock-file "$ref#managed-hook-constructor" > "$receipt/package-raw.json"
package="$("$python" -c 'import json,sys; x=json.load(open(sys.argv[1])); assert len(x)==1; print(x[0]["outputs"]["out"])' "$receipt/package-raw.json")"
public_drv="$(nix eval --raw --no-write-lock-file 'github:metacraft-labs/reprobuild/064daf5b154ea6a0758ddb2dcbcbc07685216e44#reprobuild.drvPath')"
nix derivation show "$public_drv" > "$receipt/derivation-raw.json"
nix path-info --json --recursive "$package" > "$receipt/closure.json"
nix eval --impure --raw --expr builtins.currentSystem > "$receipt/nix-system.txt"
"$python" - "$receipt" "$package" "$public_drv" "$python_output" "$attic_output" <<'PY'
import hashlib,json,os,platform,sys
from pathlib import Path
receipt,package,public_drv,python_output,attic_output=sys.argv[1:];receipt=Path(receipt);package=Path(package)
lock=json.loads(Path('flake.lock').read_text());node=lock['nodes'][lock['nodes'][lock['root']]['inputs']['managed-hook-reprobuild']]['locked']
assert node['owner']=='metacraft-labs' and node['repo']=='reprobuild' and node['rev']=='064daf5b154ea6a0758ddb2dcbcbc07685216e44'
built=json.loads((receipt/'package-raw.json').read_text());assert len(built)==1 and built[0]['drvPath']==public_drv and built[0]['outputs']['out']==str(package)
derivations=json.loads((receipt/'derivation-raw.json').read_text());assert len(derivations)==1;derivation=next(iter(derivations.values()))
machine=platform.machine();arch={'aarch64':'aarch64','arm64':'aarch64','x86_64':'x86_64'}.get(machine);assert arch,machine
system=arch+{'linux':'-linux','darwin':'-darwin'}[sys.platform]
assert (receipt/'nix-system.txt').read_text().strip()==system and derivation['system']==system
closure=json.loads((receipt/'closure.json').read_text());assert isinstance(closure,(list,dict)) and closure
closure_rows=closure if isinstance(closure,list) else [dict(v,path=k) for k,v in closure.items()]
assert any(row['path']==str(package) for row in closure_rows)
for row in closure_rows:
  path=Path(row['path']);assert path.is_absolute() and path.parent==Path('/nix/store') and '..' not in path.parts
  assert isinstance(row['narHash'],str) and row['narHash'] and isinstance(row['narSize'],int) and row['narSize']>=0
images={}
for name in ('repro','.repro-wrapped','.reprobuild-wrapped'):
  p=package/'bin'/name;assert p.is_file() and os.access(p,os.X_OK);images[name]=hashlib.sha256(p.read_bytes()).hexdigest()
engine=(package/'bin/.reprobuild-wrapped').read_bytes()
if sys.platform=='linux':
  assert engine[:6]==b'\x7fELF\x02\x01' and int.from_bytes(engine[18:20],'little')=={'aarch64':183,'x86_64':62}[arch]
else:
  assert engine[:4]==bytes.fromhex('cffaedfe') and int.from_bytes(engine[4:8],'little')=={'aarch64':0x0100000c,'x86_64':0x01000007}[arch]
identity={'publicCacheAuthority':{'endpoint':os.environ['ACP_ATTIC_ENDPOINT'],'substituter':os.environ['ACP_ATTIC_SUBSTITUTER'],'cache':os.environ['ACP_ATTIC_CACHE'],'trustedPublicKey':os.environ['ACP_ATTIC_PUBLIC_KEY']},'scope':'Exact declared064 native constructor output/closure before supported finite cache push; no ACP test credit','source':node,'package':str(package),'drvPath':public_drv,'derivationSystem':derivation['system'],'kernelMachine':machine,'platform':sys.platform,'runnerOS':os.environ.get('RUNNER_OS'),'runnerArch':os.environ.get('RUNNER_ARCH'),'imagesSHA256':images,'pythonOutput':python_output,'atticOutput':attic_output,'atticExecutableSHA256':hashlib.sha256((Path(attic_output)/'bin/attic').read_bytes()).hexdigest(),'closureReceiptSHA256':hashlib.sha256((receipt/'closure.json').read_bytes()).hexdigest()}
(receipt/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
PY
"$package/bin/repro" --version > "$receipt/repro-version.txt"
