#!/bin/sh
# audio-toolkit.sh — Main TUI launcher for the FreeBSD audio toolkit
# Provides a bsddialog menu to access all configuration scripts.
#
# Usage:
#   ./audio-toolkit.sh           — Launch main menu
#   ./audio-toolkit.sh --help    — Show help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKTITLE="FreeBSD Audio Toolkit — $(uname -r)"

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v bsddialog >/dev/null 2>&1; then
    printf "Error: bsddialog not found. Install it or use FreeBSD 14+.\n" >&2
    exit 1
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
audio-toolkit.sh — FreeBSD Audio Toolkit launcher

Main TUI menu providing access to all audio configuration scripts:

  Layer 0: Kernel & Drivers
    • HDA pin hints          (configure-hda-hints.sh)
    • Sysctl audio tuning    (configure-sysctl-audio.sh)

  Layer 1: virtual_oss
    • Setup virtual_oss      (setup-virtual-oss.sh)
    • Configure virtual_oss  (configure-virtual-oss.sh)
    • Check virtual_oss      (check-virtual-oss.sh)
    • Switch audio output    (switch-audio-output.sh)
    • Suspend/resume safety  (configure-suspend-audio.sh)
    • devfs device isolation (configure-devfs-audio.sh)
    • USB hotplug (devd)     (configure-devd-audio.sh)

  Layer 2: Sound Servers
    • PulseAudio             (configure-pulseaudio.sh)
    • ALSA                   (configure-alsa.sh)
    • JACK                   (configure-jack.sh)

  Layer 3: PipeWire
    • PipeWire               (configure-pipewire.sh)

  Diagnostics
    • Diagnose sound         (diagnose-sound.sh)

Requires: bsddialog (FreeBSD 14+ base or pkg install bsddialog)
EOF
    exit 0
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

# Run a script, clearing the screen first
run_script() {
    _script=$1
    shift
    _path="${SCRIPT_DIR}/${_script}"
    if [ ! -x "$_path" ]; then
        bsddialog --backtitle "$BACKTITLE" --title "Error" \
            --msgbox "Script not found or not executable:\n${_script}" 8 55
        return
    fi
    clear
    "$_path" "$@"
    printf "\n[Press Enter to return to menu]"
    read -r _
}

# Run a TUI script (stays in bsddialog, no clear needed)
run_tui() {
    _script=$1
    shift
    _path="${SCRIPT_DIR}/${_script}"
    if [ ! -x "$_path" ]; then
        bsddialog --backtitle "$BACKTITLE" --title "Error" \
            --msgbox "Script not found or not executable:\n${_script}" 8 55
        return
    fi
    "$_path" "$@"
}

# ── Quick status ────────────────────────────────────────────────────────────
quick_status() {
    _voss="✗"
    pgrep -x virtual_oss >/dev/null 2>&1 && _voss="✓"
    _pa="✗"
    pgrep -x pulseaudio >/dev/null 2>&1 && _pa="✓" || (command -v pulseaudio >/dev/null 2>&1 && pulseaudio --check 2>/dev/null && _pa="✓")
    _jack="✗"
    pgrep -x jackd >/dev/null 2>&1 && _jack="✓"
    _pw="✗"
    pgrep -x pipewire >/dev/null 2>&1 && _pw="✓"
    printf "virtual_oss:%s  pulse:%s  jack:%s  pipewire:%s" "$_voss" "$_pa" "$_jack" "$_pw"
}

