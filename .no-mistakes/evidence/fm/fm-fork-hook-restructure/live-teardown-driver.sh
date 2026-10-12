#!/usr/bin/env bash
set -eu
LAB="$PWD/.l"
mkdir "$LAB"
trap 'TMUX_TMPDIR="${LAB#"$PWD/"}/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="${LAB#"$PWD/"}/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
export TMUX_TMPDIR="${LAB#"$PWD/"}/tmux"
export TMUX="${LAB#"$PWD/"}/tmux/tmux-$(id -u)/fm-lab,0,0"
printf 'manual\n' > "$LAB/config/backlog-backend"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/project"
git -C "$LAB/project" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m baseline
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q origin main
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$LAB/project" remote set-head origin main
export TREEHOUSE_ROOT="$LAB/pool"
WT=$(cd "$LAB/project" && treehouse get --lease --no-fetch --base main -b fm/probe)
printf 'work\n' > "$WT/work.txt"
git -C "$WT" add work.txt
git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit -q -m work
printf 'worktree=%s\nproject=%s\nkind=ship\nmode=local-only\nbackend=tmux\nwindow=primary:fm-probe\nendpoint_task_id=probe\n' "$WT" "$LAB/project" > "$LAB/state/probe.meta"
printf 'Attempt unpushed work teardown\n'
rc=0
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-teardown.sh probe > "$LAB/out" 2>&1 || rc=$?
cat "$LAB/out"
printf 'exit=%s worktree_retained=%s\n' "$rc" "$([ -f "$WT/work.txt" ] && echo yes || echo no)"
[ "$rc" = 1 ]
git -C "$WT" push -q origin HEAD:refs/heads/fm/probe
printf 'Attempt pushed work teardown\n'
rc=0
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-teardown.sh probe > "$LAB/out" 2>&1 || rc=$?
cat "$LAB/out"
printf 'exit=%s worktree_present=%s\n' "$rc" "$([ -d "$WT" ] && echo yes || echo no)"

[ "$rc" = 0 ]
