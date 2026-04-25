#!/bin/sh
# check-virtual-oss.sh — virtual_oss Sanity Checker & Setup Assistant
# Validates the full virtual_oss stack: kernel modules, packages, rc.conf,
# device nodes, devfs rules, suspend/resume hooks, and USB hotplug.
# Offers to install/fix anything that's missing.
#
# Usage:
#   ./check-virtual-oss.sh           — Full sanity check with fix offers
#   ./check-virtual-oss.sh --check   — Read-only check (no modifications)
#   ./check-virtual-oss.sh --fix     — Auto-fix all issues (non-interactive)
#   ./check-virtual-oss.sh --help    — Show this help

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
section() { printf "\n${BOLD}${CYN}══ %s ══${RST}\n\n" "$1"; }
ok()      { printf "  ${GRN}[✓]${RST}  %s\n" "$1"; }
warn()    { printf "  ${YLW}[!]${RST}  %s\n" "$1"; }
fail()    { printf "  ${RED}[✗]${RST}  %s\n" "$1"; }
info()    { printf "  ${BOLD}[·]${RST}  %s\n" "$1"; }
dim()     { printf "       ${DIM}%s${RST}\n" "$1"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ── Counters ────────────────────────────────────────────────────────────────
PASS=0
WARN=0
FAIL=0
FIXED=0

count_ok()   { PASS=$((PASS + 1)); ok "$1"; }
count_warn() { WARN=$((WARN + 1)); warn "$1"; }
count_fail() { FAIL=$((FAIL + 1)); fail "$1"; }
count_fix()  { FIXED=$((FIXED + 1)); ok "FIXED: $1"; }

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}check-virtual-oss.sh${RST} — virtual_oss Sanity Checker & Setup Assistant

${BOLD}Usage:${RST}
  $0             Full sanity check with interactive fix offers
  $0 --check     Read-only mode (no modifications)
  $0 --fix       Auto-fix all issues without prompting
  $0 --help      Show this help

${BOLD}What it checks:${RST}
  • Package installation (virtual_oss, cuse)
  • Kernel modules (cuse.ko, snd_hda, snd_uaudio)
  • /boot/loader.conf module loading
  • /etc/rc.conf virtual_oss configuration
  • Running virtual_oss process and its flags
  • Device nodes (/dev/dsp, /dev/dsp.ctl, /dev/sndstat)
  • Backend device validity
  • /etc/devfs.rules audio visibility rules
  • /etc/rc.suspend & /etc/rc.resume hooks
  • USB hotplug devd rules
  • devfs ruleset activation

${BOLD}Requires:${RST} FreeBSD. Run as root for full fix capabilities.
EOF
    exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
MODE="interactive"
case "${1:-}" in
    --check)   MODE="check"       ;;
    --fix)     MODE="fix"         ;;
    --help|-h) usage              ;;
    "")        MODE="interactive" ;;
    *)         printf "${RED}Unknown option: %s${RST}\n" "$1"; usage ;;
esac

# ── Offer to fix / do something ─────────────────────────────────────────────
# Usage: offer_fix "description" "command_to_run"
# Returns 0 if fixed, 1 if skipped
offer_fix() {
    _desc=$1
    _cmd=$2

    case "$MODE" in
        check)
            dim "Fix: ${_cmd}"
            return 1
            ;;
        fix)
            info "Auto-fixing: ${_desc}"
            eval "$_cmd"
            if [ $? -eq 0 ]; then
                count_fix "$_desc"
                return 0
            else
                fail "Fix failed: ${_cmd}"
                return 1
            fi
            ;;
        interactive)
            printf "\n       ${YLW}Fix: ${_desc}${RST}\n"
            printf "       ${DIM}Command: ${_cmd}${RST}\n"
            printf "       ${BOLD}Apply? [y/N]: ${RST}"
            read -r _answer
            case "$_answer" in
                [yY]|[yY][eE][sS])
                    eval "$_cmd"
                    if [ $? -eq 0 ]; then
                        count_fix "$_desc"
                        return 0
                    else
                        fail "Fix failed"
                        return 1
                    fi
                    ;;
                *)
                    dim "Skipped"
                    return 1
                    ;;
            esac
            ;;
    esac
}

