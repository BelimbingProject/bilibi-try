"""Proof of the trial nightly updater's install and rollback paths.

A disposable copy of the script runs against fake commands, fake server tools
and a real tools archive, so each path is exercised end to end: a healthy
install, a failed install that rolls back, a rollback with the previous
release's tools, and a rollback without them.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / 'scripts/trial/bilibi-try-nightly.sh').read_text()

NEW_INSTALLER = '''#!/usr/bin/env bash
set -e
echo "new $*" >> "$MOCK_LOG"
case $1 in
    trust) exit 0 ;;
    release)
        [[ ${FAIL_RELEASE:-0} != 1 ]] || exit 1
        mkdir -p "$MOCK_RELEASES/3"
        printf '{\"setup\":{\"tag\":\"nightly-2026-11-25\"}}\n' > "$MOCK_RELEASES/3/release.json"
        ln -sfn 3 "$MOCK_RELEASES/current" ;;
    switch) exit 1 ;;
esac
'''
# The release in service was installed before the installer interface changed:
# it has no trust command, and its switch knows only the accounts it made.
OLD_INSTALLER = '''#!/usr/bin/env bash
set -e
echo "old $*" >> "$MOCK_LOG"
[[ $1 == switch ]] || exit 2
ln -sfn "$3" "$MOCK_RELEASES/current"
'''
PROOF_HELPER = '''import sys
if sys.argv[1] == 'trust-values':
    print('github'); print('BelimbingProject/bilibi-try'); print('1462459642')
    print('BelimbingProject/bilibi-try/.github/workflows/release.yml'); print('setup-v0.1.3')
elif sys.argv[1] == 'make-trust':
    open(sys.argv[sys.argv.index('--output') + 1], 'w').write('{}')
sys.exit(0)
'''


def tools_archive(path, installer):
    with tarfile.open(path, 'w:gz') as archive:
        for name, text, mode in [('scripts/install-server.sh', installer, 0o755),
                                ('scripts/lib/versions.sh', '#!/usr/bin/env bash\n', 0o644),
                                ('scripts/lib/release-proof.py', PROOF_HELPER, 0o644)]:
            data = text.encode()
            header = tarfile.TarInfo(name)
            header.size = len(data)
            header.mode = mode
            archive.addfile(header, io.BytesIO(data))


def instance_release(root, number):
    return root / 'instance/releases' / str(number)


class TrialNightlyTest(unittest.TestCase):
    def run_script(self, mode, *, previous_tools=True, trust_policy=False):
        self.root = Path(tempfile.mkdtemp(prefix='trial-nightly-'))
        root = self.root
        for name in ('state/downloads', 'state/tools', 'bin', 'backups', 'log'):
            (root / name).mkdir(parents=True)
        instance = root / 'instance'
        (instance / 'releases').mkdir(parents=True)
        (instance / 'env').write_text('APP_ORIGIN=https://try.bilibi.app\n')
        for number, tag in [(1, 'setup-v0.1.2'), (2, 'nightly-2026-11-24')]:
            folder = instance / 'releases' / str(number)
            folder.mkdir()
            (folder / 'bilibi-web').write_text('test')
            (folder / 'bilibi-web').chmod(0o755)
            (folder / 'release.json').write_text(json.dumps({'setup': {'tag': tag}}))
        (instance / 'releases' / 'current').symlink_to('2')
        (instance / 'current').symlink_to('releases/current')
        if trust_policy:
            (instance / 'trust').mkdir()
            (instance / 'trust/release.json').write_text('{}')
        # The tools of the release in service, kept from an earlier update.
        old = root / 'state/tools/nightly-2026-11-24-old'
        (old / 'scripts/lib').mkdir(parents=True)
        (old / 'scripts/install-server.sh').write_text(OLD_INSTALLER)
        (old / 'scripts/install-server.sh').chmod(0o755)
        (old / 'scripts/lib/release-proof.py').write_text(PROOF_HELPER)
        if previous_tools:
            (root / 'state/in-service-tools').write_text(str(old))
        binary = root / 'bin'
        fakes = {
            'pg_lsclusters': "echo '18 main 5432 online postgres x y'",
            'systemctl': 'exit 0',
            'chown': ':',
            'curl': '''if [[ $* == *releases/download* ]]; then while (($#)); do if [[ $1 == -o ]]; then
  if [[ $2 == *server-tools* ]]; then cp "$MOCK_TOOLS_ARCHIVE" "$2"; else printf asset > "$2"; fi
  break; fi; shift; done
else echo "${HEALTH_CODE:-200}"; fi''',
            'runuser': '''while (($#)) && [[ $1 == -* || $1 == postgres || $1 == -- ]]; do shift; done
case $1 in
 psql) if [[ $* == *string_agg* ]]; then echo
       elif [[ $* == *'count(*)'* ]]; then echo 0
       else echo "psql" >> "$MOCK_LOG"; fi ;;
 pg_dump) while (($#)); do if [[ $1 == --file ]]; then printf dump > "$2"; break; fi; shift; done ;;
 pg_restore) echo "pg_restore $*" >> "$MOCK_LOG" ;;
 *) exit 1 ;;
esac''',
        }
        for name, body in fakes.items():
            path = binary / name
            path.write_text('#!/usr/bin/env bash\nset -e\n' + body + '\n')
            path.chmod(0o755)
        # The new release's server tools, downloaded by the script.
        archive = root / 'prepared-server-tools.tar.gz'
        tools_archive(archive, NEW_INSTALLER)
        script = SOURCE.replace("[[ ${EUID} == 0 ]] || { echo 'Run as root' >&2; exit 1; }", ':')
        # The server pins PATH; the proof needs its fake commands first.
        script = script.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin', f'export PATH={binary}:/usr/bin:/bin')
        script = script.replace('install -d -m 0700 -o postgres -g postgres "$backups"', 'install -d -m 0700 "$backups"')
        # Do not wait out the real health-check retry loop in the proof.
        script = script.replace('for try in {1..18}; do', 'for try in {1..2}; do').replace('        sleep 5\n', '        sleep 0\n')
        (root / 'guest.sh').write_text(script)
        env = {**os.environ, 'MOCK_LOG': str(root / 'log/calls'), 'MOCK_RELEASES': str(instance / 'releases'),
               'MOCK_TOOLS_ARCHIVE': str(archive), 'PATH': f'{binary}:/usr/bin:/bin', 'BILIBI_TRIAL_STATE': str(root / 'state'),
               'BILIBI_TRIAL_VERIFIER': str(root / 'verifier.py'), 'BILIBI_TRIAL_INSTANCE_DIR': str(instance),
               'BILIBI_TRIAL_BACKUPS': str(root / 'backups'), 'BILIBI_TRIAL_TRUSTED_ROOT': str(root / 'root.jsonl'),
               'BILIBI_TRIAL_PUBLIC_URL': 'https://try.bilibi.app',
               'FAIL_RELEASE': '1' if mode == 'install_failure' else '0',
               'HEALTH_CODE': '500' if mode == 'health_failure' else '200'}
        (root / 'verifier.py').write_text('raise SystemExit(0)\n')
        result = subprocess.run(['bash', str(root / 'guest.sh'), 'nightly-2026-11-25'],
                                env=env, text=True, capture_output=True)
        calls = (root / 'log/calls').read_text() if (root / 'log/calls').exists() else ''
        transaction = root / 'state/transaction'
        current = os.readlink(instance / 'releases/current') if (instance / 'releases/current').is_symlink() else None
        return result, calls, transaction, current

    def test_healthy_install(self):
        result, calls, transaction, current = self.run_script('healthy')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('new release production', calls)
        self.assertFalse(transaction.exists())
        self.assertEqual(current, '3')
        self.assertEqual(json.loads((instance_release(self.root, 3) / 'release.json').read_text())['setup']['tag'],
                         'nightly-2026-11-25')
        self.assertEqual((self.root / 'state/in-service-tools').read_text().strip(),
                         str(next((self.root / 'state/tools').iterdir())))

    def test_failed_install_rolls_back_with_the_previous_tools(self):
        result, calls, transaction, current = self.run_script('install_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pg_restore', calls)
        self.assertIn('old switch production 2', calls)
        self.assertNotIn('new switch', calls)
        self.assertEqual(current, '2')
        self.assertFalse(transaction.exists())

    def test_failed_health_check_rolls_back(self):
        result, calls, transaction, current = self.run_script('health_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('old switch production 2', calls)
        self.assertFalse(transaction.exists())

    def test_rollback_without_previous_tools_moves_the_link(self):
        result, calls, transaction, current = self.run_script('install_failure', previous_tools=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('old switch', calls)
        self.assertEqual(current, '2')
        self.assertFalse(transaction.exists())

    def test_existing_trust_is_kept(self):
        result, calls, transaction, current = self.run_script('healthy', trust_policy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('new trust', calls)
        self.assertIn('new release production', calls)


if __name__ == '__main__':
    unittest.main()
