# Setup

Full install, configuration, and uninstall for focus-guardian.

## Requirements

- macOS (tested on recent versions; depends on `launchd`, `dscacheutil`,
  `mDNSResponder`, `sudoers.d`, `newsyslog`).
- An admin account (installation needs `sudo`).
- No third-party dependencies — pure `bash` + standard macOS tools.

## Install

```sh
git clone https://github.com/1Hendrix/focus-guardian.git
cd focus-guardian
sudo bash install.sh
```

To install the user-level sentinel for a specific account (defaults to the
account invoking `sudo`):

```sh
sudo GUARDIAN_USER=yourusername bash install.sh
```

The installer:

1. **Sudoers** — writes `/etc/sudoers.d/guardian` (validated with `visudo`
   before install), scoped to the trigger script only, and sets it
   immutable.
2. **Scripts** — copies `guardian-focus-trigger.sh`, `guardian-sentinel.sh`,
   and the `focus-guardian` CLI to `/usr/local/bin/`.
3. **Blocklists + schedule** — copies `blocklists/*.list` to
   `/etc/guardian/blocklists/`, and installs `config/schedule.conf` to
   `/etc/guardian/schedule.conf` **only if one is not already there** (your
   customized schedule is never overwritten on re-install).
4. **LaunchDaemon** — installs and loads `com.guardian.focus-trigger`
   (re-evaluates the schedule every 15 min, at boot, and on wake/login).
5. **Sentinel LaunchAgent** — installs the user-level watchdog (runs at
   login and every 3 hours).

It is safe to re-run the installer; it is idempotent.

## Configure your schedule

```sh
focus-guardian edit        # opens /etc/guardian/schedule.conf in $EDITOR
```

Each line in `GUARDIAN_WINDOWS` is:

```
"START END DOW BLOCKLIST LABEL"
```

- `START` / `END` — 24h `HHMM` (e.g. `0900`, `1700`). Window is
  `[START, END)`. If `END <= START` the window wraps past midnight
  (e.g. `"2200 0600 ..."` blocks 22:00 → 06:00).
- `DOW` — ISO weekdays `1`=Mon … `7`=Sun. Accepts `*`, ranges (`1-5`),
  lists (`1,3,5`), or combinations (`1-5,7`).
- `BLOCKLIST` — name of a file in `/etc/guardian/blocklists/<name>.list`
  (without the extension).
- `LABEL` — free text shown in `status` and logs (may contain spaces).

First matching window wins. Outside all windows, nothing is blocked.

Example:

```sh
GUARDIAN_WINDOWS=(
  "0900 1200 1-5 deep-work Morning deep-work"
  "1400 1700 1-5 focus Afternoon focus"
)
```

Apply changes immediately:

```sh
focus-guardian run
```

### Editing blocklists

`/etc/guardian/blocklists/focus.list` and `deep-work.list` are
domain-per-line, `#` for comments. Add the sites that actually distract
you; subdomains/CDNs are listed so the block is hard to bypass. After
editing, `focus-guardian run` re-applies the active block.

### To-the-minute starts (optional)

The scheduler re-checks every 15 minutes when the Mac is idle (wake, login,
and boot are instant). If you need a block to start at an exact off-15
minute, add a `StartCalendarInterval` block to
`/Library/LaunchDaemons/com.guardian.focus-trigger.plist` and reload it:

```sh
sudo launchctl bootout system/com.guardian.focus-trigger
sudo launchctl bootstrap system /Library/LaunchDaemons/com.guardian.focus-trigger.plist
```

## Status & diagnostics

```sh
focus-guardian status      # active block, current window, health (no sudo)
```

Logs:

- `/var/log/guardian/focus-trigger.log` — scheduler activity
- `/var/log/guardian/sentinel.log` — watchdog activity

Rotated automatically by `newsyslog` (100 KB, 3 generations).

## Repair

If the daemon or sudoers entry goes missing (e.g. after a macOS upgrade),
the sentinel repairs it within a few hours automatically. To force it:

```sh
focus-guardian repair
```

## Uninstall

```sh
sudo launchctl bootout system/com.guardian.focus-trigger 2>/dev/null || \
  sudo launchctl unload /Library/LaunchDaemons/com.guardian.focus-trigger.plist 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.guardian.focus-trigger.plist
sudo rm -f /usr/local/bin/guardian-focus-trigger.sh \
           /usr/local/bin/guardian-sentinel.sh \
           /usr/local/bin/focus-guardian
launchctl unload ~/Library/LaunchAgents/com.guardian.sentinel.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.guardian.sentinel.plist

# Remove only the tool's own section from /etc/hosts (leaves the rest intact):
sudo sed -i '' \
  '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</d' \
  /etc/hosts
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

sudo rm -rf /etc/guardian /var/log/guardian
sudo chflags nouchg /etc/sudoers.d/guardian 2>/dev/null
sudo rm -f /etc/sudoers.d/guardian /etc/newsyslog.d/guardian.conf
```

The uninstall is also kept as a comment block at the top of `install.sh`.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Block never activates | `focus-guardian status` — is a window active now? Is the LaunchDaemon loaded? |
| Block won't clear | `sudo focus-guardian run` outside any window; check `/etc/hosts` for the GUARDIAN markers |
| Sites still reachable | Browser DNS cache — quit/reopen the browser; the tool flushes the OS cache but some browsers cache separately |
| Daemon gone after OS update | Wait for the sentinel (≤3h) or run `focus-guardian repair` |
| `sudo` still prompts | `/etc/sudoers.d/guardian` missing or invalid — `focus-guardian repair` recreates it |
