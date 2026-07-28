#!/usr/bin/env bash
# fm-fleet-reconcile.sh - compare durable fleet claims with GitHub observations.
#
# The command is read-only and prints only divergences or checks it could not
# complete.
# Silence with exit 0 means every check in scope reconciled.
# Exit 1 means at least one divergence was observed.
# Exit 2 means at least one check could not be verified, including a run that
# also found divergences, because incomplete evidence must never read as clean.
#
# With no arguments, GitHub repositories are discovered from data/projects.md
# and task PR records.
# Repeat --repo owner/name to restrict the observation scope.
#
# The vacuous-green detector treats successful check runs whose names match
# FM_RECONCILE_TEST_JOB_PATTERN as real test execution, except names matching
# FM_RECONCILE_META_JOB_PATTERN.
# Deploy checks inspect the latest FM_RECONCILE_DEPLOY_RUNS successful runs for
# workflows matching FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN.
# A selector-only deploy is one completed job matching
# FM_RECONCILE_DEPLOY_SELECTOR_PATTERN and no other completed job.
#
# This command deliberately does not query merge-queue state, infer current
# worker state from historical status events, or guess that an old open PR was
# ejected.
# Those observations either consume scarce GraphQL quota or lack a sufficiently
# reliable claim-to-observation mapping for a scheduled heartbeat check.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE
#   FM_RECONCILE_MAIN_BRANCH             default: main
#   FM_RECONCILE_TEST_JOB_PATTERN         default: common real-test job names
#   FM_RECONCILE_META_JOB_PATTERN         default: selector/summary/gate names
#   FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN  default: deploy|release
#   FM_RECONCILE_DEPLOY_SELECTOR_PATTERN  default: selector/candidate/plan names
#   FM_RECONCILE_DEPLOY_RUNS              default: 5, range: 1..20
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
PROJECT_REGISTRY="$DATA/projects.md"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

MAIN_BRANCH=${FM_RECONCILE_MAIN_BRANCH:-main}
TEST_JOB_PATTERN=${FM_RECONCILE_TEST_JOB_PATTERN:-'integration|db gates|packages|browser|(^|[^[:alnum:]])tests?([^[:alnum:]]|$)|e2e|typecheck.*build'}
META_JOB_PATTERN=${FM_RECONCILE_META_JOB_PATTERN:-'selector|summary|aggregate|required check|merge gate|build, test, tenant-isolation gate'}
DEPLOY_WORKFLOW_PATTERN=${FM_RECONCILE_DEPLOY_WORKFLOW_PATTERN:-'deploy|release'}
DEPLOY_SELECTOR_PATTERN=${FM_RECONCILE_DEPLOY_SELECTOR_PATTERN:-'select|selector|candidate|determine|changes|plan'}
DEPLOY_RUNS=${FM_RECONCILE_DEPLOY_RUNS:-5}

DIVERGENCES=0
UNVERIFIED=0
EXPLICIT_REPOS=0
API_RESULT=
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
  sed -n '2,38{s/^# \{0,1\}//;p;}' "$0"
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

