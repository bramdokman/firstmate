#!/usr/bin/env bash
# Run a project's declared task prerequisites only when its environment is stale.
# Usage: fm-task-bootstrap.sh <worktree>
#
# A project opts in by tracking one executable regular file at
# <worktree>/.firstmate/bootstrap.
# The executable accepts exactly two Firstmate-owned modes:
#
#   .firstmate/bootstrap fingerprint
#   .firstmate/bootstrap run
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

declaration="$worktree_real/.firstmate/bootstrap"
if [ ! -e "$declaration" ] && [ ! -L "$declaration" ]; then
  exit 0
fi
[ ! -L "$declaration" ] \
  || die "declaration must not be a symbolic link: $declaration"
[ -f "$declaration" ] \
  || die "declaration is not a regular file: $declaration"
[ -x "$declaration" ] \
  || die "declaration is not executable: $declaration"

git_dir=$(git -C "$worktree_real" rev-parse --absolute-git-dir 2>/dev/null) \
  || die "worktree-specific Git directory cannot be resolved"
marker="$git_dir/fm-task-bootstrap.fingerprint"
if [ -e "$marker" ] || [ -L "$marker" ]; then
  [ ! -L "$marker" ] && [ -f "$marker" ] \
    || die "fingerprint marker is not a regular file: $marker"
fi

calculate_fingerprint() {
  local declared script_hash
  if ! declared=$(cd "$worktree_real" && "$declaration" fingerprint); then
    die "declared fingerprint command failed: $declaration fingerprint"
  fi
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

printf 'task bootstrap: environment is stale; running %s\n' "$declaration"
if ! (cd "$worktree_real" && "$declaration" run); then
  die "task bootstrap failed: $declaration run"
fi

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
