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
  display-message)
    case "$*" in
      *'#{session_name}'*) printf '%s\n' "${FM_FAKE_TMUX_SESSION:-firstmate}" ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane) printf 'idle\n> \n' ;;
  list-clients)
    clients=${FM_FAKE_TMUX_CLIENTS:-$'/dev/ttys001\tfirstmate'}
    if [ "$clients" = "none" ]; then
      echo "no attached clients" >&2
      exit 1
    fi
    printf '%b\n' "$clients"
    ;;
  select-window|switch-client) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/osascript" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_OSASCRIPT_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_OSASCRIPT_LOG"
fi
exit "${FM_FAKE_OSASCRIPT_EXIT:-0}"
SH
  chmod +x "$fb/osascript"
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
    FM_FAKE_TMUX_CLIENTS="${FM_FAKE_TMUX_CLIENTS:-}" \
    FM_FAKE_OSASCRIPT_LOG="${FM_FAKE_OSASCRIPT_LOG:-}" \
    FM_FAKE_OSASCRIPT_EXIT="${FM_FAKE_OSASCRIPT_EXIT:-0}" \
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

make_platform_pythonpath() {
  local dir=$1 system=$2 py
  py="$dir/platform-$system-pythonpath"
  mkdir -p "$py"
  cat > "$py/sitecustomize.py" <<PY
import platform

platform.system = lambda: "$system"
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

test_snapshot_bad_spawned_metadata_does_not_crash() {
  local home out no_birthtime_py unknown_ages
  home="$TMP_ROOT/bad-spawned-home"
  make_home "$home"
  no_birthtime_py=$(make_no_birthtime_pythonpath "$home")
  mkdir -p "$home/wt-bad-inf" "$home/wt-bad-nan"
  fm_write_meta "$home/state/bad-inf.meta" \
    "window=fm-bad-inf" \
    "spawned=inf" \
    "worktree=$home/wt-bad-inf" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  fm_write_meta "$home/state/bad-nan.meta" \
    "window=fm-bad-nan" \
    "spawned=nan" \
    "worktree=$home/wt-bad-nan" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(FM_TEST_PYTHONPATH="$no_birthtime_py" run_dash "$home" snapshot)

  assert_contains "$out" 'data-focus-id="bad-inf">bad-inf</a>' "snapshot renders task with infinite spawned metadata"
  assert_contains "$out" 'data-focus-id="bad-nan">bad-nan</a>' "snapshot renders task with nan spawned metadata"
  unknown_ages=$(printf '%s' "$out" | grep -o '<td>unknown</td>' | wc -l | tr -d ' ')
  [ "$unknown_ages" = "2" ] || fail "invalid spawned metadata should fall back without crashing"
  pass "snapshot rejects non-finite spawned metadata without crashing"
}

test_snapshot_legacy_meta_without_birthtime_uses_precise_since_then_unknown() {
  local home out since no_birthtime_py unknown_ages
  home="$TMP_ROOT/legacy-meta-home"
  since=$(seconds_ago_iso 90000)
  no_birthtime_py=$(make_no_birthtime_pythonpath "$home")
  make_home "$home"
  mkdir -p "$home/wt-legacy-date-only" "$home/wt-legacy-since" "$home/wt-legacy-orphan"
  fm_write_meta "$home/state/legacy-date-only.meta" \
    "window=fm-legacy-date-only" \
    "worktree=$home/wt-legacy-date-only" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
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
- [ ] legacy-date-only - old date-only task (repo: firstmate, since 1970-01-01)
- [ ] legacy-since - old active task (repo: firstmate, since $since)
EOF

  out=$(FM_TEST_PYTHONPATH="$no_birthtime_py" run_dash "$home" snapshot)

  assert_contains "$out" 'data-focus-id="legacy-date-only">legacy-date-only</a>' "snapshot renders legacy meta task with date-only backlog"
  assert_contains "$out" 'data-focus-id="legacy-since">legacy-since</a>' "snapshot renders legacy meta task with backlog"
  assert_contains "$out" 'data-focus-id="legacy-orphan">legacy-orphan</a>' "snapshot renders legacy meta task without backlog"
  assert_contains "$out" '<td>1d 1h</td>' "legacy meta without birthtime falls back to backlog since"
  unknown_ages=$(printf '%s' "$out" | grep -o '<td>unknown</td>' | wc -l | tr -d ' ')
  [ "$unknown_ages" = "2" ] || fail "legacy meta with date-only or missing backlog since has unknown age"
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
  local home port out body log calls before after injected invalid osascript_log darwin_py osascript_calls
  home="$TMP_ROOT/focus-home"
  write_fixture_home "$home"
  darwin_py=$(make_platform_pythonpath "$home" Darwin)
  port=$(free_port)
  log="$home/tmux.log"
  osascript_log="$home/osascript.log"
  : > "$log"
  : > "$osascript_log"
  SERVE_HOME="$home"
  SERVE_PORT="$port"
  out=$(FM_TEST_PYTHONPATH="$darwin_py" FM_FAKE_TMUX_LOG="$log" FM_FAKE_OSASCRIPT_LOG="$osascript_log" run_dash "$home" serve --port "$port" --interval 60)
  assert_contains "$out" "http://127.0.0.1:$port/" "focus test serve prints the local URL"

  body=$(fetch_url_status "http://127.0.0.1:$port/focus?id=alpha")
  assert_contains "$body" "status=200" "focus returns success for a known task id"
  assert_contains "$body" '"ok": true' "focus success body is JSON"
  calls=$(cat "$log")
  assert_contains "$calls" "select-window -t fm-alpha" "focus selects the recorded tmux window"
  assert_contains "$calls" "switch-client -c /dev/ttys001 -t firstmate" "focus switches an attached tmux client to the target session"
  osascript_calls=$(cat "$osascript_log")
  assert_contains "$osascript_calls" '-e tell application "iTerm" to activate' "focus activates iTerm on Darwin"

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

test_focus_reports_no_attached_clients() {
  local home port out body log calls
  home="$TMP_ROOT/focus-no-client-home"
  write_fixture_home "$home"
  port=$(free_port)
  log="$home/tmux.log"
  : > "$log"
  SERVE_HOME="$home"
  SERVE_PORT="$port"
  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CLIENTS=none run_dash "$home" serve --port "$port" --interval 60)
  assert_contains "$out" "http://127.0.0.1:$port/" "focus no-client test serve prints the local URL"

  body=$(fetch_url_status "http://127.0.0.1:$port/focus?id=alpha")
  assert_contains "$body" "status=409" "focus reports no attached tmux clients as a real error"
  assert_contains "$body" "No attached tmux client" "focus no-client error tells the operator how to recover"
  calls=$(cat "$log")
  assert_contains "$calls" "select-window -t fm-alpha" "focus still selects the recorded window before reporting no attached client"
  assert_contains "$calls" "list-clients -F" "focus checks for attached tmux clients"
  assert_not_contains "$calls" "switch-client" "focus does not pretend to switch without an attached client"

  out=$(run_dash "$home" stop --port "$port")
  assert_contains "$out" "stopped port $port" "focus no-client test stop reports the dashboard server stopped"
  SERVE_HOME=""
  SERVE_PORT=""
  pass "focus endpoint reports no attached tmux client instead of returning a false success"
}

test_focus_skips_terminal_activation_off_darwin() {
  local home port out body log osascript_log linux_py calls
  home="$TMP_ROOT/focus-linux-home"
  write_fixture_home "$home"
  linux_py=$(make_platform_pythonpath "$home" Linux)
  port=$(free_port)
  log="$home/tmux.log"
  osascript_log="$home/osascript.log"
  : > "$log"
  : > "$osascript_log"
  SERVE_HOME="$home"
  SERVE_PORT="$port"
  out=$(FM_TEST_PYTHONPATH="$linux_py" FM_FAKE_TMUX_LOG="$log" FM_FAKE_OSASCRIPT_LOG="$osascript_log" run_dash "$home" serve --port "$port" --interval 60)
  assert_contains "$out" "http://127.0.0.1:$port/" "focus non-Darwin test serve prints the local URL"

  body=$(fetch_url_status "http://127.0.0.1:$port/focus?id=alpha")
  assert_contains "$body" "status=200" "focus succeeds off Darwin"
  assert_contains "$body" '"ok": true' "focus non-Darwin success body is JSON"
  calls=$(cat "$log")
  assert_contains "$calls" "switch-client -c /dev/ttys001 -t firstmate" "focus still switches tmux clients off Darwin"
  [ ! -s "$osascript_log" ] || fail "focus should not invoke osascript off Darwin"

  out=$(run_dash "$home" stop --port "$port")
  assert_contains "$out" "stopped port $port" "focus non-Darwin test stop reports the dashboard server stopped"
  SERVE_HOME=""
  SERVE_PORT=""
  pass "focus endpoint degrades gracefully without terminal activation off Darwin"
}

test_snapshot_empty_home
test_snapshot_fixture_home
test_snapshot_meta_without_backlog_line
test_snapshot_bad_spawned_metadata_does_not_crash
test_snapshot_legacy_meta_without_birthtime_uses_precise_since_then_unknown
test_serve_and_stop
test_focus_endpoint
test_focus_reports_no_attached_clients
test_focus_skips_terminal_activation_off_darwin
