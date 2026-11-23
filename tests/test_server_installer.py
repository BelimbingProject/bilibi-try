import difflib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('package', ROOT / 'scripts/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ServerInstallerTest(unittest.TestCase):
    def test_only_reviewed_installer_variants_are_adapted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = root / 'scripts/server-tools'
            folder.mkdir(parents=True)
            original = 'before\nverify old\nafter\n'
            updated = 'before\nverify new\nafter\n'
            secure = 'before\nverify trial\nafter\n'
            for name, text in [('old', original), ('new', updated)]:
                (folder / f'public-provenance-{name}.patch').write_text(''.join(difflib.unified_diff(
                    text.splitlines(True), secure.splitlines(True), fromfile='a/script', tofile='b/script')))
            installer = root / 'installer'
            with patch.object(package.recipe, 'ROOT', root):
                for text in (original, updated):
                    installer.write_text(text)
                    self.assertEqual(package.public_server_installer(installer).decode(), secure)
                    self.assertEqual(installer.read_text(), text)
                installer.write_text('before\nunreviewed\nafter\n')
                with self.assertRaisesRegex(ValueError, 'exactly one reviewed'):
                    package.public_server_installer(installer)
                (folder / 'public-provenance-copy.patch').write_text(
                    (folder / 'public-provenance-old.patch').read_text())
                installer.write_text(original)
                with self.assertRaisesRegex(ValueError, 'exactly one reviewed'):
                    package.public_server_installer(installer)
