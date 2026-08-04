#!/usr/bin/env bash
# Regression coverage for the project-declared task bootstrap that runs after
# fm-spawn resolves an isolated worktree and before it launches a worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BOOTSTRAP="$ROOT/bin/fm-task-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-bootstrap)

# track_declaration stages the declaration so it satisfies the tracked-opt-in
# contract; ls-files reads the index, so later rewrites stay tracked.
track_declaration() {
  local worktree=$1
  git -C "$worktree" add .firstmate/bootstrap
}

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
  kill-window)
    [ -z "${FM_FAKE_CALL_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
    exit 0
    ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_CALL_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_spawn_stops_before_worker_when_declared_bootstrap_fails() {
  local case_dir home project worktree fakebin id out status calls
  case_dir="$TMP_ROOT/spawn-failure"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  calls="$case_dir/calls.log"
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
  track_declaration "$worktree"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_CALL_LOG="$calls" \
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
  assert_grep "kill-window" "$calls" \
    "failed bootstrap left its tmux window behind with no meta for fm-teardown"
  assert_grep "treehouse return --force $worktree" "$calls" \
    "failed bootstrap left the leased treehouse worktree checked out"
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
  track_declaration "$worktree"
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

test_untracked_declaration_never_runs() {
  local project worktree out status
  project="$TMP_ROOT/untracked-project"
  worktree="$TMP_ROOT/untracked-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-untracked
  mkdir -p "$worktree/.firstmate"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
printf 'untracked executable ran\n' > "$(git rev-parse --show-toplevel)/untracked-ran"
exit 0
SH
  chmod +x "$worktree/.firstmate/bootstrap"
  printf '.firstmate/\n' > "$worktree/.gitignore"

  set +e
  out=$("$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an untracked declaration was accepted as opt-in"
  assert_contains "$out" "not tracked by Git" \
    "refusal did not name the tracked-declaration contract"
  assert_absent "$worktree/untracked-ran" \
    "an untracked executable at .firstmate/bootstrap was executed"
  pass "only a tracked declaration counts as opt-in"
}

test_symlinked_firstmate_parent_never_runs() {
  local project worktree outside out status
  project="$TMP_ROOT/symlink-project"
  worktree="$TMP_ROOT/symlink-worktree"
  outside="$TMP_ROOT/symlink-outside"
  fm_git_worktree "$project" "$worktree" bootstrap-symlink
  mkdir -p "$outside"
  cat > "$outside/bootstrap" <<'SH'
#!/usr/bin/env bash
printf 'outside executable ran\n' > "$FM_TEST_SYMLINK_WITNESS"
exit 0
SH
  chmod +x "$outside/bootstrap"
  ln -s "$outside" "$worktree/.firstmate"

  set +e
  out=$(FM_TEST_SYMLINK_WITNESS="$TMP_ROOT/symlink-ran" "$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a declaration behind a symlinked .firstmate was accepted"
  assert_contains "$out" "must not be reached through a symbolic link" \
    "refusal did not name the symlinked declaration path"
  assert_absent "$TMP_ROOT/symlink-ran" \
    "a declaration outside the worktree was executed through a symlinked parent"
  pass "a symlinked .firstmate parent cannot smuggle in a declaration"
}

test_declared_modes_are_noninteractive() {
  local project worktree out
  project="$TMP_ROOT/stdin-project"
  worktree="$TMP_ROOT/stdin-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-stdin
  mkdir -p "$worktree/.firstmate"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
set -u
read -r line || line='<eof>'
printf '%s %s\n' "${1:-}" "$line" >> "$(git rev-parse --show-toplevel)/stdin-seen.log"
case "${1:-}" in
  fingerprint) printf 'stdin-v1\n' ;;
  run) : ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$worktree/.firstmate/bootstrap"
  track_declaration "$worktree"

  out=$(printf 'secret-from-the-primary-session\n' | "$BOOTSTRAP" "$worktree" 2>&1) \
    || fail "noninteractive bootstrap should have succeeded: $out"
  assert_no_grep "secret-from-the-primary-session" "$worktree/stdin-seen.log" \
    "a declared mode inherited the primary session's stdin"
  assert_grep "run <eof>" "$worktree/stdin-seen.log" \
    "the declared run mode did not read EOF on stdin"
  pass "every declared mode runs with stdin from /dev/null"
}

# A declaration that hangs and leaves a background child behind, so the bound is
# proven to reach the whole process group and not just the declaration itself.
write_hanging_declaration() {
  local worktree=$1
  mkdir -p "$worktree/.firstmate"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  timeout) printf '1\n' ;;
  fingerprint) printf 'timeout-v1\n' ;;
  run)
    sleep 300 &
    printf '%s\n' "$!" > "$(git rev-parse --show-toplevel)/grandchild.pid"
    wait
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$worktree/.firstmate/bootstrap"
  track_declaration "$worktree"
}

