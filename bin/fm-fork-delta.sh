#!/usr/bin/env bash
# Check this fork's divergence from upstream against the fork manifest below.
# Usage: fm-fork-delta.sh [--manifest <file>] [<upstream-ref>]
#        fm-fork-delta.sh [--manifest <file>] --manifest-only
#
# The divergence from upstream is permanent and never contributed upstream, so
# every upstream sync must preserve it exactly. To keep syncs cheap, local
# behaviour lives in fork-owned files, and every edit to an upstream file is a
# short hook in a part of that file upstream rarely touches. Upstream syncs land
# as true merge commits so upstream ancestry survives.
# The manifest is the single inventory of that divergence. Change it in the same
# commit as any change to the delta, and run this check first and last in every
# upstream sync.
#
# The check compares HEAD with its merge base with <upstream-ref> (default
# upstream/main; run `git fetch upstream` first) in the git repository of the
# current directory, using `git diff --numstat --no-renames`. It reports:
#   - a changed path the manifest does not list;
#   - a hook path whose added or deleted lines exceed its budget;
#   - a manifest path that is not in the delta (a stale row);
#   - an owned path that <upstream-ref> also has, which would collide on merge;
#   - a hook path that <upstream-ref> no longer has;
#   - a symbol that HEAD or <upstream-ref> no longer defines.
# A symbol is defined when its file has `<name>()` or `<name>=` at a word start.
# --manifest-only skips everything that needs <upstream-ref>: it parses the
# manifest and checks that every listed path and symbol exists in the
# checked-out files, so it also runs before a commit and where no upstream
# remote is configured.
# --manifest reads the manifest block from <file> instead of this header.
# Prints one "fail:" line per finding, then one FM_FORK_DELTA summary line.
# Exits 0 when nothing was found, 1 on findings, and 2 on a usage error, a
# malformed manifest, or a missing ref.
#
# Manifest rows sit between the BEGIN and END marker lines, one per line:
#   feature <label>                - starts a feature group; the label says why
#   owned <path>                   - a fork-owned file; any change is allowed
#   hook <path> +<n> -<n> [note]   - an upstream file the fork edits, with its
#                                    added and deleted line budget
#   symbol <path> <name> [note]    - an upstream function or variable fork code
#                                    relies on, and the upstream file defining it
#
# Conventions that keep the hooks from conflicting: never edit inside an upstream
# function body except for a one-line call at a rarely touched boundary; never
# put fork prose in upstream heredocs, header comments, or doc comments; never
# add rows to upstream lists or tables; never append tests to an upstream test
# file; prefer calling a fork-owned executable over adding a source line at the
# end of an upstream library; name new fork files bin/fm-fork-*.sh and
# tests/fm-fork-*.test.sh; and at every sync check whether upstream has made a
# fork feature redundant before resolving its conflicts.
#
# BEGIN FORK MANIFEST
# feature #2 delivery evidence: workers reported "done" with no PR, and "checks green" when nothing had run
#   owned bin/fm-fork-delivery-evidence.sh
#   owned tests/fm-fork-delivery-evidence.test.sh
#   hook bin/fm-dod-lib.sh +2 -0 one gate call after the direct-PR and no-mistakes heredocs
#   symbol bin/fm-dod-lib.sh fm_dod_block
# feature #3 issue closure: GitHub silently leaves some referenced issues open after a merge
#   owned bin/fm-issue-closure.sh
#   owned tests/fm-issue-closure.test.sh
#   hook .agents/skills/ship-landing/SKILL.md +1 -0 surface an issue-closure discrepancy
#   hook bin/fm-branch-prompt.sh +1 -0 the supervision engine escalates an open issue
#   symbol bin/fm-pr-lib.sh fm_pr_url_parse
#   symbol bin/fm-pr-lib.sh FM_PR_PROVIDER
#   symbol bin/fm-teardown.sh KIND
#   symbol bin/fm-teardown.sh PR_URL
#   symbol bin/fm-teardown.sh DATA
#   symbol bin/fm-teardown.sh ID
#   symbol bin/fm-teardown.sh FM_ROOT
# feature #4 landed proofs: false refusals of squash-merged or unfetched work
#   owned bin/fm-fork-landed-lib.sh
#   hook bin/fm-teardown.sh +9 -1 source line, work_is_landed, push proof, two refusal prints, and #3's closure call
#   hook tests/fm-teardown.test.sh +470 -1 fork cases until they move to tests/fm-fork-landed.test.sh
#   hook tests/fm-gotmp.test.sh +2 -0 link this library into both hand-picked teardown fixtures
#   symbol bin/fm-teardown.sh work_is_landed
#   symbol bin/fm-teardown.sh pr_is_merged
#   symbol bin/fm-teardown.sh content_in_default
#   symbol bin/fm-teardown.sh validate_worktree_teardown_safety
#   symbol bin/fm-teardown.sh pr_number_from_branch
#   symbol bin/fm-teardown.sh ensure_commit_object
#   symbol bin/fm-teardown.sh unpushed_patches_are_in_pr_head
#   symbol bin/fm-teardown.sh default_branch
#   symbol bin/fm-teardown.sh TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY
#   symbol bin/fm-teardown.sh WT
#   symbol bin/fm-teardown.sh BASE_BRANCH
#   symbol bin/fm-teardown.sh SCRIPT_DIR
# feature #5 Bearings at scale: regression test only; upstream owns the fix
#   hook tests/fm-bearings-snapshot.test.sh +84 -0 fork case until it moves to tests/fm-fork-bearings-scale.test.sh
#   hook .github/workflows/ci.yml +2 -2 the Bearings case count, until that case moves
# feature #6 task bootstrap: fresh worktrees lacked prepared dependencies; with #13-#15 pooled-slot fixes
#   owned bin/fm-task-bootstrap.sh
#   owned tests/fm-task-bootstrap.test.sh
#   hook bin/fm-spawn.sh +95 -1 bootstrap call, abort cleanup, slot warning, and header prose
#   hook tests/fm-spawn-pool-base-freshen.test.sh +151 -1 #13-#15 regressions, including reissued-slot warnings
#   symbol bin/fm-spawn.sh spawn_abort_cleanup
#   symbol bin/fm-spawn.sh validate_spawn_worktree
#   symbol bin/fm-spawn.sh freshen_spawn_worktree_base
#   symbol bin/fm-spawn.sh RELAUNCH
#   symbol bin/fm-spawn.sh KIND
#   symbol bin/fm-spawn.sh WT
#   symbol bin/fm-spawn.sh T
#   symbol bin/fm-spawn.sh BACKEND
#   symbol bin/fm-backend.sh fm_backend_kill
#   symbol bin/fm-backend.sh fm_meta_get
# feature fork delta check: this script and its regression test
#   owned bin/fm-fork-delta.sh
#   owned tests/fm-fork-delta.test.sh
# END FORK MANIFEST
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-fork-delta: %s\n' "$*" >&2
  exit 2
}

