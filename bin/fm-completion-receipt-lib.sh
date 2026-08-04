#!/usr/bin/env bash
# Durable completion-receipt writer for fm-teardown.sh.
#
# The append-only ledger is data/completion-receipts.jsonl.
# Each line is one JSON object with schema_version=1 and these fixed fields:
# task_id, kind, project, worktree, endpoint_task_id, delivery_mode, harness,
# model, effort, backend, yolo, dispatch_time, dispatch_time_source,
# teardown_time, terminal_outcome, delivery_outcome, pr_url, pr_head,
# merged_commit, and status_event_counts.
# Missing string values are JSON null rather than invented facts.
# dispatch_time_source is spawn_meta when state/<id>.meta contains the real
# metadata-persistence event time, or unavailable_legacy_meta for older tasks;
# filesystem mtimes are never substituted for event time.
# status_event_counts contains integer keys needs-decision, blocked, paused,
# resolved, and failed, counted only from exact keyed status-line prefixes.
# The ledger never includes status messages, brief/report prose, launch commands,
# runtime endpoint identifiers, environment values, or unrestricted meta fields.
#
# fm_completion_receipt_append takes:
#   <data-dir> <task-id> <meta-file> <status-file> <teardown-time>
#   <terminal-outcome> <delivery-outcome> <pr-url> <merged-commit>
# It serializes concurrent appends with the bounded portable private lock and
# treats an existing task_id as success, so retrying after a partial teardown
# does not append a duplicate record.
# The caller owns the best-effort policy: fm-teardown.sh logs a failure and
# continues cleanup rather than stranding a task.

fm_completion_receipt_meta_get() {
  local meta=$1 key=$2
  awk -v prefix="$key=" 'index($0, prefix) == 1 { value = substr($0, length(prefix) + 1) } END { print value }' "$meta"
}

fm_completion_receipt_status_count() {
  local status=$1 state=$2
  if [ ! -f "$status" ]; then
    printf '0\n'
    return 0
  fi
  awk -F: -v wanted="$state" '$1 == wanted { count++ } END { print count + 0 }' "$status"
}

fm_completion_receipt_append() (
  set -u
  local data=$1 id=$2 meta=$3 status=$4 teardown_time=$5 terminal_outcome=$6
  local delivery_outcome=$7 pr_url=$8 merged_commit=$9 ledger lock attempt=0 tmp
  local kind project worktree endpoint_id mode harness model effort backend yolo
  local dispatch_time dispatch_time_source pr_head needs_decision blocked paused resolved failed

  [ -d "$data" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  ledger="$data/completion-receipts.jsonl"
  lock="$data/.completion-receipts.lock"
  [ ! -L "$ledger" ] || return 1
  [ ! -e "$ledger" ] || [ -f "$ledger" ] || return 1

  while ! fm_lock_try_acquire "$lock"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 20 ] || return 1
    sleep 0.05
  done
  trap 'fm_lock_release "$lock" 2>/dev/null || true' EXIT HUP INT TERM

  if [ -f "$ledger" ] && grep -Fq "\"task_id\":\"$id\"," "$ledger"; then
    return 0
  fi

  kind=$(fm_completion_receipt_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  project=$(fm_completion_receipt_meta_get "$meta" project)
  worktree=$(fm_completion_receipt_meta_get "$meta" worktree)
  endpoint_id=$(fm_completion_receipt_meta_get "$meta" endpoint_task_id)
  mode=$(fm_completion_receipt_meta_get "$meta" mode)
  [ -n "$mode" ] || mode=no-mistakes
  harness=$(fm_completion_receipt_meta_get "$meta" harness)
  model=$(fm_completion_receipt_meta_get "$meta" model)
  effort=$(fm_completion_receipt_meta_get "$meta" effort)
  backend=$(fm_completion_receipt_meta_get "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  yolo=$(fm_completion_receipt_meta_get "$meta" yolo)
  dispatch_time=$(fm_completion_receipt_meta_get "$meta" dispatched_at)
  if [ -n "$dispatch_time" ]; then
    dispatch_time_source=spawn_meta
  else
    dispatch_time_source=unavailable_legacy_meta
  fi
  pr_head=$(fm_completion_receipt_meta_get "$meta" pr_head)
  needs_decision=$(fm_completion_receipt_status_count "$status" needs-decision)
  blocked=$(fm_completion_receipt_status_count "$status" blocked)
  paused=$(fm_completion_receipt_status_count "$status" paused)
  resolved=$(fm_completion_receipt_status_count "$status" resolved)
  failed=$(fm_completion_receipt_status_count "$status" failed)

  umask 077
  tmp=$(mktemp "$data/.completion-receipt.XXXXXXXXXX") || return 1
  trap 'rm -f "$tmp" 2>/dev/null || true; fm_lock_release "$lock" 2>/dev/null || true' EXIT HUP INT TERM
  jq -cn \
    --arg task_id "$id" \
    --arg kind "$kind" \
    --arg project "$project" \
    --arg worktree "$worktree" \
    --arg endpoint_task_id "$endpoint_id" \
    --arg delivery_mode "$mode" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg backend "$backend" \
    --arg yolo "$yolo" \
    --arg dispatch_time "$dispatch_time" \
    --arg dispatch_time_source "$dispatch_time_source" \
    --arg teardown_time "$teardown_time" \
    --arg terminal_outcome "$terminal_outcome" \
    --arg delivery_outcome "$delivery_outcome" \
    --arg pr_url "$pr_url" \
    --arg pr_head "$pr_head" \
    --arg merged_commit "$merged_commit" \
    --argjson needs_decision "$needs_decision" \
    --argjson blocked "$blocked" \
    --argjson paused "$paused" \
    --argjson resolved "$resolved" \
    --argjson failed "$failed" '
      def nullable($value): if $value == "" then null else $value end;
      {
        schema_version: 1,
        task_id: $task_id,
        kind: $kind,
        project: nullable($project),
        worktree: nullable($worktree),
        endpoint_task_id: nullable($endpoint_task_id),
        delivery_mode: $delivery_mode,
        harness: nullable($harness),
        model: nullable($model),
        effort: nullable($effort),
        backend: $backend,
        yolo: (if $yolo == "on" then true elif $yolo == "off" then false else null end),
        dispatch_time: nullable($dispatch_time),
        dispatch_time_source: $dispatch_time_source,
        teardown_time: $teardown_time,
        terminal_outcome: $terminal_outcome,
        delivery_outcome: $delivery_outcome,
        pr_url: nullable($pr_url),
        pr_head: nullable($pr_head),
        merged_commit: nullable($merged_commit),
        status_event_counts: {
          "needs-decision": $needs_decision,
          blocked: $blocked,
          paused: $paused,
          resolved: $resolved,
          failed: $failed
        }
      }
    ' > "$tmp" || return 1
  cat "$tmp" >> "$ledger" || return 1
  rm -f "$tmp" || return 1
  trap 'fm_lock_release "$lock" 2>/dev/null || true' EXIT HUP INT TERM
)
