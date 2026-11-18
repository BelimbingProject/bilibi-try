# Installing a release

Install the same tested release on Staging and Production.

## First install on a public trial server

On a trusted workstation, get a current Sigstore trusted root with `gh attestation trusted-root > trusted-root.jsonl`. Copy that file and `scripts/verify-public-provenance.py` from this reviewed application checkout to the server separately from the release assets. The server needs Python 3.11 or newer, the Python Snappy package (`sudo apt install python3-snappy` on Ubuntu), and a current GitHub CLI from the [official package repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md). The CLI uses the transferred trust root and the public GitHub attestation bundles without a GitHub login.

Download the server tools, application archive and installer from the chosen GitHub release. Set `tag` to its exact setup tag. Verify the server tools before extracting them:

```sh
tag=setup-vX.Y.Z
python3 verify-public-provenance.py bilibi-server-tools.tar.gz \
  --repo BelimbingProject/bilibi-try --repo-id 1462459642 \
  --tag "$tag" --trusted-root trusted-root.jsonl
```

After verification succeeds, install the trusted root where the packaged installer reads it and extract the archive into an empty directory:

```sh
sudo install -D -m 0644 trusted-root.jsonl /etc/bilibi/attestation-trusted-root.jsonl
mkdir server-tools
tar -xzf bilibi-server-tools.tar.gz -C server-tools
```

Use the packaged `server-tools/scripts/install-server.sh` and follow the [Platform server installation guide](https://github.com/BelimbingProject/bilibi/blob/main/docs/server-install.md#the-short-version). Pass `--repo BelimbingProject/bilibi-try --repo-id 1462459642 --tag "$tag"` to both the `release` and `installer` commands. The trial's packaged tools verify each artifact against the same repository number, signing workflow, tag and trusted root.

## Install a release

Set the Software page's **GitHub repository** setting to your own application repository, for example `your-company/my-bilibi`. The server reads its releases from that repository.

Download the `bilibi-setup-v1.0.0-x86_64-unknown-linux-gnu.tar.gz` asset from your own repository. Download `SHA256SUMS` too. The server checks both the SHA-256 and GitHub build provenance from your repository's `.github/workflows/release.yml` before it unpacks the archive. A damaged file, a hand-uploaded replacement or an asset built by another workflow is refused and the running release stays in service.

On the target Bilibi instance, open **Software → Releases**, upload that archive, review it, and confirm the install with a fresh 2FA code. Keep the same downloaded archive for Staging and Production. The existing installer handles backup, migration, switching, health checks, recovery and Undo.

GitHub's automatic **Source code** archives are not installable releases. The separate `bilibi-installer-x86_64-unknown-linux-gnu` and `bilibi-server-tools.tar.gz` assets are for initial server setup or deliberate administrator upgrades. Verify each one with `gh attestation verify`, the application repository, its `.github/workflows/release.yml` and the exact setup tag before running it; the Platform server-installation reference gives the complete command. Ordinary application installs do not update the shared installer.

An uploaded file must carry valid GitHub build provenance too. Set and accept the application repository on the Software page before uploading; a private repository also needs its read token. If verification fails, download the asset from the release again or inspect the failed **Release setup** run. Do not bypass the check or rebuild on the server.

## Where to go next

[Settings](settings.md) explains each instance’s configuration. The Platform’s [server installation reference](https://github.com/BelimbingProject/bilibi/blob/main/docs/server-install.md) covers a fresh server and its [Software reference](https://github.com/BelimbingProject/bilibi/blob/main/apps/base/software/README.md) covers install and Undo.
