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
# Serves unfiltered GitHub REST bodies, applies the caller's own --jq program to
# them, and answers in gh-axi's real api_response envelope, so the reconciler's
# production jq filters are the code under test rather than fixture shapes that
# already made every selection decision for it.
set -u
[ "${1:-}" = api ] || exit 90
path=${2:-}
if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
jq_program=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jq_program=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done

respond() {
  local body
  if [ -z "$jq_program" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if ! body=$(printf '%s' "$1" | jq -r "$jq_program" 2>/dev/null); then
    printf 'fake gh-axi: --jq program failed for %s\n' "$path" >&2
    exit 92
  fi
  printf 'api_response:\n  body: %s\n  truncated: false\n' "$body"
}

main_check_runs() {
  local sha='"head_sha":"2222222222222222222222222222222222222222"'
  case "${FM_TEST_SCENARIO:-}" in
    main-red|mixed|default-branch-trunk|override-branch)
      printf '{"total_count":2,"check_runs":[{"name":"unit tests","status":"completed","conclusion":"failure",%s},{"name":"lint","status":"completed","conclusion":"success",%s}]}' "$sha" "$sha"
      ;;
    main-superseded)
      printf '{"total_count":2,"check_runs":[{"name":"unit tests","status":"completed","conclusion":"cancelled",%s},{"name":"required gate","status":"completed","conclusion":"stale",%s}]}' "$sha" "$sha"
      ;;
    main-failure-conclusions)
      printf '{"total_count":3,"check_runs":[{"name":"slow suite","status":"completed","conclusion":"timed_out",%s},{"name":"manual approval","status":"completed","conclusion":"action_required",%s},{"name":"runner boot","status":"completed","conclusion":"startup_failure",%s}]}' "$sha" "$sha" "$sha"
      ;;
    main-benign-conclusions)
      printf '{"total_count":3,"check_runs":[{"name":"optional advice","status":"completed","conclusion":"neutral",%s},{"name":"unchanged surface","status":"completed","conclusion":"skipped",%s},{"name":"unit tests","status":"completed","conclusion":"success",%s}]}' "$sha" "$sha" "$sha"
      ;;
    main-red-and-superseded)
      printf '{"total_count":2,"check_runs":[{"name":"unit tests","status":"completed","conclusion":"failure",%s},{"name":"required gate","status":"completed","conclusion":"cancelled",%s}]}' "$sha" "$sha"
      ;;
    *)
      printf '{"total_count":1,"check_runs":[{"name":"unit tests","status":"completed","conclusion":"success",%s}]}' "$sha"
      ;;
  esac
}

