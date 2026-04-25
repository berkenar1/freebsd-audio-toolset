#!/bin/sh
# configure-suspend-audio.sh — TUI for checking/fixing virtual_oss suspend safety
# Ensures /etc/rc.suspend mutes and /etc/rc.resume restores audio output,
# so virtual_oss doesn't hold a dead USB/HDA handle across sleep cycles.
#
# Usage:
#   ./configure-suspend-audio.sh           — Launch TUI
#   ./configure-suspend-audio.sh --help    — Show help

set -u

BACKTITLE="Suspend Audio Safety — FreeBSD $(uname -r)"
RC_SUSPEND="/etc/rc.suspend"
RC_RESUME="/etc/rc.resume"

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v bsddialog >/dev/null 2>&1; then
    printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
    exit 1
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
configure-suspend-audio.sh — Suspend/resume audio safety

Checks and configures /etc/rc.suspend and /etc/rc.resume so that
virtual_oss releases the audio device before suspend and reclaims
it on resume.

What it checks:
  • /etc/rc.suspend has: virtual_oss_cmd <ctl> -f /dev/null
  • /etc/rc.resume  has: virtual_oss_cmd <ctl> -f /dev/dspX

What it can fix:
  • Create missing rc.suspend / rc.resume files
  • Add the virtual_oss_cmd lines if absent
  • Update the control socket or resume device
  • Preview changes before writing

Requires: bsddialog. Run as root to apply changes.
EOF
    exit 0
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

