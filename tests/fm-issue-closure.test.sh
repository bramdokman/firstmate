#!/usr/bin/env bash
# Behavior tests for bin/fm-issue-closure.sh: the best-effort post-merge check
# that the issues a merged GitHub PR was meant to close are actually closed.
#
# Two real GitHub failure modes motivate it:
#   - GitHub silently ignores a closing keyword, so a merged PR leaves its
#     issue open with no error. The body still carries the keyword, so the
#     check re-parses the body, cross-references GitHub's own
#     closingIssuesReferences, optionally mines the task brief, and reports any
#     referenced issue that is still OPEN.
#   - A PR carries no parseable reference at all. The check stays silent unless a
#     brief (--brief) supplies a closing reference.
#
# What the check must DO (acceptance criteria), exercised behaviorally through a
# mocked gh - never assertions about the script's source text:
#   (a) merged PR + open issue         -> clear report naming the PR and issue
#   (b) merged PR + closed issue       -> silent
#   (c) merged PR + no reference       -> silent (deliberately closes nothing)
#   (d) PR not merged                  -> silent
#   (e) gh lookup fails                -> stderr warning, exit 0, no report
#   (f) multiple issues, mixed states  -> report only the open ones
#   (g) one issue lookup fails         -> warn on stderr, still report the rest
#   (h) closingIssuesReferences source -> a commit-message-only ref is caught
#   (i) brief source                   -> a reference only in the brief is caught
#   (j) GitLab merge request           -> silent (out of scope)
#   (k) word boundary                  -> "prefixes #5" is NOT a closing ref
#   (l) cross-repo reference           -> ignored (not resolved against this repo)
#   (m) owner/repo#N and full URL form -> same-repo forms are recognized
#   (n) exit code                      -> always 0 (never blocks teardown)
#   (o) reference to a PR number       -> silent (issues and PRs share numbers)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOSURE="$ROOT/bin/fm-issue-closure.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-closure-tests)

assert_present "$CLOSURE" "bin/fm-issue-closure.sh is missing"
[ -x "$CLOSURE" ] || fail "bin/fm-issue-closure.sh must be executable"

PR_URL='https://github.com/example/repo/pull/42'
REPO_SLASH='example/repo'

# Build a fakebin case dir. Echoes the case dir. The gh mock is installed per
# test via gh_data_mock.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$case_dir"
}

# run_closure <case_dir> [args...]: run the script under the case's fakebin,
# capturing stdout and stderr into files. Sets OUT, ERR, RC.
run_closure() {
  local case_dir=$1; shift
  OUT=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CLOSURE_DATA="$case_dir/data" "$CLOSURE" "$@" 2>"$case_dir/err")
  RC=$?
  ERR=$(cat "$case_dir/err")
}

# --- gh mock builders ------------------------------------------------------

# A gh mock driven by simple data files in the case dir so a test declares the
# PR state, body, closing refs, and per-issue states without rewriting shell.
# Files (all optional):
#   pr_state    one word: MERGED (default), OPEN, CLOSED
#   pr_body     PR body text
#   pr_refs     newline-separated same-repo closingIssuesReferences numbers
#   fail        any content -> gh always exits 1 (lookup failure)
#   issue_<n>   state for issue #<n> (OPEN/CLOSED, or pull-request when #<n>
#               is actually a PR); absent -> lookup fails
gh_data_mock() {
  local case_dir=$1
  mkdir -p "$case_dir/data"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
D="${FM_CLOSURE_DATA:?}"
[ -f "$D/fail" ] && { echo "error: gh unavailable" >&2; exit 1; }
state=MERGED
[ -f "$D/pr_state" ] && state=$(cat "$D/pr_state")
body=
[ -f "$D/pr_body" ] && body=$(cat "$D/pr_body")
case "${1:-} ${2:-}" in
  "pr view")
    case "$*" in
      *"--json state -q"*) printf '%s\n' "$state"; exit 0 ;;
      *"--json body -q"*) printf '%s\n' "$body"; exit 0 ;;
      *"--json closingIssuesReferences"*)
        [ -f "$D/pr_refs" ] && cat "$D/pr_refs" || true
        exit 0 ;;
    esac
    ;;
  "api repos/"*"/issues/"*)
    n="${2##*/}"
    case "$n" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    if [ -f "$D/issue_$n" ]; then
      printf '%s\n' "$(cat "$D/issue_$n")"
      exit 0
    fi
    echo "error: issue not found" >&2
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

# --- tests -----------------------------------------------------------------

test_open_issue_is_reported() {
  local case_dir
  case_dir=$(make_case open-reported)
  gh_data_mock "$case_dir"
  printf 'MERGED\n' > "$case_dir/data/pr_state"
  printf 'This fixes #7.\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_7"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "open-issue: the check must never exit non-zero"
  assert_contains "$OUT" "issue-closure:" "open-issue: missing report line"
  assert_contains "$OUT" "$PR_URL" "open-issue: report must name the PR URL"
  assert_contains "$OUT" "#7" "open-issue: report must name the issue number"
  assert_contains "$OUT" "github.com/$REPO_SLASH/issues/7" "open-issue: report must link the issue"
  pass "a merged PR that left its issue open produces a report naming the PR and issue"
}

