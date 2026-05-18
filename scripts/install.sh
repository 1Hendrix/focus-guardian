#!/bin/bash
# install.sh — One-shot installer for focus-guardian
# Run with: sudo bash install.sh
#
# Optional: set GUARDIAN_USER=<username> to install the user-level sentinel
# for a specific account (defaults to the sudo-invoking / logged-in user).
#
# WHAT THIS DOES (step by step):
#   Phase 1: Creates /etc/sudoers.d/guardian — lets the scheduler run
#            without a password prompt (needed for LaunchDaemon + sentinel).
#   Phase 2: Copies scripts to /usr/local/bin/, blocklists to
#            /etc/guardian/blocklists/, and a default schedule to
#            /etc/guardian/schedule.conf (only if one isn't already there).
#   Phase 3: Installs + loads the LaunchDaemon that fires the scheduler.
#   Phase 4: Installs the user-level sentinel LaunchAgent (bootstrap repair).
#   Phase 5: Prints verification status.
#
# The scheduler only ever adds/removes its own clearly-marked section in
# /etc/hosts (between GUARDIAN FOCUS BLOCK START/END). It never modifies
# the rest of the file, so no full /etc/hosts backup is needed.
#
# HOW TO UNDO (complete uninstall):
#   sudo launchctl bootout system/com.guardian.focus-trigger 2>/dev/null || \
#     sudo launchctl unload /Library/LaunchDaemons/com.guardian.focus-trigger.plist 2>/dev/null
#   sudo rm -f /Library/LaunchDaemons/com.guardian.focus-trigger.plist
#   sudo rm -f /usr/local/bin/guardian-focus-trigger.sh /usr/local/bin/guardian-sentinel.sh
#   launchctl unload ~/Library/LaunchAgents/com.guardian.sentinel.plist 2>/dev/null
#   rm -f ~/Library/LaunchAgents/com.guardian.sentinel.plist
#   # Remove the scheduler's section from /etc/hosts (leaves the rest intact):
#   sudo sed -i '' '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</d' /etc/hosts
#   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
#   sudo rm -rf /etc/guardian /var/log/guardian
#   sudo chflags nouchg /etc/sudoers.d/guardian 2>/dev/null; sudo rm -f /etc/sudoers.d/guardian
#   sudo rm -f /etc/newsyslog.d/guardian.conf
#
# EMERGENCY STOP (if something goes wrong mid-install):
#   Ctrl+C — the script uses set -e and stops on the first error.
#   Remove any partial block: sudo sed -i '' \
#     '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</d' /etc/hosts
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== focus-guardian installer ==="
echo "Source: $REPO_ROOT"
echo ""

# Determine the target (non-root) user the sentinel LaunchAgent installs for.
# Installer runs via sudo, so SUDO_USER is normally correct.
TARGET_USER="${GUARDIAN_USER:-${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || true)}}"
if [ -z "${TARGET_USER:-}" ] || [ "$TARGET_USER" = "root" ]; then
    echo "ERROR: could not determine the target (non-root) user."
    echo "       Re-run as:  sudo GUARDIAN_USER=<your-username> bash install.sh"
    exit 1
fi
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$TARGET_HOME" ] || TARGET_HOME="/Users/$TARGET_USER"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo "")"
echo "Target user: $TARGET_USER  (home: $TARGET_HOME)"
echo ""

# Synced/downloaded files can carry extended attributes (quarantine,
# provenance) that block launchd bootstrap. Strip them from every
# deployed file.
deploy_clean() {
    local src="$1" dst="$2"
    cp "$src" "$dst"
    xattr -c "$dst" 2>/dev/null || true
}

# ── Phase 1: Sudoers ───────────────────────────────────
echo "▸ Phase 1: Sudoers for the scheduler"
SUDOERS_FILE="/etc/sudoers.d/guardian"
SUDOERS_TMP="$(mktemp)"
{
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: /usr/local/bin/guardian-focus-trigger.sh"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: /usr/local/bin/guardian-focus-trigger.sh --repair"
} > "$SUDOERS_TMP"
chmod 0440 "$SUDOERS_TMP"
if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    chflags nouchg "$SUDOERS_FILE" 2>/dev/null || true
    mv "$SUDOERS_TMP" "$SUDOERS_FILE"
    chown root:wheel "$SUDOERS_FILE"
    # uchg = user-immutable; root can still override, but casual cleanup can't.
    chflags uchg "$SUDOERS_FILE" 2>/dev/null || true
    echo "  Installed and validated $SUDOERS_FILE (immutable flag set)"
