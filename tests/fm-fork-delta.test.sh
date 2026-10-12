#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-delta.sh: the fork manifest check every
# upstream sync runs first and last.
#
# Each case builds a small fixture repository whose upstream-tip branch stands in
# for upstream/main, and a manifest file read through --manifest, so the cases
# never depend on a real upstream remote.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELTA="$ROOT/bin/fm-fork-delta.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-delta)

fx_git() {
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

# A repository whose shared base has an upstream library with one function and
# one variable, an upstream table, and an untouched upstream file. The
# upstream-tip branch adds one unrelated upstream commit; the fork branch (HEAD)
# adds a fork-owned file and a one-line hook in the library.
make_fixture() {
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/up" "$repo/fork"
  git init -q -b main "$repo"
  printf '%s\n' 'up_fn() {' '  echo up' '}' 'UP_VAR=1' > "$repo/up/lib.sh"
  printf '%s\n' '| a | b |' > "$repo/up/table.md"
  printf '%s\n' 'plain' > "$repo/up/other.txt"
  fx_git "$repo" add -A
  fx_git "$repo" commit -q -m base
  fx_git "$repo" branch upstream-tip
  fx_git "$repo" checkout -q upstream-tip
  printf '%s\n' 'more upstream' >> "$repo/up/other.txt"
  fx_git "$repo" commit -q -am "upstream moves on"
  fx_git "$repo" checkout -q main
  printf '%s\n' 'fork_fn() { up_fn; }' > "$repo/fork/own.sh"
  printf '%s\n' 'fork_fn' >> "$repo/up/lib.sh"
  fx_git "$repo" add -A
  fx_git "$repo" commit -q -m "fork feature"
  printf '%s\n' "$repo"
}

write_manifest() {  # <file> <row>...
  local file=$1
  shift
  {
    printf '%s\n' '#!/usr/bin/env bash' '# BEGIN FORK MANIFEST' '# feature fixture: a fork feature'
    printf '#   %s\n' "$@"
    printf '%s\n' '# END FORK MANIFEST'
  } > "$file"
}

run_delta() {  # <repo> <args>...; sets OUT and RC
  local repo=$1
  shift
  OUT=$(cd "$repo" && "$DELTA" "$@" 2>&1)
  RC=$?
}

matching_rows=(
  'owned fork/own.sh'
  'hook up/lib.sh +1 -0 one call line'
  'symbol up/lib.sh up_fn'
  'symbol up/lib.sh UP_VAR'
)

test_matching_delta_passes() {
  local repo manifest
  repo=$(make_fixture match)
  manifest="$TMP_ROOT/match.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 0 "$RC" "a delta that matches its manifest must pass (output: $OUT)"
  assert_contains "$OUT" "FM_FORK_DELTA ok" "the passing check printed no ok summary"
  assert_contains "$OUT" "paths=2 owned=1 hooks=1 hook_lines=+1/-0 symbols=2 findings=0" \
    "the summary miscounted the delta"
  assert_not_contains "$OUT" "fail:" "a matching delta still reported a finding"
  pass "fm-fork-delta.sh: a delta that matches its manifest passes"
}

test_unlisted_path_fails() {
  local repo manifest
  repo=$(make_fixture unlisted)
  printf '%s\n' 'fork edit' >> "$repo/up/other.txt"
  fx_git "$repo" commit -q -am "an unlisted fork edit"
  manifest="$TMP_ROOT/unlisted.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "an unlisted changed path must fail the check"
  assert_contains "$OUT" "fail: up/other.txt is in the fork delta (+1 -0) but not in the manifest" \
    "the check did not name the unlisted path"
  assert_contains "$OUT" "FM_FORK_DELTA fail" "the failing check printed no fail summary"
  pass "fm-fork-delta.sh: a changed path missing from the manifest fails"
}

test_hook_over_budget_fails() {
  local repo manifest
  repo=$(make_fixture budget)
  printf '%s\n' 'fork_fn again' >> "$repo/up/lib.sh"
  fx_git "$repo" commit -q -am "a second hook line"
  manifest="$TMP_ROOT/budget.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "a hook over its line budget must fail the check"
  assert_contains "$OUT" "fail: up/lib.sh changes +2 -0, over its manifest budget of +1 -0" \
    "the check did not name the over-budget hook"
  pass "fm-fork-delta.sh: a hook over its line budget fails"
}

test_stale_manifest_row_fails() {
  local repo manifest
  repo=$(make_fixture stale)
  manifest="$TMP_ROOT/stale.manifest"
  write_manifest "$manifest" "${matching_rows[@]}" 'hook up/table.md +1 -0 a row the fork dropped'
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "a manifest row for an unchanged path must fail the check"
  assert_contains "$OUT" "fail: manifest lists up/table.md (hook), but it is not in the fork delta" \
    "the check did not name the stale manifest row"
  pass "fm-fork-delta.sh: a manifest row outside the delta fails"
}

# An upstream rename of a symbol a fork library calls would merge cleanly and
# then break at run time, so the check must name it before the sync.
test_symbol_gone_upstream_fails() {
  local repo manifest
  repo=$(make_fixture symbol)
  fx_git "$repo" checkout -q upstream-tip
  printf '%s\n' 'up_fn_renamed() {' '  echo up' '}' 'UP_VAR=1' > "$repo/up/lib.sh"
  fx_git "$repo" commit -q -am "upstream renames up_fn"
  fx_git "$repo" checkout -q main
  manifest="$TMP_ROOT/symbol.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "a symbol upstream no longer defines must fail the check"
  assert_contains "$OUT" "fail: up/lib.sh no longer defines up_fn at upstream-tip" \
    "the check did not name the symbol upstream dropped"
  assert_not_contains "$OUT" "defines UP_VAR" "the check flagged a symbol upstream still defines"
  pass "fm-fork-delta.sh: a symbol upstream no longer defines fails"
}

test_symbol_mentions_are_not_definitions() {
  local repo manifest
  repo=$(make_fixture mentions)
  fx_git "$repo" checkout -q upstream-tip
  printf '%s\n' '# up_fn() was replaced' 'echo "up_fn() UP_VAR=1"' '# UP_VAR=1 was removed' > "$repo/up/lib.sh"
  fx_git "$repo" commit -q -am "upstream replaces definitions with mentions"
  fx_git "$repo" checkout -q main
  manifest="$TMP_ROOT/mentions.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "comments and quoted mentions must not satisfy symbol checks"
  assert_contains "$OUT" "fail: up/lib.sh no longer defines up_fn at upstream-tip" "the function mention passed"
  assert_contains "$OUT" "fail: up/lib.sh no longer defines UP_VAR at upstream-tip" "the variable mention passed"
  pass "fm-fork-delta.sh: symbol mentions do not count as definitions"
}

test_owned_path_collision_upstream_fails() {
  local repo manifest
  repo=$(make_fixture collision)
  fx_git "$repo" checkout -q upstream-tip
  mkdir -p "$repo/fork"
  printf '%s\n' 'upstream file' > "$repo/fork/own.sh"
  fx_git "$repo" add -A
  fx_git "$repo" commit -q -m "upstream adds the same path"
  fx_git "$repo" checkout -q main
  manifest="$TMP_ROOT/collision.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 1 "$RC" "upstream adding a fork-owned path must fail the check"
  assert_contains "$OUT" "fail: upstream-tip also has the fork-owned fork/own.sh" \
    "the check did not name the colliding fork-owned path"
  pass "fm-fork-delta.sh: upstream adding a fork-owned path fails"
}

test_malformed_manifest_and_missing_ref_are_usage_errors() {
  local repo manifest
  repo=$(make_fixture usage)
  manifest="$TMP_ROOT/malformed.manifest"
  write_manifest "$manifest" "${matching_rows[@]}" 'hook up/table.md 1 0'
  run_delta "$repo" --manifest "$manifest" upstream-tip
  expect_code 2 "$RC" "a hook row without signed budgets must be a manifest error"
  assert_contains "$OUT" "malformed manifest row" "the manifest error did not say so"

  manifest="$TMP_ROOT/good.manifest"
  write_manifest "$manifest" "${matching_rows[@]}"
  run_delta "$repo" --manifest "$manifest" no-such-upstream
  expect_code 2 "$RC" "a missing upstream ref must be a usage error, not a pass"
  assert_contains "$OUT" "upstream ref 'no-such-upstream' not found" \
    "the missing-ref error did not name the ref"
  pass "fm-fork-delta.sh: a malformed manifest or missing upstream ref stops with exit 2"
}

test_matching_delta_passes
test_unlisted_path_fails
test_hook_over_budget_fails
test_stale_manifest_row_fails
test_symbol_gone_upstream_fails
test_symbol_mentions_are_not_definitions
test_owned_path_collision_upstream_fails
test_malformed_manifest_and_missing_ref_are_usage_errors
