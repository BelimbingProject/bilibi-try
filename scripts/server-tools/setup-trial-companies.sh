#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s INSTANCE COMPANY_NAME COMPANY_CODE OWNER_EMAIL [COMPANY_NAME COMPANY_CODE OWNER_EMAIL]\n' "$0"
}

comparison_key() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value,,}"
}

if [[ $# == 1 && $1 == --help ]]; then
    usage
    exit 0
fi
if [[ $# != 4 && $# != 7 ]]; then
    usage >&2
    exit 2
fi
for argument in "$@"; do
    if [[ ! $argument =~ [^[:space:]] ]]; then
        printf 'Instance, company name, company code and owner email are required.\n' >&2
        exit 2
    fi
done
if [[ $# == 7 && ( $(comparison_key "$2") == "$(comparison_key "$5")" ||
                   $(comparison_key "$4") == "$(comparison_key "$7")" ) ]]; then
    printf 'Use different names and owner email addresses for the two companies.\n' >&2
    exit 2
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
installer="$here/install-server.sh"
if [[ ! -x $installer ]]; then
    printf 'Run this script from the verified trial server tools alongside install-server.sh.\n' >&2
    exit 1
fi

instance=$1
shift
result=0
company=1
while (( $# )); do
    if ! "$installer" tenant-provision "$instance" \
        --tenant-name "$1" --company-name "$1" --company-code "$2" --owner-email "$3"; then
        printf 'Company %d did not complete. Retry that company by itself after checking the error above.\n' "$company" >&2
        result=1
    fi
    shift 3
    company=$((company + 1))
done
exit "$result"
