#!/usr/bin/env bash
# Behavior tests for claim-to-observation fleet reconciliation.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-fleet-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-reconcile)
RUN_OUTPUT=
RUN_RC=

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

make_fakebin() {
  local fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
path=${2:-}
[ "${1:-}" = api ] || exit 90
if [ "$path" = /user ]; then
  [ "${FM_TEST_SCENARIO:-}" != unavailable ] || exit 1
  printf '{"login":"fixture"}\n'
  exit 0
fi
case "$path" in
  /repos/acme/app/pulls/7)
    case "${FM_TEST_SCENARIO:-}" in
      vacuous|untracked-vacuous|not-applicable|attested-not-applicable)
        printf '{"merged":false,"state":"open","mergeable_state":"clean","head":{"sha":"1111111111111111111111111111111111111111"}}\n'
        ;;
      landed-open)
        printf '{"merged":false,"state":"open","mergeable_state":"blocked","head":{"sha":"1111111111111111111111111111111111111111"}}\n'
        ;;
      merged-copy)
        printf '{"merged":true,"state":"closed","mergeable_state":"unknown","head":{"sha":"1111111111111111111111111111111111111111"}}\n'
        ;;
      partial)
        exit 1
        ;;
      *)
        printf '{"merged":false,"state":"open","mergeable_state":"blocked","head":{"sha":"1111111111111111111111111111111111111111"}}\n'
        ;;
    esac
    ;;
  /repos/acme/app/pulls?state=open\&head=acme%3Afm%2Funtracked\&per_page=2)
    if [ "${FM_TEST_SCENARIO:-}" = untracked-vacuous ]; then
      printf '{"pulls":[{"number":7}]}\n'
    else
      printf '{"pulls":[]}\n'
    fi
    ;;
  /repos/acme/app/commits/1111111111111111111111111111111111111111/check-runs?per_page=100)
    case "${FM_TEST_SCENARIO:-}" in
      not-applicable)
        printf '{"total_count":3,"check_runs":[{"name":"Required gate summary","conclusion":"success"},{"name":"Detect changed surfaces","conclusion":"success"},{"name":"API integration tests","conclusion":"skipped"}]}\n'
        ;;
      attested-not-applicable)
        printf '{"total_count":3,"check_runs":[{"name":"Required gate summary","conclusion":"success"},{"name":"Tests not applicable - docs-only","conclusion":"success"},{"name":"API integration tests","conclusion":"skipped"}]}\n'
        ;;
      *)
        printf '{"total_count":2,"check_runs":[{"name":"Required gate summary","conclusion":"success"},{"name":"API integration tests","conclusion":"skipped"}]}\n'
        ;;
    esac
    ;;
  /repos/acme/app/commits/main/check-runs?per_page=100)
    case "${FM_TEST_SCENARIO:-}" in
      main-red|mixed)
        printf '{"total_count":2,"returned":2,"failures":[{"name":"unit tests","conclusion":"failure"}],"sha":"2222222222222222222222222222222222222222"}\n'
        ;;
      *)
        printf '{"total_count":1,"returned":1,"failures":[],"sha":"2222222222222222222222222222222222222222"}\n'
        ;;
    esac
    ;;
  /repos/acme/app/commits/main/status?per_page=100)
    [ "${FM_TEST_SCENARIO:-}" != mixed ] || exit 1
    printf '{"state":"success","statuses":[]}\n'
    ;;
  /repos/acme/app/actions/workflows?per_page=100)
    if [ "${FM_TEST_SCENARIO:-}" = deploy-selector ]; then
      printf '{"total_count":1,"workflows":[{"id":9,"name":"Platform Deploy","path":".github/workflows/deploy.yml"}]}\n'
    else
      printf '{"total_count":0,"workflows":[]}\n'
    fi
    ;;
  /repos/acme/app/actions/workflows/9/runs?status=success\&per_page=5)
    printf '{"workflow_runs":[{"id":99,"created_at":"2026-07-28T12:00:00Z"}]}\n'
    ;;
  /repos/acme/app/actions/runs/99/jobs?per_page=100)
    printf '{"total_count":3,"jobs":[{"name":"Select deploy candidates","conclusion":"success"},{"name":"Deploy API","conclusion":"skipped"},{"name":"Deploy web","conclusion":"skipped"}]}\n'
    ;;
  *)
    printf 'unexpected fake gh-axi path: %s\n' "$path" >&2
    exit 91
    ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

