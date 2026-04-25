#!/bin/sh
# configure-pulseaudio.sh — Check/fix PulseAudio for FreeBSD + virtual_oss
# CLI mode: reports config status and fixes issues
# TUI mode: interactive settings editor via bsddialog
#
# Usage:
#   ./configure-pulseaudio.sh             — Check and prompt to fix
#   ./configure-pulseaudio.sh --auto      — Apply all fixes without prompting
#   ./configure-pulseaudio.sh --dry-run   — Check only, no changes
#   ./configure-pulseaudio.sh --tui       — Launch interactive settings editor
#   ./configure-pulseaudio.sh --help      — Show help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

MODE="interactive"
PA_SYS_DAEMON="/usr/local/etc/pulse/daemon.conf"
PA_SYS_DEFAULT="/usr/local/etc/pulse/default.pa"
PA_SYS_CLIENT="/usr/local/etc/pulse/client.conf"
PA_USER_DIR="${HOME}/.config/pulse"
PA_USER_DAEMON="${PA_USER_DIR}/daemon.conf"
PA_USER_DEFAULT="${PA_USER_DIR}/default.pa"
PA_USER_CLIENT="${PA_USER_DIR}/client.conf"

case "${1:-}" in
    --auto)    MODE="auto" ;;
    --dry-run) MODE="dryrun" ;;
    --tui)     MODE="tui" ;;
    --help|-h)
        cat <<EOF
configure-pulseaudio.sh — PulseAudio configuration for FreeBSD

CLI mode (default):
  Checks PulseAudio installation, config files, OSS module loading,
  and virtual_oss integration. Prompts to fix issues found.

TUI mode (--tui):
  Interactive bsddialog editor for daemon.conf settings like sample
  rate, format, resampler, and realtime priority.

Checks:
  • PulseAudio is installed
  • daemon.conf has FreeBSD-appropriate settings
  • default.pa loads module-oss pointed at virtual_oss device
  • PulseAudio is running and functional

Options:
  --auto      Apply all fixes without prompting
  --dry-run   Check only, no changes
  --tui       Launch interactive settings editor
  --help      Show this help
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

# Read a value from a PA config file (key = value format)
pa_get() {
    _file=$1
    _key=$2
    if [ ! -f "$_file" ]; then echo ""; return; fi
    # Skip commented lines (starting with ; or #)
    grep -E "^[[:space:]]*${_key}[[:space:]]*=" "$_file" 2>/dev/null \
        | head -1 \
        | sed "s/.*=[[:space:]]*//" \
        | sed 's/[[:space:]]*$//'
}

# Set a value in a PA config file
pa_set() {
    _file=$1
    _key=$2
    _val=$3
    mkdir -p "$(dirname "$_file")"
    if [ ! -f "$_file" ]; then
        printf "%s = %s\n" "$_key" "$_val" > "$_file"
    elif grep -qE "^[[:space:]]*${_key}[[:space:]]*=" "$_file" 2>/dev/null; then
        _tmpf=$(mktemp)
        sed "s|^[[:space:]]*${_key}[[:space:]]*=.*|${_key} = ${_val}|" "$_file" > "$_tmpf"
        mv "$_tmpf" "$_file"
    elif grep -qE "^[[:space:]]*;[[:space:]]*${_key}[[:space:]]*=" "$_file" 2>/dev/null; then
        # Uncomment and set
        _tmpf=$(mktemp)
        sed "s|^[[:space:]]*;[[:space:]]*${_key}[[:space:]]*=.*|${_key} = ${_val}|" "$_file" > "$_tmpf"
        mv "$_tmpf" "$_file"
    else
        printf "%s = %s\n" "$_key" "$_val" >> "$_file"
    fi
}

# Check if default.pa has the module-oss line
pa_has_oss_module() {
    _file=$1
    [ -f "$_file" ] && grep -q 'load-module module-oss' "$_file" 2>/dev/null
}

# Get the OSS device from default.pa
pa_oss_device() {
    _file=$1
    grep 'load-module module-oss' "$_file" 2>/dev/null \
        | grep -oE 'device=[^ ]+' | head -1 | sed 's/device=//'
}

# ── Effective value: user overrides system ─────────────────────────────────
pa_effective() {
    _key=$1
    _val=$(pa_get "$PA_USER_DAEMON" "$_key")
    [ -z "$_val" ] && _val=$(pa_get "$PA_SYS_DAEMON" "$_key")
    echo "$_val"
}

