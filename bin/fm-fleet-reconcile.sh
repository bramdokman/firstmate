#!/usr/bin/env bash
# fm-fleet-reconcile.sh - compare durable fleet claims with GitHub observations.
#
# The command is read-only and prints only divergences or checks it could not
# complete.
# Silence with exit 0 means every check in scope reconciled.
# Exit 1 means at least one divergence was observed.
# Exit 2 means at least one check the command set out to perform could not be
# completed, including a run that also found divergences, because a failed
# observation must never read as clean.
# An observation the command deliberately holds out of scope is a different
# thing from a failed one: a draft change and a check suite that is still
# executing are reported as nothing at all rather than as uncertainty, because
# incomplete is not the same as untrue.
# Only a check that was in scope and could not be carried out counts toward
# exit 2.
#
# With no arguments, GitHub repositories are discovered from data/projects.md
# and task PR records.
# The registry records project names rather than GitHub slugs, so a registered
# non-local project's slug is read from the origin remote of its clone under
# projects/<name>; a project with no readable GitHub origin there is reported
# could-not-verify rather than silently dropped from the observation scope.
# Repeat --repo owner/name to restrict the observation scope.
#
# A task's recorded PR claim is read through the same hardened metadata parser
# the PR commands gate on, so a duplicated, symlinked, hardlinked, or otherwise
# unparseable claim is reported could-not-verify rather than reconciled against
# whichever URL happens to parse.
#
# The vacuous-green detector inspects every ready open change rather than only
# the ones GitHub already reports mergeable, because a change waiting on review
# is still a change whose tests may never have run.
# Mergeability GitHub has not computed is reported could-not-verify.
#
# A draft change is out of scope: a draft asserts no readiness, so there is no
# claim for its checks to disagree with, and CI a draft defers on purpose is not
# a divergence.
# That exclusion reads only the draft field of the current pull-request
# observation and remembers nothing, so marking a change ready for review brings
# it into scope on the very next run.
# A change whose check runs have not all completed is still executing, so it
# yields no vacuous result at all.
# The command deliberately does not guess a verdict from how long a check has
# been queued, so a slow or stuck queue stays silent rather than being reported
# as either clean or unverifiable.
#
# Once the checks are complete, successful check runs whose names match
# FM_RECONCILE_TEST_JOB_PATTERN count as real test execution, except names
# matching FM_RECONCILE_META_JOB_PATTERN or
# FM_RECONCILE_NOT_APPLICABLE_PATTERN.
# A successful FM_RECONCILE_NOT_APPLICABLE_PATTERN check is an explicit
# not-applicable attestation and reconciles, so it is classified as an
# attestation before it could be misread as the test execution it attests did
# not need to happen.
# When only a generic FM_RECONCILE_APPLICABILITY_JOB_PATTERN check succeeded,
# the check-run API cannot prove its decision, so the result is could-not-verify
# instead of a false divergence.
# Only zero real tests with no successful evaluator at all is a divergence.
#
# Deploy checks inspect the latest FM_RECONCILE_DEPLOY_RUNS successful runs for
# workflows matching FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN, and observe only runs
# created within the last FM_RECONCILE_DEPLOY_MAX_AGE_DAYS days.
# That age bound is the contract that keeps the per-run job requests cheap
# enough for a heartbeat, and lets a historical selector-only deploy expire
# instead of pinning the exit code to 1 forever on a rarely deploying
# repository.
# A selector-only deploy is one job that actually ran, matching
# FM_RECONCILE_DEPLOY_SELECTOR_PATTERN, with no other job that ran.
# A skipped job did not run, so it neither counts as work the deploy performed
# nor rescues a run whose only real job was the selector.
#
# Failure-like check conclusions on the main branch are divergences.
# The cancelled and stale conclusions are routine rather than red - a superseded
# concurrency group or a re-run leaves them behind - so they are reported
# could-not-verify instead of as a broken branch or as silence.
# The branch observed is each repository's own current default branch, read once
# per run from the repository record, because one fleet-global branch name would
# make every repository that does not use it permanently unverifiable.
# FM_RECONCILE_MAIN_BRANCH is an explicit override for every repository in scope
# rather than the only source, and a default branch GitHub does not report is
# could-not-verify.
#
# This command deliberately does not query merge-queue state, infer current
# worker state from historical status events, or guess that an old open PR was
# ejected.
# Those observations either consume scarce GraphQL quota or lack a sufficiently
# reliable claim-to-observation mapping for a scheduled heartbeat check.
#
# Every observation is read through gh-axi's documented api_response envelope
# and its base64 body only.
# Any other output shape is could-not-verify, so a wrapper that changes its
# rendering degrades honestly instead of being parsed as comfortable nonsense.
#
# The job-name patterns below are deliberately generic because this repository
# is a shared template.
# A fleet's own CI job vocabulary belongs in the captain-private environment
# that invokes this command, exported as the matching FM_RECONCILE_* override,
# rather than in a tracked default every other fleet would inherit.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_PROJECTS_OVERRIDE
#   FM_RECONCILE_MAIN_BRANCH               default: each repository's own
#                                          current GitHub default branch
#   FM_RECONCILE_TEST_JOB_PATTERN          default: common real-test job names
#   FM_RECONCILE_META_JOB_PATTERN          default: selector/summary/gate names
#   FM_RECONCILE_APPLICABILITY_JOB_PATTERN default: change/path detector names
#   FM_RECONCILE_NOT_APPLICABLE_PATTERN    default: explicit no-tests-needed names
#   FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN   default: deploy|release
#   FM_RECONCILE_DEPLOY_SELECTOR_PATTERN   default: selector/candidate/plan names
#   FM_RECONCILE_DEPLOY_RUNS               default: 5, range: 1..20
#   FM_RECONCILE_DEPLOY_MAX_AGE_DAYS       default: 14, range: 1..365
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
PROJECT_REGISTRY="$DATA/projects.md"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

