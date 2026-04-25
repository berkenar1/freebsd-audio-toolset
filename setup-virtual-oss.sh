#!/bin/sh
# setup-virtual-oss.sh — virtual_oss Setup Wizard & Fixer
# Walks through every layer of virtual_oss configuration, detects issues,
# and offers step-by-step fixes. Designed to bring a FreeBSD system from
# zero to a fully working virtual_oss setup.
#
# Usage:
#   ./setup-virtual-oss.sh              — Interactive setup wizard
#   ./setup-virtual-oss.sh --auto       — Auto-fix all with sensible defaults
#   ./setup-virtual-oss.sh --dry-run    — Show what would be changed (no writes)
#   ./setup-virtual-oss.sh --help       — Show this help

set -u

# ── Colours ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')    RST=$(printf '\033[0m')
    GRN=$(printf '\033[32m')   RED=$(printf '\033[31m')
    YLW=$(printf '\033[33m')   CYN=$(printf '\033[36m')
    MAG=$(printf '\033[35m')   DIM=$(printf '\033[2m')
    WHT=$(printf '\033[97m')   BLU=$(printf '\033[34m')
else
    BOLD='' RST='' GRN='' RED='' YLW='' CYN='' MAG='' DIM='' WHT='' BLU=''
fi

# ── Output helpers ──────────────────────────────────────────────────────────
header()  { printf "\n${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"; }
section() { printf "\n${BOLD}${CYN}══ Step %s: %s ══${RST}\n\n" "$1" "$2"; }
ok()      { printf "  ${GRN}[✓]${RST}  %s\n" "$1"; }
warn()    { printf "  ${YLW}[!]${RST}  %s\n" "$1"; }
fail()    { printf "  ${RED}[✗]${RST}  %s\n" "$1"; }
info()    { printf "  ${BOLD}[·]${RST}  %s\n" "$1"; }
dim()     { printf "       ${DIM}%s${RST}\n" "$1"; }
ask()     { printf "  ${BOLD}%s${RST}" "$1"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

FIXED=0
SKIPPED=0

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}setup-virtual-oss.sh${RST} — virtual_oss Setup Wizard & Fixer

${BOLD}Usage:${RST}
  $0             Interactive wizard — walks through each fix
  $0 --auto      Apply all fixes with sensible defaults (needs root)
  $0 --dry-run   Preview what would be changed without modifying anything
  $0 --help      Show this help

${BOLD}Steps performed:${RST}
  1. Install missing packages (virtual_oss, cuse)
  2. Configure kernel module loading (/boot/loader.conf)
  3. Enable & configure the virtual_oss service (/etc/rc.conf)
  4. Set up devfs.rules for audio device visibility
  5. Activate devfs ruleset in rc.conf
  6. Add suspend/resume hooks for clean sleep/wake
  7. Generate USB audio hotplug devd rules
  8. Verify and start the service

${BOLD}Run as root${RST} for full fix capabilities.
EOF
    exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
MODE="interactive"
case "${1:-}" in
    --auto)    MODE="auto"    ;;
    --dry-run) MODE="dry"     ;;
    --help|-h) usage          ;;
    "")        MODE="interactive" ;;
    *)         printf "${RED}Unknown option: %s${RST}\n" "$1"; usage ;;
esac

# ── Core apply helper ──────────────────────────────────────────────────────
# Usage: do_action "description" "command" [skip_confirm]
# Returns 0 if applied, 1 if skipped
do_action() {
    _desc=$1
    _cmd=$2
    _force=${3:-0}

    case "$MODE" in
        dry)
            info "${YLW}[DRY-RUN]${RST} ${_desc}"
            dim "${_cmd}"
            return 1
            ;;
        auto)
            info "Applying: ${_desc}"
            if eval "$_cmd" >/dev/null 2>&1; then
                ok "Done: ${_desc}"
                FIXED=$((FIXED + 1))
                return 0
            else
                fail "Failed: ${_desc}"
                dim "${_cmd}"
                return 1
            fi
            ;;
        interactive)
            if [ "$_force" -eq 1 ]; then
                info "Applying: ${_desc}"
                if eval "$_cmd" >/dev/null 2>&1; then
                    ok "Done: ${_desc}"
                    FIXED=$((FIXED + 1))
                    return 0
                else
                    fail "Failed: ${_desc}"
                    return 1
                fi
            fi
            printf "\n"
            info "${_desc}"
            dim "Command: ${_cmd}"
            ask "Apply? [Y/n]: "
            read -r _answer
            case "$_answer" in
                [nN]|[nN][oO])
                    dim "Skipped"
                    SKIPPED=$((SKIPPED + 1))
                    return 1
                    ;;
                *)
                    if eval "$_cmd" >/dev/null 2>&1; then
                        ok "Done"
                        FIXED=$((FIXED + 1))
                        return 0
                    else
                        fail "Command failed — may need root privileges"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac
}