test_closed_issue_is_silent() {
  local case_dir
  case_dir=$(make_case closed-silent)
  gh_data_mock "$case_dir"
  printf 'This fixes #7.\n' > "$case_dir/data/pr_body"
  printf 'CLOSED\n' > "$case_dir/data/issue_7"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "closed-issue: exit must be 0"
  [ -z "$OUT" ] || fail "closed-issue: expected no report, got: $OUT"
  pass "a merged PR whose issue did close produces no noise"
}

test_no_reference_is_silent() {
  local case_dir
  case_dir=$(make_case no-ref)
  gh_data_mock "$case_dir"
  printf 'Routine change. See #100 for context.\n' > "$case_dir/data/pr_body"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "no-ref: exit must be 0"
  [ -z "$OUT" ] || fail "no-ref: 'See #100' is not a closing ref; expected silence, got: $OUT"
  pass "a merged PR with no closing reference produces no noise"
}

test_not_merged_is_silent() {
  local case_dir
  case_dir=$(make_case not-merged)
  gh_data_mock "$case_dir"
  printf 'OPEN\n' > "$case_dir/data/pr_state"
  printf 'This fixes #7.\n' > "$case_dir/data/pr_body"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "not-merged: exit must be 0"
  [ -z "$OUT" ] || fail "not-merged: an unmerged PR should not be verified, got: $OUT"
  pass "a PR that is not merged is not verified"
}

test_lookup_failure_is_reported_and_exits_zero() {
  local case_dir
  case_dir=$(make_case lookup-fail)
  gh_data_mock "$case_dir"
  : > "$case_dir/data/fail"
  printf 'This fixes #7.\n' > "$case_dir/data/pr_body"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "lookup-fail: a gh failure must not break the post-merge path (exit 0)"
  [ -z "$OUT" ] || fail "lookup-fail: no stdout report expected when the lookup fails, got: $OUT"
  assert_contains "$ERR" "could not verify" "lookup-fail: lookup failure must be reported on stderr"
  assert_contains "$ERR" "$PR_URL" "lookup-fail: warning must name the PR"
  assert_contains "$ERR" "merge is unaffected" "lookup-fail: warning must say the merge is unaffected"
  pass "failure of the issue lookup itself is reported and does not break the post-merge path"
}

test_multiple_issues_report_only_open() {
  local case_dir
  case_dir=$(make_case multi)
  gh_data_mock "$case_dir"
  printf 'fixes #1 and closes #2\n' > "$case_dir/data/pr_body"
  printf 'CLOSED\n' > "$case_dir/data/issue_1"
  printf 'OPEN\n' > "$case_dir/data/issue_2"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "multi: exit must be 0"
  assert_contains "$OUT" "#2" "multi: the open issue #2 must be reported"
  assert_not_contains "$OUT" "#1 " "multi: the closed issue #1 must not be reported"
  pass "a merged PR closing several issues reports only the ones still open"
}

test_one_issue_lookup_failure_continues() {
  local case_dir
  case_dir=$(make_case partial-fail)
  gh_data_mock "$case_dir"
  printf 'fixes #30 closes #31\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_30"
  # issue_31 intentionally absent -> lookup fails
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "partial-fail: exit must be 0"
  assert_contains "$OUT" "#30" "partial-fail: the verifiable open issue #30 must still be reported"
  assert_contains "$ERR" "#31" "partial-fail: the failed issue #31 must be warned on stderr"
  pass "a per-issue lookup failure is warned about and does not stop the rest of the check"
}

test_closing_references_source_is_used() {
  local case_dir
  case_dir=$(make_case closing-refs)
  gh_data_mock "$case_dir"
  # Body has NO keyword; GitHub linked #5 from a commit message.
  printf 'ship it\n' > "$case_dir/data/pr_body"
  printf '5\n' > "$case_dir/data/pr_refs"
  printf 'OPEN\n' > "$case_dir/data/issue_5"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "closing-refs: exit must be 0"
  assert_contains "$OUT" "#5" "closing-refs: a GitHub-linked commit-message reference must be caught"
  pass "GitHub's closingIssuesReferences supply candidates the body lacks"
}

test_brief_source_is_used() {
  local case_dir
  case_dir=$(make_case brief-src)
  gh_data_mock "$case_dir"
  printf 'ship it\n' > "$case_dir/data/pr_body"
  printf 'Task: fixes #12 by refactoring.\n' > "$case_dir/brief.md"
  printf 'OPEN\n' > "$case_dir/data/issue_12"
  run_closure "$case_dir" "$PR_URL" --brief "$case_dir/brief.md"
  expect_code 0 "$RC" "brief-src: exit must be 0"
  assert_contains "$OUT" "#12" "brief-src: a reference present only in the brief must be caught"
  pass "the task brief supplies candidates the PR body lacks"
}

