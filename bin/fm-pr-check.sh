#!/usr/bin/env bash
# Record a PR/MR-ready task: appends pr=<url> and the review head pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR/MR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-or-mr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-review-provider-lib.sh
. "$SCRIPT_DIR/fm-review-provider-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if REMOTE_HEAD=$(fm_review_head_sha "$URL" "$WT" 2>/dev/null); then
      PR_HEAD=$REMOTE_HEAD
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

SQ_FM_ROOT=$(shell_quote "$FM_ROOT")
SQ_URL=$(shell_quote "$URL")
cat > "$STATE/$ID.check.sh" <<EOF
FM_ROOT=$SQ_FM_ROOT
URL=$SQ_URL
. "\$FM_ROOT/bin/fm-review-provider-lib.sh"
state=\$(fm_review_state "\$URL" "" 2>/dev/null || true)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