# ── Discover PCM devices for display ──────────────────────────────────────
list_pcm_devices() {
    _units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)
    for _u in $_units; do
        _desc=$(sysctl -n "dev.pcm.${_u}.%desc" 2>/dev/null || echo "(unknown)")
        _mode=$(sysctl -n "dev.pcm.${_u}.mode" 2>/dev/null || echo "0")
        _caps=""
        case "$_mode" in
            7) _caps="play/rec/mix" ;;
            3) _caps="play/mix" ;;
            6) _caps="play/rec" ;;
            2) _caps="play" ;;
            4) _caps="rec" ;;
            *) _caps="mode=${_mode}" ;;
        esac
        printf "       ${BOLD}%s)${RST}  /dev/dsp%-2s  %-45s  [%s]\n" \
            "$_u" "$_u" "$_desc" "$_caps"
    done
}

# ── Detect USB audio device vendor/product IDs ───────────────────────────
detect_usb_audio() {
    # Look for uaudio devices and trace back to their ugen device
    _uaudio_devs=$(cat /var/run/dmesg.boot 2>/dev/null \
        | grep -E 'uaudio[0-9]+.*on usbus' || true)

    if [ -z "$_uaudio_devs" ]; then
        return 1
    fi

    # Find the ugen device that corresponds to uaudio
    # Trace: uaudio0 attaches on uhubX → find ugen that attaches to same addr
    _ugen=$(cat /var/run/dmesg.boot 2>/dev/null \
        | grep -B5 'uaudio0' \
        | grep -oE 'ugen[0-9]+\.[0-9]+' \
        | head -1 || true)

    if [ -z "$_ugen" ]; then
        return 1
    fi

    # Get vendor/product from sysctl
    _vendor=$(sysctl -n "dev.uaudio.0.%pnpinfo" 2>/dev/null \
        | grep -oE 'vendor=0x[0-9a-fA-F]+' | cut -d= -f2 || true)
    _product=$(sysctl -n "dev.uaudio.0.%pnpinfo" 2>/dev/null \
        | grep -oE 'product=0x[0-9a-fA-F]+' | cut -d= -f2 || true)
    _desc=$(sysctl -n "dev.uaudio.0.%desc" 2>/dev/null || echo "USB Audio")

    if [ -n "$_vendor" ]; then
        echo "${_vendor}:${_product}:${_desc}:${_ugen}"
        return 0
    fi

    return 1
}

# Find which /dev/dspN corresponds to uaudio
find_uaudio_dsp() {
    _units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)
    for _u in $_units; do
        _parent=$(sysctl -n "dev.pcm.${_u}.%parent" 2>/dev/null || true)
        case "$_parent" in
            uaudio*) echo "$_u"; return 0 ;;
        esac
    done
    return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                           SETUP STEPS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── Step 1: Packages ─────────────────────────────────────────────────────
