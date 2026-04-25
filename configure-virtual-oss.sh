#!/bin/sh
# configure-virtual-oss.sh — TUI for configuring virtual_oss via bsddialog
# Provides a full graphical TUI to create, edit, and manage virtual_oss
# configurations in /etc/rc.conf.
#
# Usage:
#   ./configure-virtual-oss.sh           — Launch TUI
#   ./configure-virtual-oss.sh --help    — Show help

set -u

BACKTITLE="virtual_oss Configuration — FreeBSD $(uname -r)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="${SCRIPT_DIR}/.voss_tmp"

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v bsddialog >/dev/null 2>&1; then
    printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
    exit 1
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
configure-virtual-oss.sh — TUI for virtual_oss configuration

Provides a bsddialog-based interface to:
  • Create new virtual_oss configurations
  • Edit existing configurations (backend, rate, depth, buffer, etc.)
  • Manage multiple named configs (dsp, dummy, etc.)
  • Toggle features (resampling, recording, real-time priority)
  • Preview and apply changes to /etc/rc.conf
  • Start/restart the service

Requires: bsddialog, sysrc. Run as root to apply changes.
EOF
    exit 0
fi

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Helpers ─────────────────────────────────────────────────────────────────

# Discover available PCM devices as "tag description" pairs for bsddialog
pcm_device_items() {
    _units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)
    for _u in $_units; do
        _desc=$(sysctl -n "dev.pcm.${_u}.%desc" 2>/dev/null || echo "(unknown)")
        _mode=$(sysctl -n "dev.pcm.${_u}.mode" 2>/dev/null || echo "0")
        _caps=""
        case "$_mode" in
            7) _caps="play/rec" ;;
            3) _caps="play" ;;
            6) _caps="play/rec" ;;
            2) _caps="play" ;;
            4) _caps="rec" ;;
            *) _caps="mode=${_mode}" ;;
        esac
        printf "/dev/dsp%s\t[%s] %s\n" "$_u" "$_caps" "$_desc"
    done
    printf "/dev/null\t[dummy] Null backend (testing/jails)\n"
}

# Parse a virtual_oss flag value from a config string
parse_flag() {
    _cfg=$1
    _flag=$2
    echo "$_cfg" | grep -oE "${_flag} [^ ]+" | awk '{print $2}' | head -1
}

# Check if a flag is present (no-argument flags like -S, -T)
has_flag() {
    _cfg=$1
    _flag=$2
    echo "$_cfg" | grep -qw -- "$_flag"
}

# ── Main menu ──────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        # Gather current state
        _vo_enable=$(sysrc -n virtual_oss_enable 2>/dev/null || echo "NO")
        _vo_configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "")
        _vo_running=$(pgrep -x virtual_oss >/dev/null 2>&1 && echo "Running" || echo "Stopped")

        _status="Service: ${_vo_enable} | Process: ${_vo_running}"
        [ -n "$_vo_configs" ] && _status="${_status} | Configs: ${_vo_configs}"

        _items=""
        # List existing configs as edit options
        if [ -n "$_vo_configs" ]; then
            for _cfg in $_vo_configs; do
                _val=$(sysrc -n "virtual_oss_${_cfg}" 2>/dev/null || echo "(not defined)")
                _back=$(parse_flag "$_val" "-f")
                [ -z "$_back" ] && _back=$(parse_flag "$_val" "-P")
                [ -z "$_back" ] && _back="?"
                _items="${_items} edit_${_cfg} \"Edit '${_cfg}' config (backend: ${_back})\""
            done
        fi

        _choice=$(eval bsddialog \
            --backtitle "\"${BACKTITLE}\"" \
            --title "\"virtual_oss Configuration Manager\"" \
            --ok-label "\"Select\"" \
            --cancel-label "\"Exit\"" \
            --menu "\"${_status}\"" 22 72 12 \
            new       "\"Create a new virtual_oss configuration\"" \
            ${_items} \
            enable    "\"Toggle service enable (currently: ${_vo_enable})\"" \
            service   "\"Start / Restart / Stop service\"" \
            preview   "\"Preview current /etc/rc.conf entries\"" \
            sndstat   "\"Show /dev/sndstat (live audio devices)\"" \
            3>&1 1>&2 2>&3) || return

        case "$_choice" in
            new)       new_config ;;
            enable)    toggle_enable ;;
            service)   service_menu ;;
            preview)   preview_config ;;
            sndstat)   show_sndstat ;;
            edit_*)    edit_config "$(echo "$_choice" | sed 's/edit_//')" ;;
        esac
    done
}

