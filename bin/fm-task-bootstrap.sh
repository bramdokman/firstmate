#!/usr/bin/env bash
# Run a project's declared task prerequisites only when its environment is stale.
# Usage: fm-task-bootstrap.sh <worktree>
#
# A project opts in by tracking one executable regular file at
# <worktree>/.firstmate/bootstrap.
# The declaration must be tracked by Git, must be a regular file, and neither it
# nor its `.firstmate` parent may be a symbolic link, so what Firstmate executes
# is always reviewable content that belongs to the worktree.
# The executable accepts two required Firstmate-owned modes and one optional one:
#
#   .firstmate/bootstrap fingerprint
#   .firstmate/bootstrap run
#   .firstmate/bootstrap timeout   (optional)
#
# `fingerprint` must print non-empty stable text describing every input that can
# stale the preserved environment, including project inputs such as lockfiles,
# relevant toolchain versions, and cheap readiness checks for generated output.
# Firstmate hashes that text together with the declaration's own bytes.
# `run` performs the project's prerequisite commands and must exit nonzero when
# any prerequisite fails.
# Firstmate recomputes the fingerprint after a successful run because readiness
# checks may change while prerequisites execute.
#
# Declarations MUST be noninteractive: every mode is invoked with stdin from
# /dev/null, so a prompt reads EOF and fails instead of blocking the primary
# session that is waiting to launch the worker.
# Every mode is also bounded in wall-clock time, because a spawn that hangs is
# neither a loud failure nor a launch. The bound defaults to 900 seconds. A
# project overrules it by handling the optional `timeout` mode and printing a
# positive whole number of seconds; a declaration that exits nonzero for that
# mode (the natural result of not handling it) keeps the default.
# The bound is enforced by `timeout`, `gtimeout`, or a one-shot inline Node
# executor, in that order. Stock macOS ships neither GNU timeout nor gtimeout,
# so the Node executor is what keeps the bound real there. There is no unbounded
# fallback: with none of the three available the declaration is refused instead
# of run. FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER pins one of timeout, gtimeout, or
# node when a host needs a specific one.
# Overrunning the bound terminates the declaration's whole process group with
# SIGTERM, then SIGKILL 10 seconds later, and fails the spawn loudly with the
# bound it exceeded - there is no retry.
#
# The last successful fingerprint lives in the worktree-specific Git directory,
# so it survives Treehouse's tracked-file reset and `git clean -fd` without
# requiring a project-specific ignored marker.
# A matching marker skips `run`.
# A missing or stale marker runs it.
# An invalid declaration, failed fingerprint, failed run, or failed marker write
# exits nonzero and never publishes a new success marker.
# Projects without the declaration are unchanged and produce no output.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'task bootstrap: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || {
  usage >&2
  exit 2
}

worktree=$1
worktree_real=$(cd "$worktree" 2>/dev/null && pwd -P) \
  || die "worktree directory cannot be resolved: $worktree"
