#!/bin/sh
# configure-jack.sh — Check/fix JACK audio for FreeBSD (OSS backend)
# CLI mode: reports installation, rc.conf, realtime setup, service status
# TUI mode: interactive editor for jackd parameters via bsddialog
#
# Usage:
#   ./configure-jack.sh             — Check and prompt to fix
#   ./configure-jack.sh --auto      — Apply all fixes without prompting
#   ./configure-jack.sh --dry-run   — Check only, no changes
#   ./configure-jack.sh --tui       — Launch interactive settings editor
#   ./configure-jack.sh --help      — Show help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

MODE="interactive"

case "${1:-}" in
    --auto)    MODE="auto" ;;
    --dry-run) MODE="dryrun" ;;
    --tui)     MODE="tui" ;;
    --help|-h)
        cat <<EOF
configure-jack.sh — JACK configuration for FreeBSD

CLI mode (default):
  Checks jackd installation, rc.conf service settings, realtime
  priority setup (mac_priority, realtime group), and service status.

TUI mode (--tui):
  Interactive editor for jackd_args: sample rate, buffer size,
  periods, bit depth, capture/playback devices.

Options:
  --auto      Apply all fixes without prompting
  --dry-run   Check only, no changes
  --tui       Launch interactive settings editor
  --help      Show this help

Run as root for service and rc.conf changes.
EOF
        exit 0
        ;;
esac

