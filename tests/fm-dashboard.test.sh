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
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
fi
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
  select-window|switch-client) exit 0 ;;
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
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-}" \
    PYTHONPATH="${FM_TEST_PYTHONPATH:-${PYTHONPATH:-}}" \
    PATH="$FAKEBIN:$PATH" \
    "$DASH" "$@"
}

write_fixture_home() {
  local home=$1 spawned
  spawned=$(( $(date +%s) - 90000 ))
  make_home "$home"
  mkdir -p "$home/wt-alpha" "$home/wt-beta"
  fm_write_meta "$home/state/alpha.meta" \
    "window=fm-alpha" \
    "spawned=$spawned" \
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
- [ ] alpha - [ship/direct-PR] build dashboard copy (repo: firstmate, since 1970-01-01)
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

fetch_url_status() {
  python3 - "$1" <<'PY'
import sys
import urllib.error
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as response:
        body = response.read().decode("utf-8")
        print(f"status={response.status}")
        print(body)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8")
    print(f"status={exc.code}")
    print(body)
PY
}

seconds_ago_iso() {
  python3 - "$1" <<'PY'
import datetime as dt
import sys

then = dt.datetime.now().astimezone() - dt.timedelta(seconds=int(sys.argv[1]))
print(then.strftime("%Y-%m-%d %H:%M:%S"))
PY
}

make_no_birthtime_pythonpath() {
  local dir=$1 py
  py="$dir/no-birthtime-pythonpath"
  mkdir -p "$py"
  cat > "$py/sitecustomize.py" <<'PY'
import pathlib

_real_path_stat = pathlib.Path.stat


class StatWithoutBirthtime:
    def __init__(self, stat):
        self._stat = stat

    def __getattr__(self, name):
        if name == "st_birthtime":
            raise AttributeError(name)
        return getattr(self._stat, name)

    def __getitem__(self, index):
        return self._stat[index]

    def __iter__(self):
        return iter(self._stat)

    def __len__(self):
        return len(self._stat)


def stat_without_birthtime(self, *args, **kwargs):
    return StatWithoutBirthtime(_real_path_stat(self, *args, **kwargs))


pathlib.Path.stat = stat_without_birthtime
PY
  printf '%s\n' "$py"
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
  assert_contains "$out" 'data-focus-id="alpha">alpha</a>' "snapshot renders alpha focus link"
  assert_contains "$out" '<div class="detail task-summary">[ship/direct-PR] build dashboard copy</div>' "snapshot renders the in-flight task summary"
  assert_not_contains "$out" 'build dashboard copy (repo: firstmate, since 1970-01-01)' "snapshot omits redundant repo/since trailer from the task summary"
  assert_contains "$out" '<div class="detail task-summary">investigate state display</div>' "snapshot renders backlog summary for bold task ids"
  assert_contains "$out" '<td>1d 1h</td>' "snapshot computes age from spawned epoch instead of backlog date"
  assert_contains "$out" '<span class="badge badge-working">working</span>' "snapshot uses fm-crew-state working state"
  assert_contains "$out" 'data-focus-id="beta">beta</a>' "snapshot renders beta focus link"
  assert_contains "$out" '<span class="badge badge-blocked">blocked</span>' "snapshot uses fm-crew-state blocked state"
  assert_contains "$out" 'working: implementing dashboard' "snapshot shows the last status event"
  assert_contains "$out" '<a href="https://github.com/example/firstmate/pull/9">PR/MR</a>' "snapshot links review URL from meta"
  assert_contains "$out" 'gamma - add polish' "snapshot renders queued backlog"
  assert_contains "$out" '<a href="https://github.com/example/firstmate/pull/1">https://github.com/example/firstmate/pull/1</a>' "snapshot linkifies done URLs"
  assert_contains "$out" 'fetch(link.href' "snapshot includes focus fetch handler"
  pass "snapshot renders fixture tasks, backlog, review links, and stays read-only"
}

test_snapshot_meta_without_backlog_line() {
  local home out spawned
  home="$TMP_ROOT/orphan-meta-home"
  spawned=$(( $(date +%s) - 90000 ))
  make_home "$home"
  mkdir -p "$home/wt-orphan"
  fm_write_meta "$home/state/orphan.meta" \
    "window=fm-orphan" \
    "spawned=$spawned" \
    "worktree=$home/wt-orphan" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_dash "$home" snapshot)

  assert_contains "$out" 'data-focus-id="orphan">orphan</a>' "snapshot renders meta-only tasks"
  assert_not_contains "$out" '<div class="detail task-summary">' "snapshot omits a summary when no backlog in-flight item exists"
  assert_contains "$out" '<td>1d 1h</td>' "snapshot computes meta-only task age from spawned epoch"
  pass "snapshot handles meta-only in-flight tasks without a backlog summary"
}