# ── Offer to install a package ──────────────────────────────────────────────
offer_install() {
    _pkg=$1
    _desc=${2:-$1}

    case "$MODE" in
        check)
            dim "Install with: pkg install ${_pkg}"
            return 1
            ;;
        fix)
            info "Auto-installing: ${_pkg}"
            pkg install -y "$_pkg"
            if [ $? -eq 0 ]; then
                count_fix "Installed ${_pkg}"
                return 0
            else
                fail "Installation failed: ${_pkg}"
                return 1
            fi
            ;;
        interactive)
            printf "\n       ${YLW}${_desc} is not installed.${RST}\n"
            printf "       ${BOLD}Install ${_pkg}? [y/N]: ${RST}"
            read -r _answer
            case "$_answer" in
                [yY]|[yY][eE][sS])
                    pkg install -y "$_pkg"
                    if [ $? -eq 0 ]; then
                        count_fix "Installed ${_pkg}"
                        return 0
                    else
                        fail "Installation failed"
                        return 1
                    fi
                    ;;
                *)
                    dim "Skipped"
                    return 1
                    ;;
            esac
            ;;
    esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                           CHECK FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── 1. Package & binary checks ─────────────────────────────────────────────
check_packages() {
    section "Package & Binary Availability"

    # virtual_oss binary
    if cmd_exists virtual_oss; then
        _voss_path=$(which virtual_oss)
        count_ok "virtual_oss binary found: ${_voss_path}"
    else
        count_fail "virtual_oss binary not found"
        # Check if it's a pkg or base
        if pkg info -e virtual_oss 2>/dev/null; then
            dim "Package installed but binary not in PATH"
        else
            offer_install "virtual_oss" "virtual_oss (sound multiplexer)"
        fi
    fi

    # virtual_oss_cmd
    if cmd_exists virtual_oss_cmd; then
        count_ok "virtual_oss_cmd found (runtime control)"
    else
        count_warn "virtual_oss_cmd not found — runtime switching won't work"
        dim "Should come with virtual_oss package"
    fi

    # cuse module availability
    if [ -f /boot/modules/cuse.ko ] || [ -f /boot/kernel/cuse.ko ]; then
        count_ok "cuse.ko module available"
    else
        count_fail "cuse.ko module not found"
        dim "Required for virtual_oss userspace device nodes"
        offer_install "cuse4bsd" "cuse kernel module"
    fi
}