manifest_file=$0
manifest_only=0
upstream_ref=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --manifest)
      [ "$#" -ge 2 ] || die_usage "--manifest needs a file"
      manifest_file=$2
      shift 2
      ;;
    --manifest-only) manifest_only=1; shift ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      [ -z "$upstream_ref" ] || die_usage "only one upstream ref may be given"
      upstream_ref=$1
      shift
      ;;
  esac
done
[ "$manifest_only" = 0 ] || [ -z "$upstream_ref" ] \
  || die_usage "--manifest-only takes no upstream ref"
upstream_ref=${upstream_ref:-upstream/main}
[ -f "$manifest_file" ] || die_usage "manifest file not found: $manifest_file"
git rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
  || die_usage "not inside a git repository with a HEAD commit"
top=$(git rev-parse --show-toplevel)

# Parallel arrays: one entry per owned or hook path, and one per symbol row.
path_list=()
path_kind=()
path_add=()
path_del=()
path_seen=()
sym_path=()
sym_name=()

manifest_error() {
  die_usage "malformed manifest row in $manifest_file: $1"
}

path_index() {  # <path>; prints the index of <path> in path_list
  local i=0
  while [ "$i" -lt "${#path_list[@]}" ]; do
    [ "${path_list[$i]}" != "$1" ] || { printf '%s\n' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

add_path_row() {  # <kind> <path> <add> <del> <row>
  ! path_index "$2" >/dev/null || manifest_error "$5 (path listed twice)"
  path_list+=("$2")
  path_kind+=("$1")
  path_add+=("$3")
  path_del+=("$4")
  path_seen+=(0)
}

in_block=0
saw_block=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '# BEGIN FORK MANIFEST') in_block=1; saw_block=1; continue ;;
    '# END FORK MANIFEST') in_block=0; continue ;;
  esac
  [ "$in_block" = 1 ] || continue
  case "$line" in
    '#'*) row=${line#\#} ;;
    *) manifest_error "$line (not a comment line)" ;;
  esac
  read -r kind a b c rest <<EOF
