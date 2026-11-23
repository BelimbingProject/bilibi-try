import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('nightly_sources', ROOT / 'scripts/nightly-sources.py')
nightly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nightly)


class NightlySourcesTest(unittest.TestCase):
    def test_verification_rejects_a_changed_repository(self):
        parent = '''format = 1
targets = ["x86_64-unknown-linux-gnu"]
[platform]
url = "https://github.com/example/reviewed.git"
commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'''
        setup = {'format': 1, 'targets': [nightly.recipe.TARGET],
                 'platform': {'url': 'https://github.com/example/other.git', 'commit': 'a' * 40}}
        sources = [('platform', setup['platform'])]
        with patch.object(sys, 'argv', ['nightly-sources.py', '--verify']), \
             patch.object(nightly.recipe, 'recipe', return_value=(setup, sources)), \
             patch.object(nightly.subprocess, 'check_output', return_value=parent):
            with self.assertRaisesRegex(ValueError, 'only change source commits'):
                nightly.main()

    def test_verification_rejects_a_commit_not_at_main(self):
        setup, sources = nightly.recipe.recipe()
        parent = (ROOT / 'setup.toml').read_text()
        def output(args, **kwargs):
            if args[:2] == ['git', 'show']:
                return parent
            return 'b' * 40 + '\trefs/heads/main\n'
        with patch.object(sys, 'argv', ['nightly-sources.py', '--verify']), \
             patch.object(nightly.recipe, 'recipe', return_value=(setup, sources)), \
             patch.object(nightly.subprocess, 'check_output', side_effect=output):
            with self.assertRaisesRegex(ValueError, 'main moved'):
                nightly.main()