# ── 2. Kernel module checks ───────────────────────────────────────────────
check_kernel_modules() {
    section "Kernel Modules"

    # cuse
    if kldstat -q -m cuse 2>/dev/null; then
        count_ok "cuse module loaded"
    else
        count_fail "cuse module NOT loaded — virtual_oss cannot create device nodes"
        offer_fix "Load cuse module" "kldload cuse"
    fi

    # Check loader.conf for cuse
    if grep -qE '^[^#]*cuse_load="YES"' /boot/loader.conf 2>/dev/null; then
        count_ok "cuse_load=\"YES\" in /boot/loader.conf"
    elif grep -qE '^[^#]*cuse_load' /boot/loader.conf 2>/dev/null; then
        count_warn "cuse_load present but not set to YES"
        dim "$(grep cuse_load /boot/loader.conf)"
    else
        count_warn "cuse not configured to load at boot in /boot/loader.conf"
        offer_fix "Add cuse_load to loader.conf" \
            "printf '\\n# Required for virtual_oss\\ncuse_load=\"YES\"\\n' >> /boot/loader.conf"
    fi

    # snd_hda
    if kldstat 2>/dev/null | grep -q snd_hda; then
        count_ok "snd_hda loaded (Intel HDA driver)"
    elif kldstat 2>/dev/null | grep -q snd_driver; then
        count_ok "snd_driver loaded (meta-driver includes HDA)"
    else
        # Not necessarily a problem — might not have HDA hardware
        _hdac=$(sysctl -n dev.hdac.0.%desc 2>/dev/null || true)
        if [ -n "$_hdac" ]; then
            count_ok "HDA controller present and working: ${_hdac}"
        else
            count_warn "No HDA driver loaded (may not be needed)"
        fi
    fi

    # snd_uaudio
    _usb_audio=$(cat /var/run/dmesg.boot 2>/dev/null | grep -c uaudio || echo "0")
    if [ "$_usb_audio" -gt 0 ]; then
        if kldstat 2>/dev/null | grep -q snd_uaudio; then
            count_ok "snd_uaudio loaded (USB audio devices detected)"
        else
            count_warn "USB audio devices detected but snd_uaudio not loaded"
            offer_fix "Load snd_uaudio" "kldload snd_uaudio"
        fi
    else
        info "No USB audio devices detected in dmesg"
    fi
}

# ── 3. rc.conf configuration ──────────────────────────────────────────────
check_rc_conf() {
    section "rc.conf Configuration"

    # virtual_oss_enable
    _vo_enable=$(sysrc -n virtual_oss_enable 2>/dev/null || echo "MISSING")
    case "$_vo_enable" in
        YES|yes)
            count_ok "virtual_oss_enable=YES"
            ;;
        NO|no)
            count_warn "virtual_oss_enable=NO (service disabled in rc.conf)"
            dim "Service won't start on boot. Currently running: $(pgrep -x virtual_oss >/dev/null && echo 'yes' || echo 'no')"
            offer_fix "Enable virtual_oss service" "sysrc virtual_oss_enable=YES"
            ;;
        MISSING)
            count_fail "virtual_oss_enable not set in rc.conf"
            offer_fix "Enable virtual_oss service" "sysrc virtual_oss_enable=YES"
            ;;
        *)
            count_warn "virtual_oss_enable has unexpected value: ${_vo_enable}"
            ;;
    esac

    # virtual_oss_configs
    _vo_configs=$(sysrc -n virtual_oss_configs 2>/dev/null || echo "MISSING")
    if [ "$_vo_configs" != "MISSING" ]; then
        count_ok "virtual_oss_configs=\"${_vo_configs}\""
        # Check each named config
        for _cfg in $_vo_configs; do
            _cfg_val=$(sysrc -n "virtual_oss_${_cfg}" 2>/dev/null || echo "MISSING")
            if [ "$_cfg_val" = "MISSING" ]; then
                count_fail "Config '${_cfg}' listed but virtual_oss_${_cfg} not defined"
            else
                count_ok "virtual_oss_${_cfg} is defined"
                dim "${_cfg_val}"

                # Validate key flags in the config
                _validate_voss_flags "$_cfg" "$_cfg_val"
            fi
        done
    else
        # Check for the single-instance style
        _vo_args=$(sysrc -n virtual_oss_args 2>/dev/null || echo "MISSING")
        if [ "$_vo_args" != "MISSING" ]; then
            count_ok "virtual_oss_args defined (single-instance mode)"
            dim "$_vo_args"
        else
            count_warn "No virtual_oss configuration found"
            dim "Neither virtual_oss_configs nor virtual_oss_args is set"
        fi
    fi
}

