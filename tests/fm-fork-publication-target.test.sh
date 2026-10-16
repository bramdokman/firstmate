#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-publication-target.sh: the fork's publication
# target for the self-repository guard, reached through the real gate
# (bin/fm-role.sh check, bin/fm-brief.sh --project).
#
# Each case builds fixture repositories that share one root commit, so lineage
# detection treats them as firstmate's own repository independent of this
# checkout's remotes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="$ROOT/bin/fm-role.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TARGET="$ROOT/bin/fm-fork-publication-target.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-publication-target)

FORK=github.com/someone/firstmate-fork
PARENT=github.com/kunchenguid/firstmate

fx_git() {
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

# The fixture code root: firstmate's stand-in history, origin on the parent.
CODE_ROOT="$TMP_ROOT/code-root"
git init -q "$CODE_ROOT" || fail "could not initialize the code root fixture"
fx_git "$CODE_ROOT" commit -q --allow-empty -m root || fail "could not commit in the code root"
git -C "$CODE_ROOT" remote add origin "https://$PARENT.git"

# make_fork_clone <name> [<remote>=<value>]... - a separate clone of the code
# root with origin on the fork and upstream on the parent, plus each given
# remote.<remote>.gh-resolved value. Echoes its path.
make_fork_clone() {
  local clone="$TMP_ROOT/$1" pair
  shift
  git clone -q --shared --no-checkout "$CODE_ROOT" "$clone" || fail "could not clone the code root"
  git -C "$clone" remote set-url origin "https://$FORK.git"
  git -C "$clone" remote add upstream "https://$PARENT.git"
  for pair in "$@"; do
    git -C "$clone" config "remote.${pair%%=*}.gh-resolved" "${pair#*=}"
  done
  printf '%s\n' "$clone"
}

# make_role_home <name> [<role-file-content>] - a bare home. Echoes its path.
make_role_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" > "$home/config/firstmate-role"
  fi
  printf '%s\n' "$home"
}

check_as() {  # <home> <project> [upstream-consent <scope>]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROLE" check "$@" 2>&1
}

test_origin_target_authority() {
  local proj out rc
  proj=$(make_fork_clone "$1" "${@:2}")
  out=$("$TARGET" "$proj"); rc=$?
  expect_code 0 "$rc" "$1 must select the fork (got: $out)"
  assert_equals "$FORK" "$out" "the fork target must be origin's normalized identity"

  out=$(check_as "$(make_role_home fork-maint "maintainer $FORK")" "$proj"); rc=$?
  expect_code 0 "$rc" "a maintainer scope naming the fork must authorize the fork's own PRs (got: $out)"
  assert_contains "$out" "authorized: maintainer scope $FORK" "the authority must name the fork scope"

  out=$(check_as "$(make_role_home fork-user)" "$proj"); rc=$?
  expect_code 1 "$rc" "a user home must still be refused on the fork (got: $out)"
  assert_contains "$out" "no publication authority for $FORK" "the refusal must name the fork as the target"
  assert_not_contains "$out" "$PARENT" "the refusal must not name the parent nothing is sent to"
  pass "$1: the guard judges the fork, and a fork maintainer scope authorizes it"
}

test_owner_repo_resolution_naming_origin_targets_the_fork() {
  local proj out rc
  proj=$(make_fork_clone named-origin origin=SomeOne/FirstMate-Fork)
  out=$("$TARGET" "$proj"); rc=$?
  expect_code 0 "$rc" "an owner/repo resolution naming origin's repository must select the fork (got: $out)"
  assert_equals "$FORK" "$out" "an owner/repo resolution must normalize to origin's identity"
  pass "an owner/repo gh resolution naming origin's repository selects the fork"
}

test_other_fork_default_targets_origin() {
  local proj out rc
  proj=$(make_fork_clone other-fork-default)
  git -C "$proj" remote add other https://github.com/another/firstmate.git
  git -C "$proj" config remote.other.gh-resolved base
  out=$("$TARGET" "$proj"); rc=$?
  expect_code 0 "$rc" "another fork default must select origin"
  assert_equals "$FORK" "$out" "another fork must not select the parent"
  out=$(check_as "$(make_role_home other-fork-maint "maintainer $FORK")" "$proj"); rc=$?
  expect_code 0 "$rc" "fork authority must cover origin with another fork default (got: $out)"
  pass "a default on another fork selects origin"
}

