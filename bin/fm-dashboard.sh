#!/usr/bin/env bash
# fm-dashboard.sh - local read-only HTML dashboard for one firstmate home.
#
# Usage:
#   bin/fm-dashboard.sh snapshot
#       Render the current fleet dashboard HTML to stdout.
#
#   bin/fm-dashboard.sh serve [--port 8799] [--interval 5]
#       Start a local HTTP server on 127.0.0.1. The served page refreshes every
#       interval seconds and re-renders by calling `snapshot` on each request.
#       Runtime pid/log files live under $FM_HOME/.lavish/fm-dashboard/.
#
#   bin/fm-dashboard.sh stop [--port 8799]
#       Stop the dashboard server recorded for this home and port.
#
# The dashboard is intentionally read-only with respect to firstmate operations:
# it reads state/*.meta, state/*.status, data/backlog.md, and calls
# bin/fm-crew-state.sh <id> for each task's current state. It does not write
# state/, touch tmux directly, or interact with watcher/supervision files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RUNTIME_DIR="${FM_DASHBOARD_RUNTIME_DIR:-$FM_HOME/.lavish/fm-dashboard}"

usage() {
  cat >&2 <<'EOF'
usage: fm-dashboard.sh snapshot
       fm-dashboard.sh serve [--port 8799] [--interval 5]
       fm-dashboard.sh stop [--port 8799]
EOF
}

positive_int() {
  case "${1:-}" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

parse_serve_args() {
  PORT=8799
  INTERVAL=5
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || { echo "error: --port needs a value" >&2; exit 2; }
        PORT=$2
        shift 2
        ;;
      --interval)
        [ "$#" -ge 2 ] || { echo "error: --interval needs a value" >&2; exit 2; }
        INTERVAL=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
  positive_int "$PORT" || { echo "error: --port must be a positive integer" >&2; exit 2; }
  positive_int "$INTERVAL" || { echo "error: --interval must be a positive integer" >&2; exit 2; }
}

parse_stop_args() {
  PORT=8799
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || { echo "error: --port needs a value" >&2; exit 2; }
        PORT=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
  positive_int "$PORT" || { echo "error: --port must be a positive integer" >&2; exit 2; }
}

pidfile_for() {
  printf '%s/fm-dashboard-%s.pid\n' "$RUNTIME_DIR" "$1"
}

logfile_for() {
  printf '%s/fm-dashboard-%s.log\n' "$RUNTIME_DIR" "$1"
}

pid_is_live() {
  local pid=${1:-}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" >/dev/null 2>&1
}

server_is_ready() {
  python3 - "$1" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 3
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)
PY
}

