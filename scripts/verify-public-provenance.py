#!/usr/bin/env python3
"""Verify a public Bilibi release artifact against an independently trusted root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def fetch_bundle(url):
    if urlsplit(url).scheme != 'https':
        raise ValueError('GitHub returned a non-HTTPS bundle URL')
    try:
        from snappy import decompress
    except ImportError:
        raise ValueError('Install python3-snappy to read GitHub attestation bundles') from None
    with urlopen(url, timeout=30) as response:
        return json.loads(decompress(response.read()))


def write_bundles(destination, repository, digest):
    url = f'https://api.github.com/repos/{repository}/attestations/sha256:{digest}?per_page=100'
    with destination.open('w', encoding='utf-8') as output:
        while url:
            page = urlsplit(url)
            if page.scheme != 'https' or page.netloc != 'api.github.com':
                raise ValueError('GitHub returned an invalid attestation page URL')
            request = Request(url, headers={
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'bilibi-public-provenance',
                'X-GitHub-Api-Version': '2026-03-10',
            })
            with urlopen(request, timeout=30) as response:
                for attestation in json.load(response)['attestations']:
                    bundle = attestation.get('bundle')
                    if bundle is None:
                        bundle = fetch_bundle(attestation['bundle_url'])
                    output.write(json.dumps(bundle) + '\n')
                next_page = re.search(r'<([^>]+)>; rel="next"', response.headers.get('Link', ''))
                url = next_page[1] if next_page else None
    if not destination.stat().st_size:
        raise ValueError('GitHub returned no public attestation bundles')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--repo-id', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--trusted-root', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('Use owner/name for --repo')
    if not re.fullmatch(r'[1-9][0-9]*', args.repo_id):
        parser.error('Use the independently recorded GitHub repository number for --repo-id')
    if not re.fullmatch(r'(?:setup-v[0-9]+\.[0-9]+\.[0-9]+|nightly-[0-9]{4}-[0-9]{2}-[0-9]{2})', args.tag):
        parser.error('Use setup-vX.Y.Z or nightly-YYYY-MM-DD for --tag')
    if args.tag.startswith('nightly-') and (args.repo, args.repo_id) != ('BelimbingProject/bilibi-try', '1462459642'):
        parser.error('Nightlies must come from the trial repository')
    if not args.trusted_root.is_file():
        parser.error('Copy the Sigstore trusted root from a trusted workstation and supply --trusted-root')

    with args.artifact.open('rb') as artifact:
        digest = hashlib.file_digest(artifact, 'sha256').hexdigest()

    with tempfile.TemporaryDirectory(prefix='bilibi-public-provenance-') as scratch:
        bundle = Path(scratch) / 'bundles.jsonl'
        write_bundles(bundle, args.repo, digest)
        env = os.environ.copy()
        for key in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
            env.pop(key, None)
        env.update(GH_CONFIG_DIR=scratch, GH_PROMPT_DISABLED='1')
        verified = subprocess.run([
            'gh', 'attestation', 'verify', str(args.artifact.resolve()),
            '--repo', args.repo,
            '--signer-workflow', f'{args.repo}/.github/workflows/release.yml',
            '--source-ref', f'refs/tags/{args.tag}',
            '--bundle', str(bundle), '--custom-trusted-root', str(args.trusted_root),
            '--format', 'json',
            '--jq', '.[].verificationResult.signature.certificate.sourceRepositoryIdentifier',
        ], env=env, check=True, text=True, stdout=subprocess.PIPE)
    if set(verified.stdout.split()) != {args.repo_id}:
        raise ValueError('The verified attestation does not match the expected GitHub repository number')

    print(f'Verified {args.artifact.name} from {args.repo} at {args.tag}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Public release provenance could not be verified: {error}') from None
