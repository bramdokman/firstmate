#!/usr/bin/env bash
# Print this fork's publication target for a firstmate-lineage project.
# Usage: fm-fork-publication-target.sh <git-dir>
#
# Fork-owned: bin/fm-fork-delta.sh owns the fork manifest. bin/fm-role-lib.sh's
# fm_role_publication_target calls this first, once, and keeps upstream's rule
# (the first of upstream, github, origin) whenever it exits nonzero. The call is
# the only fork edit in that file, so upstream's own rule and wording stay
# word-for-word.
#
# Measured failure: in this fork origin is the fork, where every pull request
# lands, and upstream is the parent it only pulls from. Upstream's rule picks
# the parent, so the self-repository guard judged every firstmate-repository
# ship as publishing to the parent: a maintainer scope naming the fork could
# never apply, and each task needed one-task consent labelled with the parent
# even though nothing went there.
#
# The target is the repository a task's pull request lands on, so this prints
# origin only when both publishing delivery paths open their pull request there:
#   - no-mistakes opens it against origin (`no-mistakes init --help`);
#   - direct-PR opens it with gh, which uses an explicitly set default
#     repository (`gh repo set-default`, recorded as remote.<name>.gh-resolved)
#     before its own upstream, github, origin order.
# That holds when exactly one remote carries gh-resolved and its value resolves
# to origin's repository: `base` names that remote's own repository, and
# `<owner>/<repo>` names that repository on the remote's host. Anything else -
# no default set, a default on another repository, more than one resolution, or
# an undeterminable origin - prints nothing and exits 1, so upstream's rule
# applies unchanged and the parent stays the target. The printed identity is
# fm_role_remote_identity's normalized form, the one a maintainer scope or task
# consent is compared against; nothing here grants authority.
# Exits 0 with the identity on stdout, 1 when upstream's rule applies, and 2 on
# a usage error. Reads local git config only; no gh or network call.
set -eu

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
[ "$#" -eq 1 ] && [ -n "$1" ] || {
  echo "usage: fm-fork-publication-target.sh <git-dir>" >&2
  exit 2
}
dir=$1

# shellcheck source=bin/fm-role-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-role-lib.sh"

# A local-path remote names no forge repository a pull request opens on, so
# nolocal keeps it path:<abs> instead of resolving it a hop, and it never
# selects origin here.
origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null) || exit 1
origin=$(fm_role_remote_identity "$origin_url" "$dir" nolocal)
case $origin in
  '' | path:*) exit 1 ;;
esac

resolved=$(git -C "$dir" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null) || exit 1
case $resolved in
  *$'\n'*) exit 1 ;;
esac
key=${resolved%% *}
value=${resolved#* }
[ "$key" != "$resolved" ] && [ -n "$value" ] || exit 1
remote=${key#remote.}
remote=${remote%.gh-resolved}
remote_url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || exit 1
remote_id=$(fm_role_remote_identity "$remote_url" "$dir" nolocal)
case $remote_id in
  '' | path:*) exit 1 ;;
esac
if [ "$value" = base ]; then
  default=$remote_id
else
  fm_role_scope_valid "${remote_id%%/*}/$value" || exit 1
  default=$(fm_role_scope_norm "${remote_id%%/*}/$value")
fi
[ "$default" = "$origin" ] || exit 1
printf '%s\n' "$origin"
