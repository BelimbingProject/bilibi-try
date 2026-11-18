#!/usr/bin/env python3
"""Prove packaging determinism by repackaging the same checked program."""
from pathlib import Path
import subprocess
import sys
import tempfile

import recipe

from publish import verify_files

root = recipe.ROOT
before = verify_files(root / 'dist')
# Repackage directly under build/, which may be on a separate mount from dist/.
with tempfile.TemporaryDirectory(prefix='package-proof-', dir=recipe.BUILD) as temp:
    output = Path(temp) / 'dist'
    subprocess.run([sys.executable, str(root / 'scripts/package.py'), *sys.argv[1:],
                    '--output-dir', str(output)], check=True)
    if before != verify_files(output):
        raise ValueError('Packaging the same checked bytes produced different asset digests')
print('Repeated packaging produced identical SHA-256 values for all assets.')
print('This does not claim two clean compiler builds produce identical programs.')
