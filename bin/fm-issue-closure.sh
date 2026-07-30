#!/usr/bin/env bash
# Best-effort post-merge verification that the issues a merged GitHub PR was
# meant to close are actually closed, reporting - never auto-closing - any GitHub
# left open despite a closing reference.
#
# GitHub silently ignores some closing keywords even when the PR body carries a
# verified one, so the work lands on the default branch and the issue stays open
# with no error or signal. This re-derives the candidate issues the PR was meant
# to close, checks each candidate's state, and prints a clear report naming the
# PR and every still-open issue. It never closes anything: closing an issue on
# inferred evidence is an outward-facing human decision, and a wrong auto-close
# is worse than an open issue.
#
# It is best-effort and never blocks its caller: it always exits 0. A lookup
# failure (network down, gh error, missing issue) is reported on stderr and the
# merge is left unaffected. GitLab merge requests are out of scope and exit
# silently; the measured failure mode is GitHub-specific.
#
# Candidate issue numbers are unioned and deduplicated, scoped to the PR's own
# repository, from three sources:
#   - the PR body, parsed for GitHub's closing-keyword grammar
#     (close[sd]|fix(es|ed)?|resolve[ds]) followed by #N, owner/repo#N, or a full
#     issue URL. GitHub may have silently ignored exactly these keywords.
#   - GitHub's closingIssuesReferences for the PR, which captures references
#     GitHub linked from commit messages even when the PR body is bare.
#   - the task brief (--brief <path>), parsed with the same grammar, as a fallback
#     for work whose PR body carried no parseable reference at all.
# Usage: fm-issue-closure.sh <pr-url> [--brief <brief-path>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ] && [ "$#" -ne 3 ]; then
  echo "usage: fm-issue-closure.sh <pr-url> [--brief <brief-path>]" >&2
  exit 2
fi

PR_URL=$1
BRIEF=
if [ "$#" -eq 3 ]; then
  if [ "$2" != "--brief" ]; then
    echo "usage: fm-issue-closure.sh <pr-url> [--brief <brief-path>]" >&2
    exit 2
  fi
  BRIEF=$3
fi

if ! fm_pr_url_parse "$PR_URL"; then
  echo "issue-closure: not a valid PR URL: $PR_URL" >&2
  exit 0
fi

# GitLab merge-request closure verification is out of scope; exit silently.
[ "$FM_PR_PROVIDER" = github ] || exit 0

OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
REPO_SLASH="$OWNER/$REPO"

# Emit same-repository issue numbers referenced as closable by GitHub's
# closing-keyword grammar in the text on stdin, one number per line. The keyword
# must begin at a word boundary so prose such as "prefixes" or "unresolved" does
# not match. The reference may be a bare #N, an explicit owner/repo#N, or a full
# issue URL; references for other repositories are deliberately not emitted,
# since they cannot be resolved against this PR's repository.
issue_refs_from_text() {
  local boundary kw repo_re bare text
  boundary='(^|[^[:alnum:]_])'
  kw='(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+'
  repo_re=$(printf '%s' "$REPO_SLASH" | sed 's/[.]/\\./g')
  bare="${boundary}${kw}"
  # Buffer stdin once: the three pattern greps each need the whole text, but a
  # bare { grep; grep; grep; } block would let the first grep consume all stdin.
  text=$(cat)
  {
    printf '%s\n' "$text" | grep -oiE "${bare}#[0-9]+"
    printf '%s\n' "$text" | grep -oiE "${bare}${repo_re}#[0-9]+"
    printf '%s\n' "$text" | grep -oiE "${bare}https://github\.com/${repo_re}/issues/[0-9]+"
  } | grep -oE '#[0-9]+|/issues/[0-9]+' | grep -oE '[0-9]+'
}

main() {
  local pr_state body closing_refs brief_text candidates n state
  # Confirm the PR is merged first: this runs after landing, and an unmerged PR's
  # closing references are not this check's concern.
  if ! pr_state=$(gh pr view "$PR_URL" --json state -q .state 2>/dev/null); then
    echo "issue-closure: could not verify issue closure for $PR_URL (gh lookup failed); the merge is unaffected." >&2
    return 0
  fi
  case "$pr_state" in
    MERGED) ;;
    *) return 0 ;;
  esac

  if ! body=$(gh pr view "$PR_URL" --json body -q .body 2>/dev/null); then
    echo "issue-closure: could not read the body of $PR_URL (gh lookup failed); the merge is unaffected." >&2
    return 0
  fi

  closing_refs=$(gh pr view "$PR_URL" --json closingIssuesReferences \
    -q "[.closingIssuesReferences[] | select(.repository.owner.login == \"$OWNER\" and .repository.name == \"$REPO\") | .number] | unique | .[]" 2>/dev/null || true)

  brief_text=
  if [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
    brief_text=$(cat -- "$BRIEF" 2>/dev/null || true)
  fi

  candidates=$(
    {
      { printf '%s\n' "$body"; [ -z "$brief_text" ] || printf '%s\n' "$brief_text"; } | issue_refs_from_text
      printf '%s\n' "$closing_refs" | grep -E '^[0-9]+$' || true
    } | sort -n | uniq
  )

  # Nothing to verify: the PR deliberately closes nothing, so stay silent.
  [ -n "$candidates" ] || return 0

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! state=$(gh issue view "$n" -R "$REPO_SLASH" --json state -q .state 2>/dev/null); then
      echo "issue-closure: could not verify state of issue #$n for $PR_URL (gh lookup failed); the merge is unaffected." >&2
      continue
    fi
    case "$state" in
      OPEN)
        printf 'issue-closure: merged PR %s carried a closing reference for #%d (https://github.com/%s/issues/%d) but GitHub left it OPEN; it may need manual closing.\n' \
          "$PR_URL" "$n" "$REPO_SLASH" "$n"
        ;;
    esac
  done <<EOF
$candidates
EOF
}

# Always exit 0: a best-effort verification must never block teardown or any
# post-merge path. Discrepancies are reported on stdout, lookup failures on
# stderr, and silence means nothing actionable.
main
exit 0