run_reconciler() {
  local home=$1 fakebin=$2 scenario=$3
  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO="$scenario" \
    "$RECONCILE" --repo acme/app 2>&1)
  RUN_RC=$?
}

write_task() {
  local home=$1 worktree=$2
  mkdir -p "$worktree"
  fm_write_meta "$home/state/task.meta" \
    "worktree=$worktree" \
    "project=$home/project" \
    "pr=https://github.com/acme/app/pull/7"
}

test_clean_is_silent() {
  local home fakebin
  home=$(make_home clean)
  fakebin=$(make_fakebin clean)
  run_reconciler "$home" "$fakebin" clean
  expect_code 0 "$RUN_RC" "reconciled fleet"
  [ -z "$RUN_OUTPUT" ] || fail "reconciled fleet must be silent, got: $RUN_OUTPUT"
  pass "reconciled fleet is silent with exit 0"
}

test_deliberate_vacuous_green_divergence() {
  local home fakebin
  home=$(make_home vacuous)
  fakebin=$(make_fakebin vacuous)
  write_task "$home" "$home/worktree"
  run_reconciler "$home" "$fakebin" vacuous
  expect_code 1 "$RUN_RC" "vacuous green"
  assert_contains "$RUN_OUTPUT" "zero real test jobs executed" \
    "green summary with skipped real test must diverge"
  pass "deliberately constructed vacuous-green claim is caught"
}

test_untracked_open_change_is_checked() {
  local home fakebin
  home=$(make_home untracked-vacuous)
  fakebin=$(make_fakebin untracked-vacuous)
  fm_git_init_commit "$home/project"
  git -C "$home/project" checkout -qb fm/untracked
  git -C "$home/project" remote add origin https://github.com/acme/app.git
  fm_write_meta "$home/state/task.meta" \
    "worktree=$home/project" \
    "project=$home/project"
  run_reconciler "$home" "$fakebin" untracked-vacuous
  expect_code 1 "$RUN_RC" "untracked open vacuous green"
  assert_contains "$RUN_OUTPUT" "zero real test jobs executed" \
    "repository open PRs must be checked even before fleet metadata records them"
  pass "open changes are reconciled even when no task record names them yet"
}

test_applicability_is_not_conflated_with_never_evaluated() {
  local home fakebin
  home=$(make_home applicability)
  fakebin=$(make_fakebin applicability)
  write_task "$home" "$home/worktree"

  run_reconciler "$home" "$fakebin" not-applicable
  expect_code 2 "$RUN_RC" "ambiguous applicability"
  assert_contains "$RUN_OUTPUT" "could not verify vacuous-green applicability" \
    "a successful detector without an exposed decision must stay explicitly unverified"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "a potentially legitimate not-applicable result must not be called a divergence"

  run_reconciler "$home" "$fakebin" attested-not-applicable
  expect_code 0 "$RUN_RC" "attested not applicable"
  [ -z "$RUN_OUTPUT" ] \
    || fail "an explicit successful not-applicable attestation should reconcile: $RUN_OUTPUT"
  pass "not-applicable and never-evaluated outcomes remain distinct"
}

