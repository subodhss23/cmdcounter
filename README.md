# cmdcounter

Lightweight command counter for Linux.
Counts every command you type in bash, shows progress to a goal on a web page.

```
10 / 1000 commands   1.0% complete   990 left
```

Stdlib Python only. Port `7777`. One server, bash hook.

Dashboard: 128 motivational quotes and 20 dark chase colors rotating every
33 commands (with a ding), Seed → Mythic rank ladder, sets-of-33 journey
map, dark/light themes.

## Install (on the Linux box)

```bash
cd cmdcounter
chmod +x start.sh
./start.sh
```

`start.sh` does everything:
1. checks `python3` (installs it with the native package manager —
   `dnf`/`yum`, `apt-get`, `pacman`, `apk`, or `zypper` — if missing)
2. starts `server.py` on `0.0.0.0:7777` (nohup, pid/log files)
3. installs bash hook to `/etc/profile.d/cmdcount.sh`
4. sources it from the system bashrc (`/etc/bashrc` or `/etc/bash.bashrc`) + `~/.bashrc`
5. opens `7777/tcp` in firewalld (or ufw)
6. prints the URL

Then open a **new** terminal and type commands. View from any machine:

```
http://192.168.0.32:7777
http://localhost:7777   (on the box itself)
```

## Use

- **Goal**: gear popup → type a number → Save (or `GOAL=2000 ./start.sh`)
- **Reset**: Reset button in UI
- **Stopwatch**: `start` / `pause` / `reset` in the thin row at the bottom.
  Whole minutes only, no seconds, no animation — it is meant to sit at the
  edge of vision. Persisted, survives restarts, independent of the counter.
- **Stop**: `./start.sh --stop`
- **Server only, no hook**: `./start.sh --no-hook`
- **Other port**: `PORT=8080 ./start.sh`

State lives in `state.json` (see Persistence below).

## Run at boot (systemd)

```bash
./start.sh --install-service
systemctl status cmdcount
```

This writes `/etc/systemd/system/cmdcount.service` (running as your user,
not root), enables it for boot, and starts it now. The counter survives
reboots and crashes (`Restart=always`). Service logs go to the journal
(`journalctl -u cmdcount -f`); in nohup mode they go to `cmdcount.log`.

```bash
./start.sh --uninstall-service   # back to nohup mode, count untouched
```

## Updating

Re-copying the whole folder overwrites `state.json` on the box with your
local copy (usually count 0) — back it up first, or copy only changed files:

```bash
scp cmdcounter/hook.sh almalinux@192.168.0.32:~/cmdcounter/
```

Then on the box: `sudo cp hook.sh /etc/profile.d/cmdcount.sh` (or re-run
`./start.sh` / `./start.sh --install-service` — count preserved either way),
and re-source running shells (`. /etc/profile.d/cmdcount.sh`) or open new
terminals. `start.sh` warns you when the installed hook actually changed.
Check what a shell loaded with `echo $__cmdcount_VERSION` (expect `1.0`).

## Persistence

The count lives in `state.json`. Reboots, `systemctl restart`, and re-runs of
`start.sh` never reset it — the number only goes back to 0 when you hit
**Reset** in the dashboard, or when you delete `state.json` to start a new
project.

## How counting works

Bash `PROMPT_COMMAND` hook diffs `history 1` after each command.
Each new command is POSTed to `/api/hit` in background (curl → python3 fallback),
disowned so there are no `[1]+ Done` job notices, and the prompt never blocks.
`exit`/`logout` and the hook's own traffic are skipped.

Tuning (put above the source line in `~/.bashrc`):

```bash
export CMDCNT_IGNORE='^(vim|less|top)$'  # regex to skip
export CMDCNT_ENABLED=0                  # disable for one shell
export CMDCNT_URL=http://10.0.0.5:7777   # different server
```

## API

- `GET /` → dashboard
- `GET /api/state` → `{count, goal, percent, remaining, timer, ...}`
- `POST /api/hit` → `n=1`
- `POST /api/goal` → `{"goal": 1000}`
- `POST /api/title` → `{"title": "My challenge"}` (dashboard heading, max 80 chars)
- `POST /api/timer` → `{"action": "start" | "pause" | "reset"}`
- `POST /api/reset`
- `GET /healthz`

## Uninstall

```bash
./start.sh --stop
./start.sh --uninstall-service   # only if the systemd unit was installed
sudo rm -f /etc/profile.d/cmdcount.sh
sudo sed -i '/# >>> cmdcount >>>/,+2d' /etc/bashrc /etc/bash.bashrc ~/.bashrc
```
