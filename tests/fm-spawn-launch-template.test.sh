#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh launch templates.
#
# These tests eval only the launch_template function from fm-spawn.sh, so they
# do not create tmux windows, worktrees, or launch real harnesses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

eval "$(
  awk '
    /^launch_template\(\)/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$ROOT/bin/fm-spawn.sh"
)"

test_claude_prefers_local_proxy_launcher() {
  local cmd
  cmd=$(launch_template claude ship)
  assert_contains "$cmd" 'command -v ccc' "claude template should detect the local ccc launcher"
  assert_contains "$cmd" 'ccc --dangerous "$(cat __BRIEF__)"' "claude template should launch through ccc in dangerous mode"
  assert_contains "$cmd" 'env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' "claude template should keep prompt suggestions disabled"
  assert_contains "$cmd" 'claude --dangerously-skip-permissions "$(cat __BRIEF__)"' "claude template should retain a direct claude fallback"
  pass "claude launch template prefers ccc and keeps direct fallback"
}

test_pi_prefers_local_proxy_wrapper() {
  local ship secondmate
  ship=$(launch_template pi ship)
  secondmate=$(launch_template pi secondmate)

  assert_contains "$ship" '$HOME/.pi/agent/pi-with-proxy.sh' "pi ship template should detect the local proxy wrapper"
  assert_contains "$ship" 'pi-with-proxy.sh" -e __PIEXT__ "$(cat __BRIEF__)"' "pi ship template should pass the turn-end extension through the wrapper"
  assert_contains "$ship" 'command pi -e __PIEXT__ "$(cat __BRIEF__)"' "pi ship template should retain a direct pi fallback"

  assert_contains "$secondmate" '$HOME/.pi/agent/pi-with-proxy.sh' "pi secondmate template should detect the local proxy wrapper"
  assert_contains "$secondmate" 'pi-with-proxy.sh" "$(cat __BRIEF__)"' "pi secondmate template should pass only the brief through the wrapper"
  assert_contains "$secondmate" 'command pi "$(cat __BRIEF__)"' "pi secondmate template should retain a direct pi fallback"
  assert_not_contains "$secondmate" '__PIEXT__' "pi secondmate template must not reference the parent turn-end extension"
  pass "pi launch templates prefer the proxy wrapper and keep direct fallback"
}

test_claude_prefers_local_proxy_launcher
test_pi_prefers_local_proxy_wrapper
