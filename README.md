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

The nightly is started daily at 06:00 Kuala Lumpur time by a dispatch from the operator's machine. The release workflow records the current `main` commits of the Platform and the Domains in `setup.toml`, then builds an immutable `nightly-YYYY-MM-DD` prerelease with the same asset provenance. It keeps seven published nightlies. The prerelease does not change the latest official release. Run the workflow manually on the default branch to prepare a nightly; if a tagged build needs retrying, dispatch the workflow on that tag. A date can be published only once.

Follow the [public server setup steps](docs/guides/installing.md#first-install-on-a-public-trial-server) to verify the published tools and install the released binaries. Tenant and account data are entered on the installed server.

## Set up trial companies

After installing the release, creating the installation owner and configuring [mail delivery](https://github.com/BelimbingProject/bilibi/blob/d0cd6bb6ad5b70aec79ff4bdfe41dd807dc1c7a9/apps/base/mail/README.md#choosing-the-transport), run this from the directory containing the verified `server-tools/` folder.

```sh
sudo server-tools/scripts/setup-trial-companies.sh production \
  'Company A' COMPA owner-a@example.com \
  'Company B' COMPB owner-b@example.com
```

Pass the company names, codes and owner emails at run time. Each company gets its own tenant and a primary company with the same name. Each owner must use a different email address that is unused by any staff sign-in. The owner accepts the invitation, chooses a password, and signs in with the Tenant Owner role.

The two companies are provisioned independently. If delivery fails for one company, rerun the command with only that company's three values and the same name and code. An expired or undelivered invitation can be reissued to the same or a different unused email before it is accepted. See the [Platform's first-owner guide](https://github.com/BelimbingProject/bilibi/blob/d0cd6bb6ad5b70aec79ff4bdfe41dd807dc1c7a9/docs/server-install.md#the-first-owner-of-a-customer-tenant).

## Guides

- [Settings](docs/guides/settings.md): local addresses, databases and settings for each instance.
- [Running your application](docs/guides/running.md): requirements, workspace, commands and commit safeguards.
- [Releasing your application](docs/guides/releasing.md): build, check and release your application.
- [Installing a release](docs/guides/installing.md): put a tested release on Staging and Production.
- [Private sources](docs/guides/private-sources.md): give checks access to private repositories.
- [Taking maker updates](docs/guides/maker-updates.md): merge maker improvements and update older workspaces.
- [Application repositories](docs/guides/about.md): where changes belong and what the maker provides.