# ── Create new config ─────────────────────────────────────────────────────
new_config() {
    # 1. Config name
    _name=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "New Configuration" \
        --inputbox "Enter a name for this config (e.g. 'dsp', 'headset', 'usb'):" \
        8 60 "dsp" \
        3>&1 1>&2 2>&3) || return

    # Validate name
    case "$_name" in
        *[!a-zA-Z0-9_]*|"")
            bsddialog --backtitle "$BACKTITLE" --title "Error" \
                --msgbox "Invalid name. Use only letters, numbers, and underscores." 7 50
            return
            ;;
    esac

    # Check if exists
    _existing=$(sysrc -n "virtual_oss_${_name}" 2>/dev/null || true)
    if [ -n "$_existing" ]; then
        bsddialog --backtitle "$BACKTITLE" --title "Exists" \
            --yesno "Config '${_name}' already exists. Edit it instead?" 7 50 || return
        edit_config "$_name"
        return
    fi

    # Build config via the editor
    _build_config "$_name" ""
}

# ── Edit existing config ─────────────────────────────────────────────────
edit_config() {
    _name=$1
    _current=$(sysrc -n "virtual_oss_${_name}" 2>/dev/null || echo "")

    while true; do
        # Parse current values for display
        _back=$(parse_flag "$_current" "-f")
        [ -z "$_back" ] && _back=$(parse_flag "$_current" "-P")
        [ -z "$_back" ] && _back="/dev/dsp0"
        _rec_back=$(parse_flag "$_current" "-R")  
        _rate=$(parse_flag "$_current" "-r")
        [ -z "$_rate" ] && _rate="48000"
        _bits=$(parse_flag "$_current" "-b")
        [ -z "$_bits" ] && _bits="16"
        _buf=$(parse_flag "$_current" "-s")
        [ -z "$_buf" ] && _buf="1024"
        _chans=$(echo "$_current" | grep -oE '\-c [0-9]+' | tail -1 | awk '{print $2}')
        [ -z "$_chans" ] && _chans="2"
        _vchans=$(parse_flag "$_current" "-C")
        [ -z "$_vchans" ] && _vchans="16"
        _prio=$(parse_flag "$_current" "-i")
        [ -z "$_prio" ] && _prio="8"
        _vdev=$(parse_flag "$_current" "-d")
        [ -z "$_vdev" ] && _vdev="$_name"
        _ctl=$(parse_flag "$_current" "-t")
        [ -z "$_ctl" ] && _ctl="${_name}.ctl"
        _wav=$(parse_flag "$_current" "-w")
        _resample="off"
        has_flag "$_current" "-S" && _resample="on"
        _sndstat_reg="off"
        has_flag "$_current" "-T" && _sndstat_reg="on"

        _choice=$(bsddialog \
            --backtitle "$BACKTITLE" \
            --title "Edit '${_name}' Configuration" \
            --ok-label "Edit" \
            --cancel-label "Back" \
            --extra-button --extra-label "Delete" \
            --menu "Current config for '${_name}':" 24 72 14 \
            backend   "Backend device: ${_back}" \
            rate      "Sample rate: ${_rate} Hz" \
            bits      "Bit depth: ${_bits}-bit" \
            buffer    "Buffer size: ${_buf} samples" \
            channels  "Channels: ${_chans}" \
            vchans    "Virtual channel capacity: ${_vchans}" \
            priority  "Real-time priority: ${_prio}" \
            vdev      "Virtual device name: /dev/${_vdev}" \
            ctl       "Control socket: /dev/${_ctl}" \
            wav       "WAV recording: ${_wav:-disabled}" \
            features  "Feature toggles (resample, sndstat)..." \
            apply     ">>> Apply changes to /etc/rc.conf <<<" \
            3>&1 1>&2 2>&3)
        _retval=$?

        # Extra button = Delete
        if [ $_retval -eq 3 ]; then
            _delete_config "$_name"
            return
        fi
        # Cancel = Back
        [ $_retval -ne 0 ] && return

        case "$_choice" in
            backend)  _current=$(_edit_backend "$_current") ;;
            rate)     _current=$(_edit_rate "$_current" "$_rate") ;;
            bits)     _current=$(_edit_bits "$_current" "$_bits") ;;
            buffer)   _current=$(_edit_buffer "$_current" "$_buf") ;;
            channels) _current=$(_edit_channels "$_current" "$_chans") ;;
            vchans)   _current=$(_edit_vchans "$_current" "$_vchans") ;;
            priority) _current=$(_edit_priority "$_current" "$_prio") ;;
            vdev)     _current=$(_edit_vdev "$_current" "$_vdev") ;;
            ctl)      _current=$(_edit_ctl "$_current" "$_ctl") ;;
            wav)      _current=$(_edit_wav "$_current" "$_wav") ;;
            features) _current=$(_edit_features "$_current") ;;
            apply)    _apply_config "$_name" "$_current"; return ;;
        esac
    done
}

