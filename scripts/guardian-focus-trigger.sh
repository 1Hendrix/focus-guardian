#!/bin/bash
# guardian-focus-trigger.sh — Focus block scheduler (hosts-based)
# Deployed to: /usr/local/bin/guardian-focus-trigger.sh
# Fired by a LaunchDaemon at block-start times + an hourly backup + on wake.
# Idempotent: safe to trigger any time, at any frequency.
#
# BLOCKING MECHANISM:
#   /etc/hosts blocking (reliable, works as root, no GUI needed).
#   Each blocked domain gets BOTH a 127.0.0.1 and a ::1 entry — without
#   the IPv6 (::1) entry, browsers reach the site over IPv6 and bypass
#   the block.
#
# SCHEDULE:
#   Fully configurable in /etc/guardian/schedule.conf (sourced at runtime).
#   No schedule is hardcoded here — edit that file to set your own focus
#   windows. See the comments in schedule.conf for the format.
#
# NOTE on set -e: functions that use return codes for flow control
# (e.g. hosts_block_active) MUST be called in a conditional context
# (if / || / &&) so set -e does not kill the script on an expected
# non-zero return.

set -euo pipefail

# ── Config ──────────────────────────────────────────────
LISTS="/etc/guardian/blocklists"
LOG="/var/log/guardian/focus-trigger.log"
LOCK="/var/log/guardian/.lock.d"
STATE="/etc/guardian/.last-healthy"
SCHEDULE_CONF="/etc/guardian/schedule.conf"

# Desktop/GUI user for user-facing notifications. Resolution order:
#   1. $GUARDIAN_USER (explicit override)
#   2. $SUDO_USER     (the user who invoked sudo, if any)
#   3. console owner  (the actual logged-in desktop user — this is the
#                      case when running from a LaunchDaemon, where there
#                      is no SUDO_USER)
GUARDIAN_RUN_USER="${GUARDIAN_USER:-${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo root)}}"

# ── Helpers ─────────────────────────────────────────────
log() {
    local level="$1" msg="$2"
    printf '%s  [%-5s]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG"
}

run_as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -n -u "$GUARDIAN_RUN_USER" "$@"
    else
        "$@"
    fi
}

# Atomic lock via mkdir (POSIX-atomic, no TOCTOU race).
acquire_lock() {
    if ! mkdir "$LOCK" 2>/dev/null; then
        if [ -d "$LOCK" ]; then
            local lock_mtime
            lock_mtime=$(stat -f %m "$LOCK" 2>/dev/null) || lock_mtime=0
            local now
            now=$(date +%s)
            local age=$(( now - lock_mtime ))
            if [ "$age" -gt 300 ]; then
                log WARN "stale lock (${age}s), removing"
                rm -rf "$LOCK"
                if ! mkdir "$LOCK" 2>/dev/null; then
                    exit 0
                fi
                trap 'rm -rf "$LOCK"' EXIT
                return
            else
                exit 0
            fi
        else
            exit 0
        fi
    fi
    trap 'rm -rf "$LOCK"' EXIT
}

