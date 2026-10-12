#!/usr/bin/env bash
# Fork-owned landed-work proofs and issue-closure report for bin/fm-teardown.sh.
# bin/fm-teardown.sh sources this right after its work_is_landed(); it is not
# run on its own. bin/fm-fork-delta.sh owns the fork manifest, which lists the
# teardown hooks below and the upstream symbols this library relies on.
#
# Upstream's landed-work test (the bin/fm-teardown.sh header) stays word-for-word.
# This library only ADDS ways to prove that work landed, each tried after the
# matching upstream proof has failed, so no upstream verdict changes:
#   1. Push proof (fork_head_is_pushed): the remote itself reports a branch of
#      the same name that contains the local commits.
#   2. After upstream's pr_is_merged (fork_pr_landed): the merged GitHub PR's
#      head or squash merge commit holds every file the branch changed.
#   3. After upstream's content_in_default (fork_target_files_match): a 3-way
#      merge against the target branch that conflicts falls through to a
#      file-by-file comparison instead of being read as unlanded work.
# Every refusal also names the evidence sources that could not settle the
# question - an unreachable remote, a failed PR lookup, an unavailable merge
# commit, files left over - so an operator can verify the named gap instead of
# reaching for --force (landed_evidence_print).
# After a PR-based ship teardown, fork_issue_closure_report runs the best-effort
# merged-PR issue-closure report (bin/fm-issue-closure.sh).
#
# Push proof. A worktree may hold NO remote-tracking ref for its own branch (a
# fresh clone, a pruned ref, a worktree that never fetched), and then the local
# ahead-of-remote comparison has nothing to compare against and reads every
# commit as unpushed. That is absence of evidence, not evidence of absence, so
# the remotes are asked directly with `git ls-remote` - a read-only lookup that
# writes nothing to the worktree, unlike the fetch that would otherwise be
# needed. A lookup that cannot complete is recorded as unknown and never read as
# "safe to discard". Each lookup is bounded by FM_LS_REMOTE_TIMEOUT_SECS
# (default 30) when a timeout command is available, and never prompts for
# credentials; a lookup that times out is an unestablished fact like any other
# failure. A dirty worktree skips the proof because it refuses either way.
#
# Squash-merge proof. Commit identity is never the only test against a merged
# PR: a squash merge rewrites the branch's commits into one, so no local hash
# exists on the base even though every change does. When hash and patch-id
# comparisons come up empty, the FILES the branch changed are compared against
# the PR head and against the PR's own merge commit. A task whose meta records
# base_branch= (bin/fm-spawn.sh) fetches a merge commit that is not available
# locally from origin's copy of its base branch instead of the default branch,
# and runs the file-by-file content comparison against that branch too. A PR
# discovered by branch name also records its canonical URL as PR_URL, so the
# backlog close can record it. Only GitHub pull requests take this proof;
# another forge's PR keeps upstream's verdict.
#
# A diverged copy is never treated as landed on path identity alone: path-set
# coverage (same paths, whatever their content), git cherry, and merge-tree
# containment each fail to prove content landed without also accepting unlanded
# edits to the same paths. The file-by-file comparison accepts only every file
# at stake byte-identical to the PR head, the PR's merge commit, or the target
# branch; the same path with different content still refuses.

# Notes explaining exactly which evidence source could not confirm the work is
# safe to discard. Printed with the refusal so an operator can verify the named
# gap instead of reaching for --force.
LANDED_EVIDENCE=()

landed_note() {
  LANDED_EVIDENCE+=("$1")
}

landed_evidence_print() {
  local note
  [ "${#LANDED_EVIDENCE[@]}" -gt 0 ] || return 0
  echo "could not confirm the work landed:" >&2
  for note in "${LANDED_EVIDENCE[@]}"; do
    printf '  - %s\n' "$note" >&2
  done
}

worktree_branch_for_safety() {
  git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD
}