else
    echo "  ERROR: sudoers syntax invalid"
    rm -f "$SUDOERS_TMP"
    exit 1
fi
echo ""

# ── Phase 2: Deploy Scripts + Blocklists + Schedule ─────
echo "▸ Phase 2: Deploy scripts, blocklists, schedule"

deploy_clean "$REPO_ROOT/scripts/guardian-focus-trigger.sh" /usr/local/bin/guardian-focus-trigger.sh
deploy_clean "$REPO_ROOT/scripts/guardian-sentinel.sh"      /usr/local/bin/guardian-sentinel.sh
deploy_clean "$REPO_ROOT/scripts/focus-guardian"            /usr/local/bin/focus-guardian
chmod +x /usr/local/bin/guardian-focus-trigger.sh /usr/local/bin/guardian-sentinel.sh /usr/local/bin/focus-guardian
echo "  Copied scripts + focus-guardian CLI to /usr/local/bin/"

mkdir -p /etc/guardian/blocklists
shopt -s nullglob
bl_count=0
for bl in "$REPO_ROOT"/blocklists/*.list; do
    deploy_clean "$bl" "/etc/guardian/blocklists/$(basename "$bl")"
    bl_count=$((bl_count + 1))
done
shopt -u nullglob
echo "  Copied $bl_count blocklist(s) to /etc/guardian/blocklists/"

# Schedule: install the default only if the user doesn't already have one
# (re-running the installer must never clobber a customized schedule).
if [ ! -f /etc/guardian/schedule.conf ]; then
    deploy_clean "$REPO_ROOT/config/schedule.conf" /etc/guardian/schedule.conf
    echo "  Installed default schedule → /etc/guardian/schedule.conf (edit to your rhythm)"
else
    echo "  Existing /etc/guardian/schedule.conf preserved (not overwritten)"
fi

mkdir -p /var/log/guardian
echo "  Created /var/log/guardian/"
echo ""

# ── Phase 3: LaunchDaemon ──────────────────────────────
echo "▸ Phase 3: Install LaunchDaemon"
PLIST_SRC="$REPO_ROOT/launchd/com.guardian.focus-trigger.plist"
PLIST_DST="/Library/LaunchDaemons/com.guardian.focus-trigger.plist"

if ! plutil -lint "$PLIST_SRC" >/dev/null 2>&1; then
    echo "  ERROR: LaunchDaemon plist syntax invalid, aborting"
    plutil -lint "$PLIST_SRC"
    exit 1
fi
echo "  Plist syntax: valid"

if launchctl list 2>/dev/null | grep -q "com.guardian.focus-trigger"; then
    launchctl bootout system/com.guardian.focus-trigger 2>/dev/null || \
        launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "  Unloaded previous version"
fi

deploy_clean "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

if launchctl bootstrap system "$PLIST_DST" 2>/dev/null; then
    echo "  Loaded com.guardian.focus-trigger (bootstrap)"
elif launchctl load "$PLIST_DST" 2>/dev/null; then
    echo "  Loaded com.guardian.focus-trigger (legacy load)"
else
    echo "  ERROR: Failed to load LaunchDaemon"
    exit 1
fi

NEWSYSLOG_CONF="/etc/newsyslog.d/guardian.conf"
cat > "$NEWSYSLOG_CONF" << 'LOGEOF'
# Guardian Focus System log rotation
# logfilename                              [owner:group] mode count size when  flags
/var/log/guardian/focus-trigger.log         root:wheel    644  3     100  *     J
/var/log/guardian/launchd-stdout.log        root:wheel    644  3     100  *     J
/var/log/guardian/launchd-stderr.log        root:wheel    644  3     100  *     J
/var/log/guardian/sentinel.log              root:wheel    644  3     100  *     J
/var/log/guardian/sentinel-stdout.log       root:wheel    644  3     100  *     J
/var/log/guardian/sentinel-stderr.log       root:wheel    644  3     100  *     J
LOGEOF
echo "  Installed log rotation config ($NEWSYSLOG_CONF)"
echo ""

# ── Phase 4: Sentinel LaunchAgent (bootstrap protection) ─
echo "▸ Phase 4: Install sentinel LaunchAgent for $TARGET_USER"
SENTINEL_PLIST_SRC="$REPO_ROOT/launchd/com.guardian.sentinel.plist"
SENTINEL_PLIST_DST="$TARGET_HOME/Library/LaunchAgents/com.guardian.sentinel.plist"

mkdir -p "$TARGET_HOME/Library/LaunchAgents"

if [ -n "$TARGET_UID" ] && sudo -u "$TARGET_USER" launchctl list 2>/dev/null | grep -q "com.guardian.sentinel"; then
    sudo -u "$TARGET_USER" launchctl bootout "gui/$TARGET_UID/com.guardian.sentinel" 2>/dev/null || \
        sudo -u "$TARGET_USER" launchctl unload "$SENTINEL_PLIST_DST" 2>/dev/null || true
    echo "  Unloaded previous sentinel"
fi

deploy_clean "$SENTINEL_PLIST_SRC" "$SENTINEL_PLIST_DST"
chown "$TARGET_USER":staff "$SENTINEL_PLIST_DST"
chmod 644 "$SENTINEL_PLIST_DST"
if [ -n "$TARGET_UID" ]; then
    sudo -u "$TARGET_USER" launchctl bootstrap "gui/$TARGET_UID" "$SENTINEL_PLIST_DST" 2>/dev/null || \
        sudo -u "$TARGET_USER" launchctl load "$SENTINEL_PLIST_DST" 2>/dev/null || true
fi
echo "  Loaded sentinel LaunchAgent"
echo ""

# ── Phase 5: Verification ──────────────────────────────
echo "▸ Phase 5: Verification"
echo -n "  LaunchDaemon loaded:  "
launchctl list 2>/dev/null | grep -q "com.guardian.focus-trigger" \
    && echo "YES" || echo "NO — check: sudo launchctl load $PLIST_DST"

echo -n "  Blocklists:           "
if compgen -G "/etc/guardian/blocklists/*.list" >/dev/null; then
    echo "OK ($(ls /etc/guardian/blocklists/*.list 2>/dev/null | wc -l | tr -d ' ') file(s))"
else
    echo "MISSING"
fi

echo -n "  Schedule:             "
[ -f /etc/guardian/schedule.conf ] && echo "OK (/etc/guardian/schedule.conf)" || echo "MISSING"

echo -n "  Sentinel LaunchAgent: "
if [ -n "$TARGET_UID" ] && sudo -u "$TARGET_USER" launchctl list 2>/dev/null | grep -q "com.guardian.sentinel"; then
    echo "loaded"
else
    echo "not loaded (will activate on next login)"
fi

echo -n "  Log directory:        "
[ -d /var/log/guardian ] && echo "OK" || echo "MISSING"
echo ""

echo "=== Installation complete ==="
echo ""
echo "WHAT HAPPENS NOW:"
echo "  • The LaunchDaemon fires the scheduler at each window start, plus an"
echo "    hourly backup and on wake."
echo "  • On each trigger it reads /etc/guardian/schedule.conf, and if the"
echo "    current time falls in a window it activates that blocklist via"
echo "    /etc/hosts (idempotent — re-triggering is a safe no-op)."
echo "  • The sentinel checks system health every few hours and self-repairs."
echo "  • The sudoers file is immutable-flagged so casual cleanup can't break it."
echo "  • Logs: /var/log/guardian/focus-trigger.log"
echo ""
echo "NEXT STEPS:"
echo "  1. Edit your schedule:   focus-guardian edit"
echo "  2. Apply it now:         focus-guardian run"
echo "  3. Check status:         focus-guardian status"
echo ""
echo "IF SOMETHING GOES WRONG:"
echo "  • Stop scheduler: sudo launchctl unload $PLIST_DST"
echo "  • Clear block:    sudo sed -i '' '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</d' /etc/hosts"
echo "  • Full uninstall: see the comment block at the top of this script"
