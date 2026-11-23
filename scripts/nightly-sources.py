#!/usr/bin/env python3
"""Select the current main commit of each source in the nightly recipe."""
import subprocess
import sys
import tomllib

import recipe
import workspace


def main():
    setup, sources = recipe.recipe()
    verify = sys.argv[1:] == ['--verify']
    if sys.argv[1:] not in ([], ['--verify']):
        raise ValueError('Use nightly-sources.py [--verify]')
    if verify:
        parent = tomllib.loads(subprocess.check_output(
            ['git', 'show', 'HEAD^:setup.toml'], cwd=recipe.ROOT, text=True))
        _, original = recipe.validate_recipe(parent)
        if [(path, {k: v for k, v in source.items() if k != 'commit'}) for path, source in sources] != [
                (path, {k: v for k, v in source.items() if k != 'commit'}) for path, source in original]:
            raise ValueError('A nightly may only change source commits in the reviewed recipe')
    for _, source in sources:
        result = subprocess.check_output(
            ['git', 'ls-remote', '--exit-code', source['url'], 'refs/heads/main'], text=True
        ).split()
        if len(result) != 2 or result[1] != 'refs/heads/main':
            raise ValueError(f"Could not identify main for {source['url']}")
        if verify and source['commit'] != result[0]:
            raise ValueError(f"{source['url']} main moved; prepare a fresh nightly")
        source['commit'] = result[0]
    setup.setdefault('domains', [])
    setup.setdefault('extensions', [])
    recipe.validate_recipe(setup)
    if not verify:
        (recipe.ROOT / 'setup.toml').write_text(workspace.serialize(setup))


if __name__ == '__main__':
    main()