# ── Build config from scratch ────────────────────────────────────────────
_build_config() {
    _name=$1
    _cfg="$2"

    # Backend
    _back=$(_select_backend "/dev/dsp0") || return
    _cfg="-f ${_back}"

    # Use the full editor from here
    # Set sensible defaults
    _cfg="-S -i 8 -C 16 -c 2 -r 48000 -b 16 -s 1024 ${_cfg} -c 2 -d ${_name} -t ${_name}.ctl"

    edit_config_with_initial "$_name" "$_cfg"
}

# Edit with an initial config (for new configs)
edit_config_with_initial() {
    _name=$1
    _initial=$2

    # Temporarily set it so edit_config can read it
    # We'll use a variable instead of sysrc for now
    _current="$_initial"

    # Go directly to apply
    bsddialog --backtitle "$BACKTITLE" --title "New Config '${_name}'" \
        --yesno "Generated default config:\n\n${_current}\n\nEdit before applying?" 12 72

    if [ $? -eq 0 ]; then
        # Save temporarily so edit_config can find it
        sysrc "virtual_oss_${_name}=${_current}" >/dev/null 2>&1
        _configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "")
        case " $_configs " in
            *" ${_name} "*) ;; # Already listed
            *) sysrc virtual_oss_configs="${_configs} ${_name}" >/dev/null 2>&1 ;;
        esac
        edit_config "$_name"
    else
        _apply_config "$_name" "$_current"
    fi
}

# ── Select backend device ────────────────────────────────────────────────
_select_backend() {
    _default=$1

    # Build device list
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
            7) _caps="play/rec" ;;
            6) _caps="play/rec" ;;
            3) _caps="play" ;;
            2) _caps="play" ;;
            4) _caps="rec" ;;
            *) _caps="?" ;;
        esac
        _items="${_items} /dev/dsp${_u} \"[${_caps}] ${_desc}\""
    done
    _items="${_items} /dev/null \"[dummy] Null backend (testing)\""
    _items="${_items} split \"[advanced] Separate playback/record devices\""

    _sel=$(eval bsddialog \
        --backtitle "\"${BACKTITLE}\"" \
        --title "\"Select Backend Device\"" \
        --default-item "\"${_default}\"" \
        --menu "\"Physical audio device to use as backend:\"" 18 72 10 \
        ${_items} \
        3>&1 1>&2 2>&3) || return 1

    if [ "$_sel" = "split" ]; then
        _play=$(eval bsddialog \
            --backtitle "\"${BACKTITLE}\"" \
            --title "\"Playback Device\"" \
            --menu "\"Select playback backend:\"" 16 72 8 \
            ${_items} \
            3>&1 1>&2 2>&3) || return 1
        _rec=$(eval bsddialog \
            --backtitle "\"${BACKTITLE}\"" \
            --title "\"Recording Device\"" \
            --menu "\"Select recording backend:\"" 16 72 8 \
            ${_items} \
            3>&1 1>&2 2>&3) || return 1
        echo "SPLIT:${_play}:${_rec}"
    else
        echo "$_sel"
    fi
}