# Ask a remote what it actually holds for a branch. `git ls-remote` reads the
# remote over the wire and writes nothing to the repository - no fetch, no ref
# update - so it is the one authoritative remote lookup teardown may run inside a
# project worktree. Echoes the branch's remote sha and returns 0 when the remote
# has it, 2 when the remote authoritatively has no such branch, and 3 when the
# lookup itself could not complete (offline, auth, forge down). 3 is never read as
# "not pushed": the caller reports it as an unestablished fact.
LS_REMOTE_TIMEOUT_SECS=${FM_LS_REMOTE_TIMEOUT_SECS:-30}

ls_remote_branch_sha() {
  local remote=$1 branch=$2 out rc runner=
  if command -v timeout >/dev/null 2>&1; then
    runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=gtimeout
  fi
  set +e
  if [ -n "$runner" ]; then
    out=$(GIT_TERMINAL_PROMPT=0 "$runner" "$LS_REMOTE_TIMEOUT_SECS" \
      git -C "$WT" ls-remote --exit-code --heads "$remote" "refs/heads/$branch" 2>/dev/null </dev/null)
  else
    out=$(GIT_TERMINAL_PROMPT=0 \
      git -C "$WT" ls-remote --exit-code --heads "$remote" "refs/heads/$branch" 2>/dev/null </dev/null)
  fi
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 3 ;;
  esac
  out=$(printf '%s\n' "$out" | awk 'NF { print $1; exit }')
  [ -n "$out" ] || return 3
  printf '%s\n' "$out"
}

# Configured remotes, origin first so the usual answer costs one lookup.
worktree_remotes_origin_first() {
  git -C "$WT" remote 2>/dev/null | grep -x origin || true
  git -C "$WT" remote 2>/dev/null | grep -vx origin || true
}

# Are the worktree's commits already on a remote branch of the same name? A
# worktree can hold ZERO remote-tracking refs for its own branch - a fresh clone,
# a pruned ref, a worktree that never fetched - and then the local
# ahead-of-remote comparison has nothing to compare against and reads every
# commit as unpushed. Absence of a local ref is absence of evidence, so ask the
# remotes themselves. Returns 0 only on positive proof; every other outcome
# records why it could not be established and returns non-zero.
head_is_on_remote_branch() {
  local branch=$1 current remote sha rc checked=0
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || {
    landed_note "the worktree's current commit could not be read, so it could not be compared with any remote"
    return 1
  }
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
    landed_note "the worktree is on a detached HEAD, so there is no branch name to look up on the remote"
    return 1
  fi
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    checked=1
    set +e
    sha=$(ls_remote_branch_sha "$remote" "$branch")
    rc=$?
    set -e
    case "$rc" in
      0)
        [ "$sha" = "$current" ] && return 0
        if git -C "$WT" cat-file -e "$sha^{commit}" 2>/dev/null; then
          if git -C "$WT" merge-base --is-ancestor "$current" "$sha" 2>/dev/null; then
            return 0
          fi
          landed_note "$remote holds $branch at ${sha:0:12}, which does not contain the local commits"
        else
          landed_note "$remote holds $branch at ${sha:0:12}, which is not available locally, so containment of the local commits could not be verified"
        fi
        ;;
      2)
        landed_note "$remote has no branch named $branch"
        ;;
      *)
        landed_note "could not reach $remote to check whether $branch is pushed (git ls-remote failed or timed out); this is unknown, not proof the work is unpushed"
        ;;
    esac
  done <<EOF
$(worktree_remotes_origin_first)
EOF
  [ "$checked" -eq 1 ] || landed_note "the worktree has no git remote configured, so the branch could not be checked against one"
  return 1
}