# ── Validate virtual_oss flags ────────────────────────────────────────────
_validate_voss_flags() {
    _name=$1
    _flags=$2

    # Check for -f (backend device)
    _backend=$(echo "$_flags" | grep -oE '\-f [^ ]+' | awk '{print $2}' | head -1)
    if [ -z "$_backend" ]; then
        # Check for -P/-R split playback/record
        _play_dev=$(echo "$_flags" | grep -oE '\-P [^ ]+' | awk '{print $2}')
        _rec_dev=$(echo "$_flags" | grep -oE '\-R [^ ]+' | awk '{print $2}')
        if [ -n "$_play_dev" ] || [ -n "$_rec_dev" ]; then
            [ -n "$_play_dev" ] && dim "  Playback backend: ${_play_dev}"
            [ -n "$_rec_dev" ] && dim "  Record backend: ${_rec_dev}"
            # Validate devices
            for _dev in $_play_dev $_rec_dev; do
                if [ "$_dev" = "/dev/null" ]; then
                    dim "  ${_dev}: dummy backend (OK)"
                elif [ -c "$_dev" ]; then
                    count_ok "  Backend ${_dev} exists and is a char device"
                else
                    count_fail "  Backend ${_dev} does NOT exist"
                fi
            done
        else
            count_fail "Config '${_name}': no backend device (-f or -P/-R)"
        fi
    else
        dim "  Backend: ${_backend}"
        if [ "$_backend" = "/dev/null" ]; then
            dim "  Dummy backend (intentional)"
        elif [ -c "$_backend" ]; then
            count_ok "Backend ${_backend} exists"
        else
            count_fail "Backend ${_backend} does NOT exist"
            dim "  Is the audio device connected / driver loaded?"
        fi
    fi

    # Check sample rate
    _rate=$(echo "$_flags" | grep -oE '\-r [0-9]+' | awk '{print $2}')
    if [ -n "$_rate" ]; then
        case "$_rate" in
            44100|48000|88200|96000|192000)
                count_ok "Sample rate: ${_rate}Hz"
                ;;
            *)
                count_warn "Unusual sample rate: ${_rate}Hz"
                ;;
        esac
    else
        count_warn "Config '${_name}': no sample rate (-r) specified"
    fi

    # Check bit depth
    _bits=$(echo "$_flags" | grep -oE '\-b [0-9]+' | awk '{print $2}')
    if [ -n "$_bits" ]; then
        case "$_bits" in
            16|24|32) count_ok "Bit depth: ${_bits}-bit" ;;
            8)        count_warn "Bit depth: 8-bit (very low quality)" ;;
            *)        count_warn "Unknown bit depth: ${_bits}" ;;
        esac
    fi

    # Check buffer size
    _buf=$(echo "$_flags" | grep -oE '\-s [0-9]+' | awk '{print $2}')
    if [ -n "$_buf" ]; then
        if [ "$_buf" -lt 256 ] 2>/dev/null; then
            count_warn "Buffer size ${_buf} samples is very small — may cause xruns"
        elif [ "$_buf" -gt 4096 ] 2>/dev/null; then
            count_warn "Buffer size ${_buf} samples is large — high latency"
        else
            count_ok "Buffer size: ${_buf} samples"
        fi
    fi

    # Check virtual device (-d)
    _vdev=$(echo "$_flags" | grep -oE '\-d [^ ]+' | awk '{print $2}')
    if [ -n "$_vdev" ]; then
        dim "  Virtual device: /dev/${_vdev}"
    else
        count_warn "Config '${_name}': no virtual device name (-d)"
    fi

    # Check control socket (-t)
    _ctl=$(echo "$_flags" | grep -oE '\-t [^ ]+' | awk '{print $2}')
    if [ -n "$_ctl" ]; then
        dim "  Control socket: /dev/${_ctl}"
    else
        count_warn "Config '${_name}': no control socket (-t) — runtime switching disabled"
    fi

    # Check -S (resampling)
    if echo "$_flags" | grep -qw '\-S'; then
        count_ok "Resampling enabled (-S)"
    else
        count_warn "Resampling not enabled (consider -S for mixed-rate sources)"
    fi

    # Check priority (-i)
    _prio=$(echo "$_flags" | grep -oE '\-i [0-9]+' | awk '{print $2}')
    if [ -n "$_prio" ]; then
        count_ok "Real-time priority: ${_prio}"
    else
        count_warn "No real-time priority set (-i) — audio may glitch under load"
    fi
}