# ── Helpers ─────────────────────────────────────────────────────────────────
ask_yes() {
    if [ "$MODE" = "auto" ]; then return 0; fi
    if [ "$MODE" = "dryrun" ]; then return 1; fi
    printf "  %s [y/N] " "$1"
    read -r _ans
    case "$_ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Parse a flag value from jackd_args
jack_get() {
    _args=$1
    _flag=$2
    echo "$_args" | grep -oE -- "${_flag} [^ ]+" | awk '{print $2}' | head -1
}

jack_has() {
    _args=$1
    _flag=$2
    echo "$_args" | grep -qw -- "$_flag"
}

# Build jackd_args string from components
jack_build_args() {
    _rt=$1
    _rate=$2
    _buf=$3
    _periods=$4
    _bits=$5
    _capture=$6
    _playback=$7

    _a=""
    [ "$_rt" = "yes" ] && _a="-R"
    _a="${_a} -d oss -r ${_rate} -p ${_buf} -n ${_periods} -w ${_bits}"
    _a="${_a} --capture ${_capture} --playback ${_playback}"
    echo "$_a" | sed 's/^ //'
}

# ════════════════════════════════════════════════════════════════════════════
#  CLI MODE
# ════════════════════════════════════════════════════════════════════════════
cli_mode() {
    ISSUES=0

    section "JACK — Installation"

    if command -v jackd >/dev/null 2>&1; then
        _ver=$(jackd --version 2>&1 | head -1 || echo "unknown")
        ok "jackd installed (${_ver})"
    else
        fail "jackd not installed"
        info "Install with: pkg install jackit"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Install jackit?"; then
            pkg install -y jackit 2>&1 | tail -1
        fi
    fi

    if command -v qjackctl >/dev/null 2>&1; then
        ok "qjackctl installed (optional GUI)"
    else
        info "qjackctl not installed (optional: pkg install qjackctl)"
    fi

    # ── Realtime priority ───────────────────────────────────────────────────
    section "JACK — Realtime Priority"

    # mac_priority module
    if kldstat -q -m mac_priority 2>/dev/null; then
        ok "mac_priority kernel module loaded"
    else
        fail "mac_priority not loaded (JACK will get xruns under load)"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Load mac_priority now?"; then
            kldload mac_priority 2>/dev/null && ok "Loaded" || fail "Failed to load"
        fi
    fi

    # Check kld_list for persistence
    _kld=$(sysrc -n kld_list 2>/dev/null || echo "")
    if echo "$_kld" | grep -q 'mac_priority'; then
        ok "mac_priority in kld_list (loads on boot)"
    else
        warn "mac_priority not in kld_list (won't persist across reboots)"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Add mac_priority to kld_list?"; then
            sysrc kld_list+="mac_priority" >/dev/null 2>&1
            ok "Added"
        fi
    fi

    # Realtime group
    _user=$(logname 2>/dev/null || echo "${USER:-$(whoami)}")
    if pw groupshow realtime >/dev/null 2>&1; then
        ok "Group 'realtime' exists"
        if pw groupshow realtime 2>/dev/null | grep -q "$_user"; then
            ok "User '${_user}' is in realtime group"
        else
            warn "User '${_user}' is NOT in realtime group"
            ISSUES=$((ISSUES + 1))
            if ask_yes "Add ${_user} to realtime group?"; then
                pw groupmod realtime -m "$_user" 2>/dev/null && ok "Added" || fail "Failed"
            fi
        fi
    else
        warn "Group 'realtime' does not exist"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Create realtime group and add ${_user}?"; then
            pw groupadd realtime 2>/dev/null
            pw groupmod realtime -m "$_user" 2>/dev/null
            ok "Created and added ${_user}"
        fi
    fi

    # ── rc.conf settings ────────────────────────────────────────────────────
    section "JACK — rc.conf Service Settings"

    _enable=$(sysrc -n jackd_enable 2>/dev/null || echo "")
    if [ "$_enable" = "YES" ] || [ "$_enable" = "yes" ]; then
        ok "jackd_enable=YES"
    else
        info "jackd_enable not set (JACK won't auto-start on boot)"
        info "This is normal if you start JACK manually or via qjackctl"
    fi

    _jack_user=$(sysrc -n jackd_user 2>/dev/null || echo "")
    if [ -n "$_jack_user" ]; then
        ok "jackd_user=${_jack_user}"
    else
        info "jackd_user not set"
    fi

    _rtprio=$(sysrc -n jackd_rtprio 2>/dev/null || echo "")
    if [ "$_rtprio" = "YES" ] || [ "$_rtprio" = "yes" ]; then
        ok "jackd_rtprio=YES"
    elif [ -n "$_rtprio" ]; then
        warn "jackd_rtprio=${_rtprio} (expected YES)"
        ISSUES=$((ISSUES + 1))
    else
        warn "jackd_rtprio not set"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Set jackd_rtprio=YES?"; then
            sysrc jackd_rtprio=YES >/dev/null 2>&1
            ok "Set"
        fi
    fi

    _args=$(sysrc -n jackd_args 2>/dev/null || echo "")
    if [ -n "$_args" ]; then
        ok "jackd_args defined"
        info "  ${_args}"

        # Validate key params
        _d=$(jack_get "$_args" "-d")
        if [ "$_d" = "oss" ]; then
            ok "  Backend: oss"
        elif [ -n "$_d" ]; then
            warn "  Backend: ${_d} (expected 'oss' on FreeBSD)"
        fi

        _r=$(jack_get "$_args" "-r")
        [ -n "$_r" ] && info "  Sample rate: ${_r}"

        _p=$(jack_get "$_args" "-p")
        [ -n "$_p" ] && info "  Buffer size: ${_p}"

        _n=$(jack_get "$_args" "-n")
        [ -n "$_n" ] && info "  Periods: ${_n}"

        _cap=$(jack_get "$_args" "--capture")
        _play=$(jack_get "$_args" "--playback")
        [ -n "$_cap" ] && info "  Capture: ${_cap}"
        [ -n "$_play" ] && info "  Playback: ${_play}"

        # Warn if pointing at virtual_oss device
        if [ -n "$_cap" ]; then
            _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
            if [ -n "$_pid" ]; then
                _vd=$(ps -ww -p "$(echo "$_pid" | head -1)" -o args= 2>/dev/null \
                    | grep -oE '\-d [^ ]+' | awk '{print $2}' | head -1)
                if [ -n "$_vd" ] && [ "$_cap" = "/dev/${_vd}" ]; then
                    warn "  Capture points at virtual_oss device — should use real hardware"
                    ISSUES=$((ISSUES + 1))
                fi
            fi
        fi
    else
        info "jackd_args not set in rc.conf"
        info "You can configure it with: ./configure-jack.sh --tui"
    fi

    # ── Service status ──────────────────────────────────────────────────────
    section "JACK — Service Status"

    if pgrep -x jackd >/dev/null 2>&1; then
        _jpid=$(pgrep -x jackd | head -1)
        _jcmd=$(ps -ww -p "$_jpid" -o args= 2>/dev/null || true)
        ok "jackd is running (PID: ${_jpid})"
        info "  ${_jcmd}"
    else
        info "jackd is not running"
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    printf "\n"
    if [ "$ISSUES" -eq 0 ]; then
        ok "All checks passed."
    else
        info "${ISSUES} issue(s) found."
        [ "$MODE" = "dryrun" ] && info "Run without --dry-run to fix."
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  TUI MODE
# ════════════════════════════════════════════════════════════════════════════
tui_mode() {
    if ! command -v bsddialog >/dev/null 2>&1; then
        printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
        exit 1
    fi

    _BT="JACK Configuration — FreeBSD $(uname -r)"

    # Load current from rc.conf or defaults
    _args=$(sysrc -n jackd_args 2>/dev/null || echo "")
    _rt="yes"
    _rate="48000"
    _buf="1024"
    _periods="3"
    _bits="16"
    _capture="/dev/dsp1"
    _playback="/dev/dsp1"

    if [ -n "$_args" ]; then
        jack_has "$_args" "-R" && _rt="yes" || _rt="no"
        _v=$(jack_get "$_args" "-r");       [ -n "$_v" ] && _rate="$_v"
        _v=$(jack_get "$_args" "-p");       [ -n "$_v" ] && _buf="$_v"
        _v=$(jack_get "$_args" "-n");       [ -n "$_v" ] && _periods="$_v"
        _v=$(jack_get "$_args" "-w");       [ -n "$_v" ] && _bits="$_v"
        _v=$(jack_get "$_args" "--capture");  [ -n "$_v" ] && _capture="$_v"
        _v=$(jack_get "$_args" "--playback"); [ -n "$_v" ] && _playback="$_v"
    fi

    while true; do
        _running="Stopped"
        pgrep -x jackd >/dev/null 2>&1 && _running="Running"

        _choice=$(bsddialog \
            --backtitle "$_BT" \
            --title "JACK Settings (jackd_args)" \
            --ok-label "Edit" \
            --cancel-label "Exit" \
            --menu "Status: ${_running}" 20 65 10 \
            rate     "Sample rate: ${_rate} Hz" \
            buffer   "Buffer size: ${_buf} samples" \
            periods  "Periods: ${_periods}" \
            bits     "Bit depth: ${_bits}-bit" \
            capture  "Capture device: ${_capture}" \
            playback "Playback device: ${_playback}" \
            rt       "Realtime mode: ${_rt}" \
            apply    ">>> Save to rc.conf <<<" \
            3>&1 1>&2 2>&3) || return

        case "$_choice" in
            rate)
                _new=$(bsddialog --backtitle "$_BT" --title "Sample Rate" \
                    --radiolist "Select sample rate (Hz):" 14 50 5 \
                    "44100"  "44.1 kHz (CD)"      "$([ "$_rate" = "44100"  ] && echo on || echo off)" \
                    "48000"  "48 kHz (standard)"  "$([ "$_rate" = "48000"  ] && echo on || echo off)" \
                    "96000"  "96 kHz (studio)"    "$([ "$_rate" = "96000"  ] && echo on || echo off)" \
                    "192000" "192 kHz (high-res)" "$([ "$_rate" = "192000" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                _rate="$_new"
                ;;
            buffer)
                _new=$(bsddialog --backtitle "$_BT" --title "Buffer Size" \
                    --radiolist "Buffer size in samples (lower = less latency):" 16 60 7 \
                    "64"   "64 — Ultra low (may xrun)"   "$([ "$_buf" = "64"   ] && echo on || echo off)" \
                    "128"  "128 — Very low"              "$([ "$_buf" = "128"  ] && echo on || echo off)" \
                    "256"  "256 — Low latency"           "$([ "$_buf" = "256"  ] && echo on || echo off)" \
                    "512"  "512 — Balanced"              "$([ "$_buf" = "512"  ] && echo on || echo off)" \
                    "1024" "1024 — Safe default"         "$([ "$_buf" = "1024" ] && echo on || echo off)" \
                    "2048" "2048 — High buffer"          "$([ "$_buf" = "2048" ] && echo on || echo off)" \
                    "4096" "4096 — Maximum stability"    "$([ "$_buf" = "4096" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                _buf="$_new"
                ;;
            periods)
                _new=$(bsddialog --backtitle "$_BT" --title "Periods" \
                    --radiolist "Number of periods (higher = more latency, fewer xruns):" 12 55 3 \
                    "2" "2 — Minimum" "$([ "$_periods" = "2" ] && echo on || echo off)" \
                    "3" "3 — Default"  "$([ "$_periods" = "3" ] && echo on || echo off)" \
                    "4" "4 — Safe"     "$([ "$_periods" = "4" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                _periods="$_new"
                ;;
            bits)
                _new=$(bsddialog --backtitle "$_BT" --title "Bit Depth" \
                    --radiolist "Select bit depth:" 12 45 3 \
                    "16" "16-bit"  "$([ "$_bits" = "16" ] && echo on || echo off)" \
                    "24" "24-bit"  "$([ "$_bits" = "24" ] && echo on || echo off)" \
                    "32" "32-bit"  "$([ "$_bits" = "32" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                _bits="$_new"
                ;;
            capture)
                _new=$(_select_hw_device "$_BT" "Capture Device" "$_capture") || continue
                _capture="$_new"
                ;;
            playback)
                _new=$(_select_hw_device "$_BT" "Playback Device" "$_playback") || continue
                _playback="$_new"
                ;;
            rt)
                [ "$_rt" = "yes" ] && _rt="no" || _rt="yes"
                ;;
            apply)
                _new_args=$(jack_build_args "$_rt" "$_rate" "$_buf" "$_periods" "$_bits" "$_capture" "$_playback")
                bsddialog --backtitle "$_BT" --title "Save to rc.conf" \
                    --yesno "Set jackd_args to:\n\n${_new_args}" 10 70 || continue
                sysrc jackd_args="${_new_args}" >/dev/null 2>&1
                bsddialog --backtitle "$_BT" --title "Saved" \
                    --msgbox "jackd_args written to rc.conf." 7 45
                ;;
        esac
    done
}

_select_hw_device() {
    _bt=$1
    _title=$2
    _default=$3

    _items=""
    _units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)

    for _u in $_units; do
        _desc=$(sysctl -n "dev.pcm.${_u}.%desc" 2>/dev/null || echo "(unknown)")
        _parent=$(sysctl -n "dev.pcm.${_u}.%parent" 2>/dev/null || echo "")
        # Skip virtual_oss devices for JACK (should use real hardware)
        case "$_parent" in
            *cuse*|*virtual_oss*) continue ;;
        esac
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

    [ -z "$_items" ] && _items="/dev/dsp0 \"Default hardware device\""

    eval bsddialog \
        --backtitle "\"${_bt}\"" \
        --title "\"${_title}\"" \
        --default-item "\"${_default}\"" \
        --menu "\"Select hardware device (JACK should use real hardware, not virtual_oss):\"" \
        18 72 8 \
        ${_items} \
        3>&1 1>&2 2>&3
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$MODE" = "tui" ]; then
    tui_mode
else
    cli_mode
fi
