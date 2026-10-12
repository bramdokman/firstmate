#!/usr/bin/env bash
# Behavior tests for the fork's delivery-evidence gate: bin/fm-fork-delivery-evidence.sh
# and the pull-request Definition of done blocks bin/fm-brief.sh renders with it.
#
# Fork-owned (bin/fm-fork-delta.sh owns the fork manifest), so these cases live
# here rather than at the tail of the upstream tests/fm-brief.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-fork-delivery-evidence.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-delivery-evidence)

# A copy of tests/fm-brief.test.sh's registry fixture: one project per delivery
# mode, which fm-brief.sh ignores because the ship mode arrives as a flag.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# Measured failure (2026-07-30/31, seven occurrences across claude, codex and
# opencode/GLM): workers reported "done: committed <sha>" with no PR, and
# "checks green" on a fork PR whose runs sat at action_required so nothing had
# run. Both treat the absence of a visible failure as success, so every PR-based
# mode must state the positive evidence each half of done requires.
test_pr_modes_require_a_real_pr_and_genuinely_run_checks() {
  local home id brief mode
  home="$TMP_ROOT/done-evidence-home"
  write_registry "$home"

  for id_proj in "brief-done-evidence-nm:no-registry-proj" "brief-done-evidence-dp:direct-proj"; do
    id=${id_proj%%:*}
    case "$id" in
      *-nm) mode=no-mistakes ;;
      *) mode=direct-PR ;;
    esac
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "Neither half of the delivery report - the done line that names a PR - may be inferred from the absence of a failure." "$brief" \
      "$id: PR-based brief lost the absence-of-failure gate"
    assert_grep "A PR must exist and you must have its real URL." "$brief" \
      "$id: PR-based brief did not require a real PR URL"
    assert_grep "A commit, or even a pushed branch, is not a delivered PR" "$brief" \
      "$id: PR-based brief did not deny that committing is delivering"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep '`gh-axi pr checks <number>` printing nothing' "$brief" \
      "$id: PR-based brief did not name the exact no-output shape that read as green"
    # Rule 3 of every ship brief requires gh-axi for GitHub operations, so the
    # gate must not hand the worker a raw gh check read.
    assert_no_grep 'gh pr checks' "$brief" \
      "$id: PR-based brief named a raw gh check read instead of gh-axi"
    assert_grep "listing only skipped, queued, or pending runs is NOT green" "$brief" \
      "$id: PR-based brief accepted a check-run set with nothing actually run"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'sits at `action_required` and runs nothing' "$brief" \
      "$id: PR-based brief lost the fork-PR case that produced the false green"
    # Upstream's commit sentence stays; the gate qualifies it as the
    # implementation stage only.
    assert_grep 'In this definition of done, "complete when committed" names the implementation stage only' "$brief" \
      "$id: PR-based brief lets a local commit read as delivery"
  done

  # The evidence gate must not hand a worker a new way to declare success:
  # a missing PR is a blocker, never a done report.
  brief="$home/data/brief-done-evidence-dp/brief.md"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'never claim delivery without one: if the report should name a PR and none exists, append `blocked [at=<epoch>]: {what is actually true}` instead' \
    "$brief" "direct-PR brief turned a missing PR into something other than a blocker"
  assert_grep 'committing is not delivering, and the task is delivered only when a PR exists for your branch.' \
    "$brief" "direct-PR brief lost its PR-is-delivery statement"

  # The no-mistakes first report is a handoff, not delivery, and its terminal
  # gate keeps the exact status token firstmate's classifier consumes.
  brief="$home/data/brief-done-evidence-nm/brief.md"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'That first `done:` is the handoff that starts the pipeline' "$brief" \
    "no-mistakes brief no longer distinguishes the handoff from delivery"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'append `done [at=<epoch>]: PR {url} checks green` and stop' "$brief" \
    "no-mistakes brief lost its terminal checks-green report token"
  assert_grep "do not wait for it to keep monitoring in the background until merge" "$brief" \
    "no-mistakes brief lost the CI-ready return point"

  pass "fm-brief.sh: PR-based modes require a real PR and checks that actually ran"
}

# The evidence gate governs only the delivery report that names a PR. The
# no-mistakes handoff has no PR by design and is reported as `done: {summary}`
# at a local commit; an unscoped gate ("if there is no PR you are not done") let
# a literal reader route that legitimate handoff to a false `blocked:` and stall
# the flow.
test_no_mistakes_handoff_is_outside_the_delivery_gate() {
  local home brief
  home="$TMP_ROOT/handoff-scope-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-handoff-scope no-registry-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-handoff-scope/brief.md"

  # The no-PR handoff is still instructed exactly as before: commit, report,
  # stop.
  assert_grep "The task is complete only when committed on your branch." "$brief" \
    "no-mistakes brief lost the commit handoff"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.' "$brief" \
    "no-mistakes brief no longer instructs the handoff report"
  # The gate names its own scope, so the PR-less handoff can neither satisfy
  # nor violate it.
  assert_grep "the done line that names a PR" "$brief" \
    "no-mistakes brief's evidence gate is not scoped to the PR-naming delivery report"
  assert_no_grep "if there is no PR you are not done" "$brief" \
    "no-mistakes brief reads every no-PR done report as a violation, turning the handoff into a false blocker"
  assert_no_grep "Neither half of done may be inferred" "$brief" \
    "no-mistakes brief still carries the unscoped gate opening"
  # A missing PR at delivery still routes to blocked, never to a done report.
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'append `blocked [at=<epoch>]: {what is actually true}` instead' "$brief" \
    "no-mistakes brief lost the blocked routing for a missing PR at delivery"
  pass "fm-brief.sh: no-mistakes handoff sits outside the delivery evidence gate"
}