MAIN_BRANCH_OVERRIDE=${FM_RECONCILE_MAIN_BRANCH:-}
TEST_JOB_PATTERN=${FM_RECONCILE_TEST_JOB_PATTERN:-'integration|db gates|packages|browser|(^|[^[:alnum:]])tests?([^[:alnum:]]|$)|e2e|typecheck.*build|jest|vitest|playwright|cypress|parity|smoke'}
META_JOB_PATTERN=${FM_RECONCILE_META_JOB_PATTERN:-'selector|summary|aggregate|required check|merge gate'}
APPLICABILITY_JOB_PATTERN=${FM_RECONCILE_APPLICABILITY_JOB_PATTERN:-'(^|[^[:alnum:]])(changes?|filters?|detect|paths?.filters?|changed.files)([^[:alnum:]]|$)|detect.*(change|surface|app)|change.*detect|path.*filter|select.*(test|suite|surface|applicab)'}
NOT_APPLICABLE_PATTERN=${FM_RECONCILE_NOT_APPLICABLE_PATTERN:-'not applicable|docs.only|no tests required|tests skipped by path filter'}
DEPLOY_WORKFLOW_PATTERN=${FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN:-'deploy|release'}
DEPLOY_SELECTOR_PATTERN=${FM_RECONCILE_DEPLOY_SELECTOR_PATTERN:-'select|selector|candidate|determine|changes|plan'}
DEPLOY_RUNS=${FM_RECONCILE_DEPLOY_RUNS:-5}
DEPLOY_MAX_AGE_DAYS=${FM_RECONCILE_DEPLOY_MAX_AGE_DAYS:-14}

DIVERGENCES=0
UNVERIFIED=0
EXPLICIT_REPOS=0
API_RESULT=
MAIN_BRANCH_RESULT=
REPOS=()
TASK_IDS=()
TASK_REPOS=()
TASK_PRS=()
TASK_WORKTREES=()
TASK_LANDED_CLAIMS=()
TASK_SOURCES=()
BRANCH_TASK_IDS=()
BRANCH_REPOS=()
BRANCH_NAMES=()
BRANCH_WORKTREES=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { line = $0; sub(/^# ?/, "", line); print line; next }
    { exit }
  ' "$0"
  printf '\nusage: fm-fleet-reconcile.sh [--repo owner/name]...\n'
}

divergence() {
  printf 'divergence: %s\n' "$1"
  DIVERGENCES=$((DIVERGENCES + 1))
}

could_not_verify() {
  printf 'could not verify %s: %s\n' "$1" "$2"
  UNVERIFIED=$((UNVERIFIED + 1))
}

repo_valid() {
  local repo=${1-}
  local LC_ALL=C
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] || return 1
  case "$repo" in
    *--*/*|*/.|*/..) return 1 ;;
  esac
}

nonnegative_integer() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

# A branch name safe to splice into a REST path. Slashes are legal in a branch
# and in the commits/<ref> route, so only the characters git itself refuses and
# the ones that would change which resource the path addresses are rejected.
branch_valid() {
  local branch=${1-}
  [ -n "$branch" ] || return 1
  case "$branch" in
    -*|/*|*/) return 1 ;;
    *[[:space:]]*|*'?'*|*'#'*|*'&'*|*'%'*|*'~'*|*'^'*|*':'*|*'['*|*'\'*|*'*'*) return 1 ;;
    *'..'*|*'//'*) return 1 ;;
  esac
}

repo_present() {
  local wanted=$1 repo
  for repo in "${REPOS[@]+"${REPOS[@]}"}"; do
    [ "$repo" = "$wanted" ] && return 0
  done
  return 1
}