# ── 4. Running process check ──────────────────────────────────────────────
check_running() {
    section "Running Process"

    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        count_ok "virtual_oss is running (PID: ${_vo_pid})"

        # Show full command line
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
        if [ -n "$_vo_cmd" ]; then
            dim "cmdline: ${_vo_cmd}"

            # Cross-check running args vs rc.conf
            _rc_configs=$(sysrc -n virtual_oss_configs 2>/dev/null || true)
            if [ -n "$_rc_configs" ]; then
                _first_cfg=$(echo "$_rc_configs" | awk '{print $1}')
                _rc_args=$(sysrc -n "virtual_oss_${_first_cfg}" 2>/dev/null || true)
                if [ -n "$_rc_args" ]; then
                    # Check if the running backend matches rc.conf
                    _running_backend=$(echo "$_vo_cmd" | grep -oE '\-[fPR] /dev/[^ ]+' || true)
                    _conf_backend=$(echo "$_rc_args" | grep -oE '\-f /dev/[^ ]+' || true)
                    if [ -n "$_running_backend" ] && [ -n "$_conf_backend" ]; then
                        if echo "$_vo_cmd" | grep -qF "$(echo "$_conf_backend" | awk '{print $2}')"; then
                            count_ok "Running backend matches rc.conf"
                        else
                            count_warn "Running backend differs from rc.conf"
                            dim "Running: ${_running_backend}"
                            dim "rc.conf: ${_conf_backend}"
                        fi
                    fi
                fi
            fi
        fi

        # Check process priority
        _vo_nice=$(ps -p "$_vo_pid" -o ni= 2>/dev/null | tr -d ' ')
        _vo_pri=$(ps -p "$_vo_pid" -o pri= 2>/dev/null | tr -d ' ')
        if [ -n "$_vo_pri" ]; then
            dim "Priority: nice=${_vo_nice} pri=${_vo_pri}"
        fi
    else
        count_fail "virtual_oss is NOT running"
        offer_fix "Start virtual_oss" "service virtual_oss start"
    fi
}

# ── 5. Device node checks ────────────────────────────────────────────────
check_devices() {
    section "Device Nodes"

    # /dev/sndstat
    if [ -r /dev/sndstat ]; then
        count_ok "/dev/sndstat readable"
        _userspace=$(cat /dev/sndstat 2>/dev/null | grep -c "userspace" || echo "0")
        if [ "$_userspace" -gt 0 ]; then
            count_ok "virtual_oss device visible in /dev/sndstat"
            cat /dev/sndstat 2>/dev/null | grep "userspace" -A5 | while IFS= read -r line; do
                dim "$line"
            done
        else
            count_warn "No userspace devices in /dev/sndstat"
        fi
    else
        count_fail "/dev/sndstat not readable"
    fi

    # Check virtual devices created by running instance
    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
        _vdevs=$(echo "$_vo_cmd" | grep -oE '\-d [^ ]+' | awk '{print $2}')
        for _vd in $_vdevs; do
            if [ -c "/dev/${_vd}" ]; then
                count_ok "/dev/${_vd} exists"
                _perms=$(ls -la "/dev/${_vd}" 2>/dev/null | awk '{print $1, $3, $4}')
                dim "Permissions: ${_perms}"
            else
                count_fail "/dev/${_vd} missing (virtual_oss may have failed to create it)"
            fi
        done

        _ctls=$(echo "$_vo_cmd" | grep -oE '\-t [^ ]+' | awk '{print $2}')
        for _ct in $_ctls; do
            if [ -c "/dev/${_ct}" ] || [ -e "/dev/${_ct}" ]; then
                count_ok "/dev/${_ct} control socket exists"
            else
                count_warn "/dev/${_ct} control socket missing"
            fi
        done
    fi

    # Check raw hardware devices
    info "Hardware OSS devices:"
    _pcm_units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un || true)
    for _pu in $_pcm_units; do
        _desc=$(sysctl -n dev.pcm.${_pu}.%desc 2>/dev/null || echo "(unknown)")
        if [ -c "/dev/dsp${_pu}" ]; then
            dim "  /dev/dsp${_pu} ✓  ${_desc}"
        else
            dim "  /dev/dsp${_pu} ✗  ${_desc} (device node missing)"
        fi
    done
}

