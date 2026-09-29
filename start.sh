#!/usr/bin/env bash
# cmdcounter / start.sh - does everything on any systemd Linux
# (RedHat/Alma/Rocky first-class; Debian/Ubuntu, Arch, Alpine, openSUSE too).
#
#   ./start.sh                    start (or restart) server + install bash hook (nohup mode)
#   ./start.sh --no-hook          server only, do not touch shell profiles
#   ./start.sh --stop             stop the server (nohup instance and service, if present)
#   ./start.sh --install-service  install + enable systemd unit (auto-start on boot)
#   ./start.sh --uninstall-service  remove the systemd unit
#   GOAL=2000 ./start.sh          set goal at startup
#   PORT=7777 BIND=0.0.0.0 ./start.sh
#
# Persistence: the count lives in state.json. Reboots, service restarts and
# re-runs of start.sh never reset it. Only the Reset button (POST /api/reset)
# or deleting state.json starts a new run.
#
# Env overrides (mainly for testing): SUDO, HOOK_DST, SYSTEMD_UNIT_DIR, SYSTEMCTL.
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-7777}"
BIND="${BIND:-0.0.0.0}"
GOAL="${GOAL:-1000}"
HOOK_SRC="$APP_DIR/hook.sh"
HOOK_DST="${HOOK_DST:-/etc/profile.d/cmdcount.sh}"
# System-wide bashrc: /etc/bashrc on RHEL-family, /etc/bash.bashrc on Debian-family.
SYS_BASHRC=""
for _cand in /etc/bashrc /etc/bash.bashrc; do
  if [ -f "$_cand" ] || [ "$(id -u)" -eq 0 ]; then SYS_BASHRC="$_cand"; break; fi
done
unset _cand
MARKER='# >>> cmdcount >>>'
PIDFILE="$APP_DIR/cmdcount.pid"
LOGFILE="$APP_DIR/cmdcount.log"
SERVICE_NAME="cmdcount"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
INSTALL_HOOK=1
if [ -z "${SUDO+x}" ]; then SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo; fi

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  x %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --stop) STOP_ONLY=1 ;;
    --no-hook) INSTALL_HOOK=0 ;;
    --install-service) INSTALL_SERVICE=1 ;;
    --uninstall-service) UNINSTALL_SERVICE=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done

stop_server() {
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
      kill -9 "$pid" 2>/dev/null || true
      info "stopped pid $pid"
    fi
    rm -f "$PIDFILE"
  fi
  pkill -f "python3 $APP_DIR/server.py" 2>/dev/null || true
  return 0
}

service_active() {
  $SUDO $SYSTEMCTL is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

uninstall_service() {  # best effort, never fails the caller
  $SUDO $SYSTEMCTL disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  if [ -f "$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service" ]; then
    $SUDO rm -f "$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service" >/dev/null 2>&1 || true
    $SUDO $SYSTEMCTL daemon-reload >/dev/null 2>&1 || true
    info "service   : removed $SERVICE_NAME"
  else
    info "service   : not installed"
  fi
  return 0
}

install_service_unit() {
  local svc_user pybin unit
  svc_user="${SUDO_USER:-$(id -un)}"
  pybin="$(command -v python3)"
  unit="$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service"
  $SUDO tee "$unit" >/dev/null <<EOF
[Unit]
Description=cmdcounter (port $PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$svc_user
WorkingDirectory=$APP_DIR
ExecStart=$pybin $APP_DIR/server.py
Environment=CMDCNT_HOST=$BIND CMDCNT_PORT=$PORT
Restart=always
RestartSec=2
SyslogIdentifier=cmdcount

[Install]
WantedBy=multi-user.target
EOF
  $SUDO chmod 0644 "$unit" 2>/dev/null || true
  info "service   : wrote $unit (user $svc_user)"
}

wait_for_port() {  # $1 = port; success when something answers on 127.0.0.1
  local ok=0
  for _ in $(seq 1 40); do
    if python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(); s.settimeout(0.3)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
    then ok=1; break; fi
    sleep 0.25
  done
  [ "$ok" -eq 1 ]
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    info "python3   : $(command -v python3) ($(python3 -V 2>&1 | cut -d' ' -f2))"
    return 0
  fi
  warn "python3 not found, installing with the native package manager"
  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y python3 || die "dnf install python3 failed"
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y python3 || die "yum install python3 failed"
  elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed, trying install anyway"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y python3 || die "apt-get install python3 failed"
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm --needed python || die "pacman install python failed"
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache python3 || die "apk add python3 failed"
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper refresh >/dev/null 2>&1 || true
    $SUDO zypper --non-interactive install -y python3 || die "zypper install python3 failed"
  else
    die "no python3 and no supported package manager (dnf/yum/apt-get/pacman/apk/zypper) - install python3 manually"
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 still not available after install"
  info "python3   : $(command -v python3) ($(python3 -V 2>&1 | cut -d' ' -f2))"
}

ensure_state() {
  case "${GOAL:-}" in ''|*[!0-9]*) GOAL=1000 ;; esac
  if [ ! -f "$APP_DIR/state.json" ]; then
    printf '{\n  "goal": %s,\n  "count": 0\n}\n' "$GOAL" > "$APP_DIR/state.json"
    info "state     : created with goal $GOAL"
  fi
}

apply_goal() {
  # Apply GOAL only if it differs from the stored goal, so a plain
  # ./start.sh (or a reboot) never silently retargets you.
  if [ -n "${GOAL:-}" ]; then
    local stored
    stored=$(python3 -c "import json;print(json.load(open('$APP_DIR/state.json')).get('goal',0))" 2>/dev/null || echo 0)
    if [ "$stored" != "$GOAL" ]; then
      if python3 - "http://127.0.0.1:$PORT" "$GOAL" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
url, goal = sys.argv[1] + "/api/goal", int(sys.argv[2])
req = urllib.request.Request(url, data=json.dumps({"goal": goal}).encode(),
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=5).read()
PY
      then info "goal      : set to $GOAL"
      else warn "could not apply GOAL=$GOAL (set it in the web UI instead)"
      fi
    fi
  fi
}

source_into() {  # $1 = rc file
  [ -f "$1" ] || touch "$1" 2>/dev/null || return 0
  grep -qF "$HOOK_DST" "$1" 2>/dev/null && return 0
  printf '\n%s\n[ -f %s ] && . %s\n' "$MARKER" "$HOOK_DST" "$HOOK_DST" | $SUDO tee -a "$1" >/dev/null
  info "sourced   : $1"
}

install_hook() {
  if [ "$INSTALL_HOOK" -ne 1 ]; then
    info "shell hook skipped (--no-hook)"
    return 0
  fi
  echo "Installing bash hook"
  HOOK_UPDATED=0
  if [ -f "$HOOK_DST" ] && ! cmp -s "$HOOK_SRC" "$HOOK_DST" 2>/dev/null; then
    HOOK_UPDATED=1
  fi
  if $SUDO cp "$HOOK_SRC" "$HOOK_DST" 2>/dev/null; then
    $SUDO chmod 0644 "$HOOK_DST" 2>/dev/null || true
    info "hook      : $HOOK_DST"
    if [ "$HOOK_UPDATED" -eq 1 ]; then
      info "hook updated: running shells still use the old copy - run '. $HOOK_DST' or open a new terminal"
    fi
    if [ -n "$SYS_BASHRC" ] && { [ -w "$SYS_BASHRC" ] || [ "$(id -u)" -eq 0 ]; }; then
      source_into "$SYS_BASHRC"
    fi
    SUDO="" source_into "$HOME/.bashrc" || true
  else
    warn "no root access - install hook manually:"
    warn "  echo '. $HOOK_SRC' >> ~/.bashrc"
  fi
}

open_firewall() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    if $SUDO firewall-cmd --state >/dev/null 2>&1; then
      if $SUDO firewall-cmd --permanent --query-port="$PORT/tcp" >/dev/null 2>&1; then
        info "firewalld : $PORT/tcp already open"
      else
        $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
        $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld : opened $PORT/tcp"
      fi
    fi
  elif command -v ufw >/dev/null 2>&1; then
    if $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
      $SUDO ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
      info "ufw       : allowed $PORT/tcp"
    fi
  fi
}

