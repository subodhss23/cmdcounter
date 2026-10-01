# Instructions — cmdcounter

## What this app does

It counts **every command you type in the terminal** on your RedHat /
AlmaLinux / Rocky box and shows progress toward a goal on a web page you can
open from any machine on your network:

```
10 / 1000 commands   1.0% complete   990 left
```

- You type normally in bash. Every Enter = +1.
- The page at `http://192.168.0.32:7777` shows the big `count / goal`,
  the remaining gap, a motivational field note (128 real quotes, a new one
  every 33 commands), a progress bar that changes into a new dark color
  every 33 commands (with a ding), rank titles to chase, and a `Goal reached` note when
  you arrive. Sun/moon button switches dark and light themes.
- You can change the goal (default `1000`) any time in the page — no
  restart. A Reset button zeroes the counter.
- Very lightweight: stdlib Python only, one background HTTP call per
  command (your prompt never waits), port `7777`, one server, bash only.

You install **nothing** on the viewing machines — just open the URL in a
browser.

---

## 1. Install (on the RedHat box)

Copy this folder to the Linux host, then:

```bash
cd cmdcounter
chmod +x start.sh
./start.sh
```

That single command does everything:

1. checks for `python3` (installs it with the native package manager —
   `dnf`/`yum`, `apt-get`, `pacman`, `apk`, or `zypper` — if missing)
2. starts `server.py` on `0.0.0.0:7777` in the background
3. installs the bash hook as `/etc/profile.d/cmdcount.sh`
4. adds a `source` line to the system bashrc (`/etc/bashrc` on RHEL-family,
   `/etc/bash.bashrc` on Debian-family) and `~/.bashrc`
5. opens `7777/tcp` in firewalld (or ufw) if a firewall is running
6. prints the URL, e.g. `http://192.168.0.32:7777`

## 2. Open a new terminal

The hook only loads when a shell **starts**, so commands in your *current*
terminal are not counted yet.

- Either close and reopen your terminal, or run once in the current one:

```bash
. /etc/profile.d/cmdcount.sh
```

Now use the terminal normally. Every command you Enter is counted.

## 3. View the dashboard

On the box itself:

```
http://localhost:7777
```

From any other machine / phone on the same network:

```
http://192.168.0.32:7777
```

(Use the IP `start.sh` printed — `192.168.0.32` is just an example.)

The page refreshes every 2 seconds. Leave it open on a second screen. It
shows:

| What you see | Meaning |
|---|---|
| Big `10 / 1000` | commands entered so far / goal |
| `363 to go` block | remaining — the gap you're closing |
| Title (eyebrow) | your challenge name — editable in Settings |
| Field note | a new motivational quote + author every 33 commands |
| Rank | Seed → Mythic ladder, `Rank up` toasts (no on-screen rank row) |
| Progress bar | new dark chase color every 33 commands with a ding (20 colors, shared by counter, `to go`, bar, pips, set bar), milestone ticks at 25/50/75% that light up + toast when crossed, gold finish flag |
| Sets | `Sets 19/31` journey map — gold pips per closed set, current pip filling darker with each command, `Set 20 · 10/33` plus `23 more to close it` |
| Stat row | Percent, Remaining, Counted, Status |
| Live pill | green dot = server reachable; grey + "Offline" = stopped |
| Sun/moon button | toggles dark / light theme (remembered in that browser) |
| Gear button | opens Settings popup: Title, Goal, Save, Reset (`S` also opens it) |
| Speaker button | ding on/off — click it once to test sound (also unlocks audio); choice remembered |
| Bottom line | stopwatch on the left, `start` / `pause` / `reset` in the middle, "Last command 2m ago" on the right |

### The stopwatch

The bottom row of the page, in one line:

```
● 1h 44m                 [ pause ]  [ reset ]              Last command 2m ago
```

- **Left** — the dot and the elapsed time.
- **Middle** — the controls. Which buttons are there depends on the state:

  | State | Buttons | How it looks |
  |---|---|---|
  | stopped | `start` | dot grey, `start` outlined; `pause`/`reset` hidden |
  | **running** | `start` `pause` `reset` | dot green and breathing, time bright, `start` dimmed |
  | paused | `start` `resume` `reset` | dot gold, `start` dimmed, `resume` + `reset` outlined |