# ════════════════════════════════════════════════════════════════════════════
#  CLI MODE — Check and fix
# ════════════════════════════════════════════════════════════════════════════
cli_mode() {
    ISSUES=0

    section "PulseAudio — Installation"

    if command -v pulseaudio >/dev/null 2>&1; then
        _ver=$(pulseaudio --version 2>/dev/null | head -1 || echo "unknown")
        ok "PulseAudio installed (${_ver})"
    else
        fail "PulseAudio not installed"
        info "Install with: pkg install pulseaudio"
        exit 1
    fi

    if command -v pacmd >/dev/null 2>&1; then
        ok "pacmd available"
    else
        warn "pacmd not found (limited diagnostics)"
    fi

    # ── Config files ────────────────────────────────────────────────────────
    section "PulseAudio — Configuration Files"

    if [ -f "$PA_SYS_DAEMON" ]; then
        ok "System daemon.conf exists"
    else
        warn "System daemon.conf missing (${PA_SYS_DAEMON})"
        ISSUES=$((ISSUES + 1))
    fi

    if [ -f "$PA_SYS_DEFAULT" ]; then
        ok "System default.pa exists"
    else
        warn "System default.pa missing (${PA_SYS_DEFAULT})"
        ISSUES=$((ISSUES + 1))
    fi

    if [ -d "$PA_USER_DIR" ]; then
        ok "User config dir exists (~/.config/pulse/)"
        [ -f "$PA_USER_DAEMON" ] && info "  User daemon.conf: present (overrides system)"
        [ -f "$PA_USER_DEFAULT" ] && info "  User default.pa: present (overrides system)"
    else
        info "No user config dir (~/.config/pulse/) — using system defaults"
    fi

    # ── daemon.conf settings ────────────────────────────────────────────────
    section "PulseAudio — daemon.conf Settings"

    # Target file: prefer user, fall back to system
    if [ -f "$PA_USER_DAEMON" ]; then
        _target_daemon="$PA_USER_DAEMON"
    else
        _target_daemon="$PA_SYS_DAEMON"
    fi

    # Sample rate
    _rate=$(pa_effective "default-sample-rate")
    if [ -n "$_rate" ]; then
        case "$_rate" in
            44100|48000|96000) ok "Sample rate: ${_rate}" ;;
            *) warn "Unusual sample rate: ${_rate}" ;;
        esac
    else
        warn "default-sample-rate not set (PA default: 44100)"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Set default-sample-rate = 48000?"; then
            pa_set "$_target_daemon" "default-sample-rate" "48000"
            ok "Set to 48000"
        fi
    fi

    # Sample format
    _fmt=$(pa_effective "default-sample-format")
    if [ -n "$_fmt" ]; then
        ok "Sample format: ${_fmt}"
    else
        info "default-sample-format not set (PA default: s16le)"
    fi

    # Realtime scheduling
    _rt=$(pa_effective "realtime-scheduling")
    if [ "$_rt" = "yes" ]; then
        ok "Realtime scheduling: enabled"
        _rtprio=$(pa_effective "realtime-priority")
        [ -n "$_rtprio" ] && info "  Priority: ${_rtprio}"
    elif [ "$_rt" = "no" ]; then
        warn "Realtime scheduling: disabled"
        ISSUES=$((ISSUES + 1))
        if ask_yes "Enable realtime-scheduling?"; then
            pa_set "$_target_daemon" "realtime-scheduling" "yes"
            pa_set "$_target_daemon" "realtime-priority" "5"
            ok "Enabled with priority 5"
        fi
    else
        info "realtime-scheduling not set (PA default: yes)"
    fi

    # Resample method
    _resample=$(pa_effective "resample-method")
    if [ -n "$_resample" ]; then
        ok "Resample method: ${_resample}"
    else
        info "resample-method not set (PA default: speex-float-1)"
        if ask_yes "Set resample-method = soxr-vhq for higher quality?"; then
            pa_set "$_target_daemon" "resample-method" "soxr-vhq"
            ok "Set to soxr-vhq"
        fi
    fi

    # ── default.pa — module-oss ─────────────────────────────────────────────
    section "PulseAudio — OSS Module (default.pa)"

    # Check which default.pa is effective
    if [ -f "$PA_USER_DEFAULT" ]; then
        _target_pa="$PA_USER_DEFAULT"
        info "Using user default.pa"
    elif [ -f "$PA_SYS_DEFAULT" ]; then
        _target_pa="$PA_SYS_DEFAULT"
        info "Using system default.pa"
    else
        _target_pa=""
    fi

    if [ -n "$_target_pa" ] && pa_has_oss_module "$_target_pa"; then
        _oss_dev=$(pa_oss_device "$_target_pa")
        ok "module-oss loaded (device=${_oss_dev:-default})"

        # Check device matches a virtual_oss node
        if [ -n "$_oss_dev" ]; then
            case "$_oss_dev" in
                /dev/dsp|/dev/dsp[0-9]*)
                    ok "  Points to OSS device: ${_oss_dev}" ;;
                *)
                    warn "  Unusual device path: ${_oss_dev}" ;;
            esac
        fi

        # Check set-default-sink
        if grep -q 'set-default-sink' "$_target_pa" 2>/dev/null; then
            _dsink=$(grep 'set-default-sink' "$_target_pa" | awk '{print $2}' | head -1)
            ok "  Default sink: ${_dsink}"
        else
            warn "  No set-default-sink directive"
        fi
    elif [ -n "$_target_pa" ]; then
        fail "module-oss not loaded in default.pa"
        ISSUES=$((ISSUES + 1))
        info "PulseAudio needs module-oss to use virtual_oss on FreeBSD"

        # Detect virtual_oss device
        _vdev="/dev/dsp"
        _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
        if [ -n "$_pid" ]; then
            _vd=$(ps -ww -p "$(echo "$_pid" | head -1)" -o args= 2>/dev/null \
                | grep -oE '\-d [^ ]+' | awk '{print $2}' | head -1)
            [ -n "$_vd" ] && _vdev="/dev/${_vd}"
        fi

        if ask_yes "Add module-oss line (device=${_vdev})?"; then
            # Create user default.pa if needed
            if [ "$_target_pa" = "$PA_SYS_DEFAULT" ]; then
                mkdir -p "$PA_USER_DIR"
                cp "$PA_SYS_DEFAULT" "$PA_USER_DEFAULT"
                _target_pa="$PA_USER_DEFAULT"
                info "  Copied system default.pa to user dir"
            fi

            cat >> "$_target_pa" <<EOF