test_snapshot_legacy_meta_without_birthtime_uses_since_then_unknown() {
  local home out since no_birthtime_py
  home="$TMP_ROOT/legacy-meta-home"
  since=$(seconds_ago_iso 90000)
  no_birthtime_py=$(make_no_birthtime_pythonpath "$home")
  make_home "$home"
  mkdir -p "$home/wt-legacy-since" "$home/wt-legacy-orphan"
  fm_write_meta "$home/state/legacy-since.meta" \
    "window=fm-legacy-since" \
    "worktree=$home/wt-legacy-since" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  fm_write_meta "$home/state/legacy-orphan.meta" \
    "window=fm-legacy-orphan" \
    "worktree=$home/wt-legacy-orphan" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] legacy-since - old active task (repo: firstmate, since $since)
EOF

  out=$(FM_TEST_PYTHONPATH="$no_birthtime_py" run_dash "$home" snapshot)

  assert_contains "$out" 'data-focus-id="legacy-since">legacy-since</a>' "snapshot renders legacy meta task with backlog"
  assert_contains "$out" 'data-focus-id="legacy-orphan">legacy-orphan</a>' "snapshot renders legacy meta task without backlog"
  assert_contains "$out" '<td>1d 1h</td>' "legacy meta without birthtime falls back to backlog since"
  assert_contains "$out" '<td>unknown</td>' "legacy meta without birthtime and backlog since has unknown age"
  pass "snapshot handles legacy meta age fallback without ctime"
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
  assert_contains "$body" 'data-focus-id="alpha">alpha</a>' "served page contains clickable live snapshot content"
  assert_contains "$body" 'data-focus-status' "served page contains focus status surface"
  pidfile="$home/.lavish/fm-dashboard/fm-dashboard-$port.pid"
  assert_present "$pidfile" "serve writes its pid file under the dashboard runtime dir"
  out=$(run_dash "$home" stop --port "$port")
  assert_contains "$out" "stopped port $port" "stop reports the dashboard server stopped"
  assert_absent "$pidfile" "stop removes the dashboard pid file"
  SERVE_HOME=""
  SERVE_PORT=""
  pass "serve starts, renders, and stop cleans up"
}

test_focus_endpoint() {
  local home port out body log calls before after injected invalid
  home="$TMP_ROOT/focus-home"
  write_fixture_home "$home"
  port=$(free_port)
  log="$home/tmux.log"
  : > "$log"
  SERVE_HOME="$home"
  SERVE_PORT="$port"
  FM_FAKE_TMUX_LOG="$log"
  out=$(run_dash "$home" serve --port "$port" --interval 60)
  assert_contains "$out" "http://127.0.0.1:$port/" "focus test serve prints the local URL"

  body=$(fetch_url_status "http://127.0.0.1:$port/focus?id=alpha")
  assert_contains "$body" "status=200" "focus returns success for a known task id"
  assert_contains "$body" '"ok": true' "focus success body is JSON"
  calls=$(cat "$log")
  assert_contains "$calls" "select-window -t fm-alpha" "focus selects the recorded tmux window"
  assert_contains "$calls" "switch-client -t fm-alpha" "focus asks tmux clients to switch when possible"

  before=$(wc -l < "$log" | tr -d ' ')
  body=$(fetch_url_status "http://127.0.0.1:$port/focus?id=missing-task")
  assert_contains "$body" "status=404" "focus rejects an unknown task id"
  after=$(wc -l < "$log" | tr -d ' ')
  [ "$before" = "$after" ] || fail "unknown task id should not invoke tmux"

  injected=$(fetch_url_status "http://127.0.0.1:$port/focus?id=alpha%3Btouch%20$home/pwned")
  assert_contains "$injected" "status=400" "focus rejects an injected task id"
  after=$(wc -l < "$log" | tr -d ' ')
  [ "$before" = "$after" ] || fail "injected task id should not invoke tmux"
  [ ! -e "$home/pwned" ] || fail "injected task id created a file"

  fm_write_meta "$home/state/evil.meta" "window=fm-evil;touch $home/pwned"
  invalid=$(fetch_url_status "http://127.0.0.1:$port/focus?id=evil")
  assert_contains "$invalid" "status=409" "focus rejects an unsafe recorded window target"
  after=$(wc -l < "$log" | tr -d ' ')
  [ "$before" = "$after" ] || fail "unsafe recorded window target should not invoke tmux"
  [ ! -e "$home/pwned" ] || fail "unsafe recorded window target created a file"

  out=$(run_dash "$home" stop --port "$port")
  assert_contains "$out" "stopped port $port" "focus test stop reports the dashboard server stopped"
  SERVE_HOME=""
  SERVE_PORT=""
  pass "focus endpoint resolves windows from known task metadata and rejects unsafe input"
}

test_snapshot_empty_home
test_snapshot_fixture_home
test_snapshot_meta_without_backlog_line
test_snapshot_legacy_meta_without_birthtime_uses_since_then_unknown
test_serve_and_stop
test_focus_endpoint
