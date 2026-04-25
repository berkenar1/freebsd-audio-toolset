#!/bin/sh
# configure-devd-audio.sh — Check and fix USB audio hotplug via devd
# Discovers USB audio devices, checks for devd rules that auto-switch
# virtual_oss on attach/detach, and generates them if missing.
#
# Usage:
#   ./configure-devd-audio.sh             — Check and prompt to fix
#   ./configure-devd-audio.sh --auto      — Apply all fixes without prompting
#   ./configure-devd-audio.sh --dry-run   — Check only, no changes
#   ./configure-devd-audio.sh --help      — Show help

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

DEVD_DIR="/usr/local/etc/devd"
MODE="interactive"

case "${1:-}" in
    --auto)    MODE="auto" ;;
    --dry-run) MODE="dryrun" ;;
    --help|-h)
        cat <<EOF
configure-devd-audio.sh — USB audio hotplug via devd

Discovers USB audio devices, checks whether devd rules exist to
auto-switch virtual_oss on attach/detach, and generates configs
if missing.

Checks:
  • USB audio devices present (via usbconfig + sysctl)
  • /usr/local/etc/devd/ has matching .conf files
  • Attach action switches to the correct /dev/dspN
  • Detach action mutes to /dev/null
  • devd service is running

Options:
  --auto      Apply all fixes without prompting
  --dry-run   Check only, report issues, make no changes
  --help      Show this help

Run as root to apply changes.
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

# Detect the virtual_oss control socket
detect_ctl_socket() {
    _pid=$(pgrep -x virtual_oss 2>/dev/null || true)
    if [ -n "$_pid" ]; then
        for _p in $_pid; do
            _args=$(ps -ww -p "$_p" -o args= 2>/dev/null || true)
            _ctl=$(echo "$_args" | grep -oE '\-t [^ ]+' | awk '{print $2}' | head -1)
            if [ -n "$_ctl" ]; then
                case "$_ctl" in /dev/*) ;; *) _ctl="/dev/${_ctl}" ;; esac
                echo "$_ctl"
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
            case "$_ctl" in /dev/*) ;; *) _ctl="/dev/${_ctl}" ;; esac
            echo "$_ctl"
            return
        fi
    done
    echo "/dev/dsp.ctl"
}

# Discover USB audio devices: outputs "ugenX.Y vendor_id product_id description"
discover_usb_audio() {
    # List all ugen devices and find audio ones
    _ugen_list=$(usbconfig list 2>/dev/null || true)
    if [ -z "$_ugen_list" ]; then
        return
    fi

    echo "$_ugen_list" | while IFS= read -r _line; do
        # Format: ugenX.Y: <desc> ...
        _ugen=$(echo "$_line" | grep -oE '^ugen[0-9]+\.[0-9]+' || true)
        [ -z "$_ugen" ] && continue

        # Check if this device has an audio class interface
        _detail=$(usbconfig -d "$_ugen" dump_device_desc 2>/dev/null || true)

        # Get vendor/product IDs
        _vid=$(echo "$_detail" | grep -i 'idVendor' | grep -oE '0x[0-9a-fA-F]+' | head -1)
        _pid=$(echo "$_detail" | grep -i 'idProduct' | grep -oE '0x[0-9a-fA-F]+' | head -1)

        [ -z "$_vid" ] && continue

        # Check if this ugen maps to a pcm device (audio device)
        # Look in dmesg for uaudio association
        _is_audio=$(dmesg 2>/dev/null | grep -i "uaudio" | grep -i "${_ugen}" | head -1 || true)
        if [ -z "$_is_audio" ]; then
            # Also try matching by ugen bus/device number to pcm
            _bus=$(echo "$_ugen" | sed 's/ugen//' | cut -d. -f1)
            _dev=$(echo "$_ugen" | sed 's/ugen//' | cut -d. -f2)
            _is_audio=$(dmesg 2>/dev/null | grep -iE "pcm[0-9]+.*uaudio" | head -1 || true)
            # If we can't confirm it's audio, check the class
            if [ -z "$_is_audio" ]; then
                _has_audio_class=$(echo "$_detail" | grep -iE 'bInterfaceClass.*audio|Audio' || true)
                [ -z "$_has_audio_class" ] && continue
            fi
        fi

        # Get the description from the usbconfig list line
        _desc=$(echo "$_line" | sed "s/^${_ugen}: *//")

        # Find the associated /dev/dspN
        _pcm=""
        _pcm_match=$(dmesg 2>/dev/null | grep -oE "pcm[0-9]+" | sort -u || true)
        for _p in $_pcm_match; do
            _pnum=$(echo "$_p" | sed 's/pcm//')
            _pdesc=$(sysctl -n "dev.pcm.${_pnum}.%desc" 2>/dev/null || true)
            _pparent=$(sysctl -n "dev.pcm.${_pnum}.%parent" 2>/dev/null || true)
            if echo "$_pparent" | grep -qi "uaudio"; then
                _pcm="/dev/dsp${_pnum}"
                break
            fi
        done

        printf "%s %s %s %s %s\n" "$_ugen" "$_vid" "${_pid:-0x0000}" "${_pcm:--}" "$_desc"
    done
}