# Detect control socket from running virtual_oss or rc.conf
detect_ctl_socket() {
    # Try running process first
    _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_pid" ]; then
        for _p in $_pid; do
            _args=$(ps -ww -p "$_p" -o args= 2>/dev/null || true)
            _ctl=$(echo "$_args" | grep -oE '\-t [^ ]+' | awk '{print $2}' | head -1)
            if [ -n "$_ctl" ]; then
                case "$_ctl" in
                    /dev/*) echo "$_ctl" ;;
                    *)      echo "/dev/${_ctl}" ;;
                esac
                return
            fi
        done
    fi

    # Fall back to rc.conf
    _configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "")
    for _c in $_configs; do
        _val=$(sysrc -n "virtual_oss_${_c}" 2>/dev/null || true)
        _ctl=$(echo "$_val" | grep -oE '\-t [^ ]+' | awk '{print $2}' | head -1)
        if [ -n "$_ctl" ]; then
            case "$_ctl" in
                /dev/*) echo "$_ctl" ;;
                *)      echo "/dev/${_ctl}" ;;
            esac
            return
        fi
    done

    echo ""
}

# Detect current backend from running virtual_oss
detect_current_backend() {
    _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_pid" ]; then
        for _p in $_pid; do
            _args=$(ps -ww -p "$_p" -o args= 2>/dev/null || true)
            _back=$(echo "$_args" | grep -oE '\-f [^ ]+' | awk '{print $2}' | head -1)
            [ -z "$_back" ] && _back=$(echo "$_args" | grep -oE '\-P [^ ]+' | awk '{print $2}' | head -1)
            if [ -n "$_back" ]; then
                echo "$_back"
                return
            fi
        done
    fi
    echo ""
}

# Check if a file contains a virtual_oss_cmd line
check_voss_line() {
    _file=$1
    if [ ! -f "$_file" ]; then
        echo "missing"
        return
    fi
    if grep -q 'virtual_oss_cmd' "$_file" 2>/dev/null; then
        # Extract the line
        grep 'virtual_oss_cmd' "$_file" | head -1
    else
        echo "absent"
    fi
}

# Extract the device from a virtual_oss_cmd line
extract_device_from_line() {
    echo "$1" | grep -oE '\-f [^ ]+' | awk '{print $2}' | head -1
}

# Extract the control socket from a virtual_oss_cmd line
extract_ctl_from_line() {
    echo "$1" | awk '{print $2}' | head -1
}

# ── Status display ──────────────────────────────────────────────────────────
show_status() {
    _ctl=$1
    _suspend_line=$2
    _resume_line=$3

    # Suspend status
    if [ "$_suspend_line" = "missing" ]; then
        _s_status="✗ ${RC_SUSPEND} does not exist"
        _s_ok=0
    elif [ "$_suspend_line" = "absent" ]; then
        _s_status="✗ ${RC_SUSPEND} exists but has no virtual_oss_cmd line"
        _s_ok=0
    else
        _s_dev=$(extract_device_from_line "$_suspend_line")
        if [ "$_s_dev" = "/dev/null" ]; then
            _s_status="✓ Suspend mutes to /dev/null"
            _s_ok=1
        else
            _s_status="⚠ Suspend switches to ${_s_dev} (should be /dev/null)"
            _s_ok=0
        fi
    fi

    # Resume status
    if [ "$_resume_line" = "missing" ]; then
        _r_status="✗ ${RC_RESUME} does not exist"
        _r_ok=0
    elif [ "$_resume_line" = "absent" ]; then
        _r_status="✗ ${RC_RESUME} exists but has no virtual_oss_cmd line"
        _r_ok=0
    else
        _r_dev=$(extract_device_from_line "$_resume_line")
        if [ -n "$_r_dev" ] && [ "$_r_dev" != "/dev/null" ]; then
            _r_status="✓ Resume restores to ${_r_dev}"
            _r_ok=1
        else
            _r_status="⚠ Resume device looks wrong: ${_r_dev:-empty}"
            _r_ok=0
        fi
    fi

    echo "${_s_status}|${_r_status}|${_s_ok}|${_r_ok}"
}

# ── Select resume device ────────────────────────────────────────────────────
select_resume_device() {
    _default=$1

    _items=""
    _units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)

    for _u in $_units; do
        _desc=$(sysctl -n "dev.pcm.${_u}.%desc" 2>/dev/null || echo "(unknown)")
        _mode=$(sysctl -n "dev.pcm.${_u}.mode" 2>/dev/null || echo "0")
        _caps=""
        case "$_mode" in
            7|6) _caps="play/rec" ;;
            3|2) _caps="play"     ;;
            4)   _caps="rec"      ;;
            *)   _caps="mode=${_mode}" ;;
        esac
        _items="${_items} /dev/dsp${_u} \"[${_caps}] ${_desc}\""
    done

    eval bsddialog \
        --backtitle "\"${BACKTITLE}\"" \
        --title "\"Resume Device\"" \
        --default-item "\"${_default}\"" \
        --menu "\"Select device to restore on resume:\"" 18 72 10 \
        ${_items} \
        3>&1 1>&2 2>&3
}

# ── Main menu ──────────────────────────────────────────────────────────────
main_menu() {
    _ctl=$(detect_ctl_socket)
    if [ -z "$_ctl" ]; then
        _ctl="/dev/dsp.ctl"
    fi

    _resume_dev=$(detect_current_backend)
    [ -z "$_resume_dev" ] && _resume_dev="/dev/dsp0"

    while true; do
        _suspend_line=$(check_voss_line "$RC_SUSPEND")
        _resume_line=$(check_voss_line "$RC_RESUME")
        _status=$(show_status "$_ctl" "$_suspend_line" "$_resume_line")

        _s_display=$(echo "$_status" | cut -d'|' -f1)
        _r_display=$(echo "$_status" | cut -d'|' -f2)
        _s_ok=$(echo "$_status" | cut -d'|' -f3)
        _r_ok=$(echo "$_status" | cut -d'|' -f4)

        if [ "$_s_ok" = "1" ] && [ "$_r_ok" = "1" ]; then
            _health="All good — suspend safety is configured."
        else
            _health="Issues found — select an action to fix."
        fi

        _choice=$(bsddialog \
            --backtitle "$BACKTITLE" \
            --title "Suspend/Resume Audio Safety" \
            --ok-label "Select" \
            --cancel-label "Exit" \
            --menu "${_health}\n\nControl socket: ${_ctl}\n\nSuspend: ${_s_display}\nResume:  ${_r_display}" \
            22 72 8 \
            check    "Re-check current status" \
            fix      "Auto-fix both rc.suspend and rc.resume" \
            suspend  "Configure rc.suspend only" \
            resume   "Configure rc.resume only" \
            ctl      "Change control socket (current: ${_ctl})" \
            device   "Change resume device (current: ${_resume_dev})" \
            view     "View current file contents" \
            3>&1 1>&2 2>&3) || return

        case "$_choice" in
            check)   continue ;;  # Loop re-checks automatically
            fix)     fix_both "$_ctl" "$_resume_dev" ;;
            suspend) fix_suspend "$_ctl" ;;
            resume)  fix_resume "$_ctl" "$_resume_dev" ;;
            ctl)     _ctl=$(edit_ctl "$_ctl") ;;
            device)  _resume_dev=$(select_resume_device "$_resume_dev") || true ;;
            view)    view_files ;;
        esac
    done
}

# ── Edit control socket ────────────────────────────────────────────────────
edit_ctl() {
    _old=$1
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Control Socket" \
        --inputbox "Control socket path for virtual_oss_cmd:" \
        8 55 "$_old" \
        3>&1 1>&2 2>&3) || { echo "$_old"; return; }
    echo "$_new"
}

# ── Fix rc.suspend ─────────────────────────────────────────────────────────
fix_suspend() {
    _ctl=$1
    _line="virtual_oss_cmd ${_ctl} -f /dev/null"

    _suspend_check=$(check_voss_line "$RC_SUSPEND")

    if [ "$_suspend_check" = "missing" ]; then
        # File doesn't exist — create it
        _content="#!/bin/sh\n# rc.suspend — run before system suspend\n\n# Mute virtual_oss before suspend to release the audio device\n${_line}\nsleep 1\n"

        bsddialog --backtitle "$BACKTITLE" --title "Create ${RC_SUSPEND}" \
            --yesno "File ${RC_SUSPEND} does not exist.\n\nCreate it with:\n\n${_line}\nsleep 1" 12 65 || return

        printf "%b" "$_content" > "$RC_SUSPEND"
        chmod 755 "$RC_SUSPEND"
        bsddialog --backtitle "$BACKTITLE" --title "Created" \
            --msgbox "${RC_SUSPEND} created successfully." 7 50

    elif [ "$_suspend_check" = "absent" ]; then
        # File exists but no virtual_oss_cmd line — inject before acpiconf or at the end
        bsddialog --backtitle "$BACKTITLE" --title "Update ${RC_SUSPEND}" \
            --yesno "Add mute line to existing ${RC_SUSPEND}?\n\nWill insert:\n  ${_line}\n  sleep 1\n\n(before any acpiconf line, or at end of file)" 13 65 || return

        if grep -q 'acpiconf' "$RC_SUSPEND" 2>/dev/null; then
            # Insert before the acpiconf line
            _tmpf=$(mktemp)
            sed "/acpiconf/i\\
# Mute virtual_oss before suspend\\
${_line}\\
sleep 1\\
" "$RC_SUSPEND" > "$_tmpf"
            mv "$_tmpf" "$RC_SUSPEND"
        else
            # Append
            printf "\n# Mute virtual_oss before suspend\n%s\nsleep 1\n" "$_line" >> "$RC_SUSPEND"
        fi
        chmod 755 "$RC_SUSPEND"
        bsddialog --backtitle "$BACKTITLE" --title "Updated" \
            --msgbox "Mute line added to ${RC_SUSPEND}." 7 50

    else
        # Line exists — check correctness
        _existing_dev=$(extract_device_from_line "$_suspend_check")
        _existing_ctl=$(extract_ctl_from_line "$_suspend_check")
        if [ "$_existing_dev" = "/dev/null" ] && [ "$_existing_ctl" = "$_ctl" ]; then
            bsddialog --backtitle "$BACKTITLE" --title "Already OK" \
                --msgbox "Suspend mute line is already correct:\n\n${_suspend_check}" 9 65
        else
            bsddialog --backtitle "$BACKTITLE" --title "Fix ${RC_SUSPEND}" \
                --yesno "Current line:\n  ${_suspend_check}\n\nReplace with:\n  ${_line}" 11 65 || return

            _tmpf=$(mktemp)
            sed "s|.*virtual_oss_cmd.*|${_line}|" "$RC_SUSPEND" > "$_tmpf"
            mv "$_tmpf" "$RC_SUSPEND"
            chmod 755 "$RC_SUSPEND"
            bsddialog --backtitle "$BACKTITLE" --title "Fixed" \
                --msgbox "Suspend line updated in ${RC_SUSPEND}." 7 50
        fi
    fi
}

# ── Fix rc.resume ──────────────────────────────────────────────────────────
fix_resume() {
    _ctl=$1
    _dev=$2
    _line="virtual_oss_cmd ${_ctl} -f ${_dev}"

    _resume_check=$(check_voss_line "$RC_RESUME")

    if [ "$_resume_check" = "missing" ]; then
        _content="#!/bin/sh\n# rc.resume — run after system resume\n\n# Restore virtual_oss output after resume\n${_line}\n"

        bsddialog --backtitle "$BACKTITLE" --title "Create ${RC_RESUME}" \
            --yesno "File ${RC_RESUME} does not exist.\n\nCreate it with:\n\n${_line}" 11 65 || return

        printf "%b" "$_content" > "$RC_RESUME"
        chmod 755 "$RC_RESUME"
        bsddialog --backtitle "$BACKTITLE" --title "Created" \
            --msgbox "${RC_RESUME} created successfully." 7 50

    elif [ "$_resume_check" = "absent" ]; then
        bsddialog --backtitle "$BACKTITLE" --title "Update ${RC_RESUME}" \
            --yesno "Add restore line to existing ${RC_RESUME}?\n\nWill append:\n  ${_line}" 10 65 || return

        printf "\n# Restore virtual_oss output after resume\n%s\n" "$_line" >> "$RC_RESUME"
        chmod 755 "$RC_RESUME"
        bsddialog --backtitle "$BACKTITLE" --title "Updated" \
            --msgbox "Restore line added to ${RC_RESUME}." 7 50

    else
        _existing_dev=$(extract_device_from_line "$_resume_check")
        _existing_ctl=$(extract_ctl_from_line "$_resume_check")
        if [ "$_existing_dev" = "$_dev" ] && [ "$_existing_ctl" = "$_ctl" ]; then
            bsddialog --backtitle "$BACKTITLE" --title "Already OK" \
                --msgbox "Resume restore line is already correct:\n\n${_resume_check}" 9 65
        else
            bsddialog --backtitle "$BACKTITLE" --title "Fix ${RC_RESUME}" \
                --yesno "Current line:\n  ${_resume_check}\n\nReplace with:\n  ${_line}" 11 65 || return

            _tmpf=$(mktemp)
            sed "s|.*virtual_oss_cmd.*|${_line}|" "$RC_RESUME" > "$_tmpf"
            mv "$_tmpf" "$RC_RESUME"
            chmod 755 "$RC_RESUME"
            bsddialog --backtitle "$BACKTITLE" --title "Fixed" \
                --msgbox "Resume line updated in ${RC_RESUME}." 7 50
        fi
    fi
}

# ── Fix both ───────────────────────────────────────────────────────────────
fix_both() {
    _ctl=$1
    _dev=$2

    _suspend_line="virtual_oss_cmd ${_ctl} -f /dev/null"
    _resume_line="virtual_oss_cmd ${_ctl} -f ${_dev}"

    bsddialog --backtitle "$BACKTITLE" --title "Auto-Fix Both" \
        --yesno "This will ensure:\n\n${RC_SUSPEND}:\n  ${_suspend_line}\n  sleep 1\n\n${RC_RESUME}:\n  ${_resume_line}\n\nProceed?" 15 65 || return

    fix_suspend "$_ctl"
    fix_resume "$_ctl" "$_dev"
}

# ── View current files ─────────────────────────────────────────────────────
view_files() {
    _tmpf=$(mktemp)

    printf "═══ %s ═══\n\n" "$RC_SUSPEND" > "$_tmpf"
    if [ -f "$RC_SUSPEND" ]; then
        cat "$RC_SUSPEND" >> "$_tmpf"
    else
        printf "(file does not exist)\n" >> "$_tmpf"
    fi

    printf "\n\n═══ %s ═══\n\n" "$RC_RESUME" >> "$_tmpf"
    if [ -f "$RC_RESUME" ]; then
        cat "$RC_RESUME" >> "$_tmpf"
    else
        printf "(file does not exist)\n" >> "$_tmpf"
    fi

    bsddialog --backtitle "$BACKTITLE" --title "Current File Contents" \
        --textbox "$_tmpf" 22 75

    rm -f "$_tmpf"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Root check
if [ "$(id -u)" -ne 0 ]; then
    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Warning" \
        --yesno "Not running as root.\nWriting to /etc/rc.suspend and /etc/rc.resume will fail.\n\nContinue anyway (view-only)?" \
        9 55 || exit 0
fi

main_menu
