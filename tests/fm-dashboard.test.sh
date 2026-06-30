#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh.
#
# These keep the dashboard hermetic by giving it a throwaway FM_HOME and a fake
# read-only tmux. The dashboard still calls the real fm-crew-state.sh for each
# task, so the "current state" path stays pinned to the production helper rather
# than tailing status files in dashboard code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)
SERVE_HOME=""
SERVE_PORT=""

cleanup_dashboard() {
  if [ -n "$SERVE_HOME" ] && [ -n "$SERVE_PORT" ]; then
    FM_HOME="$SERVE_HOME" "$DASH" stop --port "$SERVE_PORT" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_dashboard EXIT

make_fakebin() {
  local dir=$1 fb
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
}

run_dash() {
  local home=$1
  shift
  FM_HOME="$home" \
    FM_DASHBOARD_RUNTIME_DIR="$home/.lavish/fm-dashboard" \
    PATH="$FAKEBIN:$PATH" \
    "$DASH" "$@"
}

write_fixture_home() {
  local home=$1
  make_home "$home"
  mkdir -p "$home/wt-alpha" "$home/wt-beta"
  fm_write_meta "$home/state/alpha.meta" \
    "window=fm-alpha" \
    "worktree=$home/wt-alpha" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "pr=https://github.com/example/firstmate/pull/9"
  fm_write_meta "$home/state/beta.meta" \
    "window=fm-beta" \
    "worktree=$home/wt-beta" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=direct-PR" \
    "yolo=off"
  cat > "$home/state/alpha.status" <<'EOF'
working: setup complete
working: implementing dashboard
EOF
  cat > "$home/state/beta.status" <<'EOF'
working: reproducing
blocked: waiting on fixture
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] alpha - build dashboard (repo: firstmate, since 2026-06-30 00:00)
- **beta** - investigate state display (repo: firstmate, since 2026-06-29)

## Queued
- [ ] gamma - add polish (repo: firstmate) blocked-by: alpha - overlap

## Done
- [x] delta - previous change - https://github.com/example/firstmate/pull/1 (merged 2026-06-29)
EOF
}

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

fetch_url() {
  python3 - "$1" <<'PY'
import sys
import urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=5) as response:
    sys.stdout.write(response.read().decode("utf-8"))
PY
}

FAKEBIN=$(make_fakebin "$TMP_ROOT")

test_snapshot_empty_home() {
  local home out
  home="$TMP_ROOT/empty-home"
  make_home "$home"
  out=$(run_dash "$home" snapshot)
  assert_contains "$out" "in-flight 0" "empty dashboard reports zero in-flight tasks"
  assert_contains "$out" "No in-flight tasks." "empty dashboard renders an empty in-flight panel"
  assert_contains "$out" "Queued" "empty dashboard still renders queued section"
  pass "snapshot renders an empty home without errors"
}

test_snapshot_fixture_home() {
  local home before after out
  home="$TMP_ROOT/fixture-home"
  write_fixture_home "$home"
  before=$(find "$home/state" -type f | sort)
  out=$(run_dash "$home" snapshot)
  after=$(find "$home/state" -type f | sort)
  [ "$before" = "$after" ] || fail "snapshot wrote to state/"
  assert_contains "$out" '<td class="task-id">alpha</td>' "snapshot renders alpha row"
  assert_contains "$out" '<span class="badge badge-working">working</span>' "snapshot uses fm-crew-state working state"
  assert_contains "$out" '<td class="task-id">beta</td>' "snapshot renders beta row"
  assert_contains "$out" '<span class="badge badge-blocked">blocked</span>' "snapshot uses fm-crew-state blocked state"
  assert_contains "$out" 'working: implementing dashboard' "snapshot shows the last status event"
  assert_contains "$out" '<a href="https://github.com/example/firstmate/pull/9">PR/MR</a>' "snapshot links review URL from meta"
  assert_contains "$out" 'gamma - add polish' "snapshot renders queued backlog"
  assert_contains "$out" '<a href="https://github.com/example/firstmate/pull/1">https://github.com/example/firstmate/pull/1</a>' "snapshot linkifies done URLs"
  pass "snapshot renders fixture tasks, backlog, review links, and stays read-only"
}

test_serve_and_stop() {
  local home port out body pidfile
  home="$TMP_ROOT/server-home"
  write_fixture_home "$home"
  port=$(free_port)
  SERVE_HOME="$home"
  SERVE_PORT="$port"
  out=$(run_dash "$home" serve --port "$port" --interval 1)
  assert_contains "$out" "http://127.0.0.1:$port/" "serve prints the local URL"
  body=$(fetch_url "http://127.0.0.1:$port/")
  assert_contains "$body" 'http-equiv="refresh" content="1"' "served page auto-refreshes at the requested interval"
  assert_contains "$body" '<td class="task-id">alpha</td>' "served page contains live snapshot content"
  pidfile="$home/.lavish/fm-dashboard/fm-dashboard-$port.pid"
  assert_present "$pidfile" "serve writes its pid file under the dashboard runtime dir"
  out=$(run_dash "$home" stop --port "$port")
  assert_contains "$out" "stopped port $port" "stop reports the dashboard server stopped"
  assert_absent "$pidfile" "stop removes the dashboard pid file"
  SERVE_HOME=""
  SERVE_PORT=""
  pass "serve starts, renders, and stop cleans up"
}

test_snapshot_empty_home
test_snapshot_fixture_home
test_serve_and_stop
