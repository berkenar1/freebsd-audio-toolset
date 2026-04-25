#!/bin/sh
# configure-devfs-audio.sh — Check and fix devfs audio device isolation
# Ensures /etc/devfs.rules hides raw hardware audio devices and only
# exposes virtual_oss nodes, then activates the ruleset in rc.conf.
#
# Usage:
#   ./configure-devfs-audio.sh             — Check and prompt to fix
#   ./configure-devfs-audio.sh --auto      — Apply all fixes without prompting
#   ./configure-devfs-audio.sh --dry-run   — Check only, no changes
#   ./configure-devfs-audio.sh --help      — Show help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

DEVFS_RULES="/etc/devfs.rules"
RULESET_NAME="audio"
RULESET_NUM="6"
MODE="interactive"

case "${1:-}" in
    --auto)    MODE="auto" ;;
    --dry-run) MODE="dryrun" ;;
    --help|-h)
        cat <<EOF
configure-devfs-audio.sh — devfs audio device isolation

Checks and configures /etc/devfs.rules so that raw hardware audio
devices are hidden from applications, preventing them from bypassing
virtual_oss.

Checks:
  • /etc/devfs.rules exists and has an [audio=N] ruleset
  • Ruleset includes hide-all + unhide for virtual devices
  • devfs_system_ruleset is activated in /etc/rc.conf

Options:
  --auto      Apply all fixes without prompting
  --dry-run   Check only, report issues, make no changes
  --help      Show this help

Run as root to apply changes.
EOF
        exit 0
        ;;
esac

# ── The expected ruleset ────────────────────────────────────────────────────
EXPECTED_BLOCK="[${RULESET_NAME}=${RULESET_NUM}]
add include \$devfsrules_hide_all
add include \$devfsrules_unhide_basic
add include \$devfsrules_unhide_login
add path 'dsp*' unhide mode 0666
add path 'vdsp*' unhide mode 0666
add path '*midi*' unhide mode 0666
add path 'mixer*' unhide mode 0666
add path 'sndstat' unhide mode 0666"

