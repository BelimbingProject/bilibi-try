#!/usr/bin/env bash
# No upstream traffic: all Git uses file transport and all containers use an internal network.
set -Eeuo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd -P)
mirrors=${BILIBI_TRIAL_MIRRORS:-$HOME/repo/BelimbingProject}
state=${BILIBI_TRIAL_BUILD_STATE:-$HOME/.local/state/bilibi-try-build}
key=${BILIBI_TRIAL_OPERATOR_KEY:-$HOME/.config/bilibi-release/operator.pem}
repository=BelimbingProject/bilibi-try
workflow=$repository/.github/workflows/release.yml
target=x86_64-unknown-linux-gnu
mode=${1:-build}
[[ $# -le 1 && ( $mode == build || $mode == warm ) ]] || { echo 'Usage: build-local-nightly.sh [build|warm]' >&2; exit 2; }
tag=nightly-$(TZ=Asia/Kuala_Lumpur date +%F)
pg_image=postgres:18.0-bookworm@sha256:3f55f8895c4ed50603e2fbdfc72fffeeaba3173321fee5cb825bbbeb30d9d854
install -d -m 0700 "$state" "$state/ready"
exec 9>"$state/build.lock"
flock -n 9 || { echo 'Another local nightly build is running' >&2; exit 1; }
if [[ $mode == build && -d $state/ready/$tag ]]; then
    echo "Already built $tag"
    exit 0
fi
[[ -f $key && ! -L $key && $(stat -c '%a:%u' "$key") == "600:$(id -u)" ]] ||
    { echo 'Operator key must be a regular mode 0600 file owned by this user' >&2; exit 1; }
job=$(mktemp -d "$state/work.XXXXXXXX")
network=bilibi-try-${job##*.}
network_id=
pg_id=
cleanup() {
    if [[ -n $pg_id ]]; then docker rm -f "$pg_id" >/dev/null || true; fi
    if [[ -n $network_id ]]; then docker network rm "$network_id" >/dev/null || true; fi
    rm -rf -- "$job"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# Trailing slash preserves the repository's .git suffix. Use a URL for canonical path encoding.
local_url=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().as_uri()+"/")' "$mirrors")
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$local_url.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/BelimbingProject/
# The deployed, reviewed build scripts are the trusted checkout; update them explicitly.
git clone --quiet --no-local --no-tags "$root" "$job/setup"
git -C "$job/setup" checkout --quiet --detach "$(git -C "$root" rev-parse HEAD)"
cd "$job/setup"
python3 -m unittest discover -s tests
export BILIBI_BUILD_DIR=${BILIBI_BUILD_DIR:-$state/cache}
export CARGO_TARGET_DIR=$BILIBI_BUILD_DIR/target
export BILIBI_SOURCE_DIR=$job/sources
# Snapshot source refs during materialization, against the same mirrors as the proof.
exec 8>"$mirrors/.sync.lock"
flock -s 8
python3 scripts/nightly-sources.py
python3 scripts/recipe.py materialize
if [[ $mode == warm ]]; then
    flock -u 8
    docker pull "$pg_image"
    scripts/builder.sh python3 scripts/recipe.py record-candidate
    scripts/builder.sh bash -ec '
        cd "$BILIBI_SOURCE_DIR/platform"
        cargo fetch --locked --target x86_64-unknown-linux-gnu
        npm ci --prefix apps/base/ui/assets --no-audit --no-fund --ignore-scripts
    '
    exit 0
fi
docker image inspect "$pg_image" >/dev/null
network_id=$(docker network create --internal "$network")
pg_id=$(docker run -d --rm --pull never --network "$network_id" --network-alias check-db \
    -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=setup_check "$pg_image")
for _ in {1..60}; do
    if docker exec "$pg_id" pg_isready -h 127.0.0.1 -d setup_check >/dev/null; then break; fi
    sleep 1
done
docker exec "$pg_id" pg_isready -h 127.0.0.1 -d setup_check >/dev/null
export BILIBI_OFFLINE_NETWORK=$network_id BILIBI_CHECK_DATABASE_URL=postgresql://postgres@check-db:5432/setup_check
unset DATABASE_URL
scripts/builder.sh python3 scripts/recipe.py record-candidate
python3 scripts/recipe.py verify-remote
flock -u 8
python3 scripts/recipe.py check-record
git add -- setup.toml composition/manifest.txt composition/Cargo.lock
git -c user.name='Bilibi Trial Operator' -c user.email='trial-operator@bilibi.invalid' \
    -c commit.gpgsign=false commit --allow-empty -m "Record sources for $tag"
git -c tag.gpgSign=false tag "$tag"
scripts/builder.sh scripts/check.sh
scripts/builder.sh python3 scripts/package.py --tag "$tag" --repository "$repository"
scripts/builder.sh python3 scripts/verify-package.py --tag "$tag" --repository "$repository"
proof=$BILIBI_SOURCE_DIR/platform/scripts/lib/release-proof.py
for asset in "bilibi-$tag-$target.tar.gz:setup:$target" "bilibi-server-tools.tar.gz:server-tools:server-tools"; do
    IFS=: read -r name kind arch <<< "$asset"
    python3 "$proof" sign --artifact "dist/$name" --private-key "$key" \
        --repository "$repository" --repository-id 1462459642 --workflow "$workflow" \
        --tag "$tag" --kind "$kind" --target "$arch" --output "dist/$name.proof.json"
done
mv -T dist "$state/ready/$tag"
echo "Built, checked and signed $tag"