test_brief_without_reference_is_silent() {
  local case_dir
  case_dir=$(make_case brief-silent)
  gh_data_mock "$case_dir"
  printf 'ship it\n' > "$case_dir/data/pr_body"
  printf 'Investigate the build. Related: #44.\n' > "$case_dir/brief.md"
  run_closure "$case_dir" "$PR_URL" --brief "$case_dir/brief.md"
  expect_code 0 "$RC" "brief-silent: exit must be 0"
  [ -z "$OUT" ] || fail "brief-silent: a non-closing 'Related: #44' must not be reported, got: $OUT"
  pass "a brief without a closing-keyword reference produces no noise"
}

test_gitlab_is_silent() {
  local case_dir
  case_dir=$(make_case gitlab)
  gh_data_mock "$case_dir"
  run_closure "$case_dir" 'https://gitlab.example.com/group/proj/-/merge_requests/5'
  expect_code 0 "$RC" "gitlab: exit must be 0"
  [ -z "$OUT" ] || fail "gitlab: merge-request closure is out of scope, expected silence, got: $OUT"
  pass "a GitLab merge request is out of scope and stays silent"
}

test_word_boundary_rejects_prose() {
  local case_dir
  case_dir=$(make_case word-boundary)
  gh_data_mock "$case_dir"
  printf 'Adds prefixes #5 and suffixes; unresolved #6 stays open.\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_5"
  printf 'OPEN\n' > "$case_dir/data/issue_6"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "word-boundary: exit must be 0"
  [ -z "$OUT" ] || fail "word-boundary: 'prefixes'/'suffixes'/'unresolved' are not keywords, expected silence, got: $OUT"
  pass "prose containing keyword substrings is not mistaken for a closing reference"
}

test_cross_repo_reference_ignored() {
  local case_dir
  case_dir=$(make_case cross-repo)
  gh_data_mock "$case_dir"
  printf 'closes other/repo#9\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_9"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "cross-repo: exit must be 0"
  [ -z "$OUT" ] || fail "cross-repo: a reference to another repo must be ignored, got: $OUT"
  pass "cross-repository closing references are not resolved against this PR's repo"
}

test_ownerrepo_and_url_forms_recognized() {
  local case_dir
  case_dir=$(make_case forms)
  gh_data_mock "$case_dir"
  printf 'Fixes example/repo#20 and resolves https://github.com/example/repo/issues/77\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_20"
  printf 'OPEN\n' > "$case_dir/data/issue_77"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "forms: exit must be 0"
  assert_contains "$OUT" "#20" "forms: the owner/repo#N form must be recognized"
  assert_contains "$OUT" "#77" "forms: the full issue-URL form must be recognized"
  pass "owner/repo#N and full issue-URL closing references are recognized"
}

test_pr_number_reference_is_silent() {
  local case_dir
  case_dir=$(make_case pr-number-ref)
  gh_data_mock "$case_dir"
  printf 'This fixes #50.\n' > "$case_dir/data/pr_body"
  printf 'pull-request\n' > "$case_dir/data/issue_50"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "pr-number-ref: exit must be 0"
  [ -z "$OUT" ] || fail "pr-number-ref: #50 is a PR, not an issue; expected silence, got: $OUT"
  [ -z "$ERR" ] || fail "pr-number-ref: a PR-numbered candidate must be skipped silently, got: $ERR"
  pass "a closing reference to a PR number is not reported as an open issue"
}

test_malformed_url_exits_zero() {
  local case_dir
  case_dir=$(make_case bad-url)
  gh_data_mock "$case_dir"
  run_closure "$case_dir" 'not-a-url'
  expect_code 0 "$RC" "bad-url: a malformed URL must not break the post-merge path (exit 0)"
  assert_contains "$ERR" "not a valid PR URL" "bad-url: the bad URL must be noted on stderr"
  pass "a malformed PR URL is reported and exits zero"
}

test_exit_zero_on_discrepancy() {
  local case_dir
  case_dir=$(make_case discrepancy-exit)
  gh_data_mock "$case_dir"
  printf 'fixes #7\nfixes #8\n' > "$case_dir/data/pr_body"
  printf 'OPEN\n' > "$case_dir/data/issue_7"
  printf 'OPEN\n' > "$case_dir/data/issue_8"
  run_closure "$case_dir" "$PR_URL"
  expect_code 0 "$RC" "discrepancy-exit: reporting discrepancies must never exit non-zero"
  pass "a discrepancy report is never an error exit (never blocks teardown)"
}

test_open_issue_is_reported
test_closed_issue_is_silent
test_no_reference_is_silent
test_not_merged_is_silent
test_lookup_failure_is_reported_and_exits_zero
test_multiple_issues_report_only_open
test_one_issue_lookup_failure_continues
test_closing_references_source_is_used
test_brief_source_is_used
test_brief_without_reference_is_silent
test_gitlab_is_silent
test_word_boundary_rejects_prose
test_cross_repo_reference_ignored
test_ownerrepo_and_url_forms_recognized
test_pr_number_reference_is_silent
test_malformed_url_exits_zero
test_exit_zero_on_discrepancy
