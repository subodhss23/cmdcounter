# Technical Design — cmdcounter

## 1. Purpose

Count every command a user types at an interactive bash prompt on a single
Linux host (RedHat / AlmaLinux / Rocky first-class; Debian/Ubuntu, Arch,
Alpine, openSUSE supported), and show progress toward a goal on a web
dashboard reachable from any machine on the LAN:

```
http://192.168.0.32:7777   ->   10 / 1000   1.0% complete   990 left
```

Non-goals: per-user attribution, storing command text or history, multi-host
aggregation, executing commands, authentication / multi-tenancy.

## 2. Constraints

| Constraint | Consequence |
|---|---|
| Very lightweight | Python standard library only. No pip, no venv, no node, no database. `server.py` is ~250 lines. |
| Runs on any systemd Linux | Only binaries used are `python3` (required) and `curl` (optional, with a `python3` fallback). `start.sh` installs `python3` with the native manager (`dnf`/`yum`, `apt-get`, `pacman`, `apk`, `zypper`) if missing. |
| Must not change how the shell behaves | Observation-only bash hook via `PROMPT_COMMAND`. Nothing is aliased, wrapped, or shimmed. Prompt latency is unaffected. |
| Bash only (per requirement) | One hook code path, no zsh `preexec` branch. Simpler to audit and debug. |
| One machine / one number | No clustering, no login, no per-shell state on the server. The server holds two integers. |
| Readable end to end | Eight files (five runtime + three docs), no build step, no bundler, no CDN. |

## 3. Architecture

```
  interactive bash shells                browser on any LAN machine
  (all shells on this one host)          (phone, laptop, 2nd screen)
         |                                          |
         | one backgrounded POST                    | GET /api/state every 2s
         | per Enter key                            |
         v                                          v
  hook.sh -----------------------------------> server.py :7777
  installed as /etc/profile.d/cmdcount.sh        |
  wired via PROMPT_COMMAND                           | GET / -> index.html
                                                     v
                                              state.json (atomic write)
```

Two halves share exactly one HTTP contract:

1. **Hook (client side, `hook.sh`)** decides *what counts as a command* and
   fires a `POST /api/hit {n:1}` notification. It knows about bash, history,
   and skip rules. It never stores anything.
2. **Server (`server.py`)** knows nothing about shells. It holds `count` and
   `goal`, accepts increments, and serves HTML + JSON. It never sees command
   text, so it cannot leak what was typed.

This split is deliberate: shell integration is the fragile part and can be
fixed or replaced without touching the server, and the server runs fine with
zero shells attached.

## 4. File layout

| File | Role | Generated? |
|---|---|---|
| `start.sh` | Installer + supervisor. The only thing you run. | no |
| `server.py` | HTTP server, state, JSON API. Stdlib only. | no |
| `index.html` | Dashboard. Inline CSS + JS, zero external requests. | no |
| `hook.sh` | Bash hook source. Copied to `/etc/profile.d/cmdcount.sh`. | no |
| `state.json` | `{goal, count}` (+ `started_at`, `updated_at` after first run). | yes, kept |
| `cmdcount.log` | One line per HTTP request (stdout of server, nohup mode). | yes |
| `cmdcount.pid` | PID of the background server. Used by `--stop`. | yes |
| `README.md` | Overview + quick start. | no |
| `instruction.md` | Full user instructions. | no |
| `technical_design.md` | This file. | no |

Nothing is written outside the app directory except
`/etc/profile.d/cmdcount.sh`, one `source` line appended to
the system bashrc (`/etc/bashrc` or `/etc/bash.bashrc`) and `~/.bashrc`
(see §8), and — in service mode —
`/etc/systemd/system/cmdcount.service` (see §12).

## 5. The counting problem

Counting is easy. *Observing* an interactive shell reliably, cheaply, and
without counting yourself is the hard part.

### 5.1 Options considered