# local-only has no PR by definition, so the PR-based evidence gate must not be
# imposed on it: a requirement it cannot satisfy would be unfollowable.
test_local_only_keeps_its_no_pr_contract() {
  local home brief
  home="$TMP_ROOT/local-only-contract-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-localonly-nopr local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/brief-localonly-nopr/brief.md"

  assert_no_grep "A PR must exist" "$brief" \
    "local-only brief was given a PR requirement it cannot satisfy"
  assert_no_grep "Neither half of the delivery report" "$brief" \
    "local-only brief inherited the PR-based evidence gate"
  assert_no_grep "checks green" "$brief" \
    "local-only brief was given a CI-green requirement it has no CI for"
  assert_grep "no remote, no PR, no pipeline" "$brief" \
    "local-only brief lost its no-remote contract"
  assert_grep "append \`done [at=<epoch>]: ready in branch fm/brief-localonly-nopr\`" "$brief" \
    "local-only brief lost its ready-in-branch report"
  pass "fm-brief.sh: local-only keeps its no-PR definition of done"
}

# A forge=gerrit ship opens no pull request and has no forge CI to read, and its
# published-for-review report is already refused unless it names a canonical
# Gerrit change carrying the worker's HEAD tree. The PR evidence gate would
# contradict that contract, so neither Gerrit block may carry it.
test_gerrit_blocks_carry_no_pr_evidence_gate() {
  local home mode id brief
  home="$TMP_ROOT/gerrit-no-pr-gate-home"
  mkdir -p "$home/data"
  for mode in direct-PR no-mistakes; do
    id="brief-gerrit-nogate-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" review-server-project --mode "$mode" --forge gerrit >/dev/null 2>&1 \
      || fail "$mode: forge=gerrit brief generation should succeed"
    brief="$home/data/$id/brief.md"
    assert_grep "There is no pull request, no \`gh-axi\` call, and no forge CI result to report" "$brief" \
      "$mode: forge=gerrit brief lost its no-PR publishing contract"
    assert_no_grep "Neither half of the delivery report" "$brief" \
      "$mode: forge=gerrit brief was given the PR evidence gate it cannot satisfy"
    assert_no_grep "gh-axi pr checks" "$brief" \
      "$mode: forge=gerrit brief was told to read forge checks it does not have"
  done
  pass "fm-brief.sh: forge=gerrit blocks carry no PR evidence gate"
}

# The done wording must not displace any existing safety clause, in any ship
# mode.
test_ship_safety_clauses_survive_in_every_mode() {
  local home id brief mode
  home="$TMP_ROOT/safety-survival-home"
  write_registry "$home"

  for id_proj in "brief-safety-nm:no-registry-proj" "brief-safety-dp:direct-proj" "brief-safety-lo:local-proj"; do
    id=${id_proj%%:*}
    case "$id" in
      *-nm) mode=no-mistakes ;;
      *-dp) mode=direct-PR ;;
      *) mode=local-only ;;
    esac
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "**Verify isolation before anything else.**" "$brief" \
      "$id: brief lost the worktree-isolation assertion"
    assert_grep "blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree" "$brief" \
      "$id: brief lost the primary-checkout stop instruction"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$id: brief lost the Herdr lab gate"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$id: brief lost the Herdr regeneration instruction"
    assert_grep "only firstmate manages the daemon" "$brief" \
      "$id: brief lost the shared-daemon rule"
    assert_grep "append \`needs-decision [at=<epoch>]: {summary of options}\` and stop" "$brief" \
      "$id: brief lost the escalation rule"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief lost the nonterminal working: protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker"
  done

  # The Herdr hard contract still replaces the declaration when asked for.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-safety-lab direct-proj --mode direct-PR --herdr-lab >/dev/null 2>&1
  brief="$home/data/brief-safety-lab/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "--herdr-lab ship brief lost its hard safety contract alongside the done gate"
  assert_grep "A PR must exist and you must have its real URL." "$brief" \
    "--herdr-lab ship brief lost the done evidence gate"
  pass "fm-brief.sh: isolation, Herdr and reporting safety clauses survive in every ship mode"
}

# The gate names the check read for the forge the Definition of done targets, so
# a Forgejo pull request is never told to read GitHub checks.
test_gate_names_the_forge_check_read() {
  local out rc
  out=$("$GATE" forgejo) || fail "the gate refused forge=forgejo"
  assert_contains "$out" "A PR must exist and you must have its real URL." \
    "forge=forgejo gate lost the real-PR requirement"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_contains "$out" '`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/commits/<sha>/status`' \
    "forge=forgejo gate did not name the Forgejo status read"
  assert_not_contains "$out" "gh-axi" "forge=forgejo gate named a GitHub CLI"
  [ "$("$GATE")" = "$("$GATE" none)" ] \
    || fail "the gate's default forge is not none"

  out=$("$GATE" gerrit 2>"$TMP_ROOT/gate-gerrit.err"); rc=$?
  expect_code 2 "$rc" "the gate must refuse a forge with no pull requests"
  [ -z "$out" ] || fail "a refused forge still printed gate text: $out"
  assert_grep "no delivery-evidence gate for forge 'gerrit'" "$TMP_ROOT/gate-gerrit.err" \
    "the gate's refusal did not name the forge"
  pass "fm-fork-delivery-evidence.sh: names the forge's own check read and refuses forges without pull requests"
}

test_pr_modes_require_a_real_pr_and_genuinely_run_checks
test_no_mistakes_handoff_is_outside_the_delivery_gate
test_local_only_keeps_its_no_pr_contract
test_gerrit_blocks_carry_no_pr_evidence_gate
test_ship_safety_clauses_survive_in_every_mode
test_gate_names_the_forge_check_read