worktree_top=$(git -C "$worktree_real" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a Git worktree: $worktree_real"
worktree_top_real=$(cd "$worktree_top" 2>/dev/null && pwd -P) \
  || die "Git worktree root cannot be resolved: $worktree_top"
[ "$worktree_real" = "$worktree_top_real" ] \
  || die "path is not the Git worktree root: $worktree_real"

declaration_dir="$worktree_real/.firstmate"
declaration="$declaration_dir/bootstrap"
if [ ! -e "$declaration" ] && [ ! -L "$declaration" ]; then
  exit 0
fi
# -L only ever tests the final component, so the parent is resolved physically
# too: a symlinked .firstmate would otherwise execute a file outside the
# worktree whose contents never appear in the project's diff.
declaration_dir_real=$(cd "$declaration_dir" 2>/dev/null && pwd -P) \
  || die "declaration directory cannot be resolved: $declaration_dir"
[ "$declaration_dir_real" = "$declaration_dir" ] \
  || die "declaration must not be reached through a symbolic link: $declaration"
[ ! -L "$declaration" ] \
  || die "declaration must not be a symbolic link: $declaration"
[ -f "$declaration" ] \
  || die "declaration is not a regular file: $declaration"
[ -x "$declaration" ] \
  || die "declaration is not executable: $declaration"
# Opt-in means a tracked declaration. An executable that merely lands at this
# path in a preserved worktree - ignored, so it survives Treehouse's reset and
# `git clean -fd` - has no reviewed-content guarantee and must not run.
git -C "$worktree_real" ls-files --error-unmatch -- .firstmate/bootstrap >/dev/null 2>&1 \
  || die "declaration is not tracked by Git: $declaration"

BOOTSTRAP_TIMEOUT_DEFAULT_SECS=900
BOOTSTRAP_TIMEOUT_KILL_AFTER_SECS=10

# One-shot inline executor for hosts without GNU timeout. It runs the
# declaration in its own process group, signals that whole group on overrun so
# the project's own children die with it, and reproduces the timeout(1) exit
# contract this script reads: 124 on overrun, 128+signal otherwise.
BOOTSTRAP_NODE_BOUNDED_EXEC='
const { spawn } = require("child_process");
const os = require("os");
const bound = Number(process.argv[1]);
const grace = Number(process.argv[2]);
const child = spawn(process.argv[3], process.argv.slice(4), {
  stdio: ["ignore", "inherit", "inherit"],
  detached: true,
});
let timedOut = false;
let killTimer = null;
const signalGroup = (sig) => {
  try {
    process.kill(-child.pid, sig);
  } catch (groupError) {
    try {
      child.kill(sig);
    } catch (childError) {
      /* already gone */
    }
  }
};
const boundTimer = setTimeout(() => {
  timedOut = true;
  signalGroup("SIGTERM");
  killTimer = setTimeout(() => signalGroup("SIGKILL"), grace * 1000);
}, bound * 1000);
child.on("error", () => {
  clearTimeout(boundTimer);
  process.exit(127);
});
child.on("exit", (code, signal) => {
  clearTimeout(boundTimer);
  if (killTimer) clearTimeout(killTimer);
  if (timedOut) process.exit(124);
  process.exit(signal ? 128 + (os.constants.signals[signal] || 0) : code);
});
'

case "${FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER:-}" in
  '') bootstrap_runner_candidates='timeout gtimeout node' ;;
  timeout|gtimeout|node) bootstrap_runner_candidates=$FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER ;;
  *) die "unsupported FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER '$FM_TASK_BOOTSTRAP_TIMEOUT_RUNNER': expected timeout, gtimeout, or node" ;;
esac
TIMEOUT_RUNNER=
for bootstrap_runner_candidate in $bootstrap_runner_candidates; do
  if command -v "$bootstrap_runner_candidate" >/dev/null 2>&1; then
    TIMEOUT_RUNNER=$bootstrap_runner_candidate
    break
  fi
done
[ -n "$TIMEOUT_RUNNER" ] \
  || die "no bounded execution runtime found (looked for: $bootstrap_runner_candidates); refusing to run $declaration unbounded"

# One bounded, noninteractive invocation of a declared mode. No daemon and no
# persistent supervisor: the bound lives and dies with this single invocation,
# and an overrun exits 124.
declared_mode() {  # <bound-seconds> <mode>
  local bound=$1 mode=$2
  if [ "$TIMEOUT_RUNNER" = node ]; then
    ( cd "$worktree_real" && exec node -e "$BOOTSTRAP_NODE_BOUNDED_EXEC" \
        "$bound" "$BOOTSTRAP_TIMEOUT_KILL_AFTER_SECS" "$declaration" "$mode" ) < /dev/null
  else
    ( cd "$worktree_real" && exec "$TIMEOUT_RUNNER" \
        -k "$BOOTSTRAP_TIMEOUT_KILL_AFTER_SECS" "$bound" "$declaration" "$mode" ) < /dev/null
  fi
}

