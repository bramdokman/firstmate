#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-live-ssh
PARENT=$D/parent
REMOTE=$D/remote
CLAIMS=$D/claims
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/data" "$REMOTE/state" "$CLAIMS"
cat > "$PARENT/data/secondmates.md" <<EOF
- ios - isolated SSH lab (host: remote-mac; root: $D/code; home: $REMOTE; scope: testing; projects: alpha; added 2026-10-15)
EOF
: > "$REMOTE/state/parent-replies.status"
cat > "$D/ssh" <<EOF
#!/usr/bin/env bash
set -eu
while [ "\$#" -gt 0 ]; do
 case "\$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac
done
[ "\$1" = remote-mac ]; shift
[ "\$1" = fm-remote-entrypoint.sh ]; shift
exec /usr/bin/ssh -p 22489 -i '$D/client' -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR bd@127.0.0.1 env FM_REMOTE_JOB_STATE_ROOT='$D/jobs' FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux '$ROOT/bin/fm-remote-entrypoint.sh' "\$@"
EOF
chmod +x "$D/ssh"
export FM_HOME=$PARENT FM_PROCEVENT_CLAIM_ROOT=$CLAIMS FM_SSH_BIN=$D/ssh FM_REMOTE_REPLY_WAIT_SECONDS=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
 "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
 if [ -f "$D/jobs/worker.pid" ]; then fm_remote_job_stop_worker_tree "$(cat "$D/jobs/worker.pid")" || true; fi
}
trap cleanup EXIT
A=$ROOT/bin/fm-procevent-remote-reply.sh
P=$ROOT/bin/fm-procevent.sh
SID=$("$A" source-id ios)
"$A" arm ios
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 "$P" start "$SID" > "$D/runner.log" 2>&1 &
for i in $(seq 1 100); do [ ! -f "$CLAIMS/$SID.claim" ] || break; sleep .05; done
PID=$(sed -n '2p' "$CLAIMS/$SID.claim")
for n in $(seq 1 5); do
 "$A" arm ios
 printf 'working [key=ssh-round-%s]: before\000after\n' "$n" >> "$REMOTE/state/parent-replies.status"
 for i in $(seq 1 300); do
  if grep -Fq "working [key=ssh-round-$n]: before?after" "$PARENT/state/ios.status" 2>/dev/null; then break; fi
  sleep .1
 done
 grep -Fx "working [key=ssh-round-$n]: before?after" "$PARENT/state/ios.status"
 [ "$(sed -n '2p' "$CLAIMS/$SID.claim")" = "$PID" ]
 "$P" list
 printf 'round=%s original_listener=%s retained; NUL normalized and reply mirrored\n' "$n" "$PID"
done
expected=$(wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
grep -Fx "offset=$expected" "$PARENT/state/remote-replies/ios.cursor"
printf 'source bytes=%s; committed cursor agrees\n' "$expected"