assert_runner_bounds_a_hanging_run() {  # <runner>
  local runner=$1 project worktree out status started elapsed pid waited=0
  project="$TMP_ROOT/bound-$runner-project"
  worktree="$TMP_ROOT/bound-$runner-worktree"
  fm_git_worktree "$project" "$worktree" "bootstrap-bound-$runner"
  write_hanging_declaration "$worktree"

  started=$(date +%s)
  set +e
  out=$(FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER="$runner" "$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] \
    || fail "$runner: a run that exceeded its declared bound reported success"
  assert_contains "$out" "exceeded 1s" \
    "$runner: the bounded run failure did not name the bound it exceeded"
  [ "$elapsed" -lt 60 ] \
    || fail "$runner: the declared bound did not stop a hanging run (took ${elapsed}s)"
  pid=$(cat "$worktree/grandchild.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "$runner: the declaration never recorded its background child"
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$pid" 2>/dev/null \
    || fail "$runner: the declaration's process group outlived its bound (pid $pid)"
  assert_absent "$(git -C "$worktree" rev-parse --absolute-git-dir)/fm-task-bootstrap.fingerprint" \
    "$runner: a run stopped by its bound still published a success marker"
}

test_every_available_runner_bounds_a_hanging_run() {
  local runner covered=0
  for runner in timeout gtimeout node; do
    command -v "$runner" >/dev/null 2>&1 || continue
    assert_runner_bounds_a_hanging_run "$runner"
    covered=$((covered + 1))
  done
  [ "$covered" -gt 0 ] \
    || fail "this host has no bounded execution runtime, so the declared bound is unenforceable"
  pass "every available bounded runner stops a hanging run and kills its process group"
}

test_missing_bounded_runtime_refuses_the_declaration() {
  local project worktree shim out status
  project="$TMP_ROOT/no-runtime-project"
  worktree="$TMP_ROOT/no-runtime-worktree"
  shim="$TMP_ROOT/no-runtime-bin"
  fm_git_worktree "$project" "$worktree" bootstrap-no-runtime
  mkdir -p "$worktree/.firstmate" "$shim"
  cat > "$worktree/.firstmate/bootstrap" <<'SH'
#!/usr/bin/env bash
printf 'unbounded declaration ran\n' > "$FM_TEST_UNBOUNDED_WITNESS"
exit 0
SH
  chmod +x "$worktree/.firstmate/bootstrap"
  track_declaration "$worktree"
  ln -s "$(command -v git)" "$shim/git"
  ln -s "$(command -v bash)" "$shim/bash"

  set +e
  out=$(PATH="$shim" FM_TEST_UNBOUNDED_WITNESS="$TMP_ROOT/unbounded-ran" \
    FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER=node "$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a host with no bounded runtime still ran the declaration"
  assert_contains "$out" "refusing to run" \
    "the missing-runtime refusal did not say it will not run the declaration unbounded"
  assert_absent "$TMP_ROOT/unbounded-ran" \
    "the declaration ran unbounded when no bounded runtime was available"
  pass "a host with no bounded runtime refuses the declaration instead of running it unbounded"
}

test_unsupported_runner_pin_is_refused() {
  local project worktree out status
  project="$TMP_ROOT/bad-runner-project"
  worktree="$TMP_ROOT/bad-runner-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-bad-runner
  write_successful_declaration "$worktree"
  printf 'lock-v1\n' > "$worktree/desired.lock"
  printf 'tool-v1\n' > "$worktree/toolchain.version"

  set +e
  out=$(FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER=cat "$BOOTSTRAP" "$worktree" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an arbitrary command was accepted as the bounded runner"
  assert_contains "$out" "unsupported FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER" \
    "the runner pin refusal did not name the rejected value"
  pass "only timeout, gtimeout, or node may be pinned as the bounded runner"
}

test_spawn_never_returns_an_unvalidated_worktree() {
  local case_dir home project stray fakebin id out status calls
  case_dir="$TMP_ROOT/spawn-unvalidated"
  home="$case_dir/home"
  project="$case_dir/project"
  stray="$case_dir/stray"
  calls="$case_dir/calls.log"
  id=bootstrap-unvalidated-z2
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$stray"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'task brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$project"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$stray" \
    FM_FAKE_CALL_LOG="$calls" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "spawn launched from a pane that never entered a worktree"
  assert_contains "$out" "did not yield an isolated worktree" \
    "spawn did not refuse the unvalidated pane path"
  assert_grep "kill-window" "$calls" \
    "the refused spawn left its tmux window behind"
  assert_no_grep "treehouse return" "$calls" \
    "spawn handed an unvalidated non-worktree path to treehouse return --force"
  pass "an unvalidated pane path is never returned to the treehouse pool"
}

test_default_bound_applies_without_a_declared_timeout() {
  local project worktree out
  project="$TMP_ROOT/default-bound-project"
  worktree="$TMP_ROOT/default-bound-worktree"
  fm_git_worktree "$project" "$worktree" bootstrap-default-bound
  write_successful_declaration "$worktree"
  printf 'lock-v1\n' > "$worktree/desired.lock"
  printf 'tool-v1\n' > "$worktree/toolchain.version"

  out=$("$BOOTSTRAP" "$worktree" 2>&1) \
    || fail "a declaration without a timeout mode should have succeeded: $out"
  assert_contains "$out" "bounded at 900s" \
    "a declaration that does not handle the timeout mode did not get the 900s default"
  pass "declarations without a timeout mode run under the documented 900s default"
}

test_spawn_stops_before_worker_when_declared_bootstrap_fails
test_stale_fingerprint_runs_and_matching_fingerprint_skips
test_failed_run_does_not_publish_a_matching_marker
test_untracked_declaration_never_runs
test_symlinked_firstmate_parent_never_runs
test_declared_modes_are_noninteractive
test_every_available_runner_bounds_a_hanging_run
test_missing_bounded_runtime_refuses_the_declaration
test_unsupported_runner_pin_is_refused
test_default_bound_applies_without_a_declared_timeout
test_spawn_never_returns_an_unvalidated_worktree

echo "# all task-bootstrap tests passed"
