#!/usr/bin/env bash
# Install one nightly release of this trial on the trial server.
#
#   bilibi-try-nightly.sh nightly-YYYY-MM-DD
#
# Runs as root from bilibi-try-nightly.service on the trial server. The
# omar-side host script chooses the tag and calls this; it never picks a
# release itself. It is installed at /usr/local/sbin/bilibi-try-nightly beside
# the verifier at /usr/local/lib/bilibi-try-nightly/verify-public-provenance.py.
#
# Two rules shape this script:
#   1. The Platform installer interface changes between releases, so the
#      installer to use is the one in the archive being installed, never an
#      assumed command shape. The trial server's release in service may have
#      been installed by an older installer than the new archive's.
#   2. A rollback must bring the site back. It restores the database first,
#      then switches the program with the previous release's own tools when
#      they were kept, or with one link move as root. It never uses the new
#      release's installer: that one may name accounts the old install never
#      created (the 2026-11-26 failure: "user bilibi-w-... does not exist").
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ ${EUID} == 0 ]] || { echo 'Run as root' >&2; exit 1; }

# Each path can be overridden for a proof on a disposable copy; the defaults
# are the server's.
state=${BILIBI_TRIAL_STATE:-/var/lib/bilibi-try-nightly}
verifier=${BILIBI_TRIAL_VERIFIER:-/usr/local/lib/bilibi-try-nightly/verify-public-provenance.py}
instance_dir=${BILIBI_TRIAL_INSTANCE_DIR:-/opt/bilibi/production}
instance=${BILIBI_TRIAL_INSTANCE:-production}
database=${BILIBI_TRIAL_DATABASE:-bilibi_production}
repository=BelimbingProject/bilibi-try
repository_id=1462459642
backups=${BILIBI_TRIAL_BACKUPS:-/var/lib/postgresql/bilibi-try-nightly}
trusted_root=${BILIBI_TRIAL_TRUSTED_ROOT:-/etc/bilibi/attestation-trusted-root.jsonl}
public_url=${BILIBI_TRIAL_PUBLIC_URL:-}

log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