# Check if a devd conf already covers a vendor ID
find_devd_conf_for_vendor() {
    _vid=$1
    if [ ! -d "$DEVD_DIR" ]; then
        return 1
    fi
    _match=$(grep -rl "$_vid" "${DEVD_DIR}"/*.conf 2>/dev/null | head -1 || true)
    if [ -n "$_match" ]; then
        echo "$_match"
        return 0
    fi
    return 1
}

# Generate a devd conf for a USB audio device
generate_devd_conf() {
    _vid=$1
    _ctl=$2
    _dsp=$3
    _desc=$4

    cat <<EOF
# Auto-generated by configure-devd-audio.sh
# USB audio hotplug for: ${_desc}

notify 100 {
    match "system"    "USB";
    match "subsystem" "INTERFACE";
    match "type"      "ATTACH";
    match "vendor"    "${_vid}";
    action "/usr/local/sbin/virtual_oss_cmd ${_ctl} -f ${_dsp}";
};

notify 100 {
    match "system"    "USB";
    match "subsystem" "INTERFACE";
    match "type"      "DETACH";
    match "vendor"    "${_vid}";
    action "/usr/local/sbin/virtual_oss_cmd ${_ctl} -f /dev/null";
};
EOF
}

# Sanitise description into a filename
desc_to_filename() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-30
}

# ── Main ────────────────────────────────────────────────────────────────────
section "USB Audio Hotplug — devd Configuration"

# Preflight
if ! command -v usbconfig >/dev/null 2>&1; then
    fail "usbconfig not found"
    exit 1
fi

_ctl=$(detect_ctl_socket)
info "Control socket: ${_ctl}"

# Check devd dir
if [ ! -d "$DEVD_DIR" ]; then
    fail "${DEVD_DIR} does not exist"
    if ask_yes "Create ${DEVD_DIR}?"; then
        mkdir -p "$DEVD_DIR"
        ok "Created ${DEVD_DIR}"
    else
        exit 1
    fi
else
    ok "${DEVD_DIR} exists"
fi

# Discover USB audio devices
info "Scanning USB audio devices..."
_devices=$(discover_usb_audio)

if [ -z "$_devices" ]; then
    warn "No USB audio devices detected"
    info "Plug in a USB headset/DAC and re-run, or check 'usbconfig list'"
    exit 0
fi

ISSUES=0
FIXED=0

echo "$_devices" | while IFS= read -r _dev_line; do
    [ -z "$_dev_line" ] && continue

    _ugen=$(echo "$_dev_line" | awk '{print $1}')
    _vid=$(echo "$_dev_line" | awk '{print $2}')
    _pid=$(echo "$_dev_line" | awk '{print $3}')
    _dsp=$(echo "$_dev_line" | awk '{print $4}')
    _desc=$(echo "$_dev_line" | cut -d' ' -f5-)

    printf "\n"
    info "${_ugen}: ${_desc}"
    info "  Vendor: ${_vid}  Product: ${_pid}  Device: ${_dsp}"

    # Check for existing devd conf
    _existing=$(find_devd_conf_for_vendor "$_vid" 2>/dev/null || true)
    if [ -n "$_existing" ]; then
        ok "  devd rule exists: $(basename "$_existing")"

        # Validate content
        if grep -q "ATTACH" "$_existing" && grep -q "DETACH" "$_existing"; then
            ok "  Has both ATTACH and DETACH rules"
        else
            warn "  Missing ATTACH or DETACH rule in $(basename "$_existing")"
        fi

        # Check action points to correct device
        _action_dev=$(grep 'ATTACH' -A5 "$_existing" | grep 'action' | grep -oE '/dev/dsp[0-9]+' | head -1 || true)
        if [ -n "$_action_dev" ]; then
            if [ "$_dsp" != "-" ] && [ "$_action_dev" != "$_dsp" ]; then
                warn "  ATTACH action points to ${_action_dev} but device is ${_dsp}"
                if ask_yes "  Update to ${_dsp}?"; then
                    _conf=$(generate_devd_conf "$_vid" "$_ctl" "$_dsp" "$_desc")
                    printf "%s\n" "$_conf" > "$_existing"
                    ok "  Updated $(basename "$_existing")"
                fi
            else
                ok "  ATTACH action target: ${_action_dev}"
            fi
        fi
    else
        fail "  No devd rule for vendor ${_vid}"

        if [ "$_dsp" = "-" ]; then
            warn "  Could not detect /dev/dspN for this device"
            info "  Check 'cat /dev/sndstat' with the device plugged in"
            info "  Then create the rule manually or re-run this script"
            continue
        fi

        if ask_yes "  Create devd rule for ${_desc}?"; then
            _fname=$(desc_to_filename "$_desc")
            _conf_path="${DEVD_DIR}/${_fname}.conf"

            # Avoid overwriting
            _n=0
            while [ -f "$_conf_path" ]; do
                _n=$((_n + 1))
                _conf_path="${DEVD_DIR}/${_fname}-${_n}.conf"
            done

            _conf=$(generate_devd_conf "$_vid" "$_ctl" "$_dsp" "$_desc")
            printf "%s\n" "$_conf" > "$_conf_path"
            ok "  Created $(basename "$_conf_path")"

            info "  Contents:"
            echo "$_conf" | sed 's/^/    /'
        fi
    fi
done

# Check devd service
printf "\n"
section "devd Service"

if pgrep -x devd >/dev/null 2>&1; then
    ok "devd is running"

    if [ "$MODE" != "dryrun" ]; then
        if ask_yes "Restart devd to pick up new rules?"; then
            service devd restart >/dev/null 2>&1 && ok "devd restarted" || fail "devd restart failed"
        fi
    fi
else
    fail "devd is not running"
    if ask_yes "Start devd?"; then
        service devd start >/dev/null 2>&1 && ok "devd started" || fail "devd start failed"
    fi
fi

printf "\n"
ok "Done."