- **Right** — how long ago the last command was counted.

Things worth knowing:

- **`start` is always on screen.** It never vanishes — once the clock has
  started it dims into a disabled feel instead, so the layout never shifts
  and it cannot be pressed twice. `pause` and `reset` pop in only after
  `start`, and on pause the pause button reads `resume` (resuming picks up
  where it stopped rather than starting over). Press `reset` to zero it.
- **You can always tell it is running**, even though there are no seconds:
  the dot pulses a soft ring once every 2.6 seconds and the time goes
  bright. Either one is enough. (`pause` and `reset` share one ghost style
  in every state.)
- **It shows whole minutes only** — `1h 24m`, `45m`, `0m`, `2d 3h`. The
  exact time is in the tooltip if you hover over it.
- **The pulse can be turned off** by your OS "reduce motion" setting; the
  dot then shows a static ring instead of breathing.
- **It is not automatic.** It does not start when the server starts, and it
  keeps running if you close the page — that is the point, you are not meant
  to babysit a tab. Start it when you sit down to work.
- **It is independent of the counter.** Resetting the command count does not
  touch the stopwatch, and vice versa.
- **It survives a restart.** The server can be stopped and started without
  losing the time.



## 4. Set the title and goal

Click the gear button (top right) → edit **Title** and/or **Goal** → **Save**
(or press Enter in a field). Takes effect immediately, no restart. The
counter keeps its current count. The popup closes on success; Esc, the X, or
clicking outside closes it without saving. The title (max 80 characters) is
stored server-side, so every viewer sees the same heading.

From the command line instead:

```bash
GOAL=2000 ./start.sh
```

A plain `./start.sh` without `GOAL=` keeps whatever goal is stored.

## 5. Reset the counter

Click the gear button → **Reset** → confirm. Count goes to `0`, the clock
restarts, the goal is left alone.

## 6. Stop / restart

```bash
./start.sh          # restart (keeps count + goal)
./start.sh --stop   # stop the server
```

Progress lives in `state.json` and survives restarts. To start fully over:

```bash
./start.sh --stop
rm -f state.json
./start.sh
```

---

## 7. Run at boot with systemd

By default the server runs under `nohup` and does **not** survive a reboot.
To make it permanent:

```bash
./start.sh --install-service
```

This stops the nohup instance, writes
`/etc/systemd/system/cmdcount.service` (running as your user, not root),
enables it for boot, and starts it now. Your count is untouched. Needs
systemd — on non-systemd hosts (Alpine/OpenRC, Void) use nohup mode
(plain `./start.sh`) instead.

Check it:

```bash
systemctl status cmdcount
systemctl is-enabled cmdcount   # expect "enabled"
curl -s localhost:7777/api/state
```

Reboot test: `sudo reboot`, and after boot `curl -s localhost:7777/api/state`
shows the same count with no action from you. Service logs live in the
journal (`journalctl -u cmdcount -f`). (`tail -f cmdcount.log` only
applies to nohup mode.)

To go back to nohup mode (count preserved):

```bash
./start.sh --uninstall-service
```

### When does the number change?

- Typing commands in a hooked shell: +1 per Enter.
- **Reset** button in the dashboard: back to 0 (goal kept).
- Deleting `state.json`: a brand-new project on next start.
- Reboots, `systemctl restart cmdcount`, `./start.sh` re-runs: **never**
  reset — the number is loaded from `state.json` untouched.

---

## Common tasks

### Change the port

```bash
PORT=8080 ./start.sh
# dashboard is then http://192.168.0.32:8080
```

### Listen on localhost only

```bash
BIND=127.0.0.1 ./start.sh
```

Use this if you do *not* want other machines to reach (or reset) the
counter.

### Run the server without touching shell profiles

```bash
./start.sh --no-hook
```