# ── Prompt helper ───────────────────────────────────────────────────────────
ask_yes() {
    if [ "$MODE" = "auto" ]; then
        return 0
    fi
    if [ "$MODE" = "dryrun" ]; then
        return 1
    fi
    printf "  %s [y/N] " "$1"
    read -r _ans
    case "$_ans" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# ── Checks ──────────────────────────────────────────────────────────────────
ISSUES=0

section "devfs.rules — Audio Device Isolation"

# 1. File exists?
if [ ! -f "$DEVFS_RULES" ]; then
    fail "${DEVFS_RULES} does not exist"
    ISSUES=$((ISSUES + 1))

    if ask_yes "Create ${DEVFS_RULES} with audio ruleset?"; then
        printf "%s\n" "$EXPECTED_BLOCK" > "$DEVFS_RULES"
        ok "Created ${DEVFS_RULES}"
    fi
else
    ok "${DEVFS_RULES} exists"

    # 2. Audio ruleset present?
    if grep -q "^\[${RULESET_NAME}=" "$DEVFS_RULES" 2>/dev/null; then
        _num=$(grep -oE "^\[${RULESET_NAME}=[0-9]+" "$DEVFS_RULES" | head -1 | grep -oE '[0-9]+')
        ok "Ruleset [${RULESET_NAME}=${_num}] found"

        # 3. Check individual rules
        _missing=""

        if grep -q 'devfsrules_hide_all' "$DEVFS_RULES"; then
            ok "  hide_all base included"
        else
            fail "  hide_all base missing"
            _missing="${_missing} hide_all"
            ISSUES=$((ISSUES + 1))
        fi

        if grep -q 'devfsrules_unhide_basic' "$DEVFS_RULES"; then
            ok "  unhide_basic included"
        else
            fail "  unhide_basic missing"
            _missing="${_missing} unhide_basic"
            ISSUES=$((ISSUES + 1))
        fi

        if grep -q 'devfsrules_unhide_login' "$DEVFS_RULES"; then
            ok "  unhide_login included"
        else
            fail "  unhide_login missing"
            _missing="${_missing} unhide_login"
            ISSUES=$((ISSUES + 1))
        fi

        for _pat in "dsp" "mixer" "sndstat"; do
            if grep -q "path.*${_pat}.*unhide" "$DEVFS_RULES"; then
                ok "  ${_pat}* unhide rule present"
            else
                fail "  ${_pat}* unhide rule missing"
                _missing="${_missing} ${_pat}"
                ISSUES=$((ISSUES + 1))
            fi
        done

        if [ -n "$_missing" ]; then
            warn "Ruleset is incomplete (missing:${_missing})"
            if ask_yes "Replace entire audio ruleset with correct version?"; then
                # Find and replace the ruleset block
                _start=$(grep -n "^\[${RULESET_NAME}=" "$DEVFS_RULES" | head -1 | cut -d: -f1)
                _total=$(wc -l < "$DEVFS_RULES" | tr -d ' ')
                _end="$_total"

                # Find end: next [ruleset] or EOF
                _ln=0
                while IFS= read -r _line; do
                    _ln=$((_ln + 1))
                    if [ "$_ln" -gt "$_start" ]; then
                        case "$_line" in
                            \[*) _end=$((_ln - 1)); break ;;
                        esac
                    fi
                done < "$DEVFS_RULES"

                _tmpf=$(mktemp)
                [ "$_start" -gt 1 ] && head -n $((_start - 1)) "$DEVFS_RULES" > "$_tmpf" || : > "$_tmpf"
                printf "%s\n" "$EXPECTED_BLOCK" >> "$_tmpf"
                [ "$_end" -lt "$_total" ] && tail -n $((_total - _end)) "$DEVFS_RULES" >> "$_tmpf"
                mv "$_tmpf" "$DEVFS_RULES"
                ok "Ruleset replaced"
            fi
        fi
    else
        fail "No [${RULESET_NAME}=N] ruleset found"
        ISSUES=$((ISSUES + 1))

        if ask_yes "Append audio ruleset to ${DEVFS_RULES}?"; then
            printf "\n%s\n" "$EXPECTED_BLOCK" >> "$DEVFS_RULES"
            ok "Ruleset appended"
        fi
    fi
fi

# 4. rc.conf activation
section "rc.conf — Ruleset Activation"

_rc_val=$(sysrc -n devfs_system_ruleset 2>/dev/null || echo "")
if [ "$_rc_val" = "$RULESET_NAME" ]; then
    ok "devfs_system_ruleset=\"${RULESET_NAME}\""
elif [ -n "$_rc_val" ]; then
    warn "devfs_system_ruleset=\"${_rc_val}\" (expected \"${RULESET_NAME}\")"
    ISSUES=$((ISSUES + 1))
    if ask_yes "Update to \"${RULESET_NAME}\"?"; then
        sysrc devfs_system_ruleset="${RULESET_NAME}" >/dev/null 2>&1
        ok "Updated"
    fi
else
    fail "devfs_system_ruleset not set"
    ISSUES=$((ISSUES + 1))
    if ask_yes "Set devfs_system_ruleset=\"${RULESET_NAME}\"?"; then
        sysrc devfs_system_ruleset="${RULESET_NAME}" >/dev/null 2>&1
        ok "Set in rc.conf"
    fi
fi

# 5. Apply live?
if [ "$MODE" != "dryrun" ] && [ "$ISSUES" -gt 0 ]; then
    section "Apply"
    if ask_yes "Restart devfs service to apply changes now?"; then
        service devfs restart >/dev/null 2>&1 && ok "devfs restarted" || fail "devfs restart failed"
    fi
fi

# Summary
printf "\n"
if [ "$ISSUES" -eq 0 ]; then
    ok "All checks passed — devfs audio isolation is configured."
else
    info "${ISSUES} issue(s) found."
    [ "$MODE" = "dryrun" ] && info "Run without --dry-run to fix."
fi