# ── Individual field editors ─────────────────────────────────────────────

_edit_backend() {
    _cfg=$1
    _old_back=$(parse_flag "$_cfg" "-f")
    [ -z "$_old_back" ] && _old_back=$(parse_flag "$_cfg" "-P")
    [ -z "$_old_back" ] && _old_back="/dev/dsp0"

    _new=$(_select_backend "$_old_back") || { echo "$_cfg"; return; }

    case "$_new" in
        SPLIT:*)
            _play=$(echo "$_new" | cut -d: -f2)
            _rec=$(echo "$_new" | cut -d: -f3)
            # Remove old -f, -P, -R
            _cfg=$(echo "$_cfg" | sed 's/-f [^ ]*//g; s/-P [^ ]*//g; s/-R [^ ]*//g' | tr -s ' ')
            _cfg="-P ${_play} -R ${_rec} ${_cfg}"
            ;;
        *)
            # Remove old -f, -P, -R and add new -f
            _cfg=$(echo "$_cfg" | sed 's/-f [^ ]*//g; s/-P [^ ]*//g; s/-R [^ ]*//g' | tr -s ' ')
            _cfg="-f ${_new} ${_cfg}"
            ;;
    esac
    echo "$_cfg"
}

_edit_rate() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Sample Rate" \
        --radiolist "Select sample rate (Hz):" 14 50 6 \
        "44100"  "44.1 kHz (CD quality)"    "$([ "$_old" = "44100" ]  && echo on || echo off)" \
        "48000"  "48 kHz (standard)"         "$([ "$_old" = "48000" ]  && echo on || echo off)" \
        "88200"  "88.2 kHz (2× CD)"         "$([ "$_old" = "88200" ]  && echo on || echo off)" \
        "96000"  "96 kHz (studio)"           "$([ "$_old" = "96000" ]  && echo on || echo off)" \
        "192000" "192 kHz (high-res)"        "$([ "$_old" = "192000" ] && echo on || echo off)" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    echo "$_cfg" | sed "s/-r [0-9]*/-r ${_new}/"
}

_edit_bits() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Bit Depth" \
        --radiolist "Select bit depth:" 12 50 4 \
        "8"  "8-bit (low quality)"    "$([ "$_old" = "8" ]  && echo on || echo off)" \
        "16" "16-bit (CD quality)"    "$([ "$_old" = "16" ] && echo on || echo off)" \
        "24" "24-bit (studio)"        "$([ "$_old" = "24" ] && echo on || echo off)" \
        "32" "32-bit (maximum)"       "$([ "$_old" = "32" ] && echo on || echo off)" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    echo "$_cfg" | sed "s/-b [0-9]*/-b ${_new}/"
}

_edit_buffer() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Buffer Size" \
        --radiolist "Buffer size in samples (lower = less latency, more CPU):" 16 60 8 \
        "128"  "128 — Ultra low latency (may glitch)"  "$([ "$_old" = "128" ]  && echo on || echo off)" \
        "256"  "256 — Very low latency"                "$([ "$_old" = "256" ]  && echo on || echo off)" \
        "512"  "512 — Low latency"                     "$([ "$_old" = "512" ]  && echo on || echo off)" \
        "768"  "768 — Balanced"                        "$([ "$_old" = "768" ]  && echo on || echo off)" \
        "1024" "1024 — Safe default"                   "$([ "$_old" = "1024" ] && echo on || echo off)" \
        "2048" "2048 — High buffer"                    "$([ "$_old" = "2048" ] && echo on || echo off)" \
        "4096" "4096 — Maximum stability"              "$([ "$_old" = "4096" ] && echo on || echo off)" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    echo "$_cfg" | sed "s/-s [0-9]*/-s ${_new}/"
}

