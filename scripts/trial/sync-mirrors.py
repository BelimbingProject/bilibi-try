#!/usr/bin/env python3
"""Refresh the Try repository and every source named by its reviewed recipe."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib

ORG = 'https://github.com/BelimbingProject/'
TRY = 'bilibi-try'


def git(*args, cwd=None):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True,
                                   env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'},
                                   timeout=180)


def sources(record):
    setup = tomllib.loads(record)
    result = set()
    for entry in [setup['platform'], *setup.get('domains', []), *setup.get('extensions', [])]:
        match = re.fullmatch(re.escape(ORG) + r'([a-zA-Z0-9_-]+)\.git', entry['url'])
        if not match:
            raise ValueError(f"Source is outside the local mirror allowlist: {entry['url']}")
        result.add(match[1])
    return sorted(result - {TRY})


def refresh(root, name):
    dest = root / (name + '.git')
    url = ORG + name + '.git'
    for attempt in range(5):
        try:
            if dest.exists():
                if (dest.is_symlink() or git('rev-parse', '--is-bare-repository', cwd=dest).strip() != 'true'
                        or git('config', '--local', '--get', 'remote.origin.url', cwd=dest).strip() != url):
                    raise ValueError(f'{dest}: not the expected bare mirror')
                # Update all refs or none; do not prune the last usable refs on a failed fetch.
                git('fetch', '--atomic', '--no-auto-maintenance', 'origin', cwd=dest)
            else:
                with tempfile.TemporaryDirectory(prefix='.mirror-', dir=root) as temp:
                    staging = Path(temp) / 'mirror'
                    git('clone', '--mirror', '--', url, str(staging))
                    staging.rename(dest)
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print(f'{name}: fetch attempt {attempt + 1}/5 failed', file=sys.stderr, flush=True)
            if attempt < 4:
                time.sleep(10 * 2 ** attempt)
    print(f'{name}: refresh failed; any previous mirror remains available', file=sys.stderr)
    return False


def main():
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    ok = refresh(root, TRY)
    try:
        record = git('show', 'refs/heads/main:setup.toml', cwd=root / (TRY + '.git'))
    except (OSError, subprocess.SubprocessError):
        record = (Path(__file__).resolve().parents[2] / 'setup.toml').read_text()
    for name in sources(record):
        ok = refresh(root, name) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