Counting stays off; the dashboard + API still work (you can
`curl -X POST localhost:7777/api/hit` to test).

### Update the app without losing your count

Re-copying the whole folder overwrites `state.json` on the box with your
local copy (usually count 0). Back it up first — or copy only changed files:

```bash
scp cmdcounter/hook.sh almalinux@192.168.0.32:~/cmdcounter/
```

Then on the box: `sudo cp hook.sh /etc/profile.d/cmdcount.sh` (or re-run
`./start.sh` / `./start.sh --install-service` — the count is preserved
either way). `start.sh` prints a warning when the installed hook actually
changed. Then re-source running shells
(`. /etc/profile.d/cmdcount.sh`) or open new terminals, and verify with
`echo $__cmdcount_VERSION` (expect `1.1`).

### Ignore certain commands

Add this **above** the counter's `source` line in `~/.bashrc`:

```bash
export CMDCNT_IGNORE='^(vim|vi|nano|less|top|htop)$'
```

It is a regex matched against the whole command line.

### Turn counting off in one shell

```bash
export CMDCNT_ENABLED=0
```

Open (or reuse) a shell with that set — nothing you type there counts.
Unset it (or open a fresh shell) to count again.

### Point a shell at a different server

```bash
export CMDCNT_URL=http://10.0.0.5:7777
```

Put it in that shell's `~/.bashrc` above the counter line. Useful for
testing without touching the real counter.

---

## Checking that it works

Count should move:

```bash
curl -s localhost:7777/api/state
```

```json
{"count": 42, "goal": 1000, "percent": 4.2, "remaining": 958, ...}
```

Fresh page loads show dashes until the first poll lands (~1 s) — that is
the neutral skeleton, not a bug. If dashes persist, the server is
unreachable (the Live pill turns grey + "Offline").

Use the `127.0.0.1` form for checks, not `localhost`: a `localhost:7777`
command line does not match the hook's self-exclusion, so typing the check
itself counts +1. With `127.0.0.1:7777` the check is skipped and the number
only moves for real commands.

Watch requests arrive as you type (in another terminal, nohup mode):

```bash
tail -f cmdcount.log
```

Service mode: `journalctl -u cmdcount -f` instead. Every Enter in a
hooked shell produces one `POST /api/hit 200` line.
The page's LIVE indicator + auto-refresh confirm the same thing visually.

Manual end-to-end check:

1. Note the count in the page.
2. In a **new** terminal run `echo hello`.
3. Page count goes +1 within ~2 s.

---

## What is (and is not) counted

Counted: anything you Enter at an interactive bash prompt, including
commands that fail, repeats (`ls`, `ls` = +2), and `sudo ...` lines.

Not counted:

- commands run **before** the hook was installed / shell was (re)started
- `exit` and `logout` (leaving a shell is not progress)
- the counter's own `curl` / `python3` network calls
- anything matching your `CMDCNT_IGNORE` regex
- non-interactive activity: scripts, cron, `scp` / `rsync`,
  `ssh host 'command'`, commands run inside `vim`
- a line typed then abandoned with Ctrl-C (it never entered history)

---

## Troubleshooting

**The number is not moving.**

1. The hook only loads in new shells. Open a new terminal, or
   `. /etc/profile.d/cmdcount.sh` in the current one.
2. Confirm it is wired: `grep cmdcount ~/.bashrc /etc/bashrc /etc/bash.bashrc`
   should show the `source` line.
3. Confirm bash sees it: `echo "$PROMPT_COMMAND"` should contain
   `__cmdcount_prompt`.
4. Look at the server log — `tail -f cmdcount.log` in nohup mode,
   `journalctl -u cmdcount -f` in service mode. Each Enter should log
   `POST /api/hit 200`. If nothing appears, the hook is not loaded in
   that shell. If lines appear but count stays, check
   `curl -s 127.0.0.1:7777/api/state` for errors.
5. If you previously added a `__cmdcount_url=...` (originally `__cmd148_url=...`)
   export or a `__cmdcount_post() {...}` override to `~/.bashrc` as a workaround, remove
   those lines — the shipped `hook.sh` is fixed and those stale lines will shadow
   it. Then open a fresh terminal.