_edit_channels() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Channel Count" \
        --radiolist "Output channel count:" 12 50 4 \
        "1" "Mono"          "$([ "$_old" = "1" ] && echo on || echo off)" \
        "2" "Stereo"        "$([ "$_old" = "2" ] && echo on || echo off)" \
        "6" "5.1 Surround"  "$([ "$_old" = "6" ] && echo on || echo off)" \
        "8" "7.1 Surround"  "$([ "$_old" = "8" ] && echo on || echo off)" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    # Replace the LAST -c (output channels), keep the first -c if it's before -f
    echo "$_cfg" | sed "s/\\(.*\\)-c [0-9]*/\\1-c ${_new}/"
}

_edit_vchans() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Virtual Channel Capacity" \
        --radiolist "Max number of virtual channels (-C).\nHigher = more simultaneous apps, more memory:" 15 60 6 \
        "2"  "2 — Minimal"              "$([ "$_old" = "2" ]  && echo on || echo off)" \
        "4"  "4 — Light use"            "$([ "$_old" = "4" ]  && echo on || echo off)" \
        "8"  "8 — Desktop"              "$([ "$_old" = "8" ]  && echo on || echo off)" \
        "16" "16 — Heavy multitasking"  "$([ "$_old" = "16" ] && echo on || echo off)" \
        "18" "18 — Maximum"             "$([ "$_old" = "18" ] && echo on || echo off)" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    echo "$_cfg" | sed "s/-C [0-9]*/-C ${_new}/"
}

_edit_priority() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Real-Time Priority" \
        --rangebox "rtprio value (higher = more priority, 0 = no RT):" \
        8 55 0 31 "$_old" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }

    if echo "$_cfg" | grep -q '\-i [0-9]'; then
        echo "$_cfg" | sed "s/-i [0-9]*/-i ${_new}/"
    else
        echo "-i ${_new} ${_cfg}"
    fi
}

_edit_vdev() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Virtual Device Name" \
        --inputbox "Name for the virtual device (creates /dev/<name>):" \
        8 55 "$_old" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
    echo "$_cfg" | sed "s/-d [^ ]*/-d ${_new}/"
}

_edit_ctl() {
    _cfg=$1
    _old=$2
    _new=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Control Socket" \
        --inputbox "Name for the control socket (creates /dev/<name>).\nUsed by virtual_oss_cmd for runtime switching:" \
        9 60 "$_old" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }

    if echo "$_cfg" | grep -q '\-t '; then
        echo "$_cfg" | sed "s/-t [^ ]*/-t ${_new}/"
    else
        echo "${_cfg} -t ${_new}"
    fi
}

