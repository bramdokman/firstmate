#!/usr/bin/env bash
# Regression coverage for the project-declared task bootstrap that runs after
# fm-spawn resolves an isolated worktree and before it launches a worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BOOTSTRAP="$ROOT/bin/fm-task-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-bootstrap)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_stops_before_worker_when_declared_bootstrap_fails() {
  local case_dir home project worktree fakebin id out status
  case_dir="$TMP_ROOT/spawn-failure"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  id=bootstrap-failure-z1
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'task brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" bootstrap-spawn
  mkdir -p "$worktree/.firstmate"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  fingerprint) printf 'fixture-v1\n' ;;
  run) printf 'declared bootstrap failure\n' >&2; exit 19 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$worktree/.firstmate/bootstrap"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$worktree" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "spawn continued after its project-declared bootstrap failed"
  assert_contains "$out" "declared bootstrap failure" \
    "spawn did not surface the declared prerequisite's stderr"
  assert_contains "$out" "refusing to launch worker" \
    "spawn failure did not explain that the worker was stopped"
  assert_absent "$home/state/$id.meta" \
    "spawn published task metadata even though bootstrap failed"
  pass "a failed project bootstrap loudly stops spawn before worker launch"
}

write_successful_declaration() {
  local worktree=$1
  mkdir -p "$worktree/.firstmate"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  fingerprint)
    git hash-object desired.lock
    printf 'toolchain=%s\n' "$(cat toolchain.version)"
    if [ -f .environment-ready ]; then
      git hash-object .environment-ready
    else
      printf 'environment-ready=missing\n'
    fi
    ;;
  run)
    cat desired.lock toolchain.version > .environment-ready
    printf 'run\n' >> bootstrap-runs.log
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$worktree/.firstmate/bootstrap"
}

test_stale_fingerprint_runs_and_matching_fingerprint_skips() {
  local project worktree out runs
  project="$TMP_ROOT/fingerprint-project"
  worktree="$TMP_ROOT/fingerprint-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-fingerprint
  write_successful_declaration "$worktree"
  printf 'lock-v1\n' > "$worktree/desired.lock"
  printf 'tool-v1\n' > "$worktree/toolchain.version"

  out=$("$BOOTSTRAP" "$worktree" 2>&1) \
    || fail "stale bootstrap should have succeeded: $out"
  assert_contains "$out" "environment is stale; running" \
    "missing marker did not trigger the declared bootstrap"
  runs=$(wc -l < "$worktree/bootstrap-runs.log" | tr -d '[:space:]')
  [ "$runs" = 1 ] || fail "first stale bootstrap ran $runs times instead of once"

  out=$("$BOOTSTRAP" "$worktree" 2>&1) \
    || fail "matching bootstrap should have succeeded: $out"
  assert_contains "$out" "environment fingerprint matches; skipping" \
    "matching marker did not skip the bootstrap"
  runs=$(wc -l < "$worktree/bootstrap-runs.log" | tr -d '[:space:]')
  [ "$runs" = 1 ] || fail "matching fingerprint reran the bootstrap"

  printf 'lock-v2\n' > "$worktree/desired.lock"
  out=$("$BOOTSTRAP" "$worktree" 2>&1) \
    || fail "changed fingerprint bootstrap should have succeeded: $out"
  assert_contains "$out" "environment is stale; running" \
    "changed lock input did not trigger the bootstrap"
  runs=$(wc -l < "$worktree/bootstrap-runs.log" | tr -d '[:space:]')
  [ "$runs" = 2 ] || fail "changed fingerprint did not run the bootstrap exactly once"
  pass "stale fingerprints run bootstrap while matching fingerprints skip it"
}

test_failed_run_does_not_publish_a_matching_marker() {
  local project worktree git_dir marker before after out status
  project="$TMP_ROOT/failure-project"
  worktree="$TMP_ROOT/failure-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-failed-marker
  write_successful_declaration "$worktree"
  printf 'lock-v1\n' > "$worktree/desired.lock"
  printf 'tool-v1\n' > "$worktree/toolchain.version"
  "$BOOTSTRAP" "$worktree" >/dev/null
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir)
  marker="$git_dir/fm-task-bootstrap.fingerprint"
  before=$(cat "$marker")

  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  fingerprint) printf 'failure-v2\n' ;;
  run) printf 'prerequisite exploded\n' >&2; exit 23 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$worktree/.firstmate/bootstrap"
  set +e
  out=$("$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed declared prerequisite returned success"
  assert_contains "$out" "prerequisite exploded" \
    "failed prerequisite stderr was hidden"
  assert_contains "$out" "task bootstrap failed" \
    "runner did not label the prerequisite failure"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "failed prerequisite replaced the last successful marker"
  pass "a failed prerequisite stays loud and cannot publish a success marker"
}

test_spawn_stops_before_worker_when_declared_bootstrap_fails
test_stale_fingerprint_runs_and_matching_fingerprint_skips
test_failed_run_does_not_publish_a_matching_marker

echo "# all task-bootstrap tests passed"