# ── Sudoers Repair ────────────────────────────────────────
# Returns: 0=ok, 1=failed. CALLER MUST use: repair_sudoers || true
SUDOERS_CONTENT="${GUARDIAN_RUN_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/guardian-focus-trigger.sh
${GUARDIAN_RUN_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/guardian-focus-trigger.sh --repair"

repair_sudoers() {
    # Remove immutable flag if set (from installer hardening)
    chflags nouchg /etc/sudoers.d/guardian 2>/dev/null || true

    if [ -f /etc/sudoers.d/guardian ]; then
        return 0
    fi

    log HEAL "sudoers missing — recreating"
    local tmp
    tmp=$(mktemp) || return 1
    echo "$SUDOERS_CONTENT" > "$tmp"
    chmod 0440 "$tmp"

    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log ERROR "sudoers recreation failed validation"
        return 1
    fi

    mv "$tmp" /etc/sudoers.d/guardian
    chown root:wheel /etc/sudoers.d/guardian
    chflags uchg /etc/sudoers.d/guardian 2>/dev/null || true
    log HEAL "sudoers restored"
    return 0
}

# ── Schedule Logic ──────────────────────────────────────
# Match an ISO weekday ($1, 1=Mon..7=Sun) against a DOW spec ($2) like
# "*", "1-5", "1,3,5", or "1-5,7". Returns 0 on match.
dow_match() {
    local today="$1" spec="$2" part lo hi
    [ "$spec" = "*" ] && return 0
    local IFS=','
    local parts
    read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            lo=${part%-*}; hi=${part#*-}
            if [ "$today" -ge "$lo" ] && [ "$today" -le "$hi" ]; then
                return 0
            fi
        elif [ "$today" -eq "$part" ]; then
            return 0
        fi
    done
    return 1
}

# Read /etc/guardian/schedule.conf and echo "blocklist|label" for the
# first window matching the current time + weekday, or nothing if none.
get_block() {
    if [ ! -r "$SCHEDULE_CONF" ]; then
        log WARN "schedule.conf not readable at $SCHEDULE_CONF — no block"
        return
    fi

    local GUARDIAN_WINDOWS=()
    # shellcheck disable=SC1090
    source "$SCHEDULE_CONF"
    if [ "${#GUARDIAN_WINDOWS[@]}" -eq 0 ]; then
        return
    fi

    local now_str hhmm dow
    now_str=$(date '+%H%M %u')
    hhmm=$((10#${now_str%% *}))
    dow=${now_str##* }

    local w start end dows list name
    for w in "${GUARDIAN_WINDOWS[@]}"; do
        # Final field (name) absorbs all remaining words, so labels may
        # contain spaces.
        read -r start end dows list name <<< "$w"
        [ -n "$start" ] && [ -n "$end" ] && [ -n "$list" ] || continue
        start=$((10#$start))
        end=$((10#$end))

        dow_match "$dow" "$dows" || continue

        if [ "$start" -lt "$end" ]; then
            # Same-day window [start, end)
            if [ "$hhmm" -ge "$start" ] && [ "$hhmm" -lt "$end" ]; then
                echo "${list}|${name:-$list}"
                return
            fi
        else
            # Overnight wrap: [start, 2400) ∪ [0000, end)
            if [ "$hhmm" -ge "$start" ] || [ "$hhmm" -lt "$end" ]; then
                echo "${list}|${name:-$list}"
                return
            fi
        fi
    done
}

# ── Health Check (self-healing) ──────────────────────────
NEWSYSLOG_CONTENT='# Guardian Focus System log rotation
# logfilename                              [owner:group] mode count size when  flags
/var/log/guardian/focus-trigger.log         root:wheel    644  3     100  *     J
/var/log/guardian/launchd-stdout.log        root:wheel    644  3     100  *     J
/var/log/guardian/launchd-stderr.log        root:wheel    644  3     100  *     J
/var/log/guardian/sentinel.log              root:wheel    644  3     100  *     J
/var/log/guardian/sentinel-stdout.log       root:wheel    644  3     100  *     J
/var/log/guardian/sentinel-stderr.log       root:wheel    644  3     100  *     J'

health_check() {
    # 1. Blocklists non-empty
    for bl in $(active_blocklist_names); do
        if [ ! -s "$LISTS/$bl.list" ]; then
            log WARN "blocklist $bl is empty or missing — blocks may not work"
            run_as_user osascript -e \
                "display notification \"Blocklist $bl is missing. Re-run install-focus-system.sh\" with title \"Guardian\"" \
                2>/dev/null || true
        fi
    done

    # 2. Sudoers entry (non-fatal)
    repair_sudoers || log WARN "sudoers repair unsuccessful"

    # 3. Log rotation config
    if [ ! -f /etc/newsyslog.d/guardian.conf ]; then
        log HEAL "newsyslog config missing — recreating"
        echo "$NEWSYSLOG_CONTENT" > /etc/newsyslog.d/guardian.conf
    fi

    # Write state file — the sentinel watchdog checks this for freshness.
    date +%s > "$STATE" 2>/dev/null || true
}

# Distinct blocklist names referenced by the schedule (for health checks).
active_blocklist_names() {
    [ -r "$SCHEDULE_CONF" ] || return
    local GUARDIAN_WINDOWS=()
    # shellcheck disable=SC1090
    source "$SCHEDULE_CONF"
    local w _s _e _d list _n
    for w in "${GUARDIAN_WINDOWS[@]}"; do
        read -r _s _e _d list _n <<< "$w"
        [ -n "$list" ] && echo "$list"
    done | sort -u
}

# ── Hosts-Based Blocking ─────────────────────────────────
# Reliable blocking via /etc/hosts. Works as root, no GUI auth needed.
# Idempotent: safe to call every trigger. Adds/removes block markers.
HOSTS_FOCUS_START="# >>> GUARDIAN FOCUS BLOCK START <<<"
HOSTS_FOCUS_END="# >>> GUARDIAN FOCUS BLOCK END <<<"

# Returns 0 if focus block markers exist in /etc/hosts.
# CALLER MUST use in conditional context (if/||) under set -e.
hosts_block_active() {
    grep -qF "$HOSTS_FOCUS_START" /etc/hosts 2>/dev/null
}

# Returns the blocklist label from the active hosts block comment line.
hosts_block_name() {
    if hosts_block_active; then
        local comment_line
        comment_line=$(grep -A1 -F "$HOSTS_FOCUS_START" /etc/hosts 2>/dev/null | tail -1) || true
        echo "$comment_line" | sed 's/^# //; s/ — activated.*//'
    fi
}

activate_hosts_block() {
    local blocklist_file="$1" name="$2"

    if [ ! -s "$blocklist_file" ]; then
        log ERROR "cannot activate hosts block — blocklist missing: $blocklist_file"
        return 1
    fi

    # Already active for the same block? Idempotent no-op.
    if hosts_block_active; then
        local current_name
        current_name=$(hosts_block_name)
        if [ "$current_name" = "$name" ]; then
            log INFO "hosts block already active for $name"
            return 0
        fi
        log INFO "hosts block switching: '$current_name' → '$name'"
        deactivate_hosts_block || true
    fi

    # Build hosts entries: BOTH IPv4 AND IPv6 for each domain.
    # Filter empty lines and comments from the blocklist.
    local hosts_entries
    hosts_entries=$(grep -v '^[[:space:]]*$' "$blocklist_file" | grep -v '^#' | \
        awk '{print "127.0.0.1 " $1 "\n::1 " $1}')

    if [ -z "$hosts_entries" ]; then
        log ERROR "blocklist $blocklist_file produced no valid entries"
        return 1
    fi

    local domain_count
    domain_count=$(echo "$hosts_entries" | wc -l | tr -d ' ')

    {
        echo ""
        echo "$HOSTS_FOCUS_START"
        echo "# $name — activated $(date '+%Y-%m-%d %H:%M')"
        echo "$hosts_entries"
        echo "$HOSTS_FOCUS_END"
    } >> /etc/hosts

    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true

    log OK "hosts block activated for $name ($domain_count domains)"
}

deactivate_hosts_block() {
    if ! hosts_block_active; then
        return 0
    fi

    local tmp
    tmp=$(mktemp) || return 1

    # Delete from start marker through end marker (inclusive). The markers
    # contain only "# > < SPACE UPPERCASE" — none are BRE-special, so the
    # literal strings are used directly in sed.
    sed '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</d' \
        /etc/hosts > "$tmp"

    if [ -s "$tmp" ]; then
        # Preserve /etc/hosts ownership/permissions by writing back, not mv.
        cat "$tmp" > /etc/hosts
        rm -f "$tmp"
    else
        log ERROR "deactivate_hosts_block: sed produced empty output, aborting"
        rm -f "$tmp"
        return 1
    fi

    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true

    log OK "hosts block deactivated"
}

# ── Status Mode ──────────────────────────────────────────
status() {
    printf '=== Guardian Focus System ===\n'
    printf 'Time: %s\n\n' "$(date '+%Y-%m-%d %H:%M %Z')"

    printf '  Hosts block:   '
    if hosts_block_active; then
        local hb_count hb_name
        hb_count=$(sed -n '/# >>> GUARDIAN FOCUS BLOCK START <<</,/# >>> GUARDIAN FOCUS BLOCK END <<</p' \
            /etc/hosts 2>/dev/null | grep -c "^127\.0\.0\.1") || hb_count=0
        hb_name=$(hosts_block_name)
        printf 'ACTIVE — %s (%s domains)\n' "${hb_name:-unknown}" "$hb_count"
    else
        printf 'inactive\n'
    fi

    printf '  Schedule:      '
    local block
    block=$(get_block)
    if [ -z "$block" ]; then
        printf 'no window active\n'
    else
        local b_list b_name
        IFS='|' read -r b_list b_name <<< "$block"
        printf '%s (%s)\n' "$b_name" "$b_list"
    fi

    printf '  State file:    '
    if [ -f "$STATE" ]; then
        local age=$(( $(date +%s) - $(cat "$STATE") ))
        printf 'age %ds\n' "$age"
    else
        printf 'MISSING\n'
    fi

    printf '  LaunchDaemon:  '
    if launchctl list 2>/dev/null | grep -q "com.guardian.focus-trigger"; then
        printf 'loaded\n'
    else
        printf 'not loaded\n'
    fi

    printf '  Sudoers:       '
    if [ -f /etc/sudoers.d/guardian ]; then
        printf 'present\n'
    else
        printf 'MISSING\n'
    fi

    printf '  Blocklists:    '
    local missing=0 bl
    for bl in $(active_blocklist_names); do
        [ -s "$LISTS/$bl.list" ] || missing=1
    done
    if [ "$missing" -eq 0 ]; then
        printf 'OK\n'
    else
        printf 'MISSING\n'
    fi

    printf '\n--- Last 5 log entries ---\n'
    tail -5 "$LOG" 2>/dev/null || printf 'No log file yet\n'
}

# ── Main ────────────────────────────────────────────────
main() {
    mkdir -p /var/log/guardian

    acquire_lock
    health_check

    local block
    block=$(get_block)

    if [ -z "$block" ]; then
        log INFO "outside all scheduled windows — no block needed"
        deactivate_hosts_block || log WARN "failed to deactivate hosts block"
        exit 0
    fi

    local list name
    IFS='|' read -r list name <<< "$block"
    local blocklist_file="$LISTS/$list.list"
    log INFO "trigger: $name ($list)"

    activate_hosts_block "$blocklist_file" "$name" || true
}

# ── Repair Mode ─────────────────────────────────────────
repair() {
    mkdir -p /var/log/guardian
    health_check

    local plist_dst="/Library/LaunchDaemons/com.guardian.focus-trigger.plist"
    if [ -f "$plist_dst" ]; then
        if ! launchctl list 2>/dev/null | grep -q "com.guardian.focus-trigger"; then
            launchctl bootstrap system "$plist_dst" 2>/dev/null || \
                launchctl load "$plist_dst" 2>/dev/null || true
            log HEAL "reloaded LaunchDaemon"
        fi
    else
        log WARN "LaunchDaemon plist missing at $plist_dst — re-run install-focus-system.sh"
    fi
}

# ── Entry Point ─────────────────────────────────────────
case "${1:-}" in
    --repair) repair ;;
    --status) status ;;
    *)        main "$@" ;;
esac
