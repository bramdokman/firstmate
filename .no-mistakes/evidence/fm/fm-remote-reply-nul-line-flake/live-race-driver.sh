#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-live-ssh
export FM_HOME=$D/parent FM_PROCEVENT_CLAIM_ROOT=$D/claims FM_SSH_BIN=$D/ssh FM_REMOTE_REPLY_WAIT_SECONDS=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
P=${RACE_RUNNER:-$ROOT/bin/fm-procevent.sh}
A=$ROOT/bin/fm-procevent-remote-reply.sh
SID=$("$A" source-id ios)
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
 "$P" sweep-home >/dev/null 2>&1 || true
 if [ -f "$D/jobs/worker.pid" ]; then fm_remote_job_stop_worker_tree "$(cat "$D/jobs/worker.pid")" || true; fi
}
trap cleanup EXIT
stop() {
 local pid
 pid=$(sed -n '2p' "$D/claims/$SID.claim")
 kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid"
 for i in $(seq 1 100); do [ -e "$D/claims/$SID.claim" ] || return 0; sleep .1; done
 return 1
}
"$A" arm ios
# Refresh launch pacing with an actual empty read, then stop this listener.
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 "$P" start "$SID" > "$D/seed.log" 2>&1 &
for i in $(seq 1 100); do [ -e "$D/claims/$SID.claim" ] && break; sleep .1; done
sleep 3
stop
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=15 "$P" start "$SID" > "$D/race-runner.log" 2>&1 &
for i in $(seq 1 100); do [ -e "$D/claims/$SID.claim" ] && break; sleep .05; done
pid=$(sed -n '2p' "$D/claims/$SID.claim")
"$A" arm ios
key=race-$(date +%s)
printf 'working [key=%s]: held during paced re-arm\n' "$key" >> "$D/remote/state/parent-replies.status"
for i in $(seq 1 250); do grep -Fq "$key" "$D/parent/state/ios.status" && break; sleep .1; done
if ! grep -F "$key" "$D/parent/state/ios.status"; then
 printf 'FAIL: paced listener lost reply after re-arm; initial pid=%s\n' "$pid"
 "$P" list
 exit 1
fi
[ "$(sed -n '2p' "$D/claims/$SID.claim")" = "$pid" ]
"$P" list
printf 'PASS: paced re-arm delivered through same listener pid=%s\n' "$pid"