case "$path" in
  /user)
    [ "${FM_TEST_SCENARIO:-}" != unavailable ] || exit 1
    respond '{"login":"fixture"}'
    ;;
  /repos/acme/app)
    case "${FM_TEST_SCENARIO:-}" in
      override-branch)
        printf 'fake gh-axi: repository record requested despite an explicit branch override\n' >&2
        exit 93
        ;;
      default-branch-trunk)
        respond '{"name":"app","full_name":"acme/app","default_branch":"trunk"}'
        ;;
      default-branch-missing)
        respond '{"name":"app","full_name":"acme/app"}'
        ;;
      *)
        respond '{"name":"app","full_name":"acme/app","default_branch":"main"}'
        ;;
    esac
    ;;
  /repos/acme/app/pulls/7)
    case "${FM_TEST_SCENARIO:-}" in
      vacuous|untracked-vacuous|not-applicable|attested-not-applicable)
        respond '{"number":7,"merged":false,"state":"open","draft":false,"mergeable_state":"clean","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
      merged-copy)
        respond '{"number":7,"merged":true,"state":"closed","draft":false,"mergeable_state":"unknown","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
      unknown-mergeability)
        respond '{"number":7,"merged":false,"state":"open","draft":false,"mergeable_state":"unknown","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
      draft-vacuous)
        respond '{"number":7,"merged":false,"state":"open","draft":true,"mergeable_state":"blocked","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
      draft-unknown)
        respond '{"number":7,"merged":false,"state":"open","mergeable_state":"blocked","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
      partial)
        exit 1
        ;;
      *)
        respond '{"number":7,"merged":false,"state":"open","draft":false,"mergeable_state":"blocked","head":{"sha":"1111111111111111111111111111111111111111"}}'
        ;;
    esac
    ;;
  /repos/acme/app/pulls?state=open\&head=acme%3Afm%2Funtracked\&per_page=2)
    if [ "${FM_TEST_SCENARIO:-}" = untracked-vacuous ]; then
      respond '[{"number":7,"state":"open","head":{"ref":"fm/untracked"}}]'
    else
      respond '[]'
    fi
    ;;
  /repos/acme/app/commits/1111111111111111111111111111111111111111/check-runs?per_page=100)
    case "${FM_TEST_SCENARIO:-}" in
      not-applicable)
        respond '{"total_count":3,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"Detect changed surfaces","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"skipped"}]}'
        ;;
      bare-changes)
        respond '{"total_count":3,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"changes","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"skipped"}]}'
        ;;
      attested-not-applicable)
        respond '{"total_count":3,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"Docs-only change","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"skipped"}]}'
        ;;
      attested-testlike)
        respond '{"total_count":3,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"Tests skipped by path filter","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"skipped"}]}'
        ;;
      running-checks)
        respond '{"total_count":2,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"in_progress","conclusion":null}]}'
        ;;
      landed-open)
        respond '{"total_count":2,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"success"}]}'
        ;;
      *)
        respond '{"total_count":2,"check_runs":[{"name":"Required gate summary","status":"completed","conclusion":"success"},{"name":"API integration tests","status":"completed","conclusion":"skipped"}]}'
        ;;
    esac
    ;;
  /repos/acme/app/commits/main/check-runs?per_page=100|/repos/acme/app/commits/trunk/check-runs?per_page=100)
    respond "$(main_check_runs)"
    ;;
  /repos/acme/app/commits/main/status?per_page=100|/repos/acme/app/commits/trunk/status?per_page=100)
    [ "${FM_TEST_SCENARIO:-}" != mixed ] || exit 1
    respond '{"state":"success","statuses":[]}'
    ;;
  /repos/acme/app/actions/workflows?per_page=100)
    case "${FM_TEST_SCENARIO:-}" in
      deploy-selector|deploy-expired)
        respond '{"total_count":1,"workflows":[{"id":9,"name":"Platform Deploy","path":".github/workflows/deploy.yml"}]}'
        ;;
      *)
        respond '{"total_count":0,"workflows":[]}'
        ;;
    esac
    ;;
  /repos/acme/app/actions/workflows/9/runs?status=success\&per_page=5)
    if [ "${FM_TEST_SCENARIO:-}" = deploy-expired ]; then
      respond '{"total_count":1,"workflow_runs":[{"id":99,"created_at":"2019-01-01T12:00:00Z"}]}'
    else
      respond "$(printf '{"total_count":1,"workflow_runs":[{"id":99,"created_at":"%s"}]}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    fi
    ;;
  /repos/acme/app/actions/runs/99/jobs?per_page=100)
    respond '{"total_count":3,"jobs":[{"name":"Select deploy candidates","conclusion":"success"},{"name":"Deploy API","conclusion":"skipped"},{"name":"Deploy web","conclusion":"skipped"}]}'
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

# A gh-axi that answers with bare JSON instead of the documented api_response
# envelope: the shape the reconciler must refuse rather than read as an answer.
make_bare_json_fakebin() {
  local fakebin="$TMP_ROOT/$1/bare-json-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || exit 90
if [ "${2:-}" = /user ]; then
  printf '{"login":"fixture"}\n'
  exit 0
fi
printf '{"default_branch":"main","total_count":0,"returned":0,"check_runs":[],"failures":[],"uncertain":[],"workflows":[],"statuses":[]}\n'
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

# The no-argument fleet-wide mode, which discovers its own repositories.
run_reconciler_fleet() {
  local home=$1 fakebin=$2 scenario=$3
  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO="$scenario" \
    "$RECONCILE" 2>&1)
  RUN_RC=$?
}

write_registry() {
  local home=$1
  shift
  mkdir -p "$home/data"
  { printf '# Projects\n\n'; printf '%s\n' "$@"; } > "$home/data/projects.md"
}

