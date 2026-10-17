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
nix build --no-link --json --no-update-lock-file "$ref#ci-cache-action-tools" > "$receipt/action-tools-build.json"
action_tools_drv="$(nix eval --raw --no-write-lock-file "$ref#ci-cache-action-tools.drvPath")"
printf '%s\n' "$action_tools_drv" > "$receipt/action-tools-declared-drv.txt"
action_tools_output="$("$python" -c 'import json,sys; from pathlib import Path; r=json.loads(Path(sys.argv[1]).read_text()); assert len(r)==1 and r[0]["drvPath"]==sys.argv[2]; out=r[0]["outputs"]["out"]; assert out.startswith("/nix/store/"); print(out)' "$receipt/action-tools-build.json" "$action_tools_drv")"
nix path-info --json --recursive "$action_tools_output" > "$receipt/action-tools-closure.json"
# Substituted paths may legitimately retain unknown-deriver in local metadata.
# Bind the actual build receipt to the exact declared role instead; a known
# contradictory observed deriver still fails below.
nix-store --query --deriver "$action_tools_output" > "$receipt/action-tools-observed-deriver.txt"
nix derivation show "$action_tools_drv" > "$receipt/action-tools-derivation.json"
for name in sed sort mktemp rm sleep; do test -x "$action_tools_output/bin/$name"; done
printf '%s/bin\n' "$action_tools_output" >> "$GITHUB_PATH"
nix build --no-link --json --no-update-lock-file "$ref#managed-hook-constructor" > "$receipt/package-raw.json"
package="$("$python" -c 'import json,sys; x=json.load(open(sys.argv[1])); assert len(x)==1; print(x[0]["outputs"]["out"])' "$receipt/package-raw.json")"
public_drv="$(nix eval --raw --no-write-lock-file 'github:metacraft-labs/reprobuild/064daf5b154ea6a0758ddb2dcbcbc07685216e44#reprobuild.drvPath')"
nix derivation show "$public_drv" > "$receipt/derivation-raw.json"
nix path-info --json --recursive "$package" > "$receipt/closure.json"
nix eval --impure --raw --expr builtins.currentSystem > "$receipt/nix-system.txt"
"$python" - "$receipt" "$package" "$public_drv" "$python_output" "$attic_output" "$action_tools_output" <<'PY'
import hashlib,json,os,platform,sys
from pathlib import Path
receipt,package,public_drv,python_output,attic_output,action_tools_output=sys.argv[1:];receipt=Path(receipt);package=Path(package)
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
action_tools=Path(action_tools_output);tool_images={}
action_closure=json.loads((receipt/'action-tools-closure.json').read_text())
action_rows=action_closure if isinstance(action_closure,list) else [dict(v,path=k) for k,v in action_closure.items()]
assert any(row['path']==str(action_tools) for row in action_rows)
action_drv=json.loads((receipt/'action-tools-derivation.json').read_text());assert len(action_drv)==1
declared_action_drv=(receipt/'action-tools-declared-drv.txt').read_text().strip()
assert declared_action_drv.startswith('/nix/store/') and declared_action_drv.endswith('.drv')
assert set(action_drv) in ({declared_action_drv},{Path(declared_action_drv).name})
action_build=json.loads((receipt/'action-tools-build.json').read_text());assert len(action_build)==1
assert action_build[0]['drvPath']==declared_action_drv and action_build[0]['outputs']['out']==str(action_tools)
observed_action_deriver=(receipt/'action-tools-observed-deriver.txt').read_text().strip()
assert observed_action_deriver in ('unknown-deriver',declared_action_drv), 'Contradictory action-tools deriver metadata'
action_derivation=next(iter(action_drv.values()))
assert action_derivation['system']==system and action_derivation['outputs']['out']['path']==str(action_tools)
for name in ('sed','sort','mktemp','rm','sleep'):
  executable=action_tools/'bin'/name;resolved=executable.resolve(strict=True)
  assert executable.is_file() and os.access(executable,os.X_OK) and str(resolved).startswith('/nix/store/')
  assert any(str(resolved).startswith(row['path']+'/') for row in action_rows)
  tool_images[name]={'selected':str(executable),'resolved':str(resolved),'SHA256':hashlib.sha256(resolved.read_bytes()).hexdigest()}
identity={'declaredFiniteActionTools':{'declaredDrvPath':declared_action_drv,'observedLocalDeriver':observed_action_deriver,'buildReceiptSHA256':hashlib.sha256((receipt/'action-tools-build.json').read_bytes()).hexdigest(),'output':str(action_tools),'images':tool_images,'closureSHA256':hashlib.sha256((receipt/'action-tools-closure.json').read_bytes()).hexdigest(),'derivationSHA256':hashlib.sha256((receipt/'action-tools-derivation.json').read_bytes()).hexdigest(),'publishedActionRevision':'d54ea9d8bc557f92d79382b97460c82e637ce667'},'publicCacheAuthority' :{'endpoint':os.environ['ACP_ATTIC_ENDPOINT'],'substituter':os.environ['ACP_ATTIC_SUBSTITUTER'],'cache':os.environ['ACP_ATTIC_CACHE'],'trustedPublicKey':os.environ['ACP_ATTIC_PUBLIC_KEY']},'scope':'Exact declared064 native constructor output/closure before supported finite cache push; no ACP test credit','source':node,'package':str(package),'drvPath':public_drv,'derivationSystem':derivation['system'],'kernelMachine':machine,'platform':sys.platform,'runnerOS':os.environ.get('RUNNER_OS'),'runnerArch':os.environ.get('RUNNER_ARCH'),'imagesSHA256':images,'pythonOutput':python_output,'atticOutput':attic_output,'atticExecutableSHA256':hashlib.sha256((Path(attic_output)/'bin/attic').read_bytes()).hexdigest(),'closureReceiptSHA256':hashlib.sha256((receipt/'closure.json').read_bytes()).hexdigest()}
(receipt/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
PY
"$package/bin/repro" --version > "$receipt/repro-version.txt"