step_packages() {
    section "1" "Package Installation"

    # virtual_oss
    if cmd_exists virtual_oss; then
        ok "virtual_oss binary available: $(which virtual_oss)"
    else
        fail "virtual_oss not found"
        if pkg info -e virtual_oss 2>/dev/null; then
            warn "Package installed but binary not in PATH"
        else
            do_action \
                "Install virtual_oss package" \
                "pkg install -y virtual_oss"
        fi
    fi

    # virtual_oss_cmd
    if cmd_exists virtual_oss_cmd; then
        ok "virtual_oss_cmd available (runtime switching)"
    else
        warn "virtual_oss_cmd not found"
        dim "Should be included with virtual_oss"
    fi

    # cuse module file
    if [ -f /boot/modules/cuse.ko ] || [ -f /boot/kernel/cuse.ko ]; then
        ok "cuse.ko kernel module available"
    else
        fail "cuse.ko not found"
        do_action \
            "Install cuse kernel module" \
            "pkg install -y cuse4bsd"
    fi
}

# ── Step 2: Kernel modules ───────────────────────────────────────────────
step_kernel_modules() {
    section "2" "Kernel Module Loading (/boot/loader.conf)"

    # Check cuse_load
    if grep -qE '^[^#]*cuse_load="YES"' /boot/loader.conf 2>/dev/null; then
        ok "cuse_load=\"YES\" in loader.conf"
    else
        warn "cuse not set to load at boot"
        do_action \
            "Add cuse_load=\"YES\" to /boot/loader.conf" \
            "printf '\\n# Required for virtual_oss userspace device nodes\\ncuse_load=\"YES\"\\n' >> /boot/loader.conf"
    fi

    # Runtime: make sure cuse is loaded now
    if kldstat -q -m cuse 2>/dev/null; then
        ok "cuse module currently loaded"
    else
        warn "cuse not loaded in running kernel"
        do_action \
            "Load cuse module now" \
            "kldload cuse"
    fi

    # Check snd_uaudio_load if USB audio present
    _usb_audio=$(cat /var/run/dmesg.boot 2>/dev/null | grep -c 'uaudio' || echo "0")
    if [ "$_usb_audio" -gt 0 ]; then
        if grep -qE '^[^#]*snd_uaudio_load="YES"' /boot/loader.conf 2>/dev/null; then
            ok "snd_uaudio_load=\"YES\" in loader.conf"
        else
            info "USB audio detected — snd_uaudio_load not explicitly set"
            dim "May be loaded via snd_driver_load or devmatch"
            if kldstat 2>/dev/null | grep -q snd_uaudio; then
                ok "snd_uaudio is loaded (via other mechanism)"
            else
                do_action \
                    "Add snd_uaudio_load=\"YES\" to /boot/loader.conf" \
                    "printf 'snd_uaudio_load=\"YES\"\\n' >> /boot/loader.conf"
            fi
        fi
    fi
}

# ── Step 3: rc.conf service configuration ────────────────────────────────
step_rc_conf() {
    section "3" "Service Configuration (/etc/rc.conf)"

    # virtual_oss_enable
    _vo_enable=$(sysrc -n virtual_oss_enable 2>/dev/null || echo "MISSING")
    case "$_vo_enable" in
        YES|yes)
            ok "virtual_oss_enable=YES"
            ;;
        *)
            warn "virtual_oss_enable is '${_vo_enable}'"
            do_action \
                "Enable virtual_oss service" \
                "sysrc virtual_oss_enable=YES"
            ;;
    esac

    # Show current config for review
    _vo_configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "MISSING")
    if [ "$_vo_configs" != "MISSING" ]; then
        ok "virtual_oss_configs=\"${_vo_configs}\""
        for _cfg in $_vo_configs; do
            _val=$(sysrc -n "virtual_oss_${_cfg}" 2>/dev/null || echo "MISSING")
            if [ "$_val" != "MISSING" ]; then
                ok "virtual_oss_${_cfg} defined"
                dim "${_val}"

                # Check -S flag
                if ! echo "$_val" | grep -qw '\-S'; then
                    warn "Config '${_cfg}' does not have -S (resampling)"
                    dim "Without -S, apps using different sample rates may fail"

                    _new_val="-S ${_val}"
                    do_action \
                        "Enable resampling (-S) for '${_cfg}' config" \
                        "sysrc virtual_oss_${_cfg}=\"${_new_val}\""
                fi
            else
                fail "Config '${_cfg}' listed but not defined"
                _help_generate_config "$_cfg"
            fi
        done
    else
        warn "No virtual_oss configuration found"
        _help_generate_config "dsp"
    fi
}