# Are the files at stake already byte-identical at <ref>? This is the content
# question a hash comparison cannot answer: a squash merge rewrites N commits into
# one, so none of the branch's commit hashes exist at <ref> even though every
# change does. Comparing the FILES settles it, and unlike a 3-way merge it cannot
# come back "conflicted" and therefore inconclusive.
#
# branch_paths_match_ref <ref> <ref-contribution-from> <label>
#
# The files at stake are the ones this branch changed, plus - when
# <ref-contribution-from> is given - the ones <ref> itself contributed, measured
# from that revision. Both sides are needed: a local commit that REVERTS work the
# ref still carries touches no file relative to the branch's own base, so
# comparing only the branch's files would call that revert landed and discard it.
# Pass an empty <ref-contribution-from> only where the ref's own motion is not
# this task's work, as for the default branch.
# Returns 0 only when nothing at stake is left over.
branch_paths_match_ref() {
  local ref=$1 ref_from=$2 label=$3 base paths ref_paths path rc leftover count shown
  local -a changed=()
  base=$(git -C "$WT" merge-base HEAD "$ref" 2>/dev/null) || {
    landed_note "this branch shares no history with $label, so its changes could not be compared against it"
    return 1
  }
  paths=$(git -C "$WT" -c core.quotePath=true diff --no-renames --name-only "$base" HEAD -- 2>/dev/null) || {
    landed_note "could not list the files this branch changed, so nothing could be compared against $label"
    return 1
  }
  if [ -n "$ref_from" ]; then
    ref_paths=$(git -C "$WT" -c core.quotePath=true diff --no-renames --name-only "$ref_from" "$ref" -- 2>/dev/null) || {
      landed_note "could not list the files $label changed, so nothing could be compared against it"
      return 1
    }
    paths=$(printf '%s\n%s\n' "$paths" "$ref_paths" | sed '/^$/d' | sort -u)
  fi
  if [ -z "$paths" ]; then
    landed_note "this branch changes no files relative to $label, so a file-by-file comparison had nothing to check"
    return 1
  fi
  if printf '%s\n' "$paths" | grep -q '^"'; then
    landed_note "a file whose name git had to quote is at stake, so a file-by-file comparison against $label could not be trusted"
    return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] && changed+=("$path")
  done <<EOF
$paths
EOF
  [ "${#changed[@]}" -gt 0 ] || return 1
  set +e
  leftover=$(git -C "$WT" -c core.quotePath=true diff --no-renames --name-only --no-ext-diff \
    "$ref" HEAD -- "${changed[@]}" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    landed_note "comparing the files at stake against $label failed to run"
    return 1
  fi
  [ -n "$leftover" ] || return 0
  count=$(printf '%s\n' "$leftover" | grep -c . || true)
  shown=$(printf '%s\n' "$leftover" | head -5 | tr '\n' ' ')
  [ "$count" -le 5 ] || shown="$shown(and $((count - 5)) more) "
  landed_note "$label does not match this branch in $count file(s) the branch changed: ${shown% }"
  return 1
}

# Hook in validate_worktree_teardown_safety, right after the unpushed-commit read:
#   fork_head_is_pushed "$unpushed" "$dirty" && unpushed=
# `--not --remotes` can only compare against remote-tracking refs this worktree
# happens to hold, so ask the remotes themselves before treating the commits as
# unpushed. Starts every safety check with no refusal notes, and returns 0 only
# when commits looked unpushed, the worktree is clean, and a remote branch of the
# same name contains HEAD.
fork_head_is_pushed() {
  local unpushed=$1 dirty=$2 branch
  LANDED_EVIDENCE=()
  [ -n "$unpushed" ] && [ -z "$dirty" ] || return 1
  branch=$(worktree_branch_for_safety)
  # Read back by validate_worktree_teardown_safety's own branch lookup.
  # shellcheck disable=SC2034
  TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
  head_is_on_remote_branch "$branch" || return 1
  LANDED_EVIDENCE=()
}