write_project_clone() {
  local home=$1 name=$2 origin=$3
  fm_git_init_commit "$home/projects/$name"
  git -C "$home/projects/$name" remote add origin "$origin"
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

test_attestation_is_not_counted_as_test_execution() {
  local home fakebin
  home=$(make_home attestation)
  fakebin=$(make_fakebin attestation)
  write_task "$home" "$home/worktree"

  run_reconciler "$home" "$fakebin" attested-testlike
  expect_code 0 "$RUN_RC" "test-shaped attestation"
  [ -z "$RUN_OUTPUT" ] \
    || fail "an attestation must reconcile as an attestation: $RUN_OUTPUT"

  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO=attested-testlike \
    FM_RECONCILE_NOT_APPLICABLE_PATTERN='no attestation matches this' \
    "$RECONCILE" --repo acme/app 2>&1)
  RUN_RC=$?
  expect_code 0 "$RUN_RC" "attestation withdrawn from the attestation vocabulary"
  [ -z "$RUN_OUTPUT" ] \
    || fail "withdrawing the attestation vocabulary must not turn the same run into a divergence: $RUN_OUTPUT"
  pass "an attestation reconciles as an attestation whatever its name looks like"
}

test_draft_changes_are_out_of_vacuous_green_scope() {
  local home fakebin
  home=$(make_home draft)
  fakebin=$(make_fakebin draft)
  write_task "$home" "$home/worktree"

  run_reconciler "$home" "$fakebin" draft-vacuous
  expect_code 0 "$RUN_RC" "draft change"
  [ -z "$RUN_OUTPUT" ] \
    || fail "a draft asserts no readiness, so its deferred CI is not a divergence: $RUN_OUTPUT"

  run_reconciler "$home" "$fakebin" blocked-vacuous
  expect_code 1 "$RUN_RC" "ready change with the same checks"
  assert_contains "$RUN_OUTPUT" "zero real test jobs executed" \
    "the identical check set must diverge once the change is marked ready for review"

  run_reconciler "$home" "$fakebin" draft-unknown
  expect_code 2 "$RUN_RC" "undeterminable draft state"
  assert_contains "$RUN_OUTPUT" "whether the change is still a draft" \
    "an unreadable draft field must not be guessed in either direction"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "an unknown scope decision is uncertainty, not an observed disagreement"
  pass "draft changes are out of scope and re-enter it the moment they are ready"
}

test_vacuous_green_is_not_gated_on_mergeability() {
  local home fakebin
  home=$(make_home mergeability)
  fakebin=$(make_fakebin mergeability)
  write_task "$home" "$home/worktree"

  run_reconciler "$home" "$fakebin" blocked-vacuous
  expect_code 1 "$RUN_RC" "vacuous green awaiting review"
  assert_contains "$RUN_OUTPUT" "zero real test jobs executed" \
    "a change whose tests never ran must be reported even before it is mergeable"

  run_reconciler "$home" "$fakebin" unknown-mergeability
  expect_code 2 "$RUN_RC" "uncomputed mergeability"
  assert_contains "$RUN_OUTPUT" "GitHub has not computed mergeability" \
    "unknown mergeability must be explicit uncertainty"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "unknown mergeability must not be reported as a divergence"
  pass "vacuous green is judged on check completeness, not on mergeability"
}

test_running_checks_yield_no_vacuous_result() {
  local home fakebin
  home=$(make_home running)
  fakebin=$(make_fakebin running)
  write_task "$home" "$home/worktree"
  run_reconciler "$home" "$fakebin" running-checks
  expect_code 0 "$RUN_RC" "checks still running"
  [ -z "$RUN_OUTPUT" ] \
    || fail "an incomplete check set is still executing and must stay silent: $RUN_OUTPUT"
  pass "a change whose checks have not completed yields no vacuous verdict"
}

test_bare_detection_job_is_recognised_as_an_evaluator() {
  local home fakebin
  home=$(make_home bare-changes)
  fakebin=$(make_fakebin bare-changes)
  write_task "$home" "$home/worktree"
  run_reconciler "$home" "$fakebin" bare-changes
  expect_code 2 "$RUN_RC" "bare changes evaluator"
  assert_contains "$RUN_OUTPUT" "could not verify vacuous-green applicability" \
    "a bare path-filter job is an applicability evaluator whose decision is not exposed"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "a docs-only change gated by a bare changes job must not be a false divergence"
  pass "bare detection jobs are recognised instead of read as no evaluation at all"
}