repo_present() {
  local wanted=$1 repo
  for repo in "${REPOS[@]}"; do
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

registry_repo_for_name() {
  local name=$1 line candidate
  [ -f "$PROJECT_REGISTRY" ] || return 1
  line=$(awk -v n="$name" '$1 == "-" && $2 == n { print; exit }' "$PROJECT_REGISTRY")
  [ -n "$line" ] || return 1
  line=${line% \(added *}
  candidate=${line##*, }
  repo_valid "$candidate" || return 1
  printf '%s' "$candidate"
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
  local project=$1 origin name
  if [ -d "$project" ] && origin=$(git -C "$project" remote get-url origin 2>/dev/null); then
    repo_from_origin "$origin" && return 0
  fi
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
  local line candidate project
  if [ ! -f "$PROJECT_REGISTRY" ]; then
    could_not_verify "registered repositories" "$PROJECT_REGISTRY is absent"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    project=$(printf '%s\n' "$line" | awk '{print $2}')
    case "$line" in
      *"[local-only"*) continue ;;
    esac
    line=${line% \(added *}
    candidate=${line##*, }
    if repo_valid "$candidate"; then
      add_repo "$candidate"
    else
      could_not_verify "project $project repository" \
        "its non-local registry row does not end with a GitHub owner/name"
    fi
  done < "$PROJECT_REGISTRY"
}

discover_meta_tasks() {
  local meta id pr_url repo pr worktree project status landed=0 status_match branch
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    status="$STATE/$id.status"
    pr_url=$(meta_value "$meta" pr)
    worktree=$(meta_value "$meta" worktree)
    [ -n "$worktree" ] || worktree=-
    project=$(meta_value "$meta" project)
    repo=
    pr=
    if [ -n "$pr_url" ]; then
      if ! fm_pr_url_parse "$pr_url"; then
        could_not_verify "task $id change" "recorded PR URL is invalid"
        continue
      fi
      if [ "$FM_PR_PROVIDER" != github ]; then
        could_not_verify "task $id change" "the reconciler currently observes GitHub PRs only"
        continue
      fi
      repo=$FM_PR_PATH
      pr=$FM_PR_NUMBER
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
  # Test doubles may return raw JSON.
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    API_RESULT=$raw
    return 0
  fi
  case "$raw" in
    *"truncated: true"*)
      could_not_verify "$subject" "gh-axi truncated the GitHub REST response"
      return 1
      ;;
  esac
  encoded=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*body: //p' | head -1)
  if [ -z "$encoded" ] || ! API_RESULT=$(printf '%s' "$encoded" | base64_decode 2>/dev/null); then
    could_not_verify "$subject" "gh-axi returned an unreadable REST response"
    return 1
  fi
  if ! printf '%s' "$API_RESULT" | jq -e . >/dev/null 2>&1; then
    could_not_verify "$subject" "GitHub REST returned invalid JSON"
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
    if ! printf '%s' "$API_RESULT" | jq -e '.pulls | type == "array"' >/dev/null; then
      could_not_verify "open change for task $id branch $branch" \
        "GitHub REST omitted the PR list"
      continue
    fi
    count=$(printf '%s' "$API_RESULT" | jq '.pulls | length')
    if [ "$count" -gt 1 ]; then
      could_not_verify "open change for task $id branch $branch" \
        "more than one open PR uses that fleet branch"
      continue
    fi
    [ "$count" -eq 1 ] || continue
    pr=$(printf '%s' "$API_RESULT" | jq -r '.pulls[0].number')
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
  local merged state mergeable head total returned green real
  api_get "$repo PR #$pr" "/repos/$repo/pulls/$pr" \
    '{merged,state,mergeable_state,head:{sha:.head.sha}}' || return 0
  merged=$(printf '%s' "$API_RESULT" | jq -r 'if (.merged | type) == "boolean" then .merged else "invalid" end')
  state=$(printf '%s' "$API_RESULT" | jq -r '.state // "invalid"')
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
  mergeable=$(printf '%s' "$API_RESULT" | jq -r '.mergeable_state // "unknown"')
  case "$mergeable" in
    clean) ;;
    unknown)
      could_not_verify "vacuous-green state for $repo PR #$pr" "GitHub has not computed mergeability"
      return 0
      ;;
    *) return 0 ;;
  esac
  head=$(printf '%s' "$API_RESULT" | jq -r '.head.sha // empty')
  if ! fm_pr_head_valid "$head"; then
    could_not_verify "vacuous-green state for $repo PR #$pr" "GitHub REST omitted a valid head SHA"
    return 0
  fi
  api_get "check execution for $repo PR #$pr" \
    "/repos/$repo/commits/$head/check-runs?per_page=100" \
    '{total_count,check_runs:[.check_runs[]|{name,conclusion}]}' || return 0
  total=$(printf '%s' "$API_RESULT" | jq -r '.total_count // -1')
  returned=$(printf '%s' "$API_RESULT" | jq -r '.check_runs | if type == "array" then length else -1 end')
  case "$total:$returned" in
    *[!0-9:]*|*:-1|-1:*)
      could_not_verify "check execution for $repo PR #$pr" "GitHub REST omitted check-run counts"
      return 0
      ;;
  esac
  if [ "$total" -gt "$returned" ]; then
    could_not_verify "check execution for $repo PR #$pr" "more than 100 check runs exist"
    return 0
  fi
  green=$(printf '%s' "$API_RESULT" | jq '[.check_runs[] | select(.conclusion == "success")] | length')
  real=$(printf '%s' "$API_RESULT" | jq \
    --arg real "$TEST_JOB_PATTERN" \
    --arg meta "$META_JOB_PATTERN" \
    '[.check_runs[]
      | select(.conclusion == "success")
      | select(.name | test($real; "i"))
      | select((.name | test($meta; "i")) | not)
    ] | length')
  if [ "$green" -gt 0 ] && [ "$real" -eq 0 ]; then
    divergence "$repo PR #$pr reads mergeable with $green successful checks, but zero real test jobs executed"
  fi
}