_edit_wav() {
    _cfg=$1
    _old=$2

    if [ -n "$_old" ]; then
        bsddialog \
            --backtitle "$BACKTITLE" \
            --title "WAV Recording" \
            --yesno "WAV recording is currently enabled (${_old}).\n\nDisable it?" 8 50
        if [ $? -eq 0 ]; then
            echo "$_cfg" | sed 's/ *-w [^ ]*//'
        else
            _new=$(bsddialog \
                --backtitle "$BACKTITLE" \
                --title "WAV Recording" \
                --inputbox "WAV recording device name (creates /dev/<name>):" \
                8 55 "$_old" \
                3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
            echo "$_cfg" | sed "s/-w [^ ]*/-w ${_new}/"
        fi
    else
        bsddialog \
            --backtitle "$BACKTITLE" \
            --title "WAV Recording" \
            --yesno "Enable WAV recording device?\nCreates a device that outputs audio in WAV format." 8 55
        if [ $? -eq 0 ]; then
            _new=$(bsddialog \
                --backtitle "$BACKTITLE" \
                --title "WAV Recording" \
                --inputbox "WAV device name:" 8 50 "dsp.wav" \
                3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }
            echo "${_cfg} -w ${_new}"
        else
            echo "$_cfg"
        fi
    fi
}

_edit_features() {
    _cfg=$1

    _resample="off"
    has_flag "$_cfg" "-S" && _resample="on"
    _sndstat="off"
    has_flag "$_cfg" "-T" && _sndstat="on"

    _selections=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Feature Toggles" \
        --separate-output \
        --checklist "Toggle optional features:" 12 60 4 \
        "resample" "Automatic sample rate resampling (-S)"       "$_resample" \
        "sndstat"  "Register in /dev/sndstat (-T /dev/sndstat)"  "$_sndstat" \
        3>&1 1>&2 2>&3) || { echo "$_cfg"; return; }

    # Remove existing flags
    _cfg=$(echo "$_cfg" | sed 's/ *-S//g; s/ *-T [^ ]*//g' | tr -s ' ')

    # Add back selected ones
    echo "$_selections" | grep -q "resample" && _cfg="-S ${_cfg}"
    echo "$_selections" | grep -q "sndstat" && _cfg="-T /dev/sndstat ${_cfg}"

    echo "$_cfg"
}

# ── Apply configuration ─────────────────────────────────────────────────
_apply_config() {
    _name=$1
    _cfg=$2

    # Clean up whitespace
    _cfg=$(echo "$_cfg" | tr -s ' ' | sed 's/^ //;s/ $//')

    # Preview
    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Apply Configuration" \
        --yes-label "Apply" \
        --no-label "Cancel" \
        --yesno "Config '${_name}' will be set to:\n\n${_cfg}\n\nThis writes to /etc/rc.conf via sysrc." \
        12 72 || return

    # Add to configs list if not present
    _configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "")
    case " $_configs " in
        *" ${_name} "*) ;; # Already listed
        *)
            if [ -z "$_configs" ]; then
                sysrc virtual_oss_configs="${_name}" >/dev/null 2>&1
            else
                sysrc virtual_oss_configs="${_configs} ${_name}" >/dev/null 2>&1
            fi
            ;;
    esac

    # Set the config
    if sysrc "virtual_oss_${_name}=${_cfg}" >/dev/null 2>&1; then
        bsddialog \
            --backtitle "$BACKTITLE" \
            --title "Success" \
            --yesno "Configuration saved.\n\nRestart virtual_oss service now?" 8 50

        if [ $? -eq 0 ]; then
            _restart_output=$(service virtual_oss restart 2>&1 || echo "Failed to restart")
            bsddialog --backtitle "$BACKTITLE" --title "Service Restart" \
                --msgbox "${_restart_output}" 10 60
        fi
    else
        bsddialog --backtitle "$BACKTITLE" --title "Error" \
            --msgbox "Failed to write to /etc/rc.conf.\nAre you running as root?" 7 50
    fi
}

# ── Delete configuration ────────────────────────────────────────────────
_delete_config() {
    _name=$1

    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Delete Configuration" \
        --default-no \
        --yesno "Delete config '${_name}'?\n\nThis removes virtual_oss_${_name} from /etc/rc.conf." \
        8 55 || return

    # Remove from configs list
    _configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "")
    _new_configs=$(echo "$_configs" | sed "s/ *${_name}//g" | tr -s ' ' | sed 's/^ //;s/ $//')
    sysrc virtual_oss_configs="${_new_configs}" >/dev/null 2>&1

    # Remove the config variable itself
    sysrc -x "virtual_oss_${_name}" >/dev/null 2>&1

    bsddialog --backtitle "$BACKTITLE" --title "Deleted" \
        --msgbox "Config '${_name}' removed from /etc/rc.conf." 7 50
}

