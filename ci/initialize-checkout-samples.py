"""Bind the initial checkout factory, then run the owning Git transition."""
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

from capture_original_git import capture, require, directory, read_creator_binding
from transition_initial_samples import transition

root = Path.cwd()
selected = Path(sys.argv[1]).resolve(strict=True)
creator_binding = Path(sys.argv[3]).resolve(strict=True) if sys.argv[2]=='--creator-binding' else None
if creator_binding:
    original = Path(read_creator_binding(creator_binding)['creator']).resolve(strict=True)
else:
    original = Path(sys.argv[2]).resolve(strict=True)
    require(Path(shutil.which('git')).resolve(strict=True) == original,
            'Original checkout Git selection changed before capture')
# This transition owns only untouched initial sample inventories. Existing
# managed/native/unknown hooks receive no admission here: the unchanged owning
# shell guard must authenticate or refuse them before any original CI gate.
for authority in (root, root/'.git', root/'.git/hooks'):
    directory(authority)
if any(not path.name.endswith('.sample') for path in (root/'.git/hooks').iterdir()):
    print(json.dumps({'transition': False, 'authority': 'deferred-to-unchanged-owning-hook-guard'}))
    sys.exit(0)
proof_directory = Path(tempfile.mkdtemp(prefix='nim-acp-checkout-factory-'))
require(stat.S_IMODE(proof_directory.lstat().st_mode) == 0o700,
        'Private capture directory mode differs')
receipt = proof_directory / 'initial-checkout.json'
capture(root, receipt, creator_binding)
result = transition(receipt, selected)
print(json.dumps({'capture': str(receipt), 'transition': result}))
