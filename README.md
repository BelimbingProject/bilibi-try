# Bilibi trial

This is the application for [try.bilibi.app](https://try.bilibi.app). It pins the Bilibi Platform and six public Domains: Commerce, Factory, Finance, People, People Connector and Supply Chain. The exact source commits and build dependencies are recorded in `setup.toml` and `composition/`.

## Run locally

```sh
git clone https://github.com/BelimbingProject/bilibi-try.git
cd bilibi-try
printf 'BILIBI_DEV_HOST=try-site.localhost\n' > .env
./bilibi start
```

Sign in at the HTTPS address printed by the launcher. The first start builds the app and prints the development credentials. To stop it from another terminal in this repository, run `./sources/platform/bilibi stop`.

## Release and install

Merge the checked setup record to `main`. An organization owner can then cut a `setup-vX.Y.Z` tag using the [release guide](docs/guides/releasing.md#release-your-setup). GitHub Actions builds the pinned application, publishes SHA-256 checksums and GitHub build provenance, and stages the assets in a draft. The organization owner verifies and publishes the immutable release.

Install the published archive, installer and verified server tools with the [Bilibi server installation guide](https://github.com/BelimbingProject/bilibi/blob/main/docs/server-install.md). The server runs the released binaries. Tenant and account data are entered on the installed server.

## Guides

- [Settings](docs/guides/settings.md): local addresses, databases and settings for each instance.
- [Running your application](docs/guides/running.md): requirements, workspace, commands and commit safeguards.
- [Releasing your application](docs/guides/releasing.md): build, check and release your application.
- [Installing a release](docs/guides/installing.md): put a tested release on Staging and Production.
- [Private sources](docs/guides/private-sources.md): give checks access to private repositories.
- [Taking maker updates](docs/guides/maker-updates.md): merge maker improvements and update older workspaces.
- [Application repositories](docs/guides/about.md): where changes belong and what the maker provides.