add_repo() {
  repo_valid "$1" || return 1
  repo_present "$1" || REPOS+=("$1")
}

repo_selected() {
  [ "$EXPLICIT_REPOS" -eq 0 ] || repo_present "$1"
}

registry_names() {
  [ -f "$PROJECT_REGISTRY" ] || return 1
  awk '$1 == "-" && $2 != "" && $0 !~ /\[local-only/ { print $2 }' "$PROJECT_REGISTRY"
}

registry_lists_name() {
  local name=$1
  [ -f "$PROJECT_REGISTRY" ] || return 1
  awk -v n="$name" '$1 == "-" && $2 == n { found = 1 } END { exit(found ? 0 : 1) }' \
    "$PROJECT_REGISTRY"
}

repo_from_clone() {
  local dir=$1 origin
  [ -d "$dir" ] || return 1
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  repo_from_origin "$origin"
}

# The registry records project names, not GitHub slugs, so a registered
# project's repository is whatever its own clone calls origin.
registry_repo_for_name() {
  local name=$1
  registry_lists_name "$name" || return 1
  repo_from_clone "$PROJECTS/$name"
}

repo_from_origin() {
  local origin=$1 repo
  case "$origin" in
    https://github.com/*)
      repo=${origin#https://github.com/}
      ;;
    git@github.com:*)
      repo=${origin#git@github.com:}
      ;;
    ssh://git@github.com/*)
      repo=${origin#ssh://git@github.com/}
      ;;
    *) return 1 ;;
  esac
  repo=${repo%.git}
  repo_valid "$repo" || return 1
  printf '%s' "$repo"
}

repo_for_project() {
  local project=$1 name
  repo_from_clone "$project" && return 0
  name=${project##*/}
  registry_repo_for_name "$name"
}

meta_value() {
  local meta=$1 key=$2
  awk -v key="$key" '
    index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
    END { if (value != "") print value }
  ' "$meta"
}

task_record_index() {
  local id=$1 i
  for ((i = 0; i < ${#TASK_IDS[@]}; i++)); do
    [ "${TASK_IDS[$i]}" = "$id" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

add_task_record() {
  local id=$1 repo=$2 pr=$3 worktree=$4 landed=$5 source=$6 index
  repo_selected "$repo" || return 0
  if index=$(task_record_index "$id"); then
    if [ "${TASK_REPOS[$index]}" = "$repo" ] && [ "${TASK_PRS[$index]}" = "$pr" ]; then
      [ "$landed" -eq 0 ] || TASK_LANDED_CLAIMS[index]=1
      if [ "${TASK_WORKTREES[$index]}" = "-" ] && [ "$worktree" != "-" ]; then
        TASK_WORKTREES[index]=$worktree
        TASK_SOURCES[index]=$source
      fi
      return 0
    fi
    divergence "task $id claims both ${TASK_REPOS[$index]}#${TASK_PRS[$index]} and $repo#$pr"
  fi
  TASK_IDS+=("$id")
  TASK_REPOS+=("$repo")
  TASK_PRS+=("$pr")
  TASK_WORKTREES+=("$worktree")
  TASK_LANDED_CLAIMS+=("$landed")
  TASK_SOURCES+=("$source")
  [ "$EXPLICIT_REPOS" -eq 1 ] || add_repo "$repo"
}

backlog_claims_landed() {
  local id=$1
  [ -f "$BACKLOG" ] || return 1
  awk -v id="$id" '
    /^##[[:space:]]+Done[[:space:]]*$/ { done = 1; next }
    /^##[[:space:]]+/ { done = 0 }
    done && $1 == "-" && $2 == "[x]" && $3 == id { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$BACKLOG"
}

pr_from_status_url() {
  local status=$1 match
  [ -f "$status" ] || return 1
  match=$(tail -1 "$status" \
    | sed -n 's#^[a-z-]*: \(GitHub \)\{0,1\}PR https://github\.com/\([^/[:space:]]*\)/\([^/[:space:]]*\)/pull/\([0-9][0-9]*\).*#\2/\3 \4#p')
  [ -n "$match" ] || return 1
  printf '%s' "$match"
}

pr_number_from_status() {
  local status=$1 number
  [ -f "$status" ] || return 1
  number=$(tail -1 "$status" \
    | sed -n 's/^[a-z-]*: \(GitHub \)\{0,1\}PR[[:space:]]*#[[:space:]]*\([0-9][0-9]*\).*/\2/p')
  [ -n "$number" ] || return 1
  printf '%s' "$number"
}

discover_registry_repos() {
  local name candidate
  if [ ! -f "$PROJECT_REGISTRY" ]; then
    could_not_verify "registered repositories" "$PROJECT_REGISTRY is absent"
    return 0
  fi
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    if candidate=$(repo_from_clone "$PROJECTS/$name"); then
      add_repo "$candidate"
    else
      could_not_verify "project $name repository" \
        "its clone at $PROJECTS/$name reports no GitHub origin remote"
    fi
  done < <(registry_names)
}

meta_claims_pr() {
  grep -q '^pr=' "$1" 2>/dev/null
}

discover_meta_tasks() {
  local meta id repo pr worktree project status landed=0 status_match branch
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    status="$STATE/$id.status"
    worktree=$(meta_value "$meta" worktree)
    [ -n "$worktree" ] || worktree=-
    project=$(meta_value "$meta" project)
    repo=
    pr=
    if meta_claims_pr "$meta"; then
      if ! fm_pr_metadata_identity_parse "$meta"; then
        could_not_verify "task $id change" \
          "its metadata does not record exactly one parseable PR claim in an unshared regular file"
        continue
      fi
      if [ "$FM_PR_META_PROVIDER" != github ]; then
        could_not_verify "task $id change" "the reconciler currently observes GitHub PRs only"
        continue
      fi
      repo=$FM_PR_META_PATH
      pr=$FM_PR_META_NUMBER
    elif status_match=$(pr_from_status_url "$status"); then
      repo=${status_match% *}
      pr=${status_match##* }
    elif pr=$(pr_number_from_status "$status"); then
      if [ -z "$project" ] || ! repo=$(repo_for_project "$project"); then
        could_not_verify "task $id PR #$pr" "its GitHub repository could not be resolved"
        continue
      fi
    else
      if [ "$worktree" != "-" ] \
        && [ -d "$worktree" ] \
        && repo=$(repo_for_project "$project") \
        && branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) \
        && [ -n "$branch" ]; then
        repo_selected "$repo" || continue
        BRANCH_TASK_IDS+=("$id")
        BRANCH_REPOS+=("$repo")
        BRANCH_NAMES+=("$branch")
        BRANCH_WORKTREES+=("$worktree")
        [ "$EXPLICIT_REPOS" -eq 1 ] || add_repo "$repo"
      fi
      continue
    fi
    repo_valid "$repo" || {
      could_not_verify "task $id change" "its GitHub repository is invalid"
      continue
    }
    landed=0
    backlog_claims_landed "$id" && landed=1
    add_task_record "$id" "$repo" "$pr" "$worktree" "$landed" meta
  done
}

discover_backlog_tasks() {
  local section='' line id url
  [ -f "$BACKLOG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## In flight") section=in-flight; continue ;;
      "## Queued") section=queued; continue ;;
      "## Done") section='done'; continue ;;
      "## "*) section=; continue ;;
    esac
    case "$line" in
      "- ["?"] "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | awk '{print $3}')
    url=$(printf '%s\n' "$line" | grep -Eo 'https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*' | head -1)
    [ -n "$url" ] || continue
    if ! fm_pr_url_parse "$url" || [ "$FM_PR_PROVIDER" != github ]; then
      could_not_verify "backlog task $id change" "its PR URL is invalid or unsupported"
      continue
    fi
    if [ "$section" = 'done' ]; then
      add_task_record "$id" "$FM_PR_PATH" "$FM_PR_NUMBER" - 1 backlog
    else
      add_task_record "$id" "$FM_PR_PATH" "$FM_PR_NUMBER" - 0 backlog
    fi
  done < "$BACKLOG"
}

base64_decode() {
  if printf 'Zg==\n' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

api_get() {
  local subject=$1 path=$2 filter=$3 raw encoded
  API_RESULT=
  if ! raw=$(gh-axi api "$path" --jq "($filter) | @base64" 2>/dev/null); then
    could_not_verify "$subject" "GitHub REST request failed"
    return 1
  fi
  case "$raw" in
    'api_response:'*) ;;
    *)
      could_not_verify "$subject" "gh-axi did not return its documented api_response envelope"
      return 1
      ;;
  esac
  case "$raw" in
    *"truncated: true"*)
      could_not_verify "$subject" "gh-axi truncated the GitHub REST response"
      return 1
      ;;
  esac
  encoded=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*body: //p' | head -1)
  case "$encoded" in
    ''|*[!A-Za-z0-9+/=]*)
      could_not_verify "$subject" "gh-axi returned an unreadable REST response"
      return 1
      ;;
  esac
  if ! API_RESULT=$(printf '%s' "$encoded" | base64_decode 2>/dev/null); then
    could_not_verify "$subject" "gh-axi returned an unreadable REST response"
    return 1
  fi
  if ! printf '%s' "$API_RESULT" | jq -e . >/dev/null 2>&1; then
    could_not_verify "$subject" "GitHub REST returned invalid JSON"
    return 1
  fi
}

api_jq() {
  printf '%s' "$API_RESULT" | jq "$@"
}

# Reports whether the response carried every record it counted. Returns 2 when
# the counts themselves are missing and 1 when the page is short, so a caller
# whose verdict would be wrong on partial data can return while a caller that
# only reports what it did see keeps going. Both outcomes are could-not-verify.
api_counts_complete() {
  local subject=$1 returned_filter=$2 noun=$3 total returned
  total=$(api_jq -r '.total_count // -1')
  returned=$(api_jq -r "$returned_filter")
  if ! nonnegative_integer "$total" || ! nonnegative_integer "$returned"; then
    could_not_verify "$subject" "GitHub REST omitted $noun counts"
    return 2
  fi
  if [ "$total" -gt "$returned" ]; then
    could_not_verify "$subject" "more than $returned $noun exist"
    return 1
  fi
}

discover_branch_prs() {
  local i id repo branch worktree owner head_query count pr
  for ((i = 0; i < ${#BRANCH_TASK_IDS[@]}; i++)); do
    id=${BRANCH_TASK_IDS[$i]}
    repo=${BRANCH_REPOS[$i]}
    branch=${BRANCH_NAMES[$i]}
    worktree=${BRANCH_WORKTREES[$i]}
    owner=${repo%%/*}
    head_query=$(printf '%s' "$owner:$branch" | jq -sRr @uri)
    api_get "open change for task $id branch $branch" \
      "/repos/$repo/pulls?state=open&head=$head_query&per_page=2" \
      '{pulls:[.[]|{number}]}' || continue
    if ! api_jq -e '.pulls | type == "array"' >/dev/null; then
      could_not_verify "open change for task $id branch $branch" \
        "GitHub REST omitted the PR list"
      continue
    fi
    count=$(api_jq '.pulls | length')
    if [ "$count" -gt 1 ]; then
      could_not_verify "open change for task $id branch $branch" \
        "more than one open PR uses that fleet branch"
      continue
    fi
    [ "$count" -eq 1 ] || continue
    pr=$(api_jq -r '.pulls[0].number')
    if ! nonnegative_integer "$pr"; then
      could_not_verify "open change for task $id branch $branch" \
        "GitHub REST returned an invalid PR number"
      continue
    fi
    add_task_record "$id" "$repo" "$pr" "$worktree" 0 meta
  done
}

check_task_pr() {
  local id=$1 repo=$2 pr=$3 worktree=$4 landed=$5 source=$6
  local merged state draft mergeable head incomplete green real evaluated not_applicable
  api_get "$repo PR #$pr" "/repos/$repo/pulls/$pr" \
    '{merged,state,draft,mergeable_state,head:{sha:.head.sha}}' || return 0
  merged=$(api_jq -r 'if (.merged | type) == "boolean" then .merged else "invalid" end')
  state=$(api_jq -r '.state // "invalid"')
  if [ "$merged" = invalid ] || { [ "$state" != open ] && [ "$state" != closed ]; }; then
    could_not_verify "$repo PR #$pr" "GitHub REST omitted its merged or state field"
    return 0
  fi

  if [ "$landed" -eq 1 ] && [ "$merged" = false ]; then
    divergence "task $id is recorded Done, but $repo PR #$pr is not merged"
  fi
  if [ "$merged" = true ] && [ "$source" = meta ]; then
    if [ "$worktree" = "-" ]; then
      could_not_verify "cleanup for task $id" "its metadata has no worktree path"
    elif [ -e "$worktree" ] || [ -L "$worktree" ]; then
      divergence "task $id has merged $repo PR #$pr, but worker copy $worktree still exists"
    fi
  fi

  [ "$state" = open ] || return 0
  draft=$(api_jq -r 'if (.draft | type) == "boolean" then .draft else "invalid" end')
  if [ "$draft" = invalid ]; then
    could_not_verify "vacuous-green scope for $repo PR #$pr" \
      "GitHub REST omitted whether the change is still a draft"
    return 0
  fi
  [ "$draft" = false ] || return 0
  mergeable=$(api_jq -r '.mergeable_state // "unknown"')
  if [ "$mergeable" = unknown ]; then
    could_not_verify "vacuous-green state for $repo PR #$pr" "GitHub has not computed mergeability"
    return 0
  fi
  head=$(api_jq -r '.head.sha // empty')
  if ! fm_pr_head_valid "$head"; then
    could_not_verify "vacuous-green state for $repo PR #$pr" "GitHub REST omitted a valid head SHA"
    return 0
  fi
  api_get "check execution for $repo PR #$pr" \
    "/repos/$repo/commits/$head/check-runs?per_page=100" \
    '{total_count,check_runs:[.check_runs[]|{name,status,conclusion}]}' || return 0
  api_counts_complete "check execution for $repo PR #$pr" \
    '.check_runs | if type == "array" then length else -1 end' 'check runs' || return 0
  incomplete=$(api_jq '[.check_runs[]
    | select(.conclusion == null or ((.status // "completed") != "completed"))
  ] | length')
  [ "$incomplete" -eq 0 ] || return 0
  green=$(api_jq '[.check_runs[] | select(.conclusion == "success")] | length')
  # shellcheck disable=SC2016 # single quotes are deliberate: $real, $meta, and $attested are jq --arg variables, not shell expansions.
  real=$(api_jq \
    --arg real "$TEST_JOB_PATTERN" \
    --arg meta "$META_JOB_PATTERN" \
    --arg attested "$NOT_APPLICABLE_PATTERN" \
    '[.check_runs[]
      | select(.conclusion == "success")
      | select(.name | test($real; "i"))
      | select((.name | test($meta; "i")) | not)
      | select((.name | test($attested; "i")) | not)
    ] | length')
  if [ "$green" -gt 0 ] && [ "$real" -eq 0 ]; then
    # shellcheck disable=SC2016 # single quotes are deliberate: $pattern is a jq --arg variable, not a shell expansion.
    not_applicable=$(api_jq \
      --arg pattern "$NOT_APPLICABLE_PATTERN" \
      '[.check_runs[]
        | select(.conclusion == "success")
        | select(.name | test($pattern; "i"))
      ] | length')
    [ "$not_applicable" -eq 0 ] || return 0
    # shellcheck disable=SC2016 # single quotes are deliberate: $pattern is a jq --arg variable, not a shell expansion.
    evaluated=$(api_jq \
      --arg pattern "$APPLICABILITY_JOB_PATTERN" \
      '[.check_runs[]
        | select(.conclusion == "success")
        | select(.name | test($pattern; "i"))
      ] | length')
    if [ "$evaluated" -gt 0 ]; then
      could_not_verify "vacuous-green applicability for $repo PR #$pr" \
        "an applicability job ran, but check-run names do not attest whether running zero tests was correct"
    else
      divergence "$repo PR #$pr completed $green successful checks, but zero real test jobs executed and no applicability job evaluated the change"
    fi
  fi
}

# Resolves the branch check_main observes into MAIN_BRANCH_RESULT rather than
# returning it, so a failed resolution still counts toward the exit code instead
# of being swallowed by a command substitution.
resolve_main_branch() {
  local repo=$1 branch
  MAIN_BRANCH_RESULT=
  if [ -n "$MAIN_BRANCH_OVERRIDE" ]; then
    MAIN_BRANCH_RESULT=$MAIN_BRANCH_OVERRIDE
    return 0
  fi
  api_get "$repo default branch" "/repos/$repo" '{default_branch}' || return 1
  branch=$(api_jq -r '.default_branch // empty')
  if ! branch_valid "$branch"; then
    could_not_verify "$repo default branch" \
      "GitHub REST did not report a usable default branch name"
    return 1
  fi
  MAIN_BRANCH_RESULT=$branch
}

check_main() {
  local repo=$1 branch failures names uncertain uncertain_names legacy_count legacy_failures sha
  resolve_main_branch "$repo" || return 0
  branch=$MAIN_BRANCH_RESULT
  api_get "$repo $branch checks" \
    "/repos/$repo/commits/$branch/check-runs?per_page=100" \
    '{
      total_count,
      returned:(.check_runs|length),
      sha:(.check_runs[0].head_sha // null),
      failures:[
        .check_runs[]
        | select(.conclusion == "failure"
          or .conclusion == "timed_out"
          or .conclusion == "action_required"
          or .conclusion == "startup_failure")
        | {name,conclusion}
      ],
      uncertain:[
        .check_runs[]
        | select(.conclusion == "cancelled" or .conclusion == "stale")
        | {name,conclusion}
      ]
    }' || return 0
  api_counts_complete "$repo $branch checks" '.returned // -1' 'check runs'
  [ "$?" -ne 2 ] || return 0
  sha=$(api_jq -r '.sha // empty | .[0:8]')
  failures=$(api_jq '.failures | length')
  if [ "$failures" -gt 0 ]; then
    names=$(api_jq -r '[.failures[].name][0:5] | join(", ")')
    divergence "$repo $branch${sha:+ ($sha)} has $failures failing checks${names:+: $names}"
  fi
  uncertain=$(api_jq '.uncertain | length')
  if [ "$uncertain" -gt 0 ]; then
    uncertain_names=$(api_jq -r '[.uncertain[].name][0:5] | join(", ")')
    could_not_verify "$repo $branch${sha:+ ($sha)} checks" \
      "$uncertain checks were cancelled or went stale, which is routine but leaves them unproven${uncertain_names:+: $uncertain_names}"
  fi

  api_get "$repo $branch commit statuses" \
    "/repos/$repo/commits/$branch/status?per_page=100" \
    '{statuses:[.statuses[]|{context,state}]}' || return 0
  legacy_count=$(api_jq -r '.statuses | if type == "array" then length else -1 end')
  if ! nonnegative_integer "$legacy_count"; then
    could_not_verify "$repo $branch commit statuses" "GitHub REST omitted status records"
    return 0
  fi
  if [ "$legacy_count" -ge 100 ]; then
    could_not_verify "$repo $branch commit statuses" "at least 100 status records exist"
  fi
  legacy_failures=$(api_jq \
    '[.statuses[] | select(.state == "failure" or .state == "error")] | length')
  if [ "$legacy_failures" -gt 0 ]; then
    divergence "$repo $branch has $legacy_failures failing legacy commit statuses"
  fi
}

check_deploy_run() {
  local repo=$1 workflow=$2 run_id=$3 created=$4 completed selector_name selector_count
  api_get "$repo deploy run $run_id jobs" \
    "/repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
    '{total_count,jobs:[.jobs[]|{name,conclusion}]}' || return 0
  api_counts_complete "$repo deploy run $run_id jobs" \
    '.jobs | if type == "array" then length else -1 end' 'jobs' || return 0
  completed=$(api_jq \
    '[.jobs[] | select(.conclusion != null and .conclusion != "skipped")] | length')
  # shellcheck disable=SC2016 # single quotes are deliberate: $selector is a jq --arg variable, not a shell expansion.
  selector_count=$(api_jq --arg selector "$DEPLOY_SELECTOR_PATTERN" \
    '[.jobs[]
      | select(.conclusion != null and .conclusion != "skipped")
      | select(.name | test($selector; "i"))
    ] | length')
  if [ "$completed" -eq 1 ] && [ "$selector_count" -eq 1 ]; then
    selector_name=$(api_jq -r \
      '.jobs[] | select(.conclusion != null and .conclusion != "skipped") | .name' | head -1)
    divergence "$repo deploy workflow $workflow run $run_id at $created reported success, but ran only selector job \"$selector_name\""
  fi
}

check_deploys() {
  local repo=$1 workflows workflow_id workflow_name runs run_id created age
  api_get "$repo deploy workflows" \
    "/repos/$repo/actions/workflows?per_page=100" \
    '{total_count,workflows:[.workflows[]|{id,name,path}]}' || return 0
  api_counts_complete "$repo deploy workflows" \
    '.workflows | if type == "array" then length else -1 end' 'workflows'
  [ "$?" -ne 2 ] || return 0
  # shellcheck disable=SC2016 # single quotes are deliberate: $pattern is a jq --arg variable, not a shell expansion.
  workflows=$(api_jq -r --arg pattern "$DEPLOY_WORKFLOW_PATTERN" '
    .workflows[]
    | select((.name + " " + .path) | test($pattern; "i"))
    | [.id, .name] | @tsv
  ')
  while IFS="$(printf '\t')" read -r workflow_id workflow_name || [ -n "${workflow_id:-}${workflow_name:-}" ]; do
    [ -n "${workflow_id:-}" ] || continue
    if ! nonnegative_integer "$workflow_id"; then
      could_not_verify "$repo deploy workflow" "GitHub REST returned an invalid workflow id"
      continue
    fi
    api_get "$repo workflow $workflow_name successful runs" \
      "/repos/$repo/actions/workflows/$workflow_id/runs?status=success&per_page=$DEPLOY_RUNS" \
      '{workflow_runs:[.workflow_runs[]|{id,created_at}]}' || continue
    if ! api_jq -e '.workflow_runs | type == "array"' >/dev/null; then
      could_not_verify "$repo workflow $workflow_name successful runs" \
        "GitHub REST omitted workflow runs"
      continue
    fi
    # shellcheck disable=SC2016 # single quotes are deliberate: $limit, $maxage, $run, and $ts are jq variables, not shell expansions.
    runs=$(api_jq -r --argjson limit "$DEPLOY_RUNS" \
      --argjson maxage "$((DEPLOY_MAX_AGE_DAYS * 86400))" '
      .workflow_runs
      | if type == "array" then .[0:$limit][] else empty end
      | . as $run
      | ((.created_at | if type == "string" then (try fromdateiso8601 catch null) else null end)) as $ts
      | [ $run.id,
          ($run.created_at // ""),
          (if $ts == null then "unreadable"
           elif (now - $ts) <= $maxage then "recent"
           else "expired" end)
        ]
      | @tsv
    ')
    while IFS="$(printf '\t')" read -r run_id created age || [ -n "${run_id:-}${created:-}" ]; do
      [ -n "${run_id:-}" ] || continue
      if ! nonnegative_integer "$run_id"; then
        could_not_verify "$repo workflow $workflow_name deploy run" \
          "GitHub REST returned an invalid run id"
        continue
      fi
      case "${age:-}" in
        recent) ;;
        expired) continue ;;
        *)
          could_not_verify "$repo workflow $workflow_name deploy run $run_id" \
            "GitHub REST returned no readable creation timestamp, so its age is unknown"
          continue
          ;;
      esac
      check_deploy_run "$repo" "$workflow_name" "$run_id" "$created"
    done <<< "$runs"
  done <<< "$workflows"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      repo_valid "$2" || { printf 'fm-fleet-reconcile: invalid repository: %s\n' "$2" >&2; exit 2; }
      EXPLICIT_REPOS=1
      add_repo "$2"
      shift 2
      ;;
    --repo=*)
      repo=${1#*=}
      repo_valid "$repo" || { printf 'fm-fleet-reconcile: invalid repository: %s\n' "$repo" >&2; exit 2; }
      EXPLICIT_REPOS=1
      add_repo "$repo"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$MAIN_BRANCH_OVERRIDE" ] && ! branch_valid "$MAIN_BRANCH_OVERRIDE"; then
  printf 'could not verify configuration: FM_RECONCILE_MAIN_BRANCH is not a usable branch name\n'
  exit 2
fi
case "$DEPLOY_RUNS" in
  ''|*[!0-9]*) printf 'could not verify configuration: FM_RECONCILE_DEPLOY_RUNS must be 1..20\n'; exit 2 ;;
esac
if [ "$DEPLOY_RUNS" -lt 1 ] || [ "$DEPLOY_RUNS" -gt 20 ]; then
  printf 'could not verify configuration: FM_RECONCILE_DEPLOY_RUNS must be 1..20\n'
  exit 2
fi
case "$DEPLOY_MAX_AGE_DAYS" in
  ''|*[!0-9]*)
    printf 'could not verify configuration: FM_RECONCILE_DEPLOY_MAX_AGE_DAYS must be 1..365\n'
    exit 2
    ;;
esac
if [ "$DEPLOY_MAX_AGE_DAYS" -lt 1 ] || [ "$DEPLOY_MAX_AGE_DAYS" -gt 365 ]; then
  printf 'could not verify configuration: FM_RECONCILE_DEPLOY_MAX_AGE_DAYS must be 1..365\n'
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'could not verify fleet: jq is not available\n'
  exit 2
fi
if ! printf '' | jq -n \
  --arg real "$TEST_JOB_PATTERN" \
  --arg meta "$META_JOB_PATTERN" \
  --arg applicability "$APPLICABILITY_JOB_PATTERN" \
  --arg not_applicable "$NOT_APPLICABLE_PATTERN" \
  --arg deploy "$DEPLOY_WORKFLOW_PATTERN" \
  --arg selector "$DEPLOY_SELECTOR_PATTERN" \
  '("test" | test($real; "i")),
   ("test" | test($meta; "i")),
   ("test" | test($applicability; "i")),
   ("test" | test($not_applicable; "i")),
   ("test" | test($deploy; "i")),
   ("test" | test($selector; "i"))' >/dev/null 2>&1; then
  printf 'could not verify configuration: a reconciler pattern is not a valid jq regular expression\n'
  exit 2
fi

[ "$EXPLICIT_REPOS" -eq 1 ] || discover_registry_repos
discover_meta_tasks
discover_backlog_tasks

if [ "${#REPOS[@]}" -eq 0 ]; then
  could_not_verify "fleet repositories" "no GitHub repository was discovered"
  exit 2
fi
if ! command -v gh-axi >/dev/null 2>&1; then
  could_not_verify "GitHub observations" "gh-axi is not available"
  exit 2
fi
if ! gh-axi api /user >/dev/null 2>&1; then
  could_not_verify "GitHub observations" "authentication, network access, or REST quota is unavailable"
  exit 2
fi

discover_branch_prs

for ((i = 0; i < ${#TASK_IDS[@]}; i++)); do
  check_task_pr \
    "${TASK_IDS[$i]}" \
    "${TASK_REPOS[$i]}" \
    "${TASK_PRS[$i]}" \
    "${TASK_WORKTREES[$i]}" \
    "${TASK_LANDED_CLAIMS[$i]}" \
    "${TASK_SOURCES[$i]}"
done

for repo in "${REPOS[@]+"${REPOS[@]}"}"; do
  check_main "$repo"
  check_deploys "$repo"
done

if [ "$UNVERIFIED" -gt 0 ]; then
  exit 2
fi
if [ "$DIVERGENCES" -gt 0 ]; then
  exit 1
fi
exit 0
