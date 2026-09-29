#!/usr/bin/env python3
"""148_redhat_cmd_counter - lightweight command counter for any systemd Linux.

Stdlib only. Listens on 0.0.0.0:7777.
Counts every interactive bash command (reported by the shell hook),
stores count + goal + title in state.json, serves a nice dashboard.

Endpoints:
  GET  /            dashboard
  GET  /api/state   {count, goal, title, percent, remaining, ...}
  POST /api/hit     body n=1 (also accepts /api/cmd for compat) -> count += n
  POST /api/goal    {goal: 1000}
  POST /api/title   {title: "My challenge"}
  POST /api/reset   -> count = 0
  GET  /healthz     {ok: true}
"""

import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(APP_DIR, "state.json")
INDEX_FILE = os.path.join(APP_DIR, "index.html")

HOST = os.environ.get("CMDCNT_HOST", "0.0.0.0")
try:
    PORT = int(os.environ.get("CMDCNT_PORT", "7777"))
except ValueError:
    raise SystemExit("CMDCNT_PORT must be an integer, e.g. 7777")
if not 1 <= PORT <= 65535:
    raise SystemExit("CMDCNT_PORT must be between 1 and 65535")
DEFAULT_GOAL = int(os.environ.get("CMDCNT_GOAL", "1000") or 1000)
MAX_GOAL = 100_000_000
DEFAULT_TITLE = os.environ.get("CMDCNT_TITLE", "Commands entered")
MAX_TITLE = 80

_lock = threading.Lock()
_state = {}


def _default_state():
    now = time.time()
    return {
        "goal": max(1, DEFAULT_GOAL),
        "count": 0,
        "title": DEFAULT_TITLE,
        "started_at": now,
        "updated_at": now,
    }


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            raise ValueError("bad state")
    except Exception:
        data = _default_state()
    base = _default_state()
    for k in base:
        if k in data:
            base[k] = data[k]
    try:
        base["goal"] = int(base["goal"])
        base["count"] = int(base["count"])
        base["started_at"] = float(base["started_at"])
        base["updated_at"] = float(base["updated_at"])
    except (TypeError, ValueError):
        return _default_state()
    if base["goal"] < 1:
        base["goal"] = 1
    if base["count"] < 0:
        base["count"] = 0
    base["title"] = normalize_title(base.get("title"))
    return base


def normalize_title(value):
    if not isinstance(value, str):
        return DEFAULT_TITLE
    value = value.strip()[:MAX_TITLE]
    return value or DEFAULT_TITLE


def save_state():
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(_state, fh, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, STATE_FILE)


def snapshot():
    with _lock:
        count = _state["count"]
        goal = _state["goal"]
        title = _state["title"]
        started = _state["started_at"]
        updated = _state["updated_at"]
    now = time.time()
    elapsed = max(0.0, now - started)
    pct = round(min(100.0, count * 100.0 / goal), 1) if goal else 0.0
    remaining = max(0, goal - count)
    try:
        host = socket.gethostname()
    except OSError:
        host = "unknown"
    return {
        "count": count,
        "goal": goal,
        "title": title,
        "percent": pct,
        "remaining": remaining,
        "complete": count >= goal,
        "elapsed_seconds": int(elapsed),
        "idle_seconds": int(max(0.0, now - updated)),
        "started_at": started,
        "host": host,
        "port": PORT,
    }


def bump(n=1):
    with _lock:
        _state["count"] = max(0, _state["count"] + int(n))
        _state["updated_at"] = time.time()
        save_state()
        return _state["count"]


def set_goal(goal):
    goal = max(1, min(MAX_GOAL, int(goal)))
    with _lock:
        _state["goal"] = goal
        _state["updated_at"] = time.time()
        save_state()
    return goal


def set_title(title):
    title = normalize_title(title)
    with _lock:
        _state["title"] = title
        _state["updated_at"] = time.time()
        save_state()
    return title


def reset():
    with _lock:
        _state["count"] = 0
        _state["started_at"] = time.time()
        _state["updated_at"] = time.time()
        save_state()


class Handler(BaseHTTPRequestHandler):
    server_version = "redhat-cmdcount/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s - %s\n"
                         % (time.strftime("%d/%b %H:%M:%S"),
                            self.address_string(), fmt % args))
        sys.stdout.flush()

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8")

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        raw = self.rfile.read(min(length, 8 * 1024)).decode("utf-8", "replace")
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype == "application/json":
            try:
                data = json.loads(raw)
            except ValueError:
                return {}
            return data if isinstance(data, dict) else {}
        return {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        route = url.path.rstrip("/") or "/"
        if route in ("/", "/index.html"):
            try:
                with open(INDEX_FILE, "rb") as fh:
                    html = fh.read()
            except OSError:
                return self._json({"error": "index.html missing"}, 500)
            return self._send(200, html, "text/html; charset=utf-8")
        if route == "/api/state":
            return self._json(snapshot())
        if route == "/healthz":
            return self._json({"ok": True})
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        route = url.path.rstrip("/") or "/"
        body = self._read_body()

        if route in ("/api/hit", "/api/cmd"):
            n = body.get("n", 1)
            try:
                n = max(1, min(1000, int(n)))
            except (TypeError, ValueError):
                n = 1
            bump(n)
            return self._json(snapshot())

        if route == "/api/goal":
            try:
                goal = int(str(body.get("goal", "")).strip())
            except (TypeError, ValueError):
                return self._json({"error": "goal must be an integer"}, 400)
            if goal < 1 or goal > MAX_GOAL:
                return self._json({"error": "goal must be 1..%d" % MAX_GOAL}, 400)
            set_goal(goal)
            return self._json(snapshot())

        if route == "/api/title":
            title = body.get("title", None)
            if not isinstance(title, str):
                return self._json({"error": "title must be a string"}, 400)
            set_title(title)
            return self._json(snapshot())

        if route == "/api/reset":
            reset()
            return self._json(snapshot())

        return self._json({"error": "not found"}, 404)


def main():
    global _state
    _state = load_state()
    if not os.path.exists(STATE_FILE):
        with _lock:
            save_state()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    print("redhat-cmd-counter listening on http://%s:%d" % (HOST, PORT))
    print("  state : %s" % STATE_FILE)
    print("  goal  : %d" % _state["goal"])
    print("  count : %d" % _state["count"])
    print("  title : %s" % _state["title"])
    sys.stdout.flush()
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        print("\nshutting down")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