snapshot() {
  python3 - "$SCRIPT_DIR" "$FM_ROOT" "$FM_HOME" "$STATE" "$DATA" <<'PY'
import datetime as _dt
import html
import os
import pathlib
import re
import subprocess
import sys

script_dir = pathlib.Path(sys.argv[1])
fm_root = pathlib.Path(sys.argv[2])
fm_home = pathlib.Path(sys.argv[3])
state_dir = pathlib.Path(sys.argv[4])
data_dir = pathlib.Path(sys.argv[5])
backlog_path = data_dir / "backlog.md"
crew_state = script_dir / "fm-crew-state.sh"
refresh = os.environ.get("FM_DASHBOARD_REFRESH_INTERVAL", "").strip()

STATE_ORDER = ["working", "parked", "done", "blocked", "failed", "unknown"]
SEP = " \u00b7 "


def esc(value):
    return html.escape(str(value or ""), quote=True)


def linkify(text):
    escaped = esc(text)
    url_re = re.compile(r"(https?://[^\s<>()]+)")

    def repl(match):
        url = match.group(1)
        return '<a href="{0}">{0}</a>'.format(esc(url))

    return url_re.sub(repl, escaped)


def read_keyvals(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def last_status_line(task_id):
    path = state_dir / f"{task_id}.status"
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines()]
    except OSError:
        return ""
    for line in reversed(lines):
        if line:
            return line
    return ""


def current_state(task_id):
    env = os.environ.copy()
    env["FM_HOME"] = str(fm_home)
    env["FM_ROOT_OVERRIDE"] = str(fm_root)
    env["FM_STATE_OVERRIDE"] = str(state_dir)
    env["FM_DATA_OVERRIDE"] = str(data_dir)
    try:
        result = subprocess.run(
            [str(crew_state), task_id],
            cwd=str(fm_root),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
        )
    except Exception as exc:
        return "unknown", f"state: unknown{SEP}source: dashboard{SEP}{exc}"
    line = (result.stdout or "").strip().splitlines()
    detail = line[0] if line else f"state: unknown{SEP}source: none"
    match = re.search(r"\bstate:\s*([^\u00b7\n]+)", detail)
    state = match.group(1).strip() if match else "unknown"
    if state not in STATE_ORDER:
        state = "unknown"
    return state, detail


def backlog_sections():
    sections = {"In flight": [], "Queued": [], "Done": []}
    if not backlog_path.exists():
        return sections
    current = None
    try:
        lines = backlog_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return sections
    for raw in lines:
        line = raw.rstrip()
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            current = heading.group(1)
            continue
        if current in sections and line.strip().startswith("- "):
            sections[current].append(line.strip())
    return sections


ITEM_RE = re.compile(r"^-\s+(?:\[[ xX]\]\s+)?(?:\*\*)?([A-Za-z0-9][A-Za-z0-9._-]*)(?:\*\*)?\s+-\s*(.*)$")


def parse_item(line):
    match = ITEM_RE.match(line)
    if not match:
        return {"id": "", "text": line, "repo": "", "since": "", "line": line}
    task_id, rest = match.group(1), match.group(2)
    repo = ""
    since = ""
    repo_match = re.search(r"\(repo:\s*([^,\)]+)", rest)
    if repo_match:
        repo = repo_match.group(1).strip()
    since_match = re.search(r"\bsince\s+([^)]+)", rest)
    if since_match:
        since = since_match.group(1).strip()
    return {"id": task_id, "text": rest, "repo": repo, "since": since, "line": line}


def parse_since(value):
    if not value:
        return None
    text = value.strip()
    text = re.sub(r"\s+", " ", text)
    candidates = [text, text.replace(" ", "T", 1)]
    if re.match(r"^\d{4}-\d{2}-\d{2}$", text):
        candidates.append(text + "T00:00:00")
    for candidate in candidates:
        try:
            dt = _dt.datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if dt.tzinfo is None:
            return dt.astimezone()
        return dt.astimezone()
    return None


def human_age(seconds):
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m"
    return f"{seconds}s"


def task_age(item, meta_path):
    now = _dt.datetime.now().astimezone()
    since_dt = parse_since(item.get("since", ""))
    if since_dt is not None:
        return human_age((now - since_dt).total_seconds())
    try:
        return human_age(_dt.datetime.now().timestamp() - meta_path.stat().st_mtime)
    except OSError:
        return "unknown"


def meta_tasks():
    tasks = {}
    if state_dir.exists():
        for meta_path in sorted(state_dir.glob("*.meta")):
            task_id = meta_path.name[:-5]
            tasks[task_id] = {"id": task_id, "meta_path": meta_path, "meta": read_keyvals(meta_path)}
    return tasks


def status_badge(state):
    return f'<span class="badge badge-{esc(state)}">{esc(state)}</span>'


sections = backlog_sections()
inflight_items = {item["id"]: item for item in (parse_item(line) for line in sections["In flight"]) if item["id"]}
tasks = meta_tasks()
for task_id, item in inflight_items.items():
    tasks.setdefault(task_id, {"id": task_id, "meta_path": state_dir / f"{task_id}.meta", "meta": {}})

rows = []
counts = {state: 0 for state in STATE_ORDER}
for task_id in sorted(tasks):
    task = tasks[task_id]
    meta = task["meta"]
    meta_path = task["meta_path"]
    item = inflight_items.get(task_id, {"id": task_id, "text": "", "repo": "", "since": ""})
    state, state_line = current_state(task_id)
    counts[state] = counts.get(state, 0) + 1
    project = meta.get("project") or item.get("repo") or ""
    kind = meta.get("kind") or "ship"
    mode = meta.get("mode") or ""
    pr = meta.get("pr") or ""
    last = last_status_line(task_id)
    rows.append(
        {
            "id": task_id,
            "project": project,
            "kind": kind,
            "mode": mode,
            "state": state,
            "state_line": state_line,
            "last": last,
            "age": task_age(item, meta_path),
            "pr": pr,
        }
    )

generated = _dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
refresh_meta = ""
if refresh:
    try:
        refresh_secs = int(refresh)
        if refresh_secs > 0:
            refresh_meta = f'<meta http-equiv="refresh" content="{refresh_secs}">'
    except ValueError:
        pass

summary_parts = [f"in-flight {len(rows)}"]
summary_parts.extend(f"{state} {counts.get(state, 0)}" for state in STATE_ORDER if counts.get(state, 0))
if len(summary_parts) == 1:
    summary_parts.append("no active tasks")

print(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{refresh_meta}
<title>Firstmate Dashboard</title>
<style>
:root {{
  color-scheme: light;
  --bg: #f7f7f4;
  --panel: #ffffff;
  --text: #202124;
  --muted: #61666d;
  --border: #d9d9d2;
  --working: #0f766e;
  --parked: #8a5a00;
  --done: #2f6f44;
  --blocked: #a34700;
  --failed: #b42318;
  --unknown: #5f6368;
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 14px;
  line-height: 1.45;
}}
main {{
  max-width: 1280px;
  margin: 0 auto;
  padding: 24px;
}}
header {{
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: flex-end;
  border-bottom: 1px solid var(--border);
  padding-bottom: 16px;
  margin-bottom: 18px;
}}
h1 {{
  margin: 0;
  font-size: 28px;
  font-weight: 700;
}}
h2 {{
  margin: 24px 0 10px;
  font-size: 18px;
}}
.meta {{
  color: var(--muted);
  text-align: right;
  white-space: nowrap;
}}
.summary {{
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 12px 0 18px;
}}
.pill {{
  border: 1px solid var(--border);
  background: var(--panel);
  border-radius: 999px;
  padding: 5px 10px;
}}
table {{
  width: 100%;
  border-collapse: collapse;
  background: var(--panel);
  border: 1px solid var(--border);
}}
th, td {{
  padding: 9px 10px;
  border-bottom: 1px solid var(--border);
  text-align: left;
  vertical-align: top;
}}
th {{
  color: var(--muted);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0;
  background: #fbfbf8;
}}
tr:last-child td {{ border-bottom: 0; }}
.task-id {{
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  white-space: nowrap;
}}
.muted {{ color: var(--muted); }}
.detail {{
  color: var(--muted);
  font-size: 12px;
  margin-top: 3px;
}}
.badge {{
  display: inline-block;
  min-width: 76px;
  padding: 3px 8px;
  border-radius: 999px;
  color: white;
  text-align: center;
  font-weight: 650;
}}
.badge-working {{ background: var(--working); }}
.badge-parked {{ background: var(--parked); }}
.badge-done {{ background: var(--done); }}
.badge-blocked {{ background: var(--blocked); }}
.badge-failed {{ background: var(--failed); }}
.badge-unknown {{ background: var(--unknown); }}
.lists {{
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 18px;
}}
.list-panel {{
  background: var(--panel);
  border: 1px solid var(--border);
  padding: 14px 16px;
}}
ul {{
  margin: 0;
  padding-left: 19px;
}}
li + li {{ margin-top: 8px; }}
a {{
  color: #0b57d0;
  text-decoration: none;
}}
a:hover {{ text-decoration: underline; }}
.empty {{
  color: var(--muted);
  padding: 16px;
  background: var(--panel);
  border: 1px dashed var(--border);
}}
@media (max-width: 860px) {{
  main {{ padding: 14px; }}
  header {{ display: block; }}
  .meta {{ text-align: left; margin-top: 8px; white-space: normal; }}
  table {{ display: block; overflow-x: auto; }}
  .lists {{ grid-template-columns: 1fr; }}
}}
</style>
</head>
<body>
<main>
<header>
  <div>
    <h1>Firstmate Dashboard</h1>
    <div class="muted">{esc(fm_home)}</div>
  </div>
  <div class="meta">generated {esc(generated)}</div>
</header>
<section class="summary">
""")
for part in summary_parts:
    print(f'  <span class="pill">{esc(part)}</span>')
print("</section>")

print("<h2>In Flight</h2>")
if rows:
    print("""<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Project</th>
      <th>Type</th>
      <th>Mode</th>
      <th>Current</th>
      <th>Last status</th>
      <th>Age</th>
      <th>Review</th>
    </tr>
  </thead>
  <tbody>""")
    for row in rows:
        pr_html = '<span class="muted">-</span>'
        if row["pr"]:
            if re.match(r"^https?://", row["pr"]):
                pr_html = f'<a href="{esc(row["pr"])}">PR/MR</a>'
            else:
                pr_html = esc(row["pr"])
        last_html = linkify(row["last"]) if row["last"] else '<span class="muted">-</span>'
        mode_html = esc(row["mode"]) if row["mode"] else '<span class="muted">-</span>'
        project_html = esc(row["project"]) if row["project"] else '<span class="muted">-</span>'
        print(f"""    <tr>
      <td class="task-id">{esc(row["id"])}</td>
      <td>{project_html}</td>
      <td>{esc(row["kind"])}</td>
      <td>{mode_html}</td>
      <td>{status_badge(row["state"])}<div class="detail">{esc(row["state_line"])}</div></td>
      <td>{last_html}</td>
      <td>{esc(row["age"])}</td>
      <td>{pr_html}</td>
    </tr>""")
    print("  </tbody>\n</table>")
else:
    print('<div class="empty">No in-flight tasks.</div>')

def render_list(title, lines, limit=None):
    shown = lines[:limit] if limit else lines
    print(f'<div class="list-panel"><h2>{esc(title)}</h2>')
    if shown:
        print("<ul>")
        for line in shown:
            print(f"  <li>{linkify(line)}</li>")
        print("</ul>")
    else:
        print('<div class="muted">None.</div>')
    print("</div>")

print('<section class="lists">')
render_list("Queued", sections["Queued"])
render_list("Recent Done", sections["Done"], limit=10)
print("</section>")
print("</main>\n</body>\n</html>")
PY
}

serve_child() {
  parse_serve_args "$@"
  export FM_DASHBOARD_REFRESH_INTERVAL="$INTERVAL"
  exec python3 - "$SCRIPT_PATH" "$FM_ROOT" "$FM_HOME" "$STATE" "$DATA" "$PORT" "$INTERVAL" <<'PY'
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import sys

script_path, fm_root, fm_home, state_dir, data_dir, port, interval = sys.argv[1:8]
port = int(port)


class Handler(BaseHTTPRequestHandler):
    server_version = "firstmate-dashboard"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found\n")
            return
        env = os.environ.copy()
        env["FM_HOME"] = fm_home
        env["FM_ROOT_OVERRIDE"] = fm_root
        env["FM_STATE_OVERRIDE"] = state_dir
        env["FM_DATA_OVERRIDE"] = data_dir
        env["FM_DASHBOARD_REFRESH_INTERVAL"] = interval
        try:
            result = subprocess.run(
                [script_path, "snapshot"],
                cwd=fm_root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )
            if result.returncode == 0:
                body = result.stdout
                status = 200
            else:
                body = "<!doctype html><title>Firstmate Dashboard Error</title><pre>{}</pre>".format(
                    html.escape(result.stderr or result.stdout or "snapshot failed")
                )
                status = 500
        except Exception as exc:
            body = "<!doctype html><title>Firstmate Dashboard Error</title><pre>{}</pre>".format(html.escape(str(exc)))
            status = 500
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


with ThreadingHTTPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PY
}

serve() {
  parse_serve_args "$@"
  mkdir -p "$RUNTIME_DIR"
  local pidfile logfile pid
  pidfile=$(pidfile_for "$PORT")
  logfile=$(logfile_for "$PORT")
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if pid_is_live "$pid"; then
    printf 'fm-dashboard already running at http://127.0.0.1:%s/ (pid %s)\n' "$PORT" "$pid"
    return 0
  fi
  rm -f "$pidfile"
  nohup env FM_DASHBOARD_REFRESH_INTERVAL="$INTERVAL" "$SCRIPT_PATH" _serve --port "$PORT" --interval "$INTERVAL" >"$logfile" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  if ! pid_is_live "$pid" || ! server_is_ready "$PORT"; then
    rm -f "$pidfile"
    echo "error: fm-dashboard failed to start; see $logfile" >&2
    [ -s "$logfile" ] && tail -n 20 "$logfile" >&2
    exit 1
  fi
  printf 'fm-dashboard serving http://127.0.0.1:%s/ (pid %s, refresh %ss)\n' "$PORT" "$pid" "$INTERVAL"
  printf 'stop with: %s stop --port %s\n' "$SCRIPT_PATH" "$PORT"
}

stop_server() {
  parse_stop_args "$@"
  local pidfile pid
  pidfile=$(pidfile_for "$PORT")
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if ! pid_is_live "$pid"; then
    rm -f "$pidfile"
    printf 'fm-dashboard is not running for port %s\n' "$PORT"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local attempts=5
  while [ "$attempts" -gt 0 ]; do
    pid_is_live "$pid" || break
    sleep 0.2
    attempts=$((attempts - 1))
  done
  if pid_is_live "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
  printf 'fm-dashboard stopped port %s\n' "$PORT"
}

cmd=${1:-}
case "$cmd" in
  snapshot)
    shift
    [ "$#" -eq 0 ] || { usage; exit 2; }
    snapshot
    ;;
  serve)
    shift
    serve "$@"
    ;;
  stop)
    shift
    stop_server "$@"
    ;;
  _serve)
    shift
    serve_child "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