# Hook in work_is_landed, tried only after upstream's pr_is_merged has failed:
#   fork_pr_landed "$branch" && return 0
# Is the worktree's GitHub PR merged with this work in it? Resolves the PR from
# the recorded pr= URL first, then from the branch name, and asks GitHub for the
# PR state, head, canonical URL, and merge commit. Commit identity is only the
# first test; the changed FILES are then compared against the PR head and against
# the PR's own merge commit, which is where a squashed branch's content actually
# lives. A PR discovered by branch name also sets PR_URL from the canonical URL so
# the backlog close can record it; a landed proof that yields no URL still
# returns non-zero. Every failure is recorded for the refusal.
fork_pr_landed() {
  local branch=$1 target view state head merge_sha rest resolved_url current head_base landed=0
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || {
      landed_note "no pull request could be found for branch $branch"
      return 1
    }
  fi
  [ -n "$target" ] || return 1
  # A recorded URL on another forge keeps upstream's verdict alone; the
  # subshell keeps the parse from replacing upstream's FM_PR_* values.
  if ( fm_pr_url_parse "$target" && [ "$FM_PR_PROVIDER" != github ] ); then
    landed_note "pull request $target is not a GitHub pull request, so only the forge's own merge check applied"
    return 1
  fi
  view=$(cd "$WT" && gh pr view "$target" \
    --json state,headRefOid,url,mergeCommit \
    -q '.state + "\t" + .headRefOid + "\t" + .url + "\t" + (.mergeCommit.oid // "")' 2>/dev/null) || {
    landed_note "the pull request lookup for $target failed, so its merge state is unknown"
    return 1
  }
  state=${view%%$'\t'*}
  rest=${view#*$'\t'}
  [ "$state" != "$view" ] || {
    landed_note "the pull request lookup for $target returned an unreadable answer"
    return 1
  }
  head=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  # An answer without the canonical URL column is unreadable; only the last,
  # merge-commit column may be absent.
  [ "$head" != "$rest" ] || {
    landed_note "the pull request lookup for $target returned an unreadable answer"
    return 1
  }
  resolved_url=${rest%%$'\t'*}
  merge_sha=${rest#*$'\t'}
  [ "$resolved_url" != "$rest" ] || merge_sha=
  case "$state" in
    MERGED|merged) ;;
    *)
      landed_note "pull request $target is $state, not merged"
      return 1
      ;;
  esac
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  if [ -n "$head" ] && ensure_commit_object "$target" "$head"; then
    if git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
      landed=1
    elif unpushed_patches_are_in_pr_head "$head"; then
      landed=1
    else
      head_base=$(git -C "$WT" merge-base "$current" "$head" 2>/dev/null) || head_base=
      if [ -n "$head_base" ] \
        && branch_paths_match_ref "$head" "$head_base" "the merged pull request $target"; then
        landed=1
      fi
    fi
  else
    landed_note "the head commit of merged pull request $target could not be retrieved, so the local commits could not be compared against it"
  fi
  if [ "$landed" != 1 ]; then
    merged_commit_contains_branch_change "$target" "$merge_sha" || return 1
  fi
  if [ -z "$PR_URL" ]; then
    [ -n "$resolved_url" ] || {
      landed_note "the pull request lookup for $target returned no URL to record on the backlog"
      return 1
    }
    PR_URL=$resolved_url
  fi
  return 0
}

# A squash merge lands the whole branch as one new commit on the base. That merge
# commit is the authoritative record of what the PR actually merged, so compare
# the files against it. Reached only after commit-identity tests have failed,
# which is exactly the squash case. What the merge commit contributed is measured
# against its own parent, not against the branch's base: the base branch keeps
# moving between a PR opening and merging, and that motion is not this task's work.
merged_commit_contains_branch_change() {
  local target=$1 merge_sha=$2 merge_parent
  if [ -z "$merge_sha" ]; then
    landed_note "merged pull request $target reports no merge commit, so its merged content could not be compared"
    return 1
  fi
  if ! git -C "$WT" cat-file -e "$merge_sha^{commit}" 2>/dev/null; then
    # The merge commit sits on the target branch; refreshing that ref is the
    # same read the content fallback performs, and it happens at most once.
    resolve_target_branch_ref || return 1
    git -C "$WT" cat-file -e "$merge_sha^{commit}" 2>/dev/null || {
      landed_note "the merge commit ${merge_sha:0:12} of pull request $target is not available locally, so its merged content could not be compared"
      return 1
    }
  fi
  merge_parent=$(git -C "$WT" rev-parse --quiet --verify "$merge_sha^{commit}^" 2>/dev/null) || merge_parent=
  if [ -z "$merge_parent" ]; then
    landed_note "the merge commit ${merge_sha:0:12} of pull request $target has no parent to measure what it merged"
    return 1
  fi
  branch_paths_match_ref "$merge_sha" "$merge_parent" \
    "the merge commit ${merge_sha:0:12} of pull request $target"
}