# ── Toggle service enable ───────────────────────────────────────────────
toggle_enable() {
    _current=$(sysrc -n virtual_oss_enable 2>/dev/null || echo "NO")
    case "$_current" in
        YES|yes)
            sysrc virtual_oss_enable=NO >/dev/null 2>&1
            bsddialog --backtitle "$BACKTITLE" --title "Disabled" \
                --msgbox "virtual_oss_enable set to NO.\nService will not start on boot." 7 50
            ;;
        *)
            sysrc virtual_oss_enable=YES >/dev/null 2>&1
            bsddialog --backtitle "$BACKTITLE" --title "Enabled" \
                --msgbox "virtual_oss_enable set to YES.\nService will start on boot." 7 50
            ;;
    esac
}

# ── Service control ─────────────────────────────────────────────────────
service_menu() {
    _running=$(pgrep -x virtual_oss >/dev/null 2>&1 && echo "Running" || echo "Stopped")

    _choice=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Service Control (currently: ${_running})" \
        --menu "Select action:" 12 50 4 \
        start   "Start virtual_oss" \
        stop    "Stop virtual_oss" \
        restart "Restart virtual_oss" \
        status  "Show service status" \
        3>&1 1>&2 2>&3) || return

    case "$_choice" in
        start|stop|restart)
            _output=$(service virtual_oss "$_choice" 2>&1 || echo "(command failed)")
            bsddialog --backtitle "$BACKTITLE" --title "Service ${_choice}" \
                --msgbox "${_output:-Done.}" 8 55
            ;;
        status)
            _output=$(service virtual_oss status 2>&1 || echo "Not running")
            _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
            if [ -n "$_pid" ]; then
                _cmd=$(ps -ww -p "$_pid" -o args= 2>/dev/null || true)
                _output="${_output}\n\nPID: ${_pid}\nCommand:\n${_cmd}"
            fi
            bsddialog --backtitle "$BACKTITLE" --title "Service Status" \
                --msgbox "$_output" 14 72
            ;;
    esac
}

# ── Preview configs ─────────────────────────────────────────────────────
preview_config() {
    _preview=$(sysrc -a 2>/dev/null | grep virtual_oss || echo "(none)")

    # Write to temp file for textbox
    _tmpfile="${TMP_DIR}/preview.txt"
    printf "Current /etc/rc.conf virtual_oss entries:\n" > "$_tmpfile"
    printf "==========================================\n\n" >> "$_tmpfile"
    printf "%s\n" "$_preview" >> "$_tmpfile"

    printf "\n\nRunning process:\n" >> "$_tmpfile"
    printf "================\n\n" >> "$_tmpfile"
    _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_pid" ]; then
        ps -ww -p "$_pid" -o args= >> "$_tmpfile" 2>/dev/null
    else
        printf "(not running)\n" >> "$_tmpfile"
    fi

    bsddialog --backtitle "$BACKTITLE" --title "Configuration Preview" \
        --textbox "$_tmpfile" 20 75
}

# ── Show sndstat ────────────────────────────────────────────────────────
show_sndstat() {
    _tmpfile="${TMP_DIR}/sndstat.txt"
    printf "Audio Devices (/dev/sndstat):\n" > "$_tmpfile"
    printf "=============================\n\n" >> "$_tmpfile"
    cat /dev/sndstat >> "$_tmpfile" 2>/dev/null || printf "(not readable)\n" >> "$_tmpfile"

    printf "\n\nOSS Device Nodes:\n" >> "$_tmpfile"
    printf "=================\n\n" >> "$_tmpfile"
    ls -la /dev/dsp* /dev/mixer* 2>/dev/null >> "$_tmpfile" || printf "(none)\n" >> "$_tmpfile"

    bsddialog --backtitle "$BACKTITLE" --title "/dev/sndstat" \
        --textbox "$_tmpfile" 22 75
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Root check
if [ "$(id -u)" -ne 0 ]; then
    bsddialog \
        --backtitle "$BACKTITLE" \
        --title "Warning" \
        --yesno "Not running as root.\nChanges to /etc/rc.conf and service control may fail.\n\nContinue anyway?" \
        9 55 || exit 0
fi

main_menu