| Approach | Verdict |
|---|---|
| Text box in the browser, each Enter = +1 | Rejected: measures typing into a web form, not terminal use. The requirement is "every time I type/enter a command" in the terminal. |
| Poll `~/.bash_history` line count | Rejected: all shells append to one file, offsets race, each shell would report the others' commands, and history is only flushed on exit by default. |
| `auditd` / execve snooping | Rejected: needs audit rules + root policy, sees every forked process (scripts, daemons), not "what a human typed". Heavyweight. |
| Wrap `bash` / `PS1` command substitution | Rejected: changes shell behavior, breaks themes, adds latency to every prompt render. |
| `PROMPT_COMMAND` + diff of `history 1` | **Chosen.** Runs at exactly the right moment (after the command, before the next prompt), uses only a builtin, costs two forks, never blocks. |

### 5.2 How the bash hook works (`hook.sh`)

`PROMPT_COMMAND` is a bash feature: its contents run after each command
completes and before the next primary prompt. The hook prepends one function:

```bash
PROMPT_COMMAND="__cmdcount_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

`__cmdcount_prompt` then runs:

```bash
__cmdcount_raw=$(HISTTIMEFORMAT= history 1 2>/dev/null)
# -> "  512  ls -la"
```

and compares it to `__cmdcount_last` (per-shell variable):

- **First run after the hook loads** (`__cmdcount_init == 0`): store as
  baseline, report nothing. Commands typed *before* the hook was sourced are
  never counted — this avoids a +1 phantom on shell startup.
- **Same string as last time**: nothing new (e.g. empty Enter, or prompt
  redraw), return.
- **Different string**: strip leading spaces, strip the history number
  (`${raw#* }` + trim), run skip rules, else `POST /api/hit`.

The **history number** is what makes `ls` <Enter> `ls` <Enter> count as 2
instead of looking like a duplicate. Comparing the full `number + text`
string means erroring commands still count (they did occupy an Enter), and
commands with no output still count.

Verified property the design relies on: commands bash runs *from inside*
`PROMPT_COMMAND` itself are **not** appended to the history list, so the
hook's own `history`, `curl`, and `grep` invocations never become the "last
entry". The explicit self-exclusion below is belt-and-braces on top of this.

### 5.3 Self-exclusion and skip rules (`__cmdcount_skip`)

Order matters; cheapest checks first:

1. Empty string → skip.
2. `exit` / `logout` → skip. Leaving a shell is not progress; without this,
   every session close adds a phantom +1.
3. `__cmdcount*`, `*cmdcount*`, `*cmdcnt*`, `*$CMDCNT_URL*`,
   `*127.0.0.1:7777*` → skip. The hook's own `curl ... /api/hit` command
   line contains the URL, so if the user ever runs the POST by hand (e.g.
   while debugging) it still counts exactly once, not twice. The variable
   here must be `$CMDCNT_URL` — an earlier revision referenced an unset
   variable (then named `$__cmd148_url`), whose empty expansion collapsed
   the pattern to `**` and
   silently skipped *every* command (count frozen at 0 with the hook loaded).
   Proven by pty test, see §9.
4. `CMDCNT_IGNORE` regex (if set) → skip. Example:
   `export CMDCNT_IGNORE='^(vim|less|top)$'`. Matched with `grep -Eq`
   against the full command line.

### 5.4 Transport (`__cmdcount_post`)

```bash
__cmdcount_post() {
  ( curl ... || python3 ... ) >/dev/null 2>&1 & disown 2>/dev/null
}
```

- One **backgrounded subshell** per command. The interactive shell never
  `wait`s on the network; a dead server costs nothing visible.
- `disown` removes the job from bash's job table so there is no
  `[1]+ Done (...)` notice on the next prompt. Without it every Enter spams
  the terminal with the subshell text.
- `curl -fsS -m 3` is tried first (3 s timeout, fail on HTTP error).
- If curl is missing or the POST fails, the same `n=1` is sent via
`python3 + urllib` with a 3 s timeout. A minimal box without curl
still counts.
- Transport is resolved once per shell (`__cmdcount_transport` caches
  `command -v curl` / `python3`), so there is no `PATH` lookup per prompt.
- All output is discarded. Failures are silent by design (a LAN dashboard
  must never spam the terminal). Diagnose via `tail -f cmdcount.log` on the
  server side — every counted command produces one `POST /api/hit 200` line.

### 5.5 Self-healing (`__cmdcount_reattach`)

Prompt themes and framework snippets (`starship`, `oh-my-bash`, etc.)
rewrite `PROMPT_COMMAND` *after* this file is sourced, silently detaching the
hook. Every invocation of `__cmdcount_prompt` re-checks:

```bash
case ";${PROMPT_COMMAND:-};" in
  *";__cmdcount_prompt;"*) : ;;
  *) PROMPT_COMMAND="__cmdcount_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
```

String compare only, no fork in the common case, so the re-attach itself is
free. Re-sourcing the profile is idempotent — the function is never added
twice.

### 5.6 Guards

- `CMDCNT_ENABLED=0|false|no|off|disabled` → hook returns immediately. Lets
  you open one uncounted shell without uninstalling anything.
- `case "$-" in *i*)` → non-interactive shells (`scp`, `rsync`,
  `ssh host 'cmd'`, cron, scripts) return immediately. Only human prompts count.
- `[ -n "${BASH_VERSION:-}" ]` → sourced from another shell by accident?
  No-op instead of breaking it.
- `CMDCNT_URL` defaults to `http://127.0.0.1:7777`. Override per-shell to
  point at a different host during testing.

### 5.7 Cost per command

Two forks (`$(history 1)` capture + backgrounded subshell) and zero blocking
syscalls on the critical path. No polling, no timers, no file writes from
the shell side. At tens of commands per minute this is unmeasurable against
normal fork/exec of the commands themselves.

## 6. Server (`server.py`)

`http.server.ThreadingHTTPServer`, `daemon_threads = True`,
`protocol_version = HTTP/1.1` with explicit `Content-Length` and
`Cache-Control: no-store` on every response.

### 6.1 State

```json
{
  "goal": 1000, "count": 42, "title": "My challenge",
  "started_at": 1790624479.3, "updated_at": 1790624483.7,
  "timer": {"status": "running", "accumulated": 0.0, "since": 1790624480.1}
}
```

- Loaded once at startup into memory; `threading.Lock` guards every
  read-modify-write (`bump`, `set_goal`, `set_title`, `timer_action`, `reset`,
  `snapshot`).
- Written **atomically** on every mutation: dump to `state.json.tmp` +
  `fsync` + `os.replace`. A crash or `kill -9` mid-write can never leave a
  truncated `state.json`.
- Written on **every increment**, so the on-disk count is never more than
  one command behind. At human typing rates the fsync cost is irrelevant;
  surviving a power cut is worth it.
- `load_state` is defensive: missing / malformed / wrong-typed file falls
  back to defaults instead of refusing to boot. Unknown top-level keys are
  dropped, so a newer state file cannot break an older binary. `goal`
  is clamped to `>= 1`, `count` to `>= 0`.
- The nested `timer` is normalised separately by `normalize_timer`, because
  a shallow key copy is not enough for a nested object. A `state.json` from
  before the stopwatch existed simply has no `timer` key and loads as `idle`.

### 6.2 Endpoints

| Method | Path | Body (JSON or form) | Returns |
|---|---|---|---|
| `GET` | `/`, `/index.html` | — | `index.html`, `text/html`. `500` only if the file is missing. |
| `GET` | `/api/state` | — | Full snapshot (below). |
| `POST` | `/api/hit`, `/api/cmd` | `n=1` | Snapshot with new count. `n` clamped to `1..1000`. `/api/cmd` exists for compatibility with older hooks. |
| `POST` | `/api/goal` | `{"goal": 1000}` | Snapshot. `400` if not an integer or outside `1..100_000_000`. |
| `POST` | `/api/title` | `{"title": "My challenge"}` | Snapshot. `400` if not a string; stripped, truncated to 80 chars, empty falls back to the default. |
| `POST` | `/api/timer` | `{"action": "start" \| "pause" \| "reset"}` | Snapshot. `400` on any other action. |
| `POST` | `/api/reset` | — | Snapshot with `count=0` and fresh `started_at`. Goal and timer untouched. |
| `GET` | `/healthz` | — | `{"ok": true}`. Used by humans and by `start.sh` health checks. |

Snapshot shape (`GET /api/state`, also returned by every POST):

```json
{
  "count": 10, "goal": 1000, "percent": 1.0, "remaining": 990,
  "complete": false, "elapsed_seconds": 3600, "idle_seconds": 5,
  "started_at": 1790624479.3, "host": "alma9", "port": 7777,
  "timer": {"status": "running", "elapsed_seconds": 5040}
}
```

Derived server-side so the page is a dumb renderer: `percent` is
`round(min(100, count*100/goal), 1)`, `remaining` is `max(0, goal-count)`,
`timer.elapsed_seconds` is the running total. Body parsing accepts both
`application/json` and `application/x-www-form-urlencoded` (the hook sends
the latter via curl), capped at 8 KiB. The server never receives, stores, or
logs command text — it cannot leak what was typed because it never sees it.

### 6.2.1 The stopwatch

A count-up timer for working time, separate from `elapsed_seconds` (which is
just "time since the counter was started or reset", and is not something
anyone controls).

State is two numbers, not a ticking value:

- `accumulated` — seconds banked by finished runs
- `since` — wall clock at which the current run began, `0` unless running

`elapsed = accumulated + (now - since)` when running, else `accumulated`.

Storing an anchor instead of an accumulating counter is what makes the
behaviour correct for free:

| Action | Effect |
|---|---|
| `start` | if not already running, set `since = now`. Repeated `start` is a no-op, so a double click cannot restart the clock. |
| `pause` | bank `now - since` into `accumulated`, clear `since`. Repeated `pause` is a no-op. |
| `reset` | back to `idle`, `accumulated = 0`, `since = 0`, in one step whether or not it was running. |

Two properties fall out of storing `since` in `state.json`:

- **A server restart does not interrupt the clock.** The run is anchored to a
  persisted wall-clock time, so the timer is correct again immediately after
  a restart or a reboot, with no catch-up logic.
- **Closing the browser tab does not interrupt it either.** Nothing is driven
  by the page.

`normalize_timer` handles the ugly cases: a `running` timer with no anchor
(`since <= 0`, e.g. a hand-edited state file) degrades to `paused` rather than
reporting a wild or negative number, and any non-numeric or negative value
falls back to `0`.

The counter's `reset` deliberately does **not** touch the timer. They answer
different questions — "how far along am I" and "how long have I been at
this" — and coupling them would make a single button silently destroy
recorded work time.


### 6.3 Concurrency

One thread per connection. Increments are `lock + read + write + fsync`
inside `bump()`, so 50 concurrent POSTs produce exactly +50 and a valid
JSON file. The dashboard's 2 s poll is a lock-protected dict copy plus a
small `json.dumps` — negligible even with several viewers open.

### 6.4 Authentication: none, deliberately

The server is unauthenticated on a trusted LAN: anyone who can reach
`:7777` can read the count, change the goal, or reset. Rationale:

- The threat model for this app is "my home lab", not the internet. Adding
  passwords would complicate the shell hook (secret in every `~/.bashrc`)
  and the dashboard for zero benefit there.
- Do **not** expose port 7777 to the internet. Keep it behind the LAN /
  firewall; `BIND=127.0.0.1 ./start.sh` restricts it to localhost entirely.
- If you later need auth, the seam is small: check a header in
  `Handler.do_POST` and have the hook send it (the older 141 build did
  exactly this with `CMDCNT_TOKEN` / `X-Token`).

### 6.5 Resource use

Idle: one Python process (~15 MB RSS), state in memory, no timers, no open
connections. `index.html` (~8.5 KB) is read from disk per `GET /` — cheaper
than caching to save nothing meaningful, and edits to the file take effect
without a restart. Log volume is one line per request; rotate or truncate
`cmdcount.log` if you leave debug viewers polling for months.

## 7. Dashboard (`index.html`)

Single file, no build, no CDN, no web fonts, no fetch outside same origin.
Renders on a laptop with no internet route, which matters on an isolated lab
network. Olive Garden Feast theme (olive/moss, creamy beige, warm gold,
copper) with a dark/light toggle remembered per browser (follows the OS on
first visit, applied pre-paint so there is no flash).

- **Top bar**: machine hostname (from `state.host`, i.e. the server's
  `socket.gethostname()`) left; Live pill, theme toggle, and gear button
  right. No app name, no platform line — on a single-machine counter the
  hostname is the only identity that matters.
- **Hero**: editable dashboard title as eyebrow (from `state.title`), giant
  `count/goal` opposite a big `remaining` block — the gap being closed.
- **Field note**: a serif-italic motivational quote keyed to
  `floor(count/33) % 128` — 128 real, attributed quotes (perseverance,
  repetition, mastery, computers, automation, experimenting, moving fast,
  obsession with one thing), so every 33 commands brings a fresh push,
  with a small-caps author line. (An earlier `Field note · N / 128`
  kicker was removed for whitespace; the rotation is unchanged.)
- **Chase colors**: every 33 commands (`floor(count/33)`) also rotates the
  big count, `to go` number, bar fill (+ glow), percent, color name, set
  bar, and all pips through 20 dark tones — all saturated darks, no
  whites/yellows/pastels — fading over 0.5 s, so there is always a next
  color to chase. One `--band` CSS variable carries the color to the pips;
  the rest are set inline. The color name rides next to the percent
  (`63.7% · ROYAL`).
- **Rank ladder**: percent-based tiers so ranks work with any goal —
  Seed → Sprout → Sapling → Tiller → Keeper → Harvester → Reaper →
  Granary → Redwood → Legend (10%/tier), Mythic at 100%. There is no
  on-screen rank row; tiers surface only as `Rank up — X` toasts
  (milestone toasts win ties; drops stay silent).
- **Sets**: the 33-command sprint — `Sets 19/31` header, a pip journey map
  (gold done, gradient-filled current pip whose darkness grows with each
  command, dim todo), `Set 20 · 10/33` plus `23 more to close it` and a
  thin set bar. Pips rebuild only when the done/total shape changes;
  density tiers shrink pips past 40 and 100 sets so huge goals still fit
  one page. Set-close toasts yield to milestone/rank toasts.
- **Skeleton**: static HTML carries neutral placeholders (dashes, theme
  defaults) instead of sample numbers, so a refresh never flashes fake
  data before the first poll lands (~1 s on LAN).
- **Gap bar**: band-colored fill with a soft shine sweep, milestone ticks
  at 25/50/75% that ignite gold with a ping ripple plus a toast when crossed,
  a 0…goal scale, a separate large percent readout, and a gold finish flag.
- **Stat row (4)**: Percent, Remaining, Counted, Status — plus a quiet
  session line (`Session 2h 14m · Last command just now`) derived from the
  snapshot's elapsed/idle seconds.
- **Stopwatch**: a thin hairline row pinned to the bottom of the page —
  a 7 px state dot, a small-caps `STOPWATCH` label, the time, and three
  quiet text buttons (`start` / `pause` / `reset`). It is deliberately the
  least prominent element on the screen: no card, no fill, no glow, no
  animation, and no seconds anywhere in the display.
  - The time is formatted to whole minutes (`1h 24m`, `45m`, `0m`,
    `2d 3h`) by `fmtClock`, so the digits change **once a minute**. The
    page polls every 2 s, but `renderTimer` compares the formatted string to
    the last one and skips the DOM write when they match — 60 polls inside
    one minute produce 0 writes, so nothing on the page ticks or reflows.
    This was an explicit requirement (seconds are distracting on an
    always-on dashboard) and it is also the cheapest way to keep a
    permanently-open tab from doing layout work forever.
  - Exact `H:MM:SS` is kept in the `title` attribute for anyone who wants
    to hover — available without being visible.
  - State is carried by the dot colour (grey idle, olive running, gold
    paused) and by which buttons are enabled: `start` is disabled while
    running, `pause` unless running, `reset` while idle. The DOM is only
    touched when the state string changes, not on every poll.
  - Buttons post `/api/timer` and re-render from the response, so what you
    see is the server's answer, never a local guess. A failed request is
    swallowed and the next poll corrects the display.
  - Deliberately not driven by the page: the timer is anchored to a
    server-side wall clock, so it keeps running when the tab is closed and
    survives a server restart.
- **Controls (settings modal)**: title field, goal field, `SAVE` (Enter in
  either field also submits) and `RESET` (with `confirm()`) live in a popup
  behind the gear button — no always-visible control bar. Save posts
  `/api/goal` then `/api/title`. `S` opens settings, Esc, the X, or clicking
  outside closes without saving; success auto-closes. Inline message line
  clears after 2.6 s.
- **Polling**: `fetch("/api/state", {cache:"no-store"})` every 2 s. On a
  count change the number eases up via a 650 ms tween; crossing into a new
  33-band also plays a small Web Audio ding (880 Hz sine, 0.5 s, no audio
  files — the context unlocks on first click/keypress, silent until then);
  crossing into
  complete fires a confetti burst (once per transition, never on load).
  A ding that fires while audio is still suspended is remembered and played
  on unlock; the speaker button toggles/mutes (remembered) and doubles as a
  test button — if it makes no sound, check system volume and tab mute.
  Reduced-motion users get instant state changes throughout.
- **Focus guard**: the goal/title inputs are only overwritten by a poll
  while the modal is closed and unfocused, so typing is never fought by
  the refresh.

## 8. Installation (`start.sh`)

`set -euo pipefail`, idempotent, safe to re-run. Steps in order:

1. **Locate `python3`**; if absent, install with the native manager
   (`dnf`/`yum`, `apt-get`, `pacman`, `apk`, or `zypper`) via `sudo` when
   not root. Abort with a clear message if there is no supported installer.
2. **Create `state.json`** only if missing (`{"goal": $GOAL, "count": 0}`),
   so a restart never wipes progress.
3. **Stop the previous instance**: `kill` the PID in `cmdcount.pid`
   (graceful, then `-9` after 2 s), plus `pkill -f "python3 $APP_DIR/server.py"`
   as a backstop. Stale pidfiles are removed.
4. **Launch**: `setsid nohup python3 server.py >>cmdcount.log 2>&1 &`,
   record `$!` in `cmdcount.pid`. Env `CMDCNT_HOST=$BIND`,
   `CMDCNT_PORT=$PORT` controls bind address/port.
5. **Wait for health**: TCP-connect to `127.0.0.1:$PORT` for up to ~10 s.
   On failure, dump `cmdcount.log` and exit non-zero (no silent dead server).
6. **Apply `GOAL`** only if it differs from the stored goal
   (`GOAL=2000 ./start.sh`). A plain `./start.sh` keeps the stored goal —
   restarting never silently retargets you.
7. **Install the hook**: `cp hook.sh /etc/profile.d/cmdcount.sh`
   (`sudo` as needed), `chmod 0644`, then append
   `[ -f /etc/profile.d/cmdcount.sh ] && . /etc/profile.d/cmdcount.sh`
   under the `# >>> cmdcount >>>` marker to the system bashrc — `/etc/bashrc`
   on RHEL-family, `/etc/bash.bashrc` on Debian-family (first existing file
   wins; skipped when unwritable and non-root) — and `~/.bashrc`. Appends are
   skipped when the path is already present. Without root, prints a manual
   fallback (`echo '. $HOOK_SRC' >> ~/.bashrc`).
8. **Firewall**: firewalld if present (`--permanent --add-port=$PORT/tcp` +
   `--reload`), else ufw if active (`allow $PORT/tcp`); skipped otherwise
   (the script never blocks on a `sudo` password prompt for this).
9. **Print results**: LAN IP (`hostname -I`, first address),
   `http://$IP:$PORT` + `http://localhost:$PORT`, and the "open a NEW
   terminal" reminder.
10. **Service mode** (`--install-service` only): stop any nohup instance,
    (re)install the hook, render the unit (§12), `daemon-reload`,
    `reset-failed`, `enable --now`, then the same TCP health poll against
    the service. Plain `./start.sh` refuses while the unit is active.

Flags/env: `--stop` (kill + exit), `--no-hook` (server only),
`--install-service` / `--uninstall-service` (systemd),
`PORT=` / `BIND=` / `GOAL=` overrides.

Hook updates only land in shells started afterwards. Sourcing copies the
function bodies into each shell's memory, so reinstalling `hook.sh` never
changes already-running shells — open a new terminal or re-source
(`. /etc/profile.d/cmdcount.sh`). Two aids exist for this: the hook
carries `__cmdcount_VERSION` (`1.0`, first marked version — a shell reports it
via `echo $__cmdcount_VERSION`), and `start.sh` checksum-compares source vs
installed hook and prints a re-source reminder only when they differ.
`declare -f __cmdcount_skip` shows exactly which version a shell is running;
this is how the production "count frozen with hook loaded" incident was
diagnosed (the old shell still ran the pre-fix skip logic while the file on
disk was already fixed).

## 9. Verification

What was actually tested (local run, port 17777 to avoid clashing):

```bash
curl -s localhost:17777/healthz
# {"ok": true}
curl -s localhost:17777/api/state
# {"count": 0, "goal": 1000, "percent": 0.0, "remaining": 1000, ...}
curl -s -X POST localhost:17777/api/hit \
  -H 'Content-Type: application/json' -d '{"n":10}'
# {"count": 10, "goal": 1000, "percent": 1.0, "remaining": 990, ...}
```

Recommended checks on the real host after `./start.sh`:

1. `curl -s localhost:7777/api/state` shows the snapshot.
2. Open a **new** terminal, run `echo hello`, re-query — count +1.
3. `tail -f cmdcount.log` while typing (nohup mode; service mode:
   `journalctl -u cmdcount -f`): one `POST /api/hit 200` per Enter.
4. Repeat command twice (`ls` / `ls`): +2, not +1 (history-number path).
5. `exit` a shell: +0.
6. Restart (`./start.sh`): count and goal preserved.
7. `POST /api/goal {"goal": 0}` / `{"goal":"abc"}`: `400`, goal unchanged.
8. 50 concurrent `POST /api/hit`: exactly +50, `state.json` still valid JSON.

The failure mode that matters is "hook silently counts zero" (e.g. theme
clobbers `PROMPT_COMMAND`, or testing with non-interactive `bash -c` which
never fires the hook). Always verify with a real interactive terminal or a
pty, never with `bash -c '...'`.

Pty regression test (drives genuine interactive bash over `pty.fork` with the
hook sourced, asserts on `/api/state`): `echo alpha`, `echo beta`,
`echo beta`, one failing command, then `exit` → count exactly **4** (repeat
counts twice, failure counts, `exit` doesn't) and **no** `Done` job spam in
the terminal output. The same test against the pre-fix hook (unset-variable
typo) counts **0** — the exact production symptom.

### 9.1 Stopwatch

The stopwatch was verified at three levels, because the interesting bugs are
not in the arithmetic.

**Server semantics**, driven through the real HTTP API:

| Check | Result |
|---|---|
| `start` twice in a row | still one run, not a restart |
| run 2.5 s, then read | elapsed advanced |
| `pause`, wait 2 s, read | frozen — the value did not move |
| `start` again after a pause | resumes from the banked 2 s, not from 0 |
| `reset` while running | `idle`, 0 s |
| `{"action": "warp"}` | `400`, state untouched |
| server killed and restarted mid-run | still `running`, elapsed continued |
| `state.json` with no `timer` key (pre-upgrade file) | loads as `idle`, no crash |
| `timer` with junk values (`"accumulated": "nonsense"`, `since: null`) | normalised to `paused` / 0, no crash |
| `POST /api/reset` | count resets, stopwatch untouched |

**Client logic**, run in node against the real functions extracted from
`index.html` with a stub DOM — 33 assertions covering the formatting table
(`0s→0m`, `59s→0m`, `60s→1m`, `90m→1h 30m`, `2d 3h`, negative/`NaN`/
`undefined`/numeric-string inputs), an explicit check that no formatted
value ever ends in a seconds field, the full idle/running/paused button
matrix, the tooltip format, and the write-counting check: **60 polls inside
one minute cause 0 DOM writes, and the 61st causes exactly 1.**

**Rendering**: headless Chrome screenshots in both themes, at `0m` and at
`1h 24m`, confirming the row sits at the bottom, reads correctly in light and
dark, and the enabled/disabled button states match the running state.


## 10. Trade-offs and known limits

- **Enter is the commit point.** A line typed then abandoned with Ctrl-C is
  not counted — it never entered history. This matches the honest definition
  of "command entered".
- **`set +o history` stops counting.** With no history entry there is nothing
  to diff; bash offers no `preexec` equivalent. Re-enable with `set -o history`.
- **History timestamps off.** The hook forces `HISTTIMEFORMAT=` for the
  comparison read so timestamp settings cannot shift the parse.
- **Very long lines**: only the leading number + full text equality matter;
  truncation in display does not affect the diff.
- **Goal is global, counter is shared.** All shells on the host feed one
  number. Multi-tab works (each shell keeps its own `__cmdcount_last`, so no
  double-report); multi-host aggregation does not exist by design.
- **Login vs non-login shells**: `/etc/profile.d` covers login shells, the
  `source` line in the system bashrc + `~/.bashrc` covers interactive non-login
  bash. Both are installed because desktop terminals are usually non-login.
- **Reset/goal are open to the LAN.** See §6.4. On a trusted network this is
  a feature (phone can reset); elsewhere, bind to localhost.
- **Log growth**: `cmdcount.log` grows one line per request in nohup mode.
  Truncate when it bothers you (`: > cmdcount.log`); the server holds no
  file handle assumptions that break on truncation. Service mode logs to
  the journal instead (rotation handled by journald).
- **Running shells keep the hook they sourced.** Updating `hook.sh` on disk
  (or reinstalling it) does not touch already-running shells — their
  function bodies are frozen at source time. After any hook update, open a
  new terminal or re-source. Diagnose with
  `declare -f __cmdcount_skip | head -8`.

## 11. Future extensions (not built)

- Optional token auth (`X-Token`, as in the older 141 build) if the LAN
  stops being trusted.
- `/metrics` Prometheus endpoint (trivial: four gauges from `snapshot()`).
- Per-day rate / ETA (needs a timestamped log, not just two integers).
- zsh support (needs a `preexec` branch; deliberately omitted per the
  bash-only requirement).
- Stopwatch: a target duration with a quiet "over/under" hint, or a
  commands-per-hour derived from the existing `timer` and `count` — both are
  one derived field in `snapshot()` and would not need new state.


## 12. systemd service + reboot persistence

`./start.sh --install-service` promotes the nohup instance to a real unit
(nohup stays the default for zero-privilege installs; the service is opt-in):

```ini
[Unit]
Description=cmdcounter (port 7777)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<installing user>
WorkingDirectory=<APP_DIR>
ExecStart=<python3> <APP_DIR>/server.py
Environment=CMDCNT_HOST=<BIND> CMDCNT_PORT=<PORT>
Restart=always
RestartSec=2
SyslogIdentifier=cmdcount

[Install]
WantedBy=multi-user.target
```

Design points:

- **Runs as the installing user** (`${SUDO_USER:-$(id -un)}` — run it as
  yourself, not under sudo), never root. `state.json` and `cmdcount.log`
  stay owned by you, and binding port 7777 needs no privileges.
- **`Restart=always` + `RestartSec=2`**: a crash comes back in 2 s;
  `enable --now` + `WantedBy=multi-user.target` brings it back after every
  reboot. `After=network-online.target` orders it after the network so the
  LAN URL works from first boot.
- **Logs go to the journal** (`journalctl -u cmdcount -f`,
  `SyslogIdentifier=cmdcount`). An earlier version used
  `StandardOutput=append:` to a file under `/home`, but PID 1 cannot
  reliably open files there with SELinux enforcing — the unit died in ~20 ms
  with `status=209/STDOUT` before Python even started. The journal is the
  native path and always works; `tail -f cmdcount.log` remains the contract
  for nohup mode.
- **No double-start**: plain `./start.sh` refuses when the unit is active
  (`systemctl is-active --quiet`), pointing at `systemctl restart` instead —
  two instances would fight over :7777 and the loser would die with
  EADDRINUSE. `--stop` stops both the unit and any nohup instance.
- **systemd required for service mode**: `--install-service` refuses with a
  clear error when `systemctl` is absent (non-systemd hosts use nohup mode).
- **Persistence proof**: the boot path is load-only — the server reads
  `state.json` at startup and only writes on bump/goal/reset. Nothing in the
  unit, the installer, or a reboot touches the count. The number returns to 0
  exclusively via `POST /api/reset` (the Reset button) or by deleting
  `state.json` (= new project). Verified in sandbox testing: count 7 survived
  a full stop/start cycle with the original `started_at` intact.
- `--uninstall-service` disables, deletes the unit, and reloads — the count
  is preserved and you are back on nohup mode.