# ── 6. devfs.rules checks ────────────────────────────────────────────────
check_devfs() {
    section "devfs.rules & Permissions"

    if [ ! -f /etc/devfs.rules ]; then
        count_warn "/etc/devfs.rules does not exist"
        dim "Without it, apps may directly open raw hardware and block virtual_oss"
        _rules='[audio=6]
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add path '\''dsp*'\'' unhide mode 0666
add path '\''vdsp*'\'' unhide mode 0666
add path '\''*midi*'\'' unhide mode 0666
add path '\''mixer*'\'' unhide mode 0666
add path '\''sndstat'\'' unhide mode 0666'
        offer_fix "Create /etc/devfs.rules with audio ruleset" \
            "printf '%s\\n' '${_rules}' > /etc/devfs.rules"
        return
    fi

    count_ok "/etc/devfs.rules exists"

    # Check for audio ruleset
    if grep -q '\[audio' /etc/devfs.rules 2>/dev/null; then
        count_ok "Audio ruleset found in devfs.rules"

        # Check key entries
        if grep -q "dsp\*.*unhide" /etc/devfs.rules 2>/dev/null; then
            count_ok "dsp* devices unhidden"
        else
            count_warn "dsp* devices not unhidden in devfs.rules"
        fi

        if grep -q "mixer\*.*unhide" /etc/devfs.rules 2>/dev/null; then
            count_ok "mixer* devices unhidden"
        else
            count_warn "mixer* devices not unhidden in devfs.rules"
        fi

        if grep -q "sndstat.*unhide" /etc/devfs.rules 2>/dev/null; then
            count_ok "sndstat unhidden"
        else
            count_warn "sndstat not unhidden in devfs.rules"
        fi
    else
        count_warn "No [audio] ruleset in devfs.rules"
        dim "Consider adding an audio ruleset to control device visibility"
    fi

    # Check devfs_system_ruleset in rc.conf
    _ruleset=$(sysrc -n devfs_system_ruleset 2>/dev/null || echo "MISSING")
    if [ "$_ruleset" = "MISSING" ]; then
        count_warn "devfs_system_ruleset not set in rc.conf"
        dim "devfs.rules won't take effect without activation"
        if grep -q '\[audio' /etc/devfs.rules 2>/dev/null; then
            offer_fix "Activate audio devfs ruleset" \
                "sysrc devfs_system_ruleset='audio'"
        fi
    else
        if echo "$_ruleset" | grep -q "audio"; then
            count_ok "devfs_system_ruleset includes 'audio': ${_ruleset}"
        else
            count_warn "devfs_system_ruleset='${_ruleset}' (does not include 'audio')"
            dim "Audio devfs rules may not be active"
            dim "Current rulesets: ${_ruleset}"
        fi
    fi
}