$row
EOF
  case "${kind:-}" in
    '') ;;
    feature) [ -n "${a:-}" ] || manifest_error "$row (feature needs a label)" ;;
    owned)
      [ -n "${a:-}" ] && [ -z "${b:-}" ] || manifest_error "$row (owned takes one path)"
      add_path_row owned "$a" 0 0 "$row"
      ;;
    hook)
      case "${b:-}:${c:-}" in
        +[0-9]*:-[0-9]*) ;;
        *) manifest_error "$row (hook needs <path> +<added> -<deleted>)" ;;
      esac
      case "${b#+}${c#-}" in *[!0-9]*) manifest_error "$row (hook budgets are whole numbers)" ;; esac
      add_path_row hook "$a" "${b#+}" "${c#-}" "$row"
      ;;
    symbol)
      [ -n "${a:-}" ] && [ -n "${b:-}" ] || manifest_error "$row (symbol needs <path> <name>)"
      case "$b" in
        [A-Za-z_]*) ;;
        *) manifest_error "$row (bad symbol name)" ;;
      esac
      case "$b" in *[!A-Za-z0-9_]*) manifest_error "$row (bad symbol name)" ;; esac
      sym_path+=("$a")
      sym_name+=("$b")
      ;;
    *) manifest_error "$row (unknown row type '$kind')" ;;
  esac
done < "$manifest_file"
[ "$saw_block" = 1 ] || die_usage "no FORK MANIFEST block in $manifest_file"
[ "$in_block" = 0 ] || die_usage "unterminated FORK MANIFEST block in $manifest_file"

findings=0
finding() {
  findings=$((findings + 1))
  printf 'fail: %s\n' "$*"
}

# A <rev> of "" means the checked-out files rather than a commit.
has_file() {  # <rev> <path>
  if [ -z "$1" ]; then
    [ -f "$top/$2" ]
  else
    git cat-file -e "$1:$2" 2>/dev/null
  fi
}

defines_symbol() {  # <rev> <path> <name>
  if [ -z "$1" ]; then
    grep -Eq "(^|[^A-Za-z0-9_\$])$3(\(\)|=)" "$top/$2"
  else
    git show "$1:$2" 2>/dev/null | grep -Eq "(^|[^A-Za-z0-9_\$])$3(\(\)|=)"
  fi
}

check_symbols() {  # <rev> <label>
  local i=0
  while [ "$i" -lt "${#sym_name[@]}" ]; do
    if ! has_file "$1" "${sym_path[$i]}"; then
      finding "${sym_path[$i]} does not exist at $2, so ${sym_name[$i]} is gone"
    elif ! defines_symbol "$1" "${sym_path[$i]}" "${sym_name[$i]}"; then
      finding "${sym_path[$i]} no longer defines ${sym_name[$i]} at $2"
    fi
    i=$((i + 1))
  done
}