resolve_bound() {
  local declared status
  set +e
  declared=$(declared_mode "$BOOTSTRAP_TIMEOUT_DEFAULT_SECS" timeout)
  status=$?
  set -e
  [ "$status" -ne 124 ] \
    || die "declared timeout command exceeded ${BOOTSTRAP_TIMEOUT_DEFAULT_SECS}s: $declaration timeout"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$BOOTSTRAP_TIMEOUT_DEFAULT_SECS"
    return 0
  fi
  declared=$(printf '%s' "$declared" | tr -d '[:space:]')
  if [ -z "$declared" ]; then
    printf '%s\n' "$BOOTSTRAP_TIMEOUT_DEFAULT_SECS"
    return 0
  fi
  case "$declared" in
    *[!0-9]*) die "declared timeout must be a positive whole number of seconds: $declared" ;;
  esac
  [ "$declared" -gt 0 ] \
    || die "declared timeout must be a positive whole number of seconds: $declared"
  printf '%s\n' "$declared"
}

bound=$(resolve_bound)

git_dir=$(git -C "$worktree_real" rev-parse --absolute-git-dir 2>/dev/null) \
  || die "worktree-specific Git directory cannot be resolved"
marker="$git_dir/fm-task-bootstrap.fingerprint"
if [ -e "$marker" ] || [ -L "$marker" ]; then
  [ ! -L "$marker" ] && [ -f "$marker" ] \
    || die "fingerprint marker is not a regular file: $marker"
fi

calculate_fingerprint() {
  local declared script_hash status
  set +e
  declared=$(declared_mode "$bound" fingerprint)
  status=$?
  set -e
  [ "$status" -ne 124 ] \
    || die "declared fingerprint command exceeded ${bound}s: $declaration fingerprint"
  [ "$status" -eq 0 ] \
    || die "declared fingerprint command failed: $declaration fingerprint"
  [ -n "$declared" ] \
    || die "declared fingerprint command returned empty output: $declaration fingerprint"
  script_hash=$(git -C "$worktree_real" hash-object .firstmate/bootstrap 2>/dev/null) \
    || die "could not hash declaration: $declaration"
  printf '%s\0%s' "$script_hash" "$declared" \
    | git -C "$worktree_real" hash-object --stdin 2>/dev/null \
    || die "could not hash declared environment fingerprint"
}

fingerprint=$(calculate_fingerprint)
if [ -f "$marker" ]; then
  marker_fingerprint=$(cat "$marker") \
    || die "could not read fingerprint marker: $marker"
  if [ "$marker_fingerprint" = "$fingerprint" ]; then
    printf 'task bootstrap: environment fingerprint matches; skipping %s\n' "$declaration"
    exit 0
  fi
fi

printf 'task bootstrap: environment is stale; running %s (bounded at %ss)\n' \
  "$declaration" "$bound"
set +e
declared_mode "$bound" run
run_status=$?
set -e
[ "$run_status" -ne 124 ] \
  || die "task bootstrap failed: $declaration run exceeded ${bound}s"
[ "$run_status" -eq 0 ] \
  || die "task bootstrap failed: $declaration run"

fingerprint=$(calculate_fingerprint)
marker_tmp=$(mktemp "$git_dir/fm-task-bootstrap.fingerprint.XXXXXXXX") \
  || die "could not create fingerprint marker in $git_dir"
cleanup_marker_tmp() {
  [ -z "${marker_tmp:-}" ] || rm -f "$marker_tmp"
}
trap cleanup_marker_tmp EXIT
printf '%s\n' "$fingerprint" > "$marker_tmp" \
  || die "could not write fingerprint marker: $marker_tmp"
mv -f "$marker_tmp" "$marker" \
  || die "could not publish fingerprint marker: $marker"
marker_tmp=
trap - EXIT
printf 'task bootstrap: prerequisites complete; recorded environment fingerprint\n'
