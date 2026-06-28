#!/usr/bin/env bash
# Shared review-provider helpers for PR/MR workflows.
# Supported providers:
#   github - github.com pull requests, queried with gh/gh-axi
#   gitlab - code.byted.org merge requests, queried with bytedcli codebase
#
# This file is sourced by other scripts; it intentionally does not set shell
# options.

fm_review_clean_url() {
  local url=$1
  url=${url%%#*}
  url=${url%%\?*}
  url=${url%/}
  printf '%s\n' "$url"
}

fm_review_provider_from_url() {
  local url path
  url=$(fm_review_clean_url "$1")
  case "$url" in
    http://github.com/*/pull/*|https://github.com/*/pull/*)
      path=${url#*github.com/}
      [ "$path" != "${path#*/pull/}" ] || return 1
      printf '%s\n' github
      ;;
    http://code.byted.org/*/merge_requests/*|https://code.byted.org/*/merge_requests/*)
      path=${url#*code.byted.org/}
      [ "$path" != "${path#*/merge_requests/}" ] || return 1
      printf '%s\n' gitlab
      ;;
    *)
      return 1
      ;;
  esac
}

fm_review_provider_from_remote() {
  local remote=$1
  case "$remote" in
    git@github.com:*|ssh://git@github.com/*|https://github.com/*|http://github.com/*)
      printf '%s\n' github
      ;;
    git@code.byted.org:*|ssh://git@code.byted.org/*|https://code.byted.org/*|http://code.byted.org/*)
      printf '%s\n' gitlab
      ;;
    *)
      return 1
      ;;
  esac
}

fm_review_repo_from_remote() {
  local remote=$1 path
  remote=${remote%%#*}
  remote=${remote%%\?*}
  remote=${remote%/}
  case "$remote" in
    git@github.com:*) path=${remote#git@github.com:} ;;
    ssh://git@github.com/*) path=${remote#ssh://git@github.com/} ;;
    https://github.com/*) path=${remote#https://github.com/} ;;
    http://github.com/*) path=${remote#http://github.com/} ;;
    git@code.byted.org:*) path=${remote#git@code.byted.org:} ;;
    ssh://git@code.byted.org/*) path=${remote#ssh://git@code.byted.org/} ;;
    https://code.byted.org/*) path=${remote#https://code.byted.org/} ;;
    http://code.byted.org/*) path=${remote#http://code.byted.org/} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

fm_review_parse_url() {
  local url provider path repo id rest
  url=$(fm_review_clean_url "$1")
  provider=$(fm_review_provider_from_url "$url") || return 1
  case "$provider" in
    github)
      path=${url#*github.com/}
      repo=${path%%/pull/*}
      rest=${path#*/pull/}
      id=${rest%%/*}
      ;;
    gitlab)
      path=${url#*code.byted.org/}
      repo=${path%%/merge_requests/*}
      rest=${path#*/merge_requests/}
      id=${rest%%/*}
      ;;
    *)
      return 1
      ;;
  esac
  [ -n "$repo" ] || return 1
  [ -n "$id" ] || return 1
  case "$id" in *[!0-9]*) return 1 ;; esac
  printf '%s\t%s\t%s\n' "$provider" "$repo" "$id"
}

fm_review_provider_for_worktree() {
  local wt=$1 remote
  [ -n "$wt" ] || return 1
  remote=$(git -C "$wt" remote get-url origin 2>/dev/null || true)
  [ -n "$remote" ] || return 1
  fm_review_provider_from_remote "$remote"
}

fm_review_repo_for_worktree() {
  local wt=$1 remote
  [ -n "$wt" ] || return 1
  remote=$(git -C "$wt" remote get-url origin 2>/dev/null || true)
  [ -n "$remote" ] || return 1
  fm_review_repo_from_remote "$remote"
}

fm_review_provider_for_target() {
  local target=$1 wt=${2:-} provider
  provider=$(fm_review_provider_from_url "$target" 2>/dev/null || true)
  if [ -n "$provider" ]; then
    printf '%s\n' "$provider"
    return 0
  fi
  fm_review_provider_for_worktree "$wt"
}

fm_review_github_branch_target() {
  local branch=$1 wt=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  command -v gh-axi >/dev/null 2>&1 || return 1
  out=$(cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

fm_review_target_from_branch() {
  local branch=$1 wt=$2 provider
  provider=$(fm_review_provider_for_worktree "$wt") || return 1
  case "$provider" in
    github)
      fm_review_github_branch_target "$branch" "$wt"
      ;;
    gitlab)
      [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
      printf '%s\n' "$branch"
      ;;
    *)
      return 1
      ;;
  esac
}

fm_review_github_head_sha() {
  local target=$1 wt=${2:-}
  command -v gh >/dev/null 2>&1 || return 1
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    (cd "$wt" && gh pr view "$target" --json headRefOid -q .headRefOid 2>/dev/null)
  else
    gh pr view "$target" --json headRefOid -q .headRefOid 2>/dev/null
  fi
}

fm_review_github_state() {
  local target=$1 wt=${2:-}
  command -v gh >/dev/null 2>&1 || return 1
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    (cd "$wt" && gh pr view "$target" --json state -q .state 2>/dev/null)
  else
    gh pr view "$target" --json state -q .state 2>/dev/null
  fi
}

fm_review_gitlab_status_json() {
  local target=$1 wt=${2:-} parsed provider repo id selector
  command -v bytedcli >/dev/null 2>&1 || return 1
  selector=$target
  repo=
  parsed=$(fm_review_parse_url "$target" 2>/dev/null || true)
  if [ -n "$parsed" ]; then
    provider=${parsed%%$'\t'*}
    [ "$provider" = gitlab ] || return 1
    repo=${parsed#*$'\t'}
    id=${repo#*$'\t'}
    repo=${repo%%$'\t'*}
    selector=$id
  elif [ -n "$wt" ] && [ -d "$wt" ]; then
    repo=$(fm_review_repo_for_worktree "$wt" 2>/dev/null || true)
  fi

  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -n "$repo" ]; then
      (cd "$wt" && bytedcli --json codebase mr status "$selector" -R "$repo" 2>/dev/null)
    else
      (cd "$wt" && bytedcli --json codebase mr status "$selector" 2>/dev/null)
    fi
  else
    if [ -n "$repo" ]; then
      bytedcli --json codebase mr status "$selector" -R "$repo" 2>/dev/null
    else
      bytedcli --json codebase mr status "$selector" 2>/dev/null
    fi
  fi
}

fm_review_gitlab_json_field() {
  local field=$1
  node -e '
const field = process.argv[1];
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { input += chunk; });
process.stdin.on("end", () => {
  let root;
  try {
    root = JSON.parse(input);
  } catch (_) {
    process.exit(1);
  }
  const data = root && root.data ? root.data : undefined;
  const candidates = [
    data && data.merge_request,
    data && data.mergeRequest,
    data && data.mr,
    root && root.merge_request,
    root && root.mergeRequest,
    root && root.mr,
    data,
    root
  ].filter(Boolean);
  function first(names) {
    for (const obj of candidates) {
      for (const name of names) {
        if (Object.prototype.hasOwnProperty.call(obj, name) && obj[name] !== null && obj[name] !== undefined && obj[name] !== "") {
          return String(obj[name]);
        }
      }
    }
    return "";
  }
  if (field === "head") {
    const value = first(["source_commit_id", "sourceCommitId", "SourceCommitId", "head_sha", "headSha", "HeadSha", "source_sha", "sourceSha", "SourceSha", "sha", "Sha", "commit_id", "commitId", "CommitId"]);
    if (!value) process.exit(1);
    console.log(value);
    return;
  }
  if (field === "state") {
    const mergedAt = first(["merged_at", "mergedAt", "MergedAt"]);
    if (mergedAt) {
      console.log("MERGED");
      return;
    }
    const merged = first(["merged", "Merged", "is_merged", "isMerged", "IsMerged"]);
    if (/^(true|1|yes)$/i.test(merged)) {
      console.log("MERGED");
      return;
    }
    const raw = first(["state", "status", "State", "Status", "merge_state", "mergeState", "mr_state", "mrState"]);
    if (!raw) process.exit(1);
    const normalized = raw.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
    if (normalized === "merged" || normalized === "merge_request_state_merged" || normalized === "mr_state_merged") {
      console.log("MERGED");
    } else if (normalized === "open" || normalized === "opened" || normalized === "active") {
      console.log("OPEN");
    } else if (normalized === "closed" || normalized === "close") {
      console.log("CLOSED");
    } else {
      console.log(raw.toUpperCase());
    }
    return;
  }
  process.exit(1);
});
' "$field"
}

fm_review_gitlab_head_sha() {
  local target=$1 wt=${2:-} json head
  json=$(fm_review_gitlab_status_json "$target" "$wt") || return 1
  head=$(printf '%s' "$json" | fm_review_gitlab_json_field head) || return 1
  [ -n "$head" ] || return 1
  printf '%s\n' "$head"
}

fm_review_gitlab_state() {
  local target=$1 wt=${2:-} json state
  json=$(fm_review_gitlab_status_json "$target" "$wt") || return 1
  state=$(printf '%s' "$json" | fm_review_gitlab_json_field state) || return 1
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

fm_review_normalize_state() {
  local state=$1 lower
  lower=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    merged) printf '%s\n' MERGED ;;
    open|opened) printf '%s\n' OPEN ;;
    closed|close) printf '%s\n' CLOSED ;;
    *) printf '%s\n' "$state" ;;
  esac
}

fm_review_head_sha() {
  local target=$1 wt=${2:-} provider head
  provider=$(fm_review_provider_for_target "$target" "$wt") || return 1
  case "$provider" in
    github) head=$(fm_review_github_head_sha "$target" "$wt") || return 1 ;;
    gitlab) head=$(fm_review_gitlab_head_sha "$target" "$wt") || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  printf '%s\n' "$head"
}

fm_review_state() {
  local target=$1 wt=${2:-} provider state
  provider=$(fm_review_provider_for_target "$target" "$wt") || return 1
  case "$provider" in
    github) state=$(fm_review_github_state "$target" "$wt") || return 1 ;;
    gitlab) state=$(fm_review_gitlab_state "$target" "$wt") || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$state" ] || return 1
  fm_review_normalize_state "$state"
}

fm_review_is_merged_for_head() {
  local target=$1 wt=$2 state head current
  [ -n "$target" ] || return 1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  state=$(fm_review_state "$target" "$wt") || return 1
  [ "$state" = MERGED ] || return 1
  head=$(fm_review_head_sha "$target" "$wt") || return 1
  [ -n "$head" ] || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$current" = "$head" ]
}