# ── Generate a virtual_oss config interactively ──────────────────────────
_help_generate_config() {
    _name=$1

    printf "\n"
    info "Available PCM devices:"
    list_pcm_devices

    if [ "$MODE" = "auto" ]; then
        # Auto mode: use pcm0 as default
        _play_dev="/dev/dsp0"
        _rec_dev="/dev/dsp0"
        _rate=48000
        _bits=16
        _buf=1024
        _prio=8
    elif [ "$MODE" = "dry" ]; then
        info "[DRY-RUN] Would prompt for device selection"
        return
    else
        printf "\n"
        ask "Playback device number (e.g. 0 for /dev/dsp0): "
        read -r _play_num
        _play_dev="/dev/dsp${_play_num:-0}"

        ask "Recording device number (Enter for same as playback): "
        read -r _rec_num
        if [ -n "$_rec_num" ]; then
            _rec_dev="/dev/dsp${_rec_num}"
        else
            _rec_dev="$_play_dev"
        fi

        ask "Sample rate [48000]: "
        read -r _rate
        _rate=${_rate:-48000}

        ask "Bit depth [16]: "
        read -r _bits
        _bits=${_bits:-16}

        ask "Buffer size in samples [1024]: "
        read -r _buf
        _buf=${_buf:-1024}

        ask "Real-time priority [8]: "
        read -r _prio
        _prio=${_prio:-8}
    fi

    if [ "$_play_dev" = "$_rec_dev" ]; then
        _cfg_val="-S -i ${_prio} -C 16 -c 2 -r ${_rate} -b ${_bits} -s ${_buf} -f ${_play_dev} -c 2 -d ${_name} -t ${_name}.ctl"
    else
        _cfg_val="-S -i ${_prio} -C 16 -c 2 -r ${_rate} -b ${_bits} -s ${_buf} -P ${_play_dev} -R ${_rec_dev} -c 2 -d ${_name} -t ${_name}.ctl"
    fi

    printf "\n"
    info "Generated config:"
    dim "virtual_oss_${_name}=\"${_cfg_val}\""

    do_action \
        "Set virtual_oss_${_name} in /etc/rc.conf" \
        "sysrc virtual_oss_configs=${_name} && sysrc virtual_oss_${_name}=\"${_cfg_val}\""
}

# ── Step 4: devfs.rules ─────────────────────────────────────────────────
step_devfs_rules() {
    section "4" "Device Visibility (/etc/devfs.rules)"

    if [ -f /etc/devfs.rules ] && grep -q '\[audio' /etc/devfs.rules 2>/dev/null; then
        ok "/etc/devfs.rules has [audio] ruleset"

        # Verify key entries
        _missing=""
        grep -q "dsp\*.*unhide" /etc/devfs.rules 2>/dev/null || _missing="${_missing} dsp*"
        grep -q "mixer\*.*unhide" /etc/devfs.rules 2>/dev/null || _missing="${_missing} mixer*"
        grep -q "sndstat.*unhide" /etc/devfs.rules 2>/dev/null || _missing="${_missing} sndstat"

        if [ -z "$_missing" ]; then
            ok "All key audio devices are unhidden"
        else
            warn "Missing unhide rules for:${_missing}"
        fi
    elif [ -f /etc/devfs.rules ]; then
        warn "/etc/devfs.rules exists but has no [audio] ruleset"
        info "Appending audio ruleset..."
        _audio_rules='
[audio=6]
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add path '\''dsp*'\'' unhide mode 0666
add path '\''vdsp*'\'' unhide mode 0666
add path '\''*midi*'\'' unhide mode 0666
add path '\''mixer*'\'' unhide mode 0666
add path '\''sndstat'\'' unhide mode 0666'

        do_action \
            "Append [audio] ruleset to /etc/devfs.rules" \
            "printf '%s\\n' '${_audio_rules}' >> /etc/devfs.rules"
    else
        warn "/etc/devfs.rules does not exist"
        _full_rules='[audio=6]
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add path '\''dsp*'\'' unhide mode 0666
add path '\''vdsp*'\'' unhide mode 0666
add path '\''*midi*'\'' unhide mode 0666
add path '\''mixer*'\'' unhide mode 0666
add path '\''sndstat'\'' unhide mode 0666'

        do_action \
            "Create /etc/devfs.rules with audio ruleset" \
            "printf '%s\\n' '${_full_rules}' > /etc/devfs.rules"
    fi
}