print_ready() {
  echo
  echo "Ready"
  info "dashboard : http://$IP:$PORT"
  info "            http://localhost:$PORT  (on this host)"
  if [ "$INSTALL_HOOK" -eq 1 ]; then
    echo
    info "Open a NEW terminal (or run: . $HOOK_DST) then type commands."
    info "Stop with: ./start.sh --stop"
  fi
  echo
}

# ------------------------------------------------------------ uninstall ---
if [ "${UNINSTALL_SERVICE:-0}" = "1" ]; then
  echo "Removing $SERVICE_NAME service"
  uninstall_service
  exit 0
fi

# ---------------------------------------------------------------- stop ---
if [ "${STOP_ONLY:-0}" = "1" ]; then
  echo "Stopping cmdcounter"
  if [ -f "$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service" ]; then
    $SUDO $SYSTEMCTL stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    info "service   : stopped $SERVICE_NAME"
  fi
  stop_server
  exit 0
fi

# --------------------------------------------------------------- common ---
echo "cmdcounter setup"
info "directory : $APP_DIR"

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[ -n "${IP:-}" ] || IP="<this-host-ip>"

ensure_python
ensure_state

# -------------------------------------------------------------- service ---
if [ "${INSTALL_SERVICE:-0}" = "1" ]; then
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || die "no systemctl found - this host is not systemd-based; use nohup mode (plain ./start.sh) instead"
  echo "Installing systemd service"
  stop_server
  install_hook
  install_service_unit
  $SUDO $SYSTEMCTL daemon-reload || die "daemon-reload failed"
  $SUDO $SYSTEMCTL reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  $SUDO $SYSTEMCTL enable --now "$SERVICE_NAME" || die "enable --now failed"
  if ! wait_for_port "$PORT"; then
    if [ -f "$LOGFILE" ]; then echo "--- log ---" >&2; cat "$LOGFILE" >&2; fi
    die "service did not come up (see: systemctl status $SERVICE_NAME / journalctl -u $SERVICE_NAME)"
  fi
  info "service   : $SERVICE_NAME enabled and running"
  apply_goal
  open_firewall
  print_ready
  info "service   : systemctl status $SERVICE_NAME"
  info "logs      : journalctl -u $SERVICE_NAME -f"
  echo
  exit 0
fi

# ---------------------------------------------------------------- nohup ---
if service_active; then
  die "systemd service '$SERVICE_NAME' is already active - use: sudo systemctl restart $SERVICE_NAME  (or ./start.sh --uninstall-service first)"
fi

echo "Starting server"
stop_server

: > "$LOGFILE"
RUNNER=""
command -v setsid >/dev/null 2>&1 && RUNNER="setsid"
CMDCNT_HOST="$BIND" CMDCNT_PORT="$PORT" \
  $RUNNER nohup python3 "$APP_DIR/server.py" >>"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

if ! wait_for_port "$PORT"; then
  echo "--- log ---" >&2
  cat "$LOGFILE" >&2
  die "server did not come up"
fi
info "pid       : $(cat "$PIDFILE")"
info "log       : $LOGFILE"

apply_goal
install_hook
open_firewall
print_ready