check_main() {
  local repo=$1 total returned failures names legacy_count legacy_failures sha
  api_get "$repo $MAIN_BRANCH checks" \
    "/repos/$repo/commits/$MAIN_BRANCH/check-runs?per_page=100" \
    '{
      total_count,
      returned:(.check_runs|length),
      sha:(.check_runs[0].head_sha // null),
      failures:[
        .check_runs[]
        | select(.conclusion == "failure"
          or .conclusion == "timed_out"
          or .conclusion == "cancelled"
          or .conclusion == "action_required"
          or .conclusion == "startup_failure"
          or .conclusion == "stale")
        | {name,conclusion}
      ]
    }' || return 0
  total=$(printf '%s' "$API_RESULT" | jq -r '.total_count // -1')
  returned=$(printf '%s' "$API_RESULT" | jq -r '.returned // -1')
  if ! nonnegative_integer "$total" || ! nonnegative_integer "$returned"; then
    could_not_verify "$repo $MAIN_BRANCH checks" "GitHub REST omitted check-run counts"
    return 0
  fi
  if [ "$total" -gt "$returned" ]; then
    could_not_verify "$repo $MAIN_BRANCH checks" "more than 100 check runs exist"
  fi
  failures=$(printf '%s' "$API_RESULT" | jq '.failures | length')
  if [ "$failures" -gt 0 ]; then
    names=$(printf '%s' "$API_RESULT" | jq -r '[.failures[].name][0:5] | join(", ")')
    sha=$(printf '%s' "$API_RESULT" | jq -r '.sha // empty | .[0:8]')
    divergence "$repo $MAIN_BRANCH${sha:+ ($sha)} has $failures failing checks${names:+: $names}"
  fi

  api_get "$repo $MAIN_BRANCH commit statuses" \
    "/repos/$repo/commits/$MAIN_BRANCH/status?per_page=100" \
    '{statuses:[.statuses[]|{context,state}]}' || return 0
  legacy_count=$(printf '%s' "$API_RESULT" | jq -r '.statuses | if type == "array" then length else -1 end')
  if ! nonnegative_integer "$legacy_count"; then
    could_not_verify "$repo $MAIN_BRANCH commit statuses" "GitHub REST omitted status records"
    return 0
  fi
  if [ "$legacy_count" -ge 100 ]; then
    could_not_verify "$repo $MAIN_BRANCH commit statuses" "at least 100 status records exist"
  fi
  legacy_failures=$(printf '%s' "$API_RESULT" | jq \
    '[.statuses[] | select(.state == "failure" or .state == "error")] | length')
  if [ "$legacy_failures" -gt 0 ]; then
    divergence "$repo $MAIN_BRANCH has $legacy_failures failing legacy commit statuses"
  fi
}

