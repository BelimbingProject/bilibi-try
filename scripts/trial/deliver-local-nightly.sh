#!/usr/bin/env bash
# Omar's system service runs this as root; never execute content from the build spool on the host.
set -euo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run on the trial host as root' >&2; exit 1; }
tag=nightly-$(TZ=Asia/Kuala_Lumpur date +%F)
ready=/home/kiat/.local/state/bilibi-try-build/ready/$tag
[[ -d $ready ]] || { echo "No completed local build for $tag yet"; exit 0; }
vm=(ssh -T -i /var/lib/bilibi-try-vm/admin-key -o BatchMode=yes
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/var/lib/bilibi-try-vm/known_hosts
    -o ConnectTimeout=15 -p 42289 ubuntu@127.0.0.1)
inbox=/var/lib/bilibi-try-nightly/inbox
# mktemp makes a private root-owned staging directory on the same filesystem.
pending=$("${vm[@]}" "sudo -n install -d -m 0700 $inbox && sudo -n mktemp -d $inbox/.incoming.XXXXXXXX")
[[ $pending =~ ^/var/lib/bilibi-try-nightly/inbox/\.incoming\.[a-zA-Z0-9]+$ ]]
app=bilibi-$tag-x86_64-unknown-linux-gnu.tar.gz
# Opening the spool as its owner avoids following an untrusted path with root access.
for name in "$app" "$app.proof.json" bilibi-server-tools.tar.gz bilibi-server-tools.tar.gz.proof.json; do
    runuser -u kiat -- cat -- "$ready/$name" |
        "${vm[@]}" "sudo -n tee $pending/$name >/dev/null"
done
# Serialize deliveries on Omar via the system service. Never replace a prior inbox.
"${vm[@]}" "if sudo -n test -d $inbox/$tag; then sudo -n rm -rf -- $pending; else sudo -n mv -T -- $pending $inbox/$tag; fi"
"${vm[@]}" "sudo -n env BILIBI_TRIAL_LOCAL_ONLY=1 /usr/local/sbin/bilibi-try-nightly $tag"