test_unparseable_pr_claim_is_never_reconciled() {
  local home fakebin
  home=$(make_home duplicate-claim)
  fakebin=$(make_fakebin duplicate-claim)
  mkdir -p "$home/worktree"
  fm_write_meta "$home/state/task.meta" \
    "worktree=$home/worktree" \
    "project=$home/project" \
    "pr=https://github.com/acme/app/pull/7" \
    "pr=https://github.com/acme/app/pull/8"
  run_reconciler "$home" "$fakebin" clean
  expect_code 2 "$RUN_RC" "duplicate PR claim"
  assert_contains "$RUN_OUTPUT" "could not verify task task change" \
    "a metadata file with two PR claims must not be silently reconciled against one of them"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "an unparseable claim is uncertainty, not an observed disagreement"

  ln -sf "$home/state/task.meta" "$home/state/linked.meta"
  run_reconciler "$home" "$fakebin" clean
  expect_code 2 "$RUN_RC" "symlinked metadata"
  assert_contains "$RUN_OUTPUT" "could not verify task linked change" \
    "a symlinked metadata file must be refused the same way the PR commands refuse it"
  pass "PR claims are read through the hardened metadata parser only"
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

test_deploy_observation_window_expires_by_age() {
  local home fakebin
  home=$(make_home deploy-age)
  fakebin=$(make_fakebin deploy-age)
  run_reconciler "$home" "$fakebin" deploy-expired
  expect_code 0 "$RUN_RC" "expired deploy run"
  [ -z "$RUN_OUTPUT" ] \
    || fail "a deploy older than the observation window must not be re-reported forever: $RUN_OUTPUT"

  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO=deploy-selector \
    FM_RECONCILE_DEPLOY_MAX_AGE_DAYS=1 "$RECONCILE" --repo acme/app 2>&1)
  RUN_RC=$?
  expect_code 1 "$RUN_RC" "deploy run inside the window"
  assert_contains "$RUN_OUTPUT" "ran only selector job" \
    "a selector-only deploy inside the observation window must still diverge"

  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO=deploy-selector \
    FM_RECONCILE_DEPLOY_MAX_AGE_DAYS=0 "$RECONCILE" --repo acme/app 2>&1)
  RUN_RC=$?
  expect_code 2 "$RUN_RC" "invalid deploy window"
  assert_contains "$RUN_OUTPUT" "FM_RECONCILE_DEPLOY_MAX_AGE_DAYS must be 1..365" \
    "the age contract must be enforced explicitly"
  pass "the deploy observation window is bounded by run age"
}

test_cancelled_and_stale_main_checks_are_uncertain() {
  local home fakebin
  home=$(make_home main-superseded)
  fakebin=$(make_fakebin main-superseded)
  run_reconciler "$home" "$fakebin" main-superseded
  expect_code 2 "$RUN_RC" "cancelled and stale main checks"
  assert_contains "$RUN_OUTPUT" "cancelled or went stale" \
    "routine cancelled and stale checks must be reported as uncertainty"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "a superseded concurrency group is not a broken main branch"
  pass "cancelled and stale main checks are neither divergence nor silence"
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

test_main_check_conclusions_are_classified_by_the_shipped_filter() {
  local home fakebin
  home=$(make_home main-conclusions)
  fakebin=$(make_fakebin main-conclusions)

  run_reconciler "$home" "$fakebin" main-failure-conclusions
  expect_code 1 "$RUN_RC" "failure-like main conclusions"
  assert_contains "$RUN_OUTPUT" "has 3 failing checks" \
    "timed_out, action_required, and startup_failure are each failure-like on main"
  assert_contains "$RUN_OUTPUT" "slow suite" "the failing check names must be reported"
  assert_not_contains "$RUN_OUTPUT" "could not verify" \
    "an outright failing conclusion is an observed divergence, not uncertainty"

  run_reconciler "$home" "$fakebin" main-benign-conclusions
  expect_code 0 "$RUN_RC" "neutral, skipped, and successful main conclusions"
  [ -z "$RUN_OUTPUT" ] \
    || fail "neutral and skipped main checks are not a broken branch: $RUN_OUTPUT"

  run_reconciler "$home" "$fakebin" main-red-and-superseded
  expect_code 2 "$RUN_RC" "one failing and one cancelled main check"
  assert_contains "$RUN_OUTPUT" "has 1 failing checks" \
    "the failing check must stay a divergence when a cancelled one sits beside it"
  assert_contains "$RUN_OUTPUT" "cancelled or went stale" \
    "the cancelled check must stay uncertainty rather than joining the failure count"
  pass "main check conclusions are split by the shipped filter, not by the fixtures"
}

test_repository_default_branch_is_resolved_per_repository() {
  local home fakebin
  home=$(make_home default-branch)
  fakebin=$(make_fakebin default-branch)

  run_reconciler "$home" "$fakebin" default-branch-trunk
  expect_code 1 "$RUN_RC" "repository whose default branch is not main"
  assert_contains "$RUN_OUTPUT" "acme/app trunk" \
    "a repository that does not use main must be observed on its own default branch"
  assert_not_contains "$RUN_OUTPUT" "acme/app main" \
    "the fleet must not assume main for every repository"

  RUN_OUTPUT=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_SCENARIO=override-branch \
    FM_RECONCILE_MAIN_BRANCH=trunk "$RECONCILE" --repo acme/app 2>&1)
  RUN_RC=$?
  expect_code 1 "$RUN_RC" "explicit branch override"
  assert_contains "$RUN_OUTPUT" "acme/app trunk" \
    "an explicit override must select the branch without consulting the repository record"

  run_reconciler "$home" "$fakebin" default-branch-missing
  expect_code 2 "$RUN_RC" "unreported default branch"
  assert_contains "$RUN_OUTPUT" "could not verify acme/app default branch" \
    "a default branch GitHub does not report must be explicit uncertainty"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "an unresolved branch is uncertainty, not an observed disagreement"
  pass "each repository is observed on its own default branch"
}