if [ "$manifest_only" = 1 ]; then
  i=0
  while [ "$i" -lt "${#path_list[@]}" ]; do
    has_file "" "${path_list[$i]}" \
      || finding "manifest lists ${path_list[$i]} (${path_kind[$i]}), but the checkout has no such file"
    i=$((i + 1))
  done
  check_symbols "" "the checkout"
  status=ok
  [ "$findings" -eq 0 ] || status=fail
  printf 'FM_FORK_DELTA %s manifest-only paths=%s symbols=%s findings=%s\n' \
    "$status" "${#path_list[@]}" "${#sym_name[@]}" "$findings"
  [ "$findings" -eq 0 ] || exit 1
  exit 0
fi

upstream_sha=$(git rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null) \
  || die_usage "upstream ref '$upstream_ref' not found; run 'git fetch upstream' or pass the ref"
base=$(git merge-base HEAD "$upstream_sha" 2>/dev/null) \
  || die_usage "HEAD shares no history with $upstream_ref"
numstat=$(mktemp "${TMPDIR:-/tmp}/fm-fork-delta.XXXXXX")
trap 'rm -f "$numstat"' EXIT
git -c core.quotePath=false diff -z --numstat --no-renames "$base" HEAD -- > "$numstat" \
  || die_usage "git diff $base HEAD failed"

delta_paths=0
owned_paths=0
hook_paths=0
hook_added=0
hook_deleted=0
while IFS=$'\t' read -r -d '' added deleted path; do
  delta_paths=$((delta_paths + 1))
  if ! i=$(path_index "$path"); then
    finding "$path is in the fork delta (+$added -$deleted) but not in the manifest"
    continue
  fi
  path_seen[i]=1
  if [ "${path_kind[$i]}" = owned ]; then
    owned_paths=$((owned_paths + 1))
    continue
  fi
  hook_paths=$((hook_paths + 1))
  if [ "$added" = - ] || [ "$deleted" = - ]; then
    finding "$path is a binary change, which a hook budget cannot measure"
    continue
  fi
  hook_added=$((hook_added + added))
  hook_deleted=$((hook_deleted + deleted))
  if [ "$added" -gt "${path_add[$i]}" ] || [ "$deleted" -gt "${path_del[$i]}" ]; then
    finding "$path changes +$added -$deleted, over its manifest budget of +${path_add[$i]} -${path_del[$i]}"
  fi
done < "$numstat"

i=0
while [ "$i" -lt "${#path_list[@]}" ]; do
  if [ "${path_seen[$i]}" = 0 ]; then
    finding "manifest lists ${path_list[$i]} (${path_kind[$i]}), but it is not in the fork delta"
  fi
  if [ "${path_kind[$i]}" = owned ]; then
    ! git cat-file -e "$upstream_sha:${path_list[$i]}" 2>/dev/null \
      || finding "$upstream_ref also has the fork-owned ${path_list[$i]}, so a sync would collide; rename the fork file"
  else
    git cat-file -e "$upstream_sha:${path_list[$i]}" 2>/dev/null \
      || finding "$upstream_ref no longer has ${path_list[$i]}, so its fork hook has nowhere to land"
  fi
  i=$((i + 1))
done
check_symbols HEAD HEAD
check_symbols "$upstream_sha" "$upstream_ref"

status=ok
[ "$findings" -eq 0 ] || status=fail
printf 'FM_FORK_DELTA %s base=%s upstream=%s paths=%s owned=%s hooks=%s hook_lines=+%s/-%s symbols=%s findings=%s\n' \
  "$status" "$(git rev-parse --short=12 "$base")" "$upstream_ref" "$delta_paths" "$owned_paths" \
  "$hook_paths" "$hook_added" "$hook_deleted" "${#sym_name[@]}" "$findings"
[ "$findings" -eq 0 ] || exit 1