# ── 7. Suspend/resume hooks ──────────────────────────────────────────────
check_suspend_resume() {
    section "Suspend/Resume Hooks"

    _has_ctl=0
    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)
        echo "$_vo_cmd" | grep -q '\-t' && _has_ctl=1
    fi

    # Check rc.suspend
    if [ -f /etc/rc.suspend ]; then
        if grep -q "virtual_oss" /etc/rc.suspend 2>/dev/null; then
            count_ok "virtual_oss hook found in /etc/rc.suspend"
            grep "virtual_oss" /etc/rc.suspend | while IFS= read -r line; do
                dim "$line"
            done
        else
            count_warn "No virtual_oss hook in /etc/rc.suspend"
            dim "Audio device may not release cleanly on suspend"
            if [ "$_has_ctl" -eq 1 ]; then
                dim "Recommended: add 'virtual_oss_cmd /dev/dsp.ctl -f /dev/null' before suspend"
            fi
        fi
    else
        count_warn "/etc/rc.suspend does not exist"
    fi

    # Check rc.resume
    if [ -f /etc/rc.resume ]; then
        if grep -q "virtual_oss" /etc/rc.resume 2>/dev/null; then
            count_ok "virtual_oss hook found in /etc/rc.resume"
            grep "virtual_oss" /etc/rc.resume | while IFS= read -r line; do
                dim "$line"
            done
        else
            count_warn "No virtual_oss hook in /etc/rc.resume"
            dim "Audio may not restore after waking from suspend"
            if [ "$_has_ctl" -eq 1 ]; then
                dim "Recommended: add 'virtual_oss_cmd /dev/dsp.ctl -f /dev/dspN' after resume"
            fi
        fi
    else
        count_warn "/etc/rc.resume does not exist"
    fi
}