6. Updated `hook.sh` but an old shell still misbehaves? Sourcing copies the
   functions into shell memory, so running shells keep whatever version
   they loaded. Quick check: `echo $__cmdcount_VERSION` (expect `1.1`;
   empty means pre-version hook — definitely stale). Definitive check:
   `declare -f __cmdcount_skip | head -8`. Then re-source
   (`. /etc/profile.d/cmdcount.sh`) or open a new terminal.

**The browser cannot reach the host.**

```bash
curl -s localhost:7777/healthz     # expect {"ok": true}
sudo firewall-cmd --list-ports     # firewalld: expect 7777/tcp
sudo ufw status                    # ufw: expect "7777/tcp ALLOW"
sudo ss -ltnp | grep 7777          # server listening?
```

If firewalld is off and SELinux is enforcing, check
`sudo ausearch -m avc -ts recent` for a denial naming the port.

**`POST /api/timer 404` in the browser console (stopwatch dead).**

The page is newer than the running server: `index.html` was copied over but
`server.py` was not (or the service was not restarted after copying it).
Copy `server.py` too, then restart — the count is preserved:

```bash
scp cmdcounter/server.py almalinux@192.168.0.32:~/cmdcounter/
# on the box:
sudo systemctl restart cmdcount
```

Rule of thumb: `index.html` needs no restart, everything else does.

**Commands counted twice.**

Each Enter should log exactly one `POST /api/hit 200` line (`tail -f
cmdcount.log` in nohup mode, `journalctl -u cmdcount -f` in service mode).
Two lines per Enter means two hook copies are loaded in that shell: a stale
copy under a different function name (e.g. a pre-1.1 `__cmd148_prompt`
leftover or old workaround lines in `~/.bashrc`) keeps its own baseline, so
every command posts once per copy. Check:

```bash
echo $__cmdcount_VERSION        # want 1.1; empty = stale pre-version hook
echo "$PROMPT_COMMAND"          # want exactly one __cmdcount_prompt
declare -f | grep -E "__cmd(148|count)_prompt"   # want only __cmdcount_prompt
grep -n "cmd148\|cmdcount\|cmdcnt" ~/.bashrc /etc/bashrc /etc/bash.bashrc
```

Hook 1.1 removes stale `__cmd148_*` copies and collapses duplicate
`PROMPT_COMMAND` entries on load, so deploying it fixes this going forward.
On the box: copy over the new `hook.sh`, reinstall it (`sudo cp hook.sh
/etc/profile.d/cmdcount.sh` or re-run `./start.sh` — count preserved),
delete any stale `__cmd148_*` / duplicate source lines the grep above finds
in rc files, then open a fresh terminal (or `. /etc/profile.d/cmdcount.sh`)
and confirm `echo $__cmdcount_VERSION` prints `1.1`.

**`set +o history` was run.**

Bash counting needs history enabled. Run `set -o history` to resume.

**Start everything from scratch.**

```bash
./start.sh --stop
rm -f state.json cmdcount.log cmdcount.pid
./start.sh
```

---

## Files

| File | What it is |
|---|---|
| `start.sh` | One-command installer / restarter / stopper |
| `server.py` | Counter server (stdlib only, `:7777`) |
| `index.html` | Dashboard (no internet needed) |
| `hook.sh` | Bash hook source (installed as `/etc/profile.d/cmdcount.sh`) |
| `state.json` | Saved `count` + `goal` + `title` + stopwatch state |
| `README.md` | Overview + quick start |
| `instruction.md` | This file |
| `technical_design.md` | How it works under the hood |

## Uninstall

```bash
./start.sh --stop
./start.sh --uninstall-service   # only if the systemd unit was installed
sudo rm -f /etc/profile.d/cmdcount.sh
sudo sed -i '/# >>> cmdcount >>>/,+2d' /etc/bashrc /etc/bash.bashrc ~/.bashrc
```

Then delete the folder. No packages or users were created, so nothing else
needs cleanup.
