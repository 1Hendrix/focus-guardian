# focus-guardian

A hosts-based focus enforcer for macOS. It blocks distracting sites on a
schedule you define, and it is built to be hard to disable in a weak moment.

## Why this exists

SelfControl is the usual macOS answer to this problem. Its command-line
interface broke on macOS 26.4, which made it unusable for an automated
schedule. Instead of waiting for a fix, I rebuilt the enforcement on
`/etc/hosts`: it works at the root level, needs no GUI, and cannot be
clicked away.

The interesting part was not the blocking — it was making the blocking
survive everything that normally defeats a focus tool:

- **Survives reboot.** A LaunchDaemon re-applies the current block at boot,
  on wake, on login, and every 15 minutes.
- **No password prompts.** A single `sudoers` entry, scoped to exactly one
  script, lets the schedule run unattended without weakening anything else.
- **Survives a macOS upgrade.** Upgrades silently delete system
  LaunchDaemons. A user-level sentinel detects the missing daemon and
  repairs it — solving the bootstrap paradox where the thing that restores
  the daemon was itself removed by the daemon's removal.
- **Survives the weak moment.** The `sudoers` file carries the immutable
  flag, so the casual "let me just disable this for a minute" does not work
  without slow, deliberate, friction-heavy effort.

Each of those was a failure mode found in use, then closed.

## What it does

- Reads a schedule from `/etc/guardian/schedule.conf` (windows you define:
  time range, weekdays, which blocklist).
- When the current time falls in a window, writes the matching blocklist
  into `/etc/hosts` — both an IPv4 (`127.0.0.1`) and an IPv6 (`::1`) entry
  per domain, so browsers cannot slip past the block over IPv6.
- Outside all windows, removes its block and leaves `/etc/hosts` exactly as
  it was. It only ever touches its own clearly-marked section.
- Idempotent: re-running at any time, any frequency, is a safe no-op.

Two example blocklists ship with it — `focus` (social + entertainment) and
`deep-work` (also news). They are starting points; edit them to match the
things that actually pull your attention.

## Quickstart

```sh
git clone https://github.com/1Hendrix/focus-guardian.git
cd focus-guardian
sudo bash install.sh

focus-guardian edit      # set your schedule
focus-guardian run       # apply it now
focus-guardian status    # see what's active
```

`status` runs without `sudo`. `run` and `repair` self-elevate.

## How it works

| Piece | Role |
|-------|------|
| `guardian-focus-trigger.sh` | The scheduler. Reads `schedule.conf`, applies/clears the `/etc/hosts` block. |
| `guardian-sentinel.sh` | User-level watchdog. Detects a missing daemon/sudoers (e.g. after an OS upgrade) and self-repairs. |
| `focus-guardian` | The CLI: `status` / `run` / `repair` / `edit`. |
| `schedule.conf` | Your windows. Pure config — no schedule is hardcoded anywhere. |
| `blocklists/*.list` | Domain-per-line lists. The schedule names which one applies when. |

Full install, configuration, and uninstall instructions are in
[SETUP.md](SETUP.md).

## The privilege model (read this)

This tool is effective because it is privileged. Be deliberate about that:

- It installs a system LaunchDaemon and a `sudoers.d` entry that allows one
  specific script (`/usr/local/bin/guardian-focus-trigger.sh`) to run as
  root without a password. Nothing else is granted.
- That `sudoers` file is set immutable (`chflags uchg`). Root can still
  remove it; casual cleanup cannot. This is intentional — a focus tool you
  can disable on impulse does not work.
- Uninstall is fully documented (top of `install.sh` and in SETUP.md) and
  removes everything, including clearing the immutable flag.

If you are not comfortable with a root LaunchDaemon and a scoped passwordless
`sudoers` entry on your own machine, this tool is not for you, and that is a
reasonable position.

## Limitations

- **macOS only.** It depends on `launchd`, `dscacheutil`, and
  `/etc/hosts` semantics. No Linux/Windows port.
- **Requires admin.** Installation and operation need root.
- **Schedule granularity.** When the Mac is on and idle across a window
  boundary, the block starts within ~15 minutes (wake/login/boot are
  instant). To-the-minute starts can be added via a `StartCalendarInterval`
  in the LaunchDaemon — see SETUP.md.
- **Not a parental-control product.** A determined user with admin rights
  can remove it. It is built to defeat *impulse*, not a motivated attacker.

## License

MIT — see [LICENSE](LICENSE).
