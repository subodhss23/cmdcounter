#!/bin/bash
# 148_redhat_cmd_counter - bash hook.
# Installed as /etc/profile.d/cmdcount.sh by start.sh (bash only).
# Counts every interactive command by diffing `history 1` in PROMPT_COMMAND,
# POSTs to http://127.0.0.1:7777 in background so prompt never blocks.
#
#   CMDCNT_ENABLED=0      disable for one shell
#   CMDCNT_URL=http://host:7777   point at another server
#   CMDCNT_IGNORE='^(vim|less)'   regex of commands to skip
#
# Diagnose what a shell loaded:  echo $__cmdcount_VERSION   (expect 1.0)

[ -n "${CMDCNT_URL:-}" ] || CMDCNT_URL="http://127.0.0.1:7777"

case "${CMDCNT_ENABLED:-1}" in
  0|false|no|off|disabled) return 0 2>/dev/null || exit 0 ;;
esac

# Only interactive bash shells.
case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ -n "${BASH_VERSION:-}" ] || return 0 2>/dev/null || exit 0

__cmdcount_last=""
__cmdcount_init=0
__cmdcount_curl=""
__cmdcount_py=""
__cmdcount_ignore_rx="${CMDCNT_IGNORE:-}"
__cmdcount_VERSION="1.0"   # first marked version; a shell reports it via: echo $__cmdcount_VERSION

__cmdcount_transport() {
  if [ -z "$__cmdcount_curl" ] && [ -z "$__cmdcount_py" ]; then
    __cmdcount_curl=$(command -v curl 2>/dev/null)
    [ -n "$__cmdcount_curl" ] || __cmdcount_py=$(command -v python3 2>/dev/null)
  fi
}

__cmdcount_skip() {
  [ -n "$1" ] || return 0
  case "$1" in
    exit|logout) return 0 ;;
    __cmdcount*|*cmdcount*|*cmdcnt*|*"$CMDCNT_URL"*|*"127.0.0.1:7777"*) return 0 ;;
  esac
  if [ -n "$__cmdcount_ignore_rx" ]; then
    printf '%s' "$1" | grep -Eq "$__cmdcount_ignore_rx" 2>/dev/null && return 0
  fi
  return 1
}

__cmdcount_post() {
  (
    if [ -n "$__cmdcount_curl" ]; then
      "$__cmdcount_curl" -fsS -m 3 -o /dev/null -X POST \
        --data-urlencode "n=1" "$CMDCNT_URL/api/hit" 2>/dev/null && exit 0
    fi
    if [ -n "$__cmdcount_py" ]; then
      "$__cmdcount_py" -c 'import sys,urllib.request,urllib.parse as p
d=p.urlencode({"n":1}).encode()
h={"Content-Type":"application/x-www-form-urlencoded"}
urllib.request.urlopen(urllib.request.Request(sys.argv[1],d,h),timeout=3).read()' \
        "$CMDCNT_URL/api/hit" 2>/dev/null && exit 0
    fi
  # disown: each Enter spawns one background POST, and without this bash
  # would print a "[1]+ Done (...)" job notice on the next prompt.
  ) >/dev/null 2>&1 & disown 2>/dev/null
  return 0
}

# Re-attach if a theme rewrote PROMPT_COMMAND.
__cmdcount_reattach() {
  case ";${PROMPT_COMMAND:-};" in
    *";__cmdcount_prompt;"*) : ;;
    *) PROMPT_COMMAND="__cmdcount_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
}

__cmdcount_prompt() {
  __cmdcount_transport
  __cmdcount_raw=$(HISTTIMEFORMAT= history 1 2>/dev/null)
  while :; do case "$__cmdcount_raw" in " "*) __cmdcount_raw=${__cmdcount_raw#?};; *) break;; esac; done

  if [ "$__cmdcount_init" -eq 0 ]; then
    __cmdcount_init=1
    __cmdcount_last="$__cmdcount_raw"
  elif [ "$__cmdcount_raw" != "$__cmdcount_last" ]; then
    __cmdcount_last="$__cmdcount_raw"
    __cmdcount_cmd=${__cmdcount_raw#* }
    while :; do case "$__cmdcount_cmd" in " "*) __cmdcount_cmd=${__cmdcount_cmd#?};; *) break;; esac; done
    __cmdcount_skip "$__cmdcount_cmd" || __cmdcount_post
  fi
  __cmdcount_reattach
  return 0
}

__cmdcount_reattach
unset __cmdcount_raw __cmdcount_cmd
