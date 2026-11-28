#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
mirrors=${BILIBI_TRIAL_MIRRORS:-$HOME/repo/BelimbingProject}
mkdir -p "$mirrors"
status=0
flock "$mirrors/.sync.lock" python3 "$root/scripts/trial/sync-mirrors.py" "$mirrors" || status=$?
"$root/scripts/trial/build-local-nightly.sh" warm
exit "$status"