# ── 8. USB hotplug devd ──────────────────────────────────────────────────
check_devd_hotplug() {
    section "USB Audio Hotplug (devd)"

    # Check if there are USB audio devices
    _usb_audio_devs=$(cat /var/run/dmesg.boot 2>/dev/null | grep 'uaudio[0-9]' || true)
    if [ -z "$_usb_audio_devs" ]; then
        info "No USB audio devices detected — hotplug config not applicable"
        return
    fi

    count_ok "USB audio devices detected:"
    echo "$_usb_audio_devs" | head -5 | while IFS= read -r line; do
        dim "$line"
    done

    # Check for audio-related devd rules
    _audio_devd=0
    if [ -d /usr/local/etc/devd ]; then
        for _conf in /usr/local/etc/devd/*.conf; do
            [ ! -f "$_conf" ] && continue
            if grep -q "virtual_oss\|dsp\.ctl" "$_conf" 2>/dev/null; then
                _audio_devd=1
                count_ok "Audio hotplug rule found: $(basename "$_conf")"
                grep -A3 "virtual_oss\|dsp\.ctl" "$_conf" | head -6 | while IFS= read -r line; do
                    dim "$line"
                done
            fi
        done
    fi

    if [ "$_audio_devd" -eq 0 ]; then
        count_warn "No USB audio hotplug rules found in /usr/local/etc/devd/"
        dim "virtual_oss won't auto-switch when USB headsets are plugged in"
        dim "See README for devd rule examples"

        # Get USB audio vendor IDs for hint
        _vendors=$(usbconfig list 2>/dev/null | grep -i audio || true)
        if [ -n "$_vendors" ]; then
            info "Detected USB audio devices for hotplug config:"
            echo "$_vendors" | while IFS= read -r line; do
                dim "$line"
            done
        fi
    fi
}

# ── 9. Cross-layer sanity ────────────────────────────────────────────────
check_cross_layer() {
    section "Cross-Layer Sanity Checks"

    # Check if default_unit points to a valid device
    _defunit=$(sysctl -n hw.snd.default_unit 2>/dev/null || echo "0")
    if [ -c "/dev/dsp${_defunit}" ]; then
        _desc=$(sysctl -n "dev.pcm.${_defunit}.%desc" 2>/dev/null || echo "(unknown)")
        count_ok "hw.snd.default_unit=${_defunit} → /dev/dsp${_defunit} (${_desc})"
    else
        count_fail "hw.snd.default_unit=${_defunit} but /dev/dsp${_defunit} does not exist"
    fi

    # Check if virtual_oss backend device matches a real pcm device
    _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_vo_pid" ]; then
        _vo_cmd=$(ps -ww -p "$_vo_pid" -o args= 2>/dev/null || true)

        # Check for backend devices
        _backends=$(echo "$_vo_cmd" | grep -oE '\-[fPR] /dev/[^ ]+' | awk '{print $2}' | sort -u)
        for _be in $_backends; do
            [ "$_be" = "/dev/null" ] && continue
            if [ -c "$_be" ]; then
                count_ok "Backend ${_be} is accessible"
            else
                count_fail "Backend ${_be} is NOT accessible — audio is broken!"
            fi
        done
    fi

    # Check if PulseAudio is fighting with virtual_oss
    _pa_pid=$(pgrep -x pulseaudio 2>/dev/null || true)
    if [ -n "$_pa_pid" ]; then
        info "PulseAudio is running (PID: ${_pa_pid})"
        # Check if PA is using virtual_oss device
        _pa_module=$(pactl list short modules 2>/dev/null | grep oss || true)
        if [ -n "$_pa_module" ]; then
            count_ok "PulseAudio using OSS module (should be via virtual_oss)"
        else
            count_warn "PulseAudio running but not using module-oss"
            dim "PA might be opening raw hardware, bypassing virtual_oss"
        fi
    fi

    # Check if PipeWire is running
    _pw_pid=$(pgrep -x pipewire 2>/dev/null || true)
    if [ -n "$_pw_pid" ]; then
        info "PipeWire is running (PID: ${_pw_pid})"
    fi

    # Check if JACK is running (and is it using a different device)
    _jack_pid=$(pgrep -x jackd 2>/dev/null || true)
    if [ -n "$_jack_pid" ]; then
        info "JACK is running (PID: ${_jack_pid})"
        _jack_cmd=$(ps -ww -p "$_jack_pid" -o args= 2>/dev/null || true)
        dim "$_jack_cmd"
    fi

    # Check device permissions for current user
    _user=$(id -un)
    if [ -c /dev/dsp ]; then
        if [ -r /dev/dsp ] && [ -w /dev/dsp ]; then
            count_ok "/dev/dsp is read/write accessible by ${_user}"
        else
            count_fail "/dev/dsp is not accessible by ${_user}"
            dim "Check devfs.rules permissions"
        fi
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "\n${BOLD}${CYN}virtual_oss Sanity Checker${RST}\n"
printf "${DIM}  FreeBSD $(uname -r) — $(date '+%Y-%m-%d %H:%M')${RST}\n"
case "$MODE" in
    check)       printf "${DIM}  Mode: read-only check${RST}\n" ;;
    fix)         printf "${DIM}  Mode: auto-fix${RST}\n" ;;
    interactive) printf "${DIM}  Mode: interactive${RST}\n" ;;
esac

check_packages
check_kernel_modules
check_rc_conf
check_running
check_devices
check_devfs
check_suspend_resume
check_devd_hotplug
check_cross_layer

# ── Summary ─────────────────────────────────────────────────────────────────
header
printf "\n  ${BOLD}Summary${RST}\n\n"
printf "    ${GRN}Passed:${RST}  %d\n" "$PASS"
printf "    ${YLW}Warnings:${RST} %d\n" "$WARN"
printf "    ${RED}Failed:${RST}  %d\n" "$FAIL"
[ "$FIXED" -gt 0 ] && printf "    ${MAG}Fixed:${RST}   %d\n" "$FIXED"
printf "\n"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    printf "  ${GRN}${BOLD}All checks passed — virtual_oss stack looks healthy!${RST}\n"
elif [ "$FAIL" -eq 0 ]; then
    printf "  ${YLW}No critical failures, but %d warning(s) to review.${RST}\n" "$WARN"
else
    printf "  ${RED}%d critical issue(s) found. Review the failures above.${RST}\n" "$FAIL"
fi

printf "\n"