# ── Step 5: devfs ruleset activation ─────────────────────────────────────
step_devfs_activation() {
    section "5" "Activate devfs Ruleset"

    _current=$(sysrc -n devfs_system_ruleset 2>/dev/null || echo "MISSING")

    if [ "$_current" = "MISSING" ] || [ -z "$_current" ]; then
        warn "devfs_system_ruleset not set — audio rules won't apply"
        do_action \
            "Set devfs_system_ruleset=\"audio\"" \
            "sysrc devfs_system_ruleset=audio"
    elif echo "$_current" | grep -q "audio"; then
        ok "devfs_system_ruleset includes 'audio': ${_current}"
    else
        warn "devfs_system_ruleset='${_current}' — does not include 'audio'"
        dim "Your current rulesets: ${_current}"
        dim "The audio ruleset needs to be included for device visibility"

        # Append 'audio' to existing rulesets
        _new_ruleset="${_current} audio"
        do_action \
            "Add 'audio' to devfs_system_ruleset (→ '${_new_ruleset}')" \
            "sysrc devfs_system_ruleset=\"${_new_ruleset}\""
    fi

    # Apply rules immediately if possible
    if [ "$MODE" != "dry" ]; then
        if service devfs status >/dev/null 2>&1; then
            info "Restarting devfs to apply rules..."
            do_action \
                "Restart devfs service" \
                "service devfs restart" 1
        fi
    fi
}

# ── Step 6: Suspend/Resume hooks ─────────────────────────────────────────
step_suspend_resume() {
    section "6" "Suspend/Resume Hooks"

    # Determine the control device and backend
    _ctl_dev=""
    _resume_backend=""
    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
        _ctl_dev=$(echo "$_vo_cmd" | grep -oE '\-t [^ ]+' | awk '{print $2}')
        _resume_backend=$(echo "$_vo_cmd" | grep -oE '\-[fP] /dev/dsp[0-9]+' | awk '{print $2}' | head -1)
    fi

    # Fallback from rc.conf
    if [ -z "$_ctl_dev" ]; then
        _first_cfg=$(sysrc -n virtual_oss_configs 2>/dev/null | awk '{print $1}')
        if [ -n "$_first_cfg" ]; then
            _cfg_val=$(sysrc -n "virtual_oss_${_first_cfg}" 2>/dev/null || true)
            _ctl_dev=$(echo "$_cfg_val" | grep -oE '\-t [^ ]+' | awk '{print $2}')
            _resume_backend=$(echo "$_cfg_val" | grep -oE '\-f /dev/dsp[0-9]+' | awk '{print $2}')
        fi
    fi

    if [ -z "$_ctl_dev" ]; then
        _ctl_dev="dsp.ctl"
        warn "Could not determine control device, assuming /dev/${_ctl_dev}"
    fi
    if [ -z "$_resume_backend" ]; then
        _resume_backend="/dev/dsp0"
        warn "Could not determine resume backend, assuming ${_resume_backend}"
    fi

    # ── rc.suspend ──
    if [ -f /etc/rc.suspend ]; then
        if grep -q "virtual_oss" /etc/rc.suspend 2>/dev/null; then
            ok "virtual_oss hook already in /etc/rc.suspend"
            grep "virtual_oss" /etc/rc.suspend | while IFS= read -r line; do
                dim "$line"
            done
        else
            warn "No virtual_oss hook in /etc/rc.suspend"
            dim "Audio device won't be released before suspend → may cause hang"

            # Find the right insertion point (before acpiconf -k or zzz)
            _voss_cmd_path=$(which virtual_oss_cmd 2>/dev/null || echo "/usr/sbin/virtual_oss_cmd")
            _suspend_snippet="${_voss_cmd_path} /dev/${_ctl_dev} -f /dev/null
sleep 1"

            do_action \
                "Add virtual_oss suspend hook to /etc/rc.suspend" \
                "sed -i '' '/^\\/bin\\/sync/i\\
# Release virtual_oss backend before suspend\\
${_voss_cmd_path} /dev/${_ctl_dev} -f /dev/null\\
sleep 1\\
' /etc/rc.suspend"
        fi
    else
        warn "/etc/rc.suspend does not exist"
    fi

    # ── rc.resume ──
    if [ -f /etc/rc.resume ]; then
        if grep -q "virtual_oss" /etc/rc.resume 2>/dev/null; then
            ok "virtual_oss hook already in /etc/rc.resume"
            grep "virtual_oss" /etc/rc.resume | while IFS= read -r line; do
                dim "$line"
            done
        else
            warn "No virtual_oss hook in /etc/rc.resume"
            dim "Audio won't restore after waking from suspend"

            _voss_cmd_path=$(which virtual_oss_cmd 2>/dev/null || echo "/usr/sbin/virtual_oss_cmd")

            do_action \
                "Add virtual_oss resume hook to /etc/rc.resume" \
                "sed -i '' '/^\\/bin\\/sync/a\\
# Restore virtual_oss backend after resume\\
${_voss_cmd_path} /dev/${_ctl_dev} -f ${_resume_backend}\\
' /etc/rc.resume"
        fi
    else
        warn "/etc/rc.resume does not exist"
    fi
}