test_only_the_documented_gh_axi_envelope_is_accepted() {
  local home fakebin
  home=$(make_home bare-json)
  fakebin=$(make_bare_json_fakebin bare-json)
  run_reconciler "$home" "$fakebin" clean
  expect_code 2 "$RUN_RC" "bare JSON instead of the api_response envelope"
  assert_contains "$RUN_OUTPUT" "did not return its documented api_response envelope" \
    "an undocumented response shape must be refused explicitly"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "an unparsed response must never be reported as an observation"
  pass "arbitrary JSON is could-not-verify rather than a comfortable answer"
}

test_no_argument_mode_discovers_registered_projects() {
  local home fakebin
  home=$(make_home registry)
  fakebin=$(make_fakebin registry)
  write_registry "$home" \
    '- app [direct-PR] - the delivery app (added 2026-06-22)' \
    '- notes [local-only] - captain notes (added 2026-06-22)'
  write_project_clone "$home" app https://github.com/acme/app.git
  run_reconciler_fleet "$home" "$fakebin" main-red
  expect_code 1 "$RUN_RC" "registry-discovered repository"
  assert_contains "$RUN_OUTPUT" "acme/app main" \
    "a registered project's repository must be discovered from its clone origin"
  assert_not_contains "$RUN_OUTPUT" "notes" \
    "a local-only project claims no GitHub repository and must not be reported"

  write_registry "$home" \
    '- app [direct-PR] - the delivery app (added 2026-06-22)' \
    '- ghost [no-mistakes] - registered but never cloned (added 2026-06-22)' \
    '- notes [local-only] - captain notes (added 2026-06-22)'
  run_reconciler_fleet "$home" "$fakebin" clean
  expect_code 2 "$RUN_RC" "registered project with no clone"
  assert_contains "$RUN_OUTPUT" "could not verify project ghost repository" \
    "a registered project whose clone is missing must be reported, not silently dropped"
  assert_not_contains "$RUN_OUTPUT" "divergence:" \
    "a missing clone is uncertainty, not an observed disagreement"
  pass "no-argument discovery reads the registry's own format"
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
test_attestation_is_not_counted_as_test_execution
test_draft_changes_are_out_of_vacuous_green_scope
test_vacuous_green_is_not_gated_on_mergeability
test_running_checks_yield_no_vacuous_result
test_bare_detection_job_is_recognised_as_an_evaluator
test_unparseable_pr_claim_is_never_reconciled
test_done_claim_and_merged_copy_diverge
test_selector_only_deploy_and_red_main_diverge
test_deploy_observation_window_expires_by_age
test_cancelled_and_stale_main_checks_are_uncertain
test_unavailable_and_partial_observations_exit_two
test_mixed_divergence_and_uncertainty_exit_two
test_main_check_conclusions_are_classified_by_the_shipped_filter
test_repository_default_branch_is_resolved_per_repository
test_only_the_documented_gh_axi_envelope_is_accepted
test_no_argument_mode_discovers_registered_projects
test_status_reference_is_not_claimed_as_task_pr
