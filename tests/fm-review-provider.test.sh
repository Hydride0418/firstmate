#!/usr/bin/env bash
# Tests for bin/fm-review-provider-lib.sh provider detection and state lookups.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-review-provider-lib.sh
. "$ROOT/bin/fm-review-provider-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-provider-tests)

expect_value() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

test_url_and_remote_detection() {
  local parsed

  parsed=$(fm_review_parse_url "https://github.com/owner/repo/pull/42?plain=1")
  expect_value $'github\towner/repo\t42' "$parsed" "github URL parse"

  parsed=$(fm_review_parse_url "https://code.byted.org/group/repo/merge_requests/8#note_1")
  expect_value $'gitlab\tgroup/repo\t8' "$parsed" "code.byted URL parse"

  expect_value github "$(fm_review_provider_from_remote "git@github.com:owner/repo.git")" "github SSH provider"
  expect_value "owner/repo" "$(fm_review_repo_from_remote "https://github.com/owner/repo.git")" "github HTTPS repo"

  expect_value gitlab "$(fm_review_provider_from_remote "git@code.byted.org:group/repo.git")" "code.byted scp provider"
  expect_value gitlab "$(fm_review_provider_from_remote "ssh://git@code.byted.org/group/repo.git")" "code.byted SSH provider"
  expect_value gitlab "$(fm_review_provider_from_remote "https://code.byted.org/group/repo.git")" "code.byted HTTPS provider"
  expect_value "group/sub/repo" "$(fm_review_repo_from_remote "ssh://git@code.byted.org/group/sub/repo.git")" "nested code.byted repo"

  pass "review provider URL and remote detection handles GitHub and code.byted.org"
}

test_github_lookup_uses_gh() {
  local case_dir fakebin head state
  case_dir="$TMP_ROOT/github"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json headRefOid "*) printf '%s\n' abc123 ; exit 0 ;;
  *" --json state "*) printf '%s\n' MERGED ; exit 0 ;;
esac
printf '%s\n' "unexpected gh args: $*" >&2
exit 1
SH
  chmod +x "$fakebin/gh"

  head=$(PATH="$fakebin:$PATH" fm_review_head_sha "https://github.com/owner/repo/pull/42" "")
  state=$(PATH="$fakebin:$PATH" fm_review_state "https://github.com/owner/repo/pull/42" "")

  expect_value abc123 "$head" "github head lookup"
  expect_value MERGED "$state" "github state lookup"
  pass "GitHub review lookup uses gh-compatible path"
}

test_gitlab_lookup_uses_bytedcli_codebase() {
  local case_dir fakebin log head state
  case_dir="$TMP_ROOT/gitlab"
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/bytedcli.log"
  cat > "$fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case " \$* " in
  *" --json codebase mr status 8 -R group/repo "*)
    printf '%s\n' '{"data":{"merge_request":{"state":"merged","source_commit_id":"def456"}}}'
    exit 0
    ;;
esac
printf '%s\n' "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$fakebin/bytedcli"

  head=$(PATH="$fakebin:$PATH" fm_review_head_sha "https://code.byted.org/group/repo/merge_requests/8" "")
  state=$(PATH="$fakebin:$PATH" fm_review_state "https://code.byted.org/group/repo/merge_requests/8" "")

  expect_value def456 "$head" "code.byted head lookup"
  expect_value MERGED "$state" "code.byted state lookup"
  assert_grep "--json codebase mr status 8 -R group/repo" "$log" "code.byted lookup should pass selector and repo to bytedcli"
  pass "code.byted.org review lookup uses bytedcli codebase path"
}

test_gitlab_branch_selector_fallback_uses_bytedcli() {
  local case_dir fakebin log repo state head selector
  case_dir="$TMP_ROOT/gitlab-branch"
  fakebin=$(fm_fakebin "$case_dir")
  repo="$case_dir/repo"
  log="$case_dir/bytedcli.log"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin https://code.byted.org/group/repo.git
  selector=feature/source-branch
  cat > "$fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case " \$* " in
  *" --json codebase mr status $selector -R group/repo "*)
    printf '%s\n' '{"data":{"merge_request":{"state":"opened","source_commit_id":"branch789"}}}'
    exit 0
    ;;
esac
printf '%s\n' "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$fakebin/bytedcli"

  head=$(PATH="$fakebin:$PATH" fm_review_head_sha "$selector" "$repo")
  state=$(PATH="$fakebin:$PATH" fm_review_state "$selector" "$repo")

  expect_value branch789 "$head" "code.byted branch selector head lookup"
  expect_value OPEN "$state" "code.byted branch selector state lookup"
  assert_grep "--json codebase mr status $selector -R group/repo" "$log" "code.byted branch fallback should pass source branch selector and repo to bytedcli"
  pass "code.byted.org branch fallback uses bytedcli source-branch selector"
}

test_url_and_remote_detection
test_github_lookup_uses_gh
test_gitlab_lookup_uses_bytedcli_codebase
test_gitlab_branch_selector_fallback_uses_bytedcli