test_parent_target_still_refused_without_its_grant() {
  local case_name proj out rc fork_home user_home
  fork_home=$(make_role_home parent-fork-maint "maintainer $FORK")
  user_home=$(make_role_home parent-user)
  for case_name in base-on-upstream renamed-parent github-parent both-resolved; do
    case $case_name in
    base-on-upstream) proj=$(make_fork_clone "parent-$case_name" upstream=base) ;;
    renamed-parent | github-parent)
      proj=$(make_fork_clone "parent-$case_name" upstream=base)
      git -C "$proj" remote rename upstream parent
      git -C "$proj" remote set-url parent 'git@GitHub.com:Kunchenguid/Firstmate.git'
      if [ "$case_name" = github-parent ]; then
        git -C "$proj" remote rename parent github
      fi
      ;;
    both-resolved) proj=$(make_fork_clone "parent-$case_name" origin=base upstream=base) ;;
    esac
    out=$("$TARGET" "$proj"); rc=$?
    expect_code 0 "$rc" "$case_name must return the explicit parent target (got: $out)"
    assert_equals "$PARENT" "$out" "$case_name must print the normalized parent target"

    out=$(check_as "$fork_home" "$proj"); rc=$?
    expect_code 1 "$rc" "$case_name: a fork maintainer scope must not authorize publishing to the parent (got: $out)"
    assert_contains "$out" "no publication authority for $PARENT" "$case_name: the refusal must name the parent"

    out=$(check_as "$user_home" "$proj"); rc=$?
    expect_code 1 "$rc" "$case_name: a user home must be refused publishing to the parent (got: $out)"

    out=$(check_as "$user_home" "$proj" upstream-consent "$FORK"); rc=$?
    expect_code 1 "$rc" "$case_name: consent naming the fork must not cover the parent (got: $out)"

    out=$(check_as "$user_home" "$proj" upstream-consent "$PARENT"); rc=$?
    expect_code 0 "$rc" "$case_name: one-task consent naming the parent must still authorize it (got: $out)"
  done
  pass "an explicit parent target requires a grant naming the parent"
}

# A parent maintainer grant or parent consent does not leak onto the fork:
# authority always has to name the repository the PR lands on.
test_parent_grant_does_not_cover_the_fork() {
  local proj out rc
  proj=$(make_fork_clone parent-grant origin=base)
  out=$(check_as "$(make_role_home parent-maint "maintainer $PARENT")" "$proj"); rc=$?
  expect_code 1 "$rc" "a parent maintainer scope must not authorize the fork target (got: $out)"
  assert_contains "$out" "no publication authority for $FORK" "the refusal must name the fork"

  out=$(check_as "$(make_role_home parent-consent)" "$proj" upstream-consent "$PARENT"); rc=$?
  expect_code 1 "$rc" "consent naming the parent must not authorize the fork target (got: $out)"
  pass "authority must name the fork when the fork is the target"
}

# A local-path origin or default names no forge repository, so the fork rule
# never applies to it; an origin-only checkout keeps upstream's answer.
test_local_and_plain_checkouts_keep_upstream_rule() {
  local proj out rc
  proj=$(make_fork_clone local-origin origin=base)
  git -C "$proj" remote set-url origin "$CODE_ROOT"
  out=$("$TARGET" "$proj"); rc=$?
  expect_code 1 "$rc" "a local-path origin must not select a fork target (got: $out)"

  proj="$TMP_ROOT/plain"
  git clone -q --shared --no-checkout "$CODE_ROOT" "$proj" || fail "could not clone the code root"
  git -C "$proj" remote set-url origin "https://$FORK.git"
  out=$("$TARGET" "$proj"); rc=$?
  expect_code 0 "$rc" "an origin-only checkout without a gh default must select origin (got: $out)"
  assert_equals "$FORK" "$out" "the origin-only target must name the fork"
  out=$(check_as "$(make_role_home plain-maint "maintainer $FORK")" "$proj"); rc=$?
  expect_code 0 "$rc" "upstream's rule must still select origin when it is the only remote (got: $out)"

  out=$("$TARGET" "$TMP_ROOT/not-a-repo"); rc=$?
  expect_code 1 "$rc" "a missing project must leave upstream's rule"
  out=$("$TARGET" 2>&1); rc=$?
  expect_code 2 "$rc" "a missing argument must be a usage error"
  pass "local-path remotes and plain checkouts keep upstream's publication target"
}

# The dispatch surface sees the same target: fm-brief.sh's remedy names the
# fork, so the captain's grant is the fork scope rather than the parent.
test_brief_gate_names_the_fork() {
  local proj home out rc
  proj=$(make_fork_clone brief-fork)
  home=$(make_role_home brief-user)
  out=$(FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-fork-a some-proj --mode no-mistakes --project "$proj" 2>&1); rc=$?
  expect_code 1 "$rc" "a user home must be refused a publishing brief on the fork (got: $out)"
  assert_contains "$out" "write 'maintainer $FORK'" "the remedy must name the fork scope"

  home=$(make_role_home brief-maint "maintainer $FORK")
  out=$(FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-fork-b some-proj --mode no-mistakes --project "$proj" 2>&1); rc=$?
  expect_code 0 "$rc" "a fork maintainer home must scaffold the fork's publishing brief (got: $out)"
  pass "fm-brief.sh: the self-repository gate judges the fork and its maintainer scope"
}

test_origin_target_authority base-on-origin origin=base
test_origin_target_authority unset-default
test_origin_target_authority origin-names-other origin=another/firstmate
test_origin_target_authority origin-names-parent origin=kunchenguid/firstmate
test_other_fork_default_targets_origin
test_owner_repo_resolution_naming_origin_targets_the_fork
test_parent_target_still_refused_without_its_grant
test_parent_grant_does_not_cover_the_fork
test_local_and_plain_checkouts_keep_upstream_rule
test_brief_gate_names_the_fork

echo "# all fm-fork-publication-target tests passed"