check_deploy_run() {
  local repo=$1 workflow=$2 run_id=$3 created=$4 total returned completed selector_name selector_count
  api_get "$repo deploy run $run_id jobs" \
    "/repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
    '{total_count,jobs:[.jobs[]|{name,conclusion}]}' || return 0
  total=$(printf '%s' "$API_RESULT" | jq -r '.total_count // -1')
  returned=$(printf '%s' "$API_RESULT" | jq -r '.jobs | if type == "array" then length else -1 end')
  if ! nonnegative_integer "$total" || ! nonnegative_integer "$returned"; then
    could_not_verify "$repo deploy run $run_id jobs" "GitHub REST omitted job counts"
    return 0
  fi
  if [ "$total" -gt "$returned" ]; then
    could_not_verify "$repo deploy run $run_id jobs" "more than 100 jobs exist"
    return 0
  fi
  completed=$(printf '%s' "$API_RESULT" | jq \
    '[.jobs[] | select(.conclusion != null and .conclusion != "skipped")] | length')
  selector_count=$(printf '%s' "$API_RESULT" | jq --arg selector "$DEPLOY_SELECTOR_PATTERN" \
    '[.jobs[]
      | select(.conclusion != null and .conclusion != "skipped")
      | select(.name | test($selector; "i"))
    ] | length')
  if [ "$completed" -eq 1 ] && [ "$selector_count" -eq 1 ]; then
    selector_name=$(printf '%s' "$API_RESULT" | jq -r \
      '.jobs[] | select(.conclusion != null and .conclusion != "skipped") | .name' | head -1)
    divergence "$repo deploy workflow $workflow run $run_id at $created reported success, but ran only selector job \"$selector_name\""
  fi
}

check_deploys() {
  local repo=$1 total returned workflows workflow_id workflow_name runs run_id created
  api_get "$repo deploy workflows" \
    "/repos/$repo/actions/workflows?per_page=100" \
    '{total_count,workflows:[.workflows[]|{id,name,path}]}' || return 0
  total=$(printf '%s' "$API_RESULT" | jq -r '.total_count // -1')
  returned=$(printf '%s' "$API_RESULT" | jq -r '.workflows | if type == "array" then length else -1 end')
  if ! nonnegative_integer "$total" || ! nonnegative_integer "$returned"; then
    could_not_verify "$repo deploy workflows" "GitHub REST omitted workflow counts"
    return 0
  fi
  if [ "$total" -gt "$returned" ]; then
    could_not_verify "$repo deploy workflows" "more than 100 workflows exist"
  fi
  workflows=$(printf '%s' "$API_RESULT" | jq -r --arg pattern "$DEPLOY_WORKFLOW_PATTERN" '
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
    if ! printf '%s' "$API_RESULT" | jq -e '.workflow_runs | type == "array"' >/dev/null; then
      could_not_verify "$repo workflow $workflow_name successful runs" \
        "GitHub REST omitted workflow runs"
      continue
    fi
    runs=$(printf '%s' "$API_RESULT" | jq -r --argjson limit "$DEPLOY_RUNS" '
      .workflow_runs
      | if type == "array" then .[0:$limit][] else empty end
      | [.id, .created_at] | @tsv
    ')
    while IFS="$(printf '\t')" read -r run_id created || [ -n "${run_id:-}${created:-}" ]; do
      [ -n "${run_id:-}" ] || continue
      if ! nonnegative_integer "$run_id"; then
        could_not_verify "$repo workflow $workflow_name deploy run" \
          "GitHub REST returned an invalid run id"
        continue
      fi
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

case "$DEPLOY_RUNS" in
  ''|*[!0-9]*) printf 'could not verify configuration: FM_RECONCILE_DEPLOY_RUNS must be 1..20\n'; exit 2 ;;
esac
if [ "$DEPLOY_RUNS" -lt 1 ] || [ "$DEPLOY_RUNS" -gt 20 ]; then
  printf 'could not verify configuration: FM_RECONCILE_DEPLOY_RUNS must be 1..20\n'
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'could not verify fleet: jq is not available\n'
  exit 2
fi
if ! printf '' | jq -n \
  --arg real "$TEST_JOB_PATTERN" \
  --arg meta "$META_JOB_PATTERN" \
  --arg deploy "$DEPLOY_WORKFLOW_PATTERN" \
  --arg selector "$DEPLOY_SELECTOR_PATTERN" \
  '("test" | test($real; "i")),
   ("test" | test($meta; "i")),
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

for repo in "${REPOS[@]}"; do
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