# ── Main menu ──────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        _status=$(quick_status)

        _choice=$(bsddialog \
            --backtitle "$BACKTITLE" \
            --title "Audio Toolkit" \
            --ok-label "Open" \
            --cancel-label "Exit" \
            --menu "${_status}" 28 72 18 \
            ""           "─── Layer 0: Kernel & Drivers ───" \
            hda          "HDA Pin Hints (configure-hda-hints.sh)" \
            sysctl       "Sysctl Audio Tuning (configure-sysctl-audio.sh)" \
            ""           "" \
            ""           "─── Layer 1: virtual_oss ───" \
            setup        "Setup virtual_oss (setup-virtual-oss.sh)" \
            voss-cfg     "Configure virtual_oss (configure-virtual-oss.sh)" \
            voss-chk     "Check virtual_oss (check-virtual-oss.sh)" \
            switch       "Switch Audio Output (switch-audio-output.sh)" \
            suspend      "Suspend/Resume Safety (configure-suspend-audio.sh)" \
            devfs        "devfs Device Isolation (configure-devfs-audio.sh)" \
            devd         "USB Hotplug / devd (configure-devd-audio.sh)" \
            ""           "" \
            ""           "─── Layer 2: Sound Servers ───" \
            pulse        "PulseAudio (configure-pulseaudio.sh)" \
            alsa         "ALSA (configure-alsa.sh)" \
            jack         "JACK (configure-jack.sh)" \
            ""           "" \
            ""           "─── Layer 3: PipeWire ───" \
            pipewire     "PipeWire (configure-pipewire.sh)" \
            ""           "" \
            ""           "─── Diagnostics ───" \
            diag         "Diagnose Sound (diagnose-sound.sh)" \
            3>&1 1>&2 2>&3) || return

        case "$_choice" in
            hda)        run_tui  configure-hda-hints.sh ;;
            sysctl)     run_tui  configure-sysctl-audio.sh ;;
            setup)      run_tui  setup-virtual-oss.sh ;;
            voss-cfg)   run_tui  configure-virtual-oss.sh ;;
            voss-chk)   run_tui  check-virtual-oss.sh ;;
            switch)     run_tui  switch-audio-output.sh ;;
            suspend)    _suspend_menu ;;
            devfs)      _cli_menu "configure-devfs-audio.sh" "devfs Audio Rules" ;;
            devd)       _cli_menu "configure-devd-audio.sh" "USB Hotplug (devd)" ;;
            pulse)      _dual_menu "configure-pulseaudio.sh" "PulseAudio" ;;
            alsa)       _dual_menu "configure-alsa.sh" "ALSA" ;;
            jack)       _dual_menu "configure-jack.sh" "JACK" ;;
            pipewire)   _dual_menu "configure-pipewire.sh" "PipeWire" ;;
            diag)       run_script diagnose-sound.sh ;;
            "")         ;; # separator, ignore
        esac
    done
}

# ── Sub-menu for dual-mode scripts (CLI + TUI) ─────────────────────────────
_dual_menu() {
    _script=$1
    _name=$2

    _choice=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "$_name" \
        --menu "Select mode for ${_name}:" 14 60 5 \
        tui      "Interactive settings editor" \
        check    "Check and fix (interactive)" \
        auto     "Auto-fix all issues" \
        dryrun   "Check only (no changes)" \
        3>&1 1>&2 2>&3) || return

    case "$_choice" in
        tui)    run_tui    "$_script" --tui ;;
        check)  run_script "$_script" ;;
        auto)   run_script "$_script" --auto ;;
        dryrun) run_script "$_script" --dry-run ;;
    esac
}

# ── Sub-menu for CLI-only scripts ──────────────────────────────────────────
_cli_menu() {
    _script=$1
    _name=$2

    _choice=$(bsddialog \
        --backtitle "$BACKTITLE" \
        --title "$_name" \
        --menu "Select mode:" 12 55 3 \
        check    "Check and fix (interactive)" \
        auto     "Auto-fix all issues" \
        dryrun   "Check only (no changes)" \
        3>&1 1>&2 2>&3) || return

    case "$_choice" in
        check)  run_script "$_script" ;;
        auto)   run_script "$_script" --auto ;;
        dryrun) run_script "$_script" --dry-run ;;
    esac
}

# ── Sub-menu for suspend (TUI only) ───────────────────────────────────────
_suspend_menu() {
    run_tui configure-suspend-audio.sh
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

main_menu