tag=${1:-}
[[ $tag =~ ^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 'Usage: bilibi-try-nightly.sh nightly-YYYY-MM-DD'

install -d -m 0700 "$state" "$state/downloads" "$state/tools"
install -d -m 0700 -o postgres -g postgres "$backups"
exec 9>"$state/lock"
flock -n 9 || die 'Another nightly update is running'
pgport=$(pg_lsclusters -h | awk '$1 == 18 && $2 == "main" {print $3}')
[[ $pgport =~ ^[0-9]+$ ]] || die 'PostgreSQL 18 main cluster not found'

# ---------------------------------------------------------------- instance
current_release() {
    local target
    target=$(readlink -f "$instance_dir/current" 2>/dev/null) || return 0
    [[ -n $target && -d $target ]] || return 0
    basename "$target"
}
release_tag() {
    python3 - "$instance_dir/releases/$1/release.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["setup"]["tag"])
except (OSError, KeyError, ValueError):
    pass
PY
}
app_origin() {
    if [[ -n $public_url ]]; then printf '%s' "$public_url"; return; fi
    sed -n 's/^APP_ORIGIN=//p' "$instance_dir/env" | head -n1
}
# answers: the site's public sign-in page answers over its own HTTPS route.
answers() {
    local origin=$1 try
    for try in {1..18}; do
        [[ $(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$origin/login" 2>/dev/null) == 200 ]] && return 0
        sleep 5
    done
    return 1
}

# ---------------------------------------------------------------- database
# Empty the database before a restore. One DROP SCHEMA of a full database
# exceeds max_locks_per_transaction, so drop tables in batches first.
clear_public_schema() {
    local batch
    while :; do
        batch=$(runuser -u postgres -- psql -p "$pgport" -d "$database" -X -qAt -v ON_ERROR_STOP=1 -c \
            "SELECT string_agg(format('%I.%I', schemaname, tablename), ',') FROM (SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'public' LIMIT 40) t" 2>/dev/null) || return 1
        [[ -n $batch ]] || break
        runuser -u postgres -- psql -p "$pgport" -d "$database" -X -q -v ON_ERROR_STOP=1 -c \
            "SET ROLE $database; DROP TABLE IF EXISTS $batch CASCADE;" >/dev/null 2>&1 || return 1
    done
    runuser -u postgres -- psql -p "$pgport" -d "$database" -X -q -v ON_ERROR_STOP=1 -c \
        'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;' >/dev/null 2>&1
}

# ---------------------------------------------------------------- rollback
# The transaction file holds: previous release, dump, dump checksum and the
# tools folder of the release in service (empty when there is none).
restore_backup() {
    local previous archive expected actual
    [[ -f $state/transaction ]] || return 0
    readarray -t txn <"$state/transaction"
    previous=${txn[0]:-}; archive=${txn[1]:-}; expected=${txn[2]:-}; previous_tools=${txn[3]:-}
    [[ $previous =~ ^[0-9]+$ && $archive == "$backups"/nightly-*/*.dump && $expected =~ ^[0-9a-f]{64}$ && -f $archive ]] ||
        { log 'Invalid rollback record; services need administrator attention'; return 1; }
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] || { log 'Backup checksum failed; services need administrator attention'; return 1; }
    systemctl stop "bilibi-installer@$instance" || true
    systemctl stop "bilibi@$instance" || return 1
    clear_public_schema || { log 'Clearing the database for restore failed'; return 1; }
    runuser -u postgres -- pg_restore -p "$pgport" --role="$database" --no-owner --no-privileges \
        --exit-on-error --dbname "$database" "$archive" >/dev/null 2>&1 ||
        { log 'Database restore failed'; return 1; }
    log "Restored the database from $archive"
}
# switch_back <release number>: the previous release's tools when they are
# kept, otherwise one link move as root (root may write releases/ whatever its
# owner) and a start. Never the new release's installer.
switch_back() {
    local previous=$1 tools=${previous_tools:-}
    # An older transaction format kept the NEW release's tools in this field;
    # only a folder under our own tools directory is a release's own tools.
    [[ -z $tools || $tools == "$state"/tools/* ]] || tools=''
    [[ -n $tools ]] || tools=$(in_service_tools)
    if [[ -n $tools && -x $tools/scripts/install-server.sh ]]; then
        "$tools/scripts/install-server.sh" switch "$instance" "$previous" >"$state/last-switch.log" 2>&1 && {
            log "Switched back with release $previous's installer"; return 0; }
        log "Release $previous's installer could not switch back; moving the link directly"
    fi
    {
        systemctl stop "bilibi@$instance" || true
        ln -sfn "$previous" "$instance_dir/releases/current.new"
        mv -T "$instance_dir/releases/current.new" "$instance_dir/releases/current"
        systemctl start "bilibi@$instance"
    } >"$state/last-switch.log" 2>&1 || { log "Switching back failed; see $state/last-switch.log"; return 1; }
    answers "$(app_origin)" || { log 'The previous release does not answer; see last-switch.log'; return 1; }
    log "Returned to release $previous"
}
rollback() {
    local previous previous_tools=''
    [[ -f $state/transaction ]] || return 0
    restore_backup || return 1
    readarray -t txn <"$state/transaction"
    previous=${txn[0]}
    previous_tools=${txn[3]:-}
    switch_back "$previous" || return 1
    rm -f "$state/transaction"
    systemctl start "bilibi-installer@$instance" || true
}
# in_service_tools: the tools folder kept for the release in service.
in_service_tools() {
    [[ -f $state/in-service-tools ]] || return 0
    local folder; folder=$(cat "$state/in-service-tools")
    [[ -x $folder/scripts/install-server.sh ]] && printf '%s' "$folder"
}

# An update cut off half way is rolled back before anything else.
if [[ -f $state/transaction ]]; then
    log 'Found an interrupted nightly update; restoring its backup'
    rollback || { systemctl stop "bilibi-installer@$instance" || true; systemctl stop "bilibi@$instance" || true; die 'Rollback failed; services need administrator attention'; }
    exit 1
fi

previous=$(current_release)
[[ $previous =~ ^[0-9]+$ && -x $instance_dir/releases/$previous/bilibi-web ]] || die 'No previous release to restore'
if [[ $(release_tag "$previous") == "$tag" ]]; then
    answers "$(app_origin)" || die 'Public login health check failed'
    echo "$tag is already installed and public login answers"
    exit 0
fi

# ---------------------------------------------------------------- download
archive="$state/downloads/bilibi-$tag-x86_64-unknown-linux-gnu.tar.gz"
tools_archive="$state/downloads/server-tools-$tag.tar.gz"
local_mode=${BILIBI_TRIAL_LOCAL_ONLY:-0}
release_flags=()
if [[ $local_mode == 1 ]]; then
    inbox="$state/inbox/$tag"
    proof_helper=${BILIBI_TRIAL_PROOF_HELPER:-/usr/local/lib/bilibi-try-nightly/release-proof.py}
    policy="$instance_dir/trust/release.json"
    values=$(python3 "$proof_helper" trust-values --trust "$policy") || die 'Invalid release trust'
    mapfile -t trust <<< "$values"
    [[ ${trust[0]:-} == operator && ${trust[1]:-} == "$repository" &&
       ${trust[2]:-} == "$repository_id" && ${trust[3]:-} == "$repository/.github/workflows/release.yml" ]] ||
        die 'Local nightlies require the trial operator trust policy'
    python3 "$proof_helper" check-tag --trust "$policy" --tag "$tag"
    for entry in "${archive##*/}:$archive:setup:x86_64-unknown-linux-gnu" \
                 "bilibi-server-tools.tar.gz:$tools_archive:server-tools:server-tools"; do
        IFS=: read -r name dest kind target <<< "$entry"
        [[ -f $inbox/$name && -f $inbox/$name.proof.json ]] || die "Local asset or proof missing for $name"
        install -m 0600 -- "$inbox/$name" "$dest"
        install -m 0600 -- "$inbox/$name.proof.json" "$dest.proof.json"
        python3 "$proof_helper" verify-operator --artifact "$dest" --proof "$dest.proof.json" \
            --trust "$policy" --tag "$tag" --kind "$kind" --target "$target" >/dev/null ||
            die "Operator proof failed for $name"
    done
    release_flags=(--proof "$archive.proof.json")
elif [[ $local_mode == 0 ]]; then
    base="https://github.com/$repository/releases/download/$tag"
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 1200 --retry 3 \
        -o "$archive.part" "$base/bilibi-$tag-x86_64-unknown-linux-gnu.tar.gz" || die "Download failed for $tag"
    mv "$archive.part" "$archive"
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 1200 --retry 3 \
        -o "$tools_archive.part" "$base/bilibi-server-tools.tar.gz" || die "Server tools download failed for $tag"
    mv "$tools_archive.part" "$tools_archive"
    for file in "$archive" "$tools_archive"; do
        python3 "$verifier" "$file" --repo "$repository" --repo-id "$repository_id" --tag "$tag" \
            --trusted-root "$trusted_root" >/dev/null 2>&1 || die "Provenance verification failed for $file"
    done
else
    die 'BILIBI_TRIAL_LOCAL_ONLY must be 0 or 1'
fi
tools=$(mktemp -d "$state/tools/$tag-XXXXXX")
python3 - "$tools_archive" "$tools" <<'PYTOOLS'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    members = archive.getmembers()
    if len(members) > 500 or sum(m.size for m in members) > 64 * 1024 * 1024 or any(not (m.isfile() or m.isdir()) for m in members):
        raise SystemExit('Invalid server tools archive')
    archive.extractall(sys.argv[2], filter='data')
PYTOOLS
release="$tools/scripts/install-server.sh"
[[ -x $release && -f $tools/scripts/lib/versions.sh ]] || die 'Server tools are incomplete'

# ---------------------------------------------------------------- trust
# Since BelimbingProject/bilibi#892 the trust policy is pinned once and
# `release` verifies against it. An older installer has no `trust` command.
has_trust_interface() { grep -q ' trust <instance>' "$release"; }
minimum_tag() {
    # The trust helper requires a minimum newer than every installed release.
    # A nightly tag is not a setup-v tag, so this is the next patch of the
    # newest official release the trial knows.
    local newest
    newest=$(for n in "$instance_dir"/releases/*/release.json; do
        [[ -f $n ]] || continue
        release_tag "$(basename "$(dirname "$n")")"
    done | grep -E '^setup-v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
    [[ -n $newest ]] || newest=setup-v0.0.0
    python3 - "$newest" <<'PY'
import sys
major, minor, patch = sys.argv[1].removeprefix('setup-v').split('.')
print(f'setup-v{major}.{minor}.{int(patch) + 1}')
PY
}
# nightly_accepted: does the trust helper accept a nightly tag at all? The
# helper compares tags as setup-vX.Y.Z, so a nightly is refused until the
# Platform learns about nightly tags. Check before stopping anything.
nightly_accepted() {
    local policy=$instance_dir/trust/release.json probe=$state/downloads/probe-trust.json
    if [[ -f $policy ]]; then
        python3 "$tools/scripts/lib/release-proof.py" check-tag --trust "$policy" --tag "$tag" >/dev/null 2>&1
        return
    fi
    python3 "$tools/scripts/lib/release-proof.py" make-trust --kind github --repository "$repository" \
        --repository-id "$repository_id" --workflow "$repository/.github/workflows/release.yml" \
        --minimum-tag "$(minimum_tag)" --changed-by terminal-uid:0 --output "$probe" >/dev/null 2>&1 &&
        python3 "$tools/scripts/lib/release-proof.py" check-tag --trust "$probe" --tag "$tag" >/dev/null 2>&1
    rm -f "$probe"
}
ensure_trust() {
    local policy=$instance_dir/trust/release.json values=''
    if [[ -f $policy ]]; then
        values=$(python3 "$tools/scripts/lib/release-proof.py" trust-values --trust "$policy" 2>/dev/null) ||
            die 'The installed release trust record is invalid'
        if [[ $(printf '%s\n' "$values" | sed -n '2p') == "$repository" &&
              $(printf '%s\n' "$values" | sed -n '3p') == "$repository_id" &&
              $(printf '%s\n' "$values" | sed -n '4p') == "$repository/.github/workflows/release.yml" ]]; then
            log "Release trust already names $repository ($repository_id)"
            return 0
        fi
        die 'Release trust names another repository; the installation owner must replace it on Software with a fresh 2FA code'
    fi
    "$release" trust "$instance" --github --repo "$repository" --repo-id "$repository_id" \
        --minimum-tag "$(minimum_tag)" >"$state/last-trust.log" 2>&1 ||
        { log "Pinning release trust failed; see $state/last-trust.log"; return 1; }
}

# ---------------------------------------------------------------- services
software_idle() {
    local count
    count=$(runuser -u postgres -- psql -p "$pgport" -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM base_software_jobs WHERE state IN ('queued','running')" 2>/dev/null) || return 1
    [[ $count == 0 ]]
}

committed=0
on_exit() {
    local status=$?
    trap - EXIT
    if (( committed == 0 )); then
        if [[ -f $state/transaction ]]; then
            log "Nightly $tag failed; restoring previous release and database"
            rollback || { systemctl stop "bilibi-installer@$instance" || true; systemctl stop "bilibi@$instance" || true; log 'Rollback failed; services need administrator attention'; }
        else
            log "Nightly $tag stopped before installation; restarting services"
            systemctl start "bilibi@$instance" || log 'Could not restart instance service'
            systemctl start "bilibi-installer@$instance" || true
        fi
        exit 1
    fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

if [[ $local_mode == 1 ]]; then
    has_trust_interface || die 'This archive cannot install operator-signed releases'
elif has_trust_interface; then
    nightly_accepted || die "The Platform release trust does not accept $tag yet; nothing was changed"
    ensure_trust || exit 1
fi
software_idle || die 'A software job is active or cannot be checked; update deferred'
systemctl is-active --quiet "bilibi@$instance" ||
    die 'The instance service is not active'

# ---------------------------------------------------------------- backup
# Stop both writers before the backup. Never start an update without it.
systemctl stop "bilibi-installer@$instance" || true
systemctl stop "bilibi@$instance" || die 'Could not stop instance service'
software_idle || die 'A software job started before the pause; update deferred'
backup=$(mktemp -d "$backups/nightly-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
chown postgres:postgres "$backup"
if ! runuser -u postgres -- pg_dump -p "$pgport" --role="$database" --format=custom --no-owner --no-privileges \
        --file "$backup/database.dump" "$database" >/dev/null 2>&1 ||
   ! runuser -u postgres -- pg_restore --file /dev/null "$backup/database.dump" >/dev/null 2>&1; then
    die 'Backup failed; no release was installed'
fi
sha=$(sha256sum "$backup/database.dump" | cut -d' ' -f1)
printf '%s\n%s\n%s\n%s\n' "$previous" "$backup/database.dump" "$sha" "$(in_service_tools)" >"$state/transaction.new"
mv -f "$state/transaction.new" "$state/transaction"

# ---------------------------------------------------------------- install
if has_trust_interface; then
    "$release" release "$instance" "$archive" --tag "$tag" "${release_flags[@]}" >"$state/last-release.log" 2>&1 ||
        { log "Installation failed for $tag; see $state/last-release.log"; exit 1; }
else
    "$release" release "$instance" "$archive" --repo "$repository" --repo-id "$repository_id" --tag "$tag" \
        >"$state/last-release.log" 2>&1 ||
        { log "Installation failed for $tag; see $state/last-release.log"; exit 1; }
fi
systemctl start "bilibi-installer@$instance" || true
# The public check exercises the same HTTPS route visitors use.
answers "$(app_origin)" || die 'Public login health check failed'
rm -f "$state/transaction"
committed=1
printf '%s\n' "$tools" >"$state/in-service-tools"
# Keep the tools of the release in service for a later rollback; drop older.
for folder in "$state"/tools/*; do
    [[ $folder == "$tools" ]] || rm -rf -- "$folder"
done
rm -f -- "$archive" "$tools_archive" "$archive.proof.json" "$tools_archive.proof.json"
printf 'Installed %s; backup %s; public login answered successfully\n' "$tag" "$backup/database.dump"