# ── Step 7: USB hotplug ──────────────────────────────────────────────────
step_usb_hotplug() {
    section "7" "USB Audio Hotplug (devd)"

    # Detect USB audio devices
    _usb_info=$(detect_usb_audio)
    if [ -z "$_usb_info" ]; then
        info "No USB audio devices detected — skipping hotplug setup"
        return
    fi

    _vendor=$(echo "$_usb_info" | cut -d: -f1)
    _product=$(echo "$_usb_info" | cut -d: -f2)
    _desc=$(echo "$_usb_info" | cut -d: -f3)
    _ugen=$(echo "$_usb_info" | cut -d: -f4)

    ok "USB audio device detected: ${_desc}"
    dim "Vendor: ${_vendor}  Product: ${_product}  (${_ugen})"

    # Find corresponding dsp device
    _usb_dsp=$(find_uaudio_dsp)
    if [ -n "$_usb_dsp" ]; then
        dim "Maps to: /dev/dsp${_usb_dsp}"
    fi

    # Check for existing hotplug rule
    _has_rule=0
    if [ -d /usr/local/etc/devd ]; then
        for _conf in /usr/local/etc/devd/*.conf; do
            [ ! -f "$_conf" ] && continue
            if grep -q "virtual_oss\|dsp\.ctl" "$_conf" 2>/dev/null; then
                _has_rule=1
                ok "Audio hotplug rule found in $(basename "$_conf")"
            fi
        done
    fi

    if [ "$_has_rule" -eq 0 ]; then
        warn "No USB audio hotplug rules configured"
        dim "virtual_oss won't auto-switch when this device is (un)plugged"

        # Determine control device
        _ctl_dev="dsp.ctl"
        _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
        if [ -n "$_vo_pid" ]; then
            _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
            _detected_ctl=$(echo "$_vo_cmd" | grep -oE '\-t [^ ]+' | awk '{print $2}')
            [ -n "$_detected_ctl" ] && _ctl_dev="$_detected_ctl"
        fi

        _voss_cmd_path=$(which virtual_oss_cmd 2>/dev/null || echo "/usr/sbin/virtual_oss_cmd")
        _usb_dsp_path="/dev/dsp${_usb_dsp:-3}"

        _devd_rule="# USB audio hotplug for ${_desc}
# Auto-generated by setup-virtual-oss.sh
notify 100 {
    match \"system\"    \"USB\";
    match \"subsystem\" \"INTERFACE\";
    match \"type\"      \"ATTACH\";
    match \"vendor\"    \"${_vendor}\";
    action \"${_voss_cmd_path} /dev/${_ctl_dev} -f ${_usb_dsp_path}\";
};

notify 100 {
    match \"system\"    \"USB\";
    match \"subsystem\" \"INTERFACE\";
    match \"type\"      \"DETACH\";
    match \"vendor\"    \"${_vendor}\";
    action \"${_voss_cmd_path} /dev/${_ctl_dev} -f /dev/null\";
};"

        printf "\n"
        info "Proposed devd rule:"
        printf "%s\n" "$_devd_rule" | while IFS= read -r line; do
            dim "$line"
        done

        _safe_desc=$(echo "$_desc" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-' | head -c 30)
        _rule_file="/usr/local/etc/devd/usb-audio-${_safe_desc}.conf"

        do_action \
            "Create devd rule: $(basename "$_rule_file")" \
            "printf '%s\\n' '${_devd_rule}' > '${_rule_file}' && service devd restart"
    fi
}

# ── Step 8: Verify & Start ──────────────────────────────────────────────
step_verify() {
    section "8" "Verify & Start Service"

    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        ok "virtual_oss is already running (PID: ${_vo_pid})"
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
        dim "${_vo_cmd}"

        # Verify the virtual device works
        if [ -c /dev/dsp ]; then
            ok "/dev/dsp virtual device exists and accessible"
        fi

        if [ -r /dev/sndstat ]; then
            _userspace=$(cat /dev/sndstat 2>/dev/null | grep "userspace" || true)
            if [ -n "$_userspace" ]; then
                ok "virtual_oss visible in /dev/sndstat"
            fi
        fi
    else
        warn "virtual_oss is not currently running"

        _vo_enable=$(sysrc -n virtual_oss_enable 2>/dev/null || echo "NO")
        if [ "$_vo_enable" = "YES" ] || [ "$_vo_enable" = "yes" ]; then
            do_action \
                "Start virtual_oss service" \
                "service virtual_oss start"
        else
            warn "Service not enabled — start manually or enable first"
            dim "Run: sysrc virtual_oss_enable=YES && service virtual_oss start"
        fi
    fi

    # Final sndstat
    printf "\n"
    info "Current /dev/sndstat:"
    if [ -r /dev/sndstat ]; then
        cat /dev/sndstat 2>/dev/null | while IFS= read -r line; do
            dim "$line"
        done
    else
        warn "/dev/sndstat not readable"
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "\n${BOLD}${CYN}virtual_oss Setup Wizard${RST}\n"
printf "${DIM}  FreeBSD $(uname -r) — $(date '+%Y-%m-%d %H:%M')${RST}\n"
case "$MODE" in
    auto) printf "${DIM}  Mode: auto-fix (will apply all changes)${RST}\n" ;;
    dry)  printf "${DIM}  Mode: dry-run (preview only, no changes)${RST}\n" ;;
    interactive) printf "${DIM}  Mode: interactive (will ask before each change)${RST}\n" ;;
esac

# Root check
if [ "$(id -u)" -ne 0 ] && [ "$MODE" != "dry" ]; then
    warn "Not running as root — some fixes may fail"
    dim "Consider: sudo $0 $*"
    printf "\n"
fi

step_packages
step_kernel_modules
step_rc_conf
step_devfs_rules
step_devfs_activation
step_suspend_resume
step_usb_hotplug
step_verify

# ── Summary ─────────────────────────────────────────────────────────────────
header
printf "\n  ${BOLD}Setup Complete${RST}\n\n"
if [ "$MODE" = "dry" ]; then
    printf "    ${DIM}Dry run — no changes were made${RST}\n"
else
    printf "    ${GRN}Applied:${RST}  %d fix(es)\n" "$FIXED"
    printf "    ${DIM}Skipped:${RST}  %d\n" "$SKIPPED"
fi
printf "\n"

if [ "$FIXED" -gt 0 ]; then
    info "Some changes require a reboot to take full effect:"
    dim "• /boot/loader.conf changes (kernel modules)"
    dim "• /etc/rc.conf changes (service enable)"
    dim "• devfs ruleset changes"
    printf "\n"
fi

printf "  ${DIM}Run ./check-virtual-oss.sh --check to verify the final state.${RST}\n\n"
