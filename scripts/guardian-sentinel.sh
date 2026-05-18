#!/bin/bash
# guardian-sentinel.sh — Bootstrap protection for the Guardian Focus System
# Deployed to: /usr/local/bin/guardian-sentinel.sh
# Triggered by: LaunchAgent (user-level) at login + every 3 hours
#
# Solves the bootstrap paradox: if a macOS upgrade deletes the system
# LaunchDaemon, this user-level sentinel detects it and triggers repair.
# After repair, also fires the scheduler so the current block starts immediately.
# All repair logic lives in guardian-focus-trigger.sh --repair (runs as root).

TRIGGER="/usr/local/bin/guardian-focus-trigger.sh"
STATE="/etc/guardian/.last-healthy"
LOG="/var/log/guardian/sentinel.log"

log() {
    local level="$1" msg="$2"
    printf '%s  [%-5s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG" 2>/dev/null
}
notify() { osascript -e "display notification \"$1\" with title \"Guardian Sentinel\"" 2>/dev/null || true; }

mkdir -p /var/log/guardian 2>/dev/null || true

# 1. Check state file freshness (written by health_check on every scheduler run)
needs_repair=false
if [ -f "$STATE" ]; then
    state_age=$(( $(date +%s) - $(cat "$STATE" 2>/dev/null || echo 0) ))
    if [ "$state_age" -gt 7200 ]; then
        log WARN "state file stale (${state_age}s) — daemon may not be running"
        needs_repair=true
    fi
else
    log WARN "no state file — daemon may never have run"
    needs_repair=true
fi

# 2. Check if LaunchDaemon plist exists (user-level launchctl can't see system daemons)
if [ ! -f /Library/LaunchDaemons/com.guardian.focus-trigger.plist ]; then
    log ALERT "LaunchDaemon plist missing"
    needs_repair=true
fi

# 3. Check if sudoers exists (common failure mode)
if [ ! -f /etc/sudoers.d/guardian ]; then
    log ALERT "sudoers file missing"
    needs_repair=true
fi

# 4. If repair needed, run diagnostics then repair
if [ "$needs_repair" = true ]; then
    # Diagnostics — record what's broken and why
    log DIAG "sudoers: $([ -f /etc/sudoers.d/guardian ] && echo 'present' || echo 'MISSING')"
    log DIAG "plist: $([ -f /Library/LaunchDaemons/com.guardian.focus-trigger.plist ] && echo 'present' || echo 'MISSING')"
    log DIAG "trigger: $([ -x "$TRIGGER" ] && echo 'present' || echo 'MISSING')"
    log DIAG "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown') build $(sw_vers -buildVersion 2>/dev/null || echo 'unknown')"

    # Check for recent reboot (possible macOS update)
    last_boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/') || true
    if [ -n "${last_boot:-}" ]; then
        boot_age=$(( $(date +%s) - last_boot ))
        log DIAG "last boot: ${boot_age}s ago"
        if [ "$boot_age" -lt 3600 ]; then
            log DIAG "recent reboot detected — possible macOS update"
        fi
    fi

    # Attempt repair
    if [ -x "$TRIGGER" ]; then
        log REPAIR "invoking $TRIGGER --repair via sudo"
        if sudo -n "$TRIGGER" --repair 2>>"$LOG"; then
            log REPAIR "completed successfully"
            notify "Focus system restored automatically"

            # Post-repair: fire the scheduler to start the current block immediately
            log REPAIR "triggering scheduler to start current block"
            if sudo -n "$TRIGGER" 2>>"$LOG"; then
                log REPAIR "scheduler ran — block should be active"
            else
                log WARN "post-repair scheduler trigger failed"
            fi
        else
            log ERROR "repair failed (sudo may need password)"
            notify "Focus system needs repair — run: sudo bash install.sh"
        fi
    else
        log ERROR "trigger script missing at $TRIGGER"
        notify "Focus system missing — run: sudo bash install.sh"
    fi
else
    log OK "system healthy"
fi