# Resolves the ref naming the up-to-date target branch into TEARDOWN_TARGET_REF,
# refreshing it from origin once per run. The target is the task's named base
# branch when its meta records base_branch= (bin/fm-spawn.sh), since the pull
# request targets it; otherwise the project's default branch. Returns non-zero,
# with the reason recorded, when the target branch cannot be established - a
# refresh that cannot complete is an unknown state, never a silent pass.
TEARDOWN_TARGET_REF=
TEARDOWN_TARGET_LABEL=
resolve_target_branch_ref() {
  local name
  [ -z "$TEARDOWN_TARGET_REF" ] || return 0
  if [ -n "${BASE_BRANCH:-}" ]; then
    name=$BASE_BRANCH
    TEARDOWN_TARGET_LABEL="the base branch"
  else
    name=$(default_branch) || {
      landed_note "the project's default branch could not be determined (expected origin/HEAD, main, or master), so the content check could not run"
      return 1
    }
    TEARDOWN_TARGET_LABEL="the default branch"
  fi
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || {
      landed_note "origin/$name could not be refreshed, so whether the work is already on $TEARDOWN_TARGET_LABEL is unknown"
      return 1
    }
    TEARDOWN_TARGET_REF="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    TEARDOWN_TARGET_REF="refs/heads/$name"
  else
    landed_note "there is no origin remote and no local $name branch to compare the work against"
    return 1
  fi
}


# Hook in work_is_landed, tried only after upstream's content_in_default has
# failed:
#   fork_target_files_match
# Is the branch's content already present in the up-to-date target branch? The
# same 3-way merge as upstream's content check, except that a merge which
# conflicts proves nothing either way, so it falls through to the file-by-file
# comparison rather than being read as unlanded work. Records why it could not
# prove landing, so the caller refuses rather than guesses.
fork_target_files_match() {
  local ref default_tree merged_tree
  resolve_target_branch_ref || return 1
  ref=$TEARDOWN_TARGET_REF
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || {
    landed_note "$TEARDOWN_TARGET_LABEL ref $ref could not be read"
    return 1
  }
  if merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null); then
    merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
    [ "$merged_tree" = "$default_tree" ] && return 0
    landed_note "$ref does not already contain this branch's changes"
    return 1
  fi
  # The target branch's own motion is not this task's work, so only the files
  # this branch changed are at stake - the same question the whole-tree merge
  # above answers when it can run.
  branch_paths_match_ref "$ref" "" "$TEARDOWN_TARGET_LABEL $ref"
}

# Hook at the end of a teardown, right after the fleet sync:
#   fork_issue_closure_report
# Best-effort: verify a merged PR's issues actually closed. GitHub silently
# ignores some closing keywords, leaving an issue open after the work lands; this
# reports any such discrepancy so firstmate can surface it. It never blocks
# teardown and never auto-closes anything. See bin/fm-issue-closure.sh.
fork_issue_closure_report() {
  if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ -n "$PR_URL" ]; then
    if [ -f "$DATA/$ID/brief.md" ]; then
      "$FM_ROOT/bin/fm-issue-closure.sh" "$PR_URL" --brief "$DATA/$ID/brief.md" || true
    else
      "$FM_ROOT/bin/fm-issue-closure.sh" "$PR_URL" || true
    fi
  fi
}