# OSS output — virtual_oss device (added by configure-pulseaudio.sh)
load-module module-oss device=${_vdev} sink_name=oss_out source_name=oss_in
set-default-sink oss_out
set-default-source oss_in
EOF
            ok "  Added module-oss configuration"
        fi
    else
        fail "No default.pa found"
        ISSUES=$((ISSUES + 1))
    fi

    # ── Service status ──────────────────────────────────────────────────────
    section "PulseAudio — Service Status"

    if pulseaudio --check 2>/dev/null; then
        ok "PulseAudio is running"

        if command -v pacmd >/dev/null 2>&1; then
            _sinks=$(pacmd list-sinks 2>/dev/null | grep -c 'index:' || echo "0")
            _sources=$(pacmd list-sources 2>/dev/null | grep -c 'index:' || echo "0")
            info "  Sinks: ${_sinks}  Sources: ${_sources}"

            _dsink=$(pacmd info 2>/dev/null | grep 'Default sink' | sed 's/.*: //' || true)
            [ -n "$_dsink" ] && info "  Default sink: ${_dsink}"
        fi
    else
        warn "PulseAudio is not running"
        if ask_yes "Start PulseAudio?"; then
            pulseaudio --start 2>/dev/null && ok "Started" || fail "Failed to start"
        fi
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
#  TUI MODE — Interactive settings editor
# ════════════════════════════════════════════════════════════════════════════
tui_mode() {
    if ! command -v bsddialog >/dev/null 2>&1; then
        printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
        exit 1
    fi

    if ! command -v pulseaudio >/dev/null 2>&1; then
        bsddialog --backtitle "PulseAudio" --title "Error" \
            --msgbox "PulseAudio is not installed.\n\npkg install pulseaudio" 8 50
        exit 1
    fi

    _BACKTITLE="PulseAudio Configuration — FreeBSD $(uname -r)"

    # Decide target: user config (safe, doesn't need root)
    mkdir -p "$PA_USER_DIR"
    _target="$PA_USER_DAEMON"
    [ ! -f "$_target" ] && [ -f "$PA_SYS_DAEMON" ] && cp "$PA_SYS_DAEMON" "$_target"
    [ ! -f "$_target" ] && touch "$_target"

    while true; do
        _rate=$(pa_effective "default-sample-rate")
        [ -z "$_rate" ] && _rate="(default: 44100)"
        _fmt=$(pa_effective "default-sample-format")
        [ -z "$_fmt" ] && _fmt="(default: s16le)"
        _rt=$(pa_effective "realtime-scheduling")
        [ -z "$_rt" ] && _rt="(default: yes)"
        _rtprio=$(pa_effective "realtime-priority")
        [ -z "$_rtprio" ] && _rtprio="(default: 5)"
        _resample=$(pa_effective "resample-method")
        [ -z "$_resample" ] && _resample="(default: speex-float-1)"
        _autospawn=$(pa_effective "autospawn")
        [ -z "$_autospawn" ] && _autospawn="(default: yes)"

        _running="Stopped"
        pulseaudio --check 2>/dev/null && _running="Running"

        _choice=$(bsddialog \
            --backtitle "$_BACKTITLE" \
            --title "PulseAudio Settings" \
            --ok-label "Edit" \
            --cancel-label "Exit" \
            --menu "Editing: ${_target}\nStatus: ${_running}" 20 68 10 \
            rate      "Sample rate: ${_rate}" \
            format    "Sample format: ${_fmt}" \
            resample  "Resample method: ${_resample}" \
            rt        "Realtime scheduling: ${_rt}" \
            rtprio    "Realtime priority: ${_rtprio}" \
            autospawn "Autospawn: ${_autospawn}" \
            restart   "Restart PulseAudio" \
            3>&1 1>&2 2>&3) || return

        case "$_choice" in
            rate)
                _new=$(bsddialog --backtitle "$_BACKTITLE" --title "Sample Rate" \
                    --radiolist "Select sample rate (Hz):" 14 50 5 \
                    "44100"  "44.1 kHz (CD)"       "$([ "$(pa_effective default-sample-rate)" = "44100"  ] && echo on || echo off)" \
                    "48000"  "48 kHz (standard)"   "$([ "$(pa_effective default-sample-rate)" = "48000"  ] && echo on || echo off)" \
                    "96000"  "96 kHz (studio)"     "$([ "$(pa_effective default-sample-rate)" = "96000"  ] && echo on || echo off)" \
                    "192000" "192 kHz (high-res)"  "$([ "$(pa_effective default-sample-rate)" = "192000" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                pa_set "$_target" "default-sample-rate" "$_new"
                ;;
            format)
                _new=$(bsddialog --backtitle "$_BACKTITLE" --title "Sample Format" \
                    --radiolist "Select sample format:" 14 50 5 \
                    "s16le"   "16-bit signed LE (CD)"     "$([ "$(pa_effective default-sample-format)" = "s16le"   ] && echo on || echo off)" \
                    "s24le"   "24-bit signed LE (studio)" "$([ "$(pa_effective default-sample-format)" = "s24le"   ] && echo on || echo off)" \
                    "s32le"   "32-bit signed LE"          "$([ "$(pa_effective default-sample-format)" = "s32le"   ] && echo on || echo off)" \
                    "float32le" "32-bit float"            "$([ "$(pa_effective default-sample-format)" = "float32le" ] && echo on || echo off)" \
                    3>&1 1>&2 2>&3) || continue
                pa_set "$_target" "default-sample-format" "$_new"
                ;;
            resample)
                _new=$(bsddialog --backtitle "$_BACKTITLE" --title "Resample Method" \
                    --radiolist "Select resampler:" 16 55 7 \
                    "speex-float-1"  "Speex float (fast, low quality)"  "off" \
                    "speex-float-5"  "Speex float (balanced)"           "off" \
                    "speex-float-10" "Speex float (best)"               "off" \
                    "soxr-mq"        "SoX medium quality"               "off" \
                    "soxr-hq"        "SoX high quality"                 "off" \
                    "soxr-vhq"       "SoX very high quality"            "$([ "$(pa_effective resample-method)" = "soxr-vhq" ] && echo on || echo off)" \
                    "trivial"        "Trivial (nearest sample, no CPU)" "off" \
                    3>&1 1>&2 2>&3) || continue
                pa_set "$_target" "resample-method" "$_new"
                ;;
            rt)
                _cur=$(pa_effective "realtime-scheduling")
                if [ "$_cur" = "yes" ]; then
                    pa_set "$_target" "realtime-scheduling" "no"
                else
                    pa_set "$_target" "realtime-scheduling" "yes"
                fi
                ;;
            rtprio)
                _cur=$(pa_effective "realtime-priority")
                [ -z "$_cur" ] && _cur="5"
                _new=$(bsddialog --backtitle "$_BACKTITLE" --title "Realtime Priority" \
                    --rangebox "rtprio value (higher = more priority):" 8 50 0 9 "$_cur" \
                    3>&1 1>&2 2>&3) || continue
                pa_set "$_target" "realtime-priority" "$_new"
                ;;
            autospawn)
                _cur=$(pa_effective "autospawn")
                if [ "$_cur" = "no" ]; then
                    pa_set "$_target" "autospawn" "yes"
                else
                    pa_set "$_target" "autospawn" "no"
                fi
                ;;
            restart)
                pulseaudio --kill 2>/dev/null; sleep 1
                pulseaudio --start 2>/dev/null
                _msg="Restarted."
                pulseaudio --check 2>/dev/null || _msg="Failed to restart."
                bsddialog --backtitle "$_BACKTITLE" --title "Restart" \
                    --msgbox "$_msg" 7 40
                ;;
        esac
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$MODE" = "tui" ]; then
    tui_mode
else
    cli_mode
fi
