#!/usr/bin/env bash
# Print the fork's delivery-evidence gate for a pull-request Definition of done.
# Usage: fm-fork-delivery-evidence.sh [<forge>]
#
# Fork-owned: bin/fm-fork-delta.sh owns the fork manifest. bin/fm-dod-lib.sh's
# fm_dod_block calls this once at the end of each pull-request arm (direct-PR and
# no-mistakes) and the output closes that Definition of done. The call is the
# only fork edit in that file, so upstream's own wording stays word-for-word.
#
# Measured failure: workers on every harness reported "done: committed <sha>"
# with no PR, and "checks green" on a fork PR whose workflow runs sat at
# action_required so nothing had run at all. Both read the absence of a visible
# failure as success, so the delivery report has to name the positive evidence
# each half requires.
# Upstream's "The task is complete only when committed on your branch." stays in
# both blocks; the gate opens with a qualifier that this names the implementation
# stage only and that delivery needs a PR.
# The gate governs only the done line that names a PR: the no-mistakes handoff
# has no PR by design and must not read the gate as a blocker.
# local-only never gets the gate: it has no PR by definition. Neither do the
# forge=gerrit blocks: they open no pull request and report no forge CI, and
# fm_dod_accept_ship_done already refuses their published-for-review report
# unless it names a canonical Gerrit change whose current patch set carries the
# worker copy's HEAD tree.
#
# <forge> is fm_dod_block's forge argument and defaults to none. It selects the
# forge CLI the check read names: gh-axi for none (GitHub) and tea for forgejo.
# Any other value prints nothing and exits 2, so a brief is never rendered with a
# gate for the wrong forge.
set -eu

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ "$#" -le 1 ] || {
  echo "usage: fm-fork-delivery-evidence.sh [<forge>]" >&2
  exit 2
}

forge=${1:-none}
case "$forge" in
  none)
    # shellcheck disable=SC2016  # the backticks are literal Markdown, not expansions
    checks_read='`gh-axi pr checks <number>` printing nothing, reporting no checks, or listing only skipped, queued, or pending runs is NOT green - a fork PR awaiting approval sits at `action_required` and runs nothing.'
    ;;
  forgejo)
    # shellcheck disable=SC2016  # the backticks are literal Markdown, not expansions
    checks_read='The status of the PR head commit (`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/commits/<sha>/status`, where <sha> is the PR head commit) listing no statuses, or only pending ones, is NOT green - a workflow awaiting approval runs nothing.'
    ;;
  *)
    echo "error: fm-fork-delivery-evidence.sh: no delivery-evidence gate for forge '$forge' (expected none or forgejo)" >&2
    exit 2
    ;;
esac

cat <<EOF

In this definition of done, "complete when committed" names the implementation stage only: committing is not delivering, and the task is delivered only when a PR exists for your branch.
**Neither half of the delivery report - the done line that names a PR - may be inferred from the absence of a failure.**
1. A PR must exist and you must have its real URL. A commit, or even a pushed branch, is not a delivered PR - never claim delivery without one: if the report should name a PR and none exists, append \`blocked [at=<epoch>]: {what is actually true}\` instead.
2. \`checks green\` may describe only checks that actually ran and passed. $checks_read If nothing ran, never write \`checks green\`: report what you actually see and let firstmate decide.
EOF
