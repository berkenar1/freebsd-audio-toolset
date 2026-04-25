#!/bin/sh
# switch-audio-output.sh — TUI for runtime audio output switching
# Switches the active virtual_oss backend device on the fly via
# virtual_oss_cmd, without restarting the service.
#
# Usage:
#   ./switch-audio-output.sh           — Launch TUI
#   ./switch-audio-output.sh --help    — Show help

set -u

BACKTITLE="Audio Output Switcher — FreeBSD $(uname -r)"

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v bsddialog >/dev/null 2>&1; then
    printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
    exit 1
fi

if ! command -v virtual_oss_cmd >/dev/null 2>&1; then
    printf "Error: virtual_oss_cmd not found. Install virtual_oss.\n" >&2
    exit 1
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
switch-audio-output.sh — Runtime audio output switcher

Switches the active virtual_oss backend device on the fly using
virtual_oss_cmd.  No service restart is needed.

Features:
  • Lists all available PCM devices from the kernel
  • Shows which device is currently active
  • Supports muting output (switch to /dev/null)
  • Discovers control sockets from running virtual_oss instances

Requires: bsddialog, virtual_oss_cmd, virtual_oss (running).
EOF
    exit 0
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

# Get the control socket from a running virtual_oss process.
# Returns the first -t argument found, prefixed with /dev/.
detect_ctl_socket() {
    _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -z "$_pid" ]; then
        return 1
    fi

    # There may be multiple virtual_oss processes; collect all ctl sockets
    _sockets=""
    for _p in $_pid; do
        _args=$(ps -ww -p "$_p" -o args= 2>/dev/null || true)
        _ctl=$(echo "$_args" | grep -oE '\-t [^ ]+' | awk '{print $2}' | head -1)
        if [ -n "$_ctl" ]; then
            # Normalise: ensure /dev/ prefix
            case "$_ctl" in
                /dev/*) ;;
                *)      _ctl="/dev/${_ctl}" ;;
            esac
            _sockets="${_sockets} ${_ctl}"
        fi
    done

    echo "$_sockets" | tr -s ' ' | sed 's/^ //;s/ $//'
}

# Get the current backend from the running process for a given ctl socket
detect_current_backend() {
    _ctl_name=$1
    # Strip /dev/ to match the -t arg in process list
    _ctl_short=$(echo "$_ctl_name" | sed 's|^/dev/||')

    for _p in $(pgrep -x virtual_oss 2>/dev/null); do
        _args=$(ps -ww -p "$_p" -o args= 2>/dev/null || true)
        if echo "$_args" | grep -q -- "-t ${_ctl_short}"; then
            # Extract -f (combined) or -P (playback-only) backend
            _back=$(echo "$_args" | grep -oE '\-f [^ ]+' | awk '{print $2}' | head -1)
            [ -z "$_back" ] && _back=$(echo "$_args" | grep -oE '\-P [^ ]+' | awk '{print $2}' | head -1)
            echo "$_back"
            return
        fi
    done
    echo "(unknown)"
}

# ── Control socket selection (if multiple) ──────────────────────────────────
select_ctl_socket() {
    _sockets=$1

    _count=$(echo "$_sockets" | wc -w | tr -d ' ')
    if [ "$_count" -eq 1 ]; then
        echo "$_sockets"
        return
    fi

    # Build menu items
    _items=""
    for _s in $_sockets; do
        _back=$(detect_current_backend "$_s")
        _items="${_items} ${_s} \"current backend: ${_back}\""
    done

    eval bsddialog \
        --backtitle "\"${BACKTITLE}\"" \
        --title "\"Select Control Socket\"" \
        --menu "\"Multiple virtual_oss instances found. Pick one:\"" 14 65 8 \
        ${_items} \
        3>&1 1>&2 2>&3
}

# ── Main switch menu ────────────────────────────────────────────────────────
switch_menu() {
    _ctl=$1

    while true; do
        _current=$(detect_current_backend "$_ctl")

        # Build PCM device list
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
            _dev="/dev/dsp${_u}"
            _marker=""
            [ "$_dev" = "$_current" ] && _marker=" ←ACTIVE"
            _items="${_items} ${_dev} \"[${_caps}] ${_desc}${_marker}\""
        done

        # Mute option
        _mute_marker=""
        [ "$_current" = "/dev/null" ] && _mute_marker=" ←ACTIVE"
        _items="${_items} /dev/null \"[mute] Silence output (suspend-safe)${_mute_marker}\""

        _choice=$(eval bsddialog \
            --backtitle "\"${BACKTITLE}\"" \
            --title "\"Switch Audio Output\"" \
            --ok-label "\"Switch\"" \
            --cancel-label "\"Exit\"" \
            --menu "\"Control: ${_ctl}\\nCurrent backend: ${_current}\\n\\nSelect new output device:\"" \
            20 72 10 \
            ${_items} \
            3>&1 1>&2 2>&3) || return

        # Skip if already active
        if [ "$_choice" = "$_current" ]; then
            bsddialog --backtitle "$BACKTITLE" --title "No Change" \
                --msgbox "Already using ${_choice}." 7 45
            continue
        fi

        # Confirm
        if [ "$_choice" = "/dev/null" ]; then
            _confirm_msg="Mute audio output?\n\nThis switches the backend to /dev/null.\nUseful before suspend or to silence output."
        else
            _dev_desc=$(sysctl -n "dev.pcm.$(echo "$_choice" | sed 's|/dev/dsp||').%desc" 2>/dev/null || echo "$_choice")
            _confirm_msg="Switch output to ${_choice}?\n\n${_dev_desc}"
        fi

        bsddialog --backtitle "$BACKTITLE" --title "Confirm Switch" \
            --yesno "$_confirm_msg" 10 55 || continue

        # Execute the switch
        _output=$(virtual_oss_cmd "$_ctl" -f "$_choice" 2>&1) || true
        _retval=$?

        if [ $_retval -eq 0 ]; then
            bsddialog --backtitle "$BACKTITLE" --title "Switched" \
                --msgbox "Output switched to ${_choice}.\n\n${_output}" 9 55
        else
            bsddialog --backtitle "$BACKTITLE" --title "Error" \
                --msgbox "Failed to switch output:\n\n${_output}" 10 60
        fi
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Check virtual_oss is running
if ! pgrep -x virtual_oss >/dev/null 2>&1; then
    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Error" \
        --msgbox "virtual_oss is not running.\n\nStart it first:\n  service virtual_oss start" 10 50
    exit 1
fi

# Detect available control sockets
_all_sockets=$(detect_ctl_socket)
if [ -z "$_all_sockets" ]; then
    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Error" \
        --msgbox "No control socket (-t) found in running virtual_oss.\n\nMake sure your config includes a -t flag, e.g.:\n  -t dsp.ctl" 10 60
    exit 1
fi

# Select socket (auto if only one)
_ctl=$(select_ctl_socket "$_all_sockets") || exit 0

switch_menu "$_ctl"