test_done_claim_and_merged_copy_diverge() {
  local home fakebin
  home=$(make_home landed)
  fakebin=$(make_fakebin landed)
  mkdir -p "$home/data"
  printf '%s\n' \
    '## In flight' \
    '' \
    '## Queued' \
    '' \
    '## Done' \
    '- [x] task - Shipped https://github.com/acme/app/pull/7 (repo: app) (merged 2026-07-28)' \
    > "$home/data/backlog.md"
  write_task "$home" "$home/worktree"
  run_reconciler "$home" "$fakebin" landed-open
  expect_code 1 "$RUN_RC" "Done claim"
  assert_contains "$RUN_OUTPUT" "is recorded Done" "Done backlog claim must be checked against merge state"

  run_reconciler "$home" "$fakebin" merged-copy
  expect_code 1 "$RUN_RC" "merged copy"
  assert_contains "$RUN_OUTPUT" "worker copy" "merged PR with existing worktree must diverge"
  pass "landed claims and silently retained worker copies are reconciled"
}

test_selector_only_deploy_and_red_main_diverge() {
  local home fakebin
  home=$(make_home deploy)
  fakebin=$(make_fakebin deploy)
  run_reconciler "$home" "$fakebin" deploy-selector
  expect_code 1 "$RUN_RC" "selector-only deploy"
  assert_contains "$RUN_OUTPUT" "ran only selector job" "selector-only successful deploy must diverge"

  run_reconciler "$home" "$fakebin" main-red
  expect_code 1 "$RUN_RC" "red main"
  assert_contains "$RUN_OUTPUT" "main (22222222) has 1 failing checks" "red main must diverge"
  pass "selector-only deploys and failing main checks are caught"
}

test_unavailable_and_partial_observations_exit_two() {
  local home fakebin
  home=$(make_home unavailable)
  fakebin=$(make_fakebin unavailable)
  run_reconciler "$home" "$fakebin" unavailable
  expect_code 2 "$RUN_RC" "unavailable GitHub"
  assert_contains "$RUN_OUTPUT" "could not verify GitHub observations" \
    "authentication or network failure must be explicit"

  write_task "$home" "$home/worktree"
  run_reconciler "$home" "$fakebin" partial
  expect_code 2 "$RUN_RC" "partial GitHub observation"
  assert_contains "$RUN_OUTPUT" "could not verify acme/app PR #7" \
    "one failed REST observation must make the run incomplete"
  pass "unavailable and partial observations degrade honestly with exit 2"
}

test_mixed_divergence_and_uncertainty_exit_two() {
  local home fakebin
  home=$(make_home mixed)
  fakebin=$(make_fakebin mixed)
  run_reconciler "$home" "$fakebin" mixed
  expect_code 2 "$RUN_RC" "mixed divergence and uncertainty"
  assert_contains "$RUN_OUTPUT" "divergence:" "mixed result must preserve observed divergence"
  assert_contains "$RUN_OUTPUT" "could not verify" "mixed result must preserve uncertainty"
  pass "incomplete verification dominates the exit code without hiding divergences"
}

test_status_reference_is_not_claimed_as_task_pr() {
  local home fakebin
  home=$(make_home status-reference)
  fakebin=$(make_fakebin status-reference)
  fm_write_meta "$home/state/task.meta" \
    "worktree=$home/worktree" \
    "project=$home/missing-project"
  printf '%s\n' \
    'resolved: leave the plan unchanged to avoid PR #7 conflict with another task' \
    > "$home/state/task.status"
  run_reconciler "$home" "$fakebin" clean
  expect_code 0 "$RUN_RC" "historical status reference"
  [ -z "$RUN_OUTPUT" ] || fail "a prose PR reference must not become the task change: $RUN_OUTPUT"
  pass "status prose that merely references another PR is not treated as the task claim"
}

test_clean_is_silent
test_deliberate_vacuous_green_divergence
test_untracked_open_change_is_checked
test_applicability_is_not_conflated_with_never_evaluated
test_done_claim_and_merged_copy_diverge
test_selector_only_deploy_and_red_main_diverge
test_unavailable_and_partial_observations_exit_two
test_mixed_divergence_and_uncertainty_exit_two
test_status_reference_is_not_claimed_as_task_pr
