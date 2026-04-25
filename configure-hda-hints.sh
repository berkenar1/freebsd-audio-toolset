#!/bin/sh
# configure-hda-hints.sh — Discover HDA topology and generate loader.conf hints
# Detects all HDA controllers, codecs, and pin widgets, then generates
# correct hint.hdaa.*.nid*.config lines for /boot/loader.conf.
#
# Usage:
#   ./configure-hda-hints.sh              — Display topology + interactive hint editor
#   ./configure-hda-hints.sh --dump       — Dump current topology (no changes)
#   ./configure-hda-hints.sh --apply      — Write generated hints to /boot/loader.conf
#   ./configure-hda-hints.sh --help       — Show this help

set -u

# ── Colours (real escape bytes so they work inside printf %s) ───────────────
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
section() { printf "\n${BOLD}${CYN}══ %s ══${RST}\n" "$1"; }
info()    { printf "  ${BOLD}[·]${RST}  %s\n" "$1"; }
ok()      { printf "  ${GRN}[✓]${RST}  %s\n" "$1"; }
warn()    { printf "  ${YLW}[!]${RST}  %s\n" "$1"; }
fail()    { printf "  ${RED}[✗]${RST}  %s\n" "$1"; }
dim()     { printf "  ${DIM}     %s${RST}\n" "$1"; }

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}configure-hda-hints.sh${RST} — FreeBSD HDA Pin Widget Discovery & Hint Generator

${BOLD}Usage:${RST}
  $0              Interactive mode: display topology, edit pin roles, generate hints
  $0 --dump       Read-only: dump full HDA topology and current pin configuration
  $0 --apply      Non-interactive: auto-detect and write hints to /boot/loader.conf
  $0 --help       Show this help

${BOLD}What it does:${RST}
  1. Discovers all HDA controllers (hdac), codecs (hdacc), and audio function groups (hdaa)
  2. Enumerates every pin widget with its current and original BIOS config
  3. Maps NIDs to PCM devices so you can see which pin drives which /dev/dsp*
  4. Generates hint.hdaa.X.nidN.config lines for /boot/loader.conf
  5. Optionally lets you reassign pin roles (headphones ↔ speaker) interactively

${BOLD}Requires:${RST} FreeBSD with snd_hda(4) loaded.
EOF
    exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
MODE="interactive"
case "${1:-}" in
    --dump)    MODE="dump"    ;;
    --apply)   MODE="apply"   ;;
    --help|-h) usage          ;;
    "")        MODE="interactive" ;;
    *)         printf "${RED}Unknown option: %s${RST}\n" "$1"; usage ;;
esac

# ── Preflight checks ───────────────────────────────────────────────────────
if ! sysctl -N dev.hdac 2>/dev/null | grep -q dev.hdac; then
    fail "No HDA controllers found (dev.hdac sysctl tree missing)"
    fail "Is snd_hda_core / snd_hda loaded?  Try: kldload snd_hda"
    exit 1
fi

# ── Discover HDA controllers ───────────────────────────────────────────────
discover_controllers() {
    sysctl -N dev.hdac 2>/dev/null \
        | grep -oE 'dev\.hdac\.[0-9]+' \
        | sed 's/dev\.hdac\.//' \
        | sort -un
}

# ── Discover codecs on a controller ────────────────────────────────────────
discover_codecs() {
    _ctrl=$1
    sysctl -N dev.hdacc 2>/dev/null \
        | grep -oE 'dev\.hdacc\.[0-9]+' \
        | sed 's/dev\.hdacc\.//' \
        | sort -un \
        | while read -r _cc; do
            _parent=$(sysctl -n dev.hdacc.${_cc}.%parent 2>/dev/null)
            if [ "$_parent" = "hdac${_ctrl}" ]; then
                echo "$_cc"
            fi
        done
}

# ── Discover audio function groups on a codec ──────────────────────────────
discover_afgs() {
    _codec=$1
    sysctl -N dev.hdaa 2>/dev/null \
        | grep -oE 'dev\.hdaa\.[0-9]+' \
        | sed 's/dev\.hdaa\.//' \
        | sort -un \
        | while read -r _aa; do
            _parent=$(sysctl -n dev.hdaa.${_aa}.%parent 2>/dev/null)
            if [ "$_parent" = "hdacc${_codec}" ]; then
                echo "$_aa"
            fi
        done
}

# ── Discover pin widgets on an AFG ─────────────────────────────────────────
# Returns NID numbers that have _config sysctl (i.e. are pin widgets)
discover_pins() {
    _afg=$1
    sysctl -N dev.hdaa.${_afg} 2>/dev/null \
        | grep -oE "dev\.hdaa\.${_afg}\.nid[0-9]+_config" \
        | sed "s/dev\.hdaa\.${_afg}\.nid//;s/_config//" \
        | sort -n
}

# ── Parse pin config string into fields ────────────────────────────────────
# Input: "0x03211020 as=2 seq=0 device=Headphones conn=Jack ctype=1/8 loc=Left color=Black misc=0"
parse_pin_field() {
    _config=$1
    _field=$2
    echo "$_config" | grep -oE "${_field}=[^ ]+" | cut -d= -f2
}

# ── Get PCM device mapping for a NID ──────────────────────────────────────
get_pcm_for_nid() {
    _afg=$1
    _nid=$2
    _parent="hdaa${_afg}"
    # Search all pcm devices for one whose parent matches and location contains this NID
    _pcm_units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un)
    for _pu in $_pcm_units; do
        _pp=$(sysctl -n dev.pcm.${_pu}.%parent 2>/dev/null || true)
        if [ "$_pp" = "$_parent" ]; then
            _loc=$(sysctl -n dev.pcm.${_pu}.%location 2>/dev/null || true)
            case "$_loc" in
                *"${_nid}"*) echo "pcm${_pu}"; return ;;
            esac
        fi
    done
    echo "-"
}

# ── Build complete topology map ────────────────────────────────────────────
# Stores results in a temp file as tab-separated rows:
# ctrl  codec  cad  afg  nid  hex  device  conn  ctype  loc  color  as  seq  misc  state  pcm  desc  original_hex
build_topology() {
    _outfile=$1
    : > "$_outfile"

    for ctrl in $(discover_controllers); do
        _ctrl_desc=$(sysctl -n dev.hdac.${ctrl}.%desc 2>/dev/null || echo "Unknown")
        for codec in $(discover_codecs "$ctrl"); do
            _codec_desc=$(sysctl -n dev.hdacc.${codec}.%desc 2>/dev/null || echo "Unknown")
            _cad=$(sysctl -n dev.hdacc.${codec}.%location 2>/dev/null | sed 's/cad=//')
            for afg in $(discover_afgs "$codec"); do
                for nid in $(discover_pins "$afg"); do
                    _config=$(sysctl -n dev.hdaa.${afg}.nid${nid}_config 2>/dev/null || true)
                    _original=$(sysctl -n dev.hdaa.${afg}.nid${nid}_original 2>/dev/null || true)
                    _summary=$(sysctl -n dev.hdaa.${afg}.nid${nid} 2>/dev/null || true)
                    [ -z "$_config" ] && continue

                    _hex=$(echo "$_config" | awk '{print $1}')
                    _orig_hex=$(echo "$_original" | awk '{print $1}')
                    _device=$(parse_pin_field "$_config" "device")
                    _conn=$(parse_pin_field "$_config" "conn")
                    _ctype=$(parse_pin_field "$_config" "ctype")
                    _loc=$(parse_pin_field "$_config" "loc")
                    _color=$(parse_pin_field "$_config" "color")
                    _as=$(parse_pin_field "$_config" "as")
                    _seq=$(parse_pin_field "$_config" "seq")
                    _misc=$(parse_pin_field "$_config" "misc")

                    # Check if pin is disabled
                    _state="active"
                    case "$_summary" in
                        *DISABLED*) _state="disabled" ;;
                    esac

                    # Check if config has been overridden
                    _modified="no"
                    if [ "$_hex" != "$_orig_hex" ]; then
                        _modified="yes"
                    fi

                    _pcm=$(get_pcm_for_nid "$afg" "$nid")

                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                        "$ctrl" "$_ctrl_desc" "$codec" "$_codec_desc" "$_cad" \
                        "$afg" "$nid" "$_hex" "$_device" "$_conn" "$_ctype" \
                        "$_loc" "$_color" "$_as" "$_seq" "$_misc" \
                        "$_state" "$_pcm" "$_modified" "$_orig_hex" \
                        >> "$_outfile"
                done
            done
        done
    done
}

# ── Pretty-print the topology ─────────────────────────────────────────────
print_topology() {
    _topofile=$1
    _prev_ctrl=""
    _prev_codec=""

    while IFS='	' read -r ctrl ctrl_desc codec codec_desc cad afg nid hex \
            device conn ctype loc color as seq misc state pcm modified orig_hex; do

        # Print controller header on change
        if [ "$ctrl" != "$_prev_ctrl" ]; then
            header
            printf "  ${BOLD}${WHT}HDA Controller: hdac%s${RST}\n" "$ctrl"
            printf "  ${DIM}%s${RST}\n" "$ctrl_desc"
            _prev_ctrl="$ctrl"
            _prev_codec=""
        fi

        # Print codec header on change
        if [ "$codec" != "$_prev_codec" ]; then
            section "Codec: hdacc${codec} (cad=${cad}) — ${codec_desc}"
            printf "\n"
            # Table header
            printf "  ${BOLD}${DIM}%-5s  %-14s  %-6s  %-8s  %-10s  %-8s  %-5s  %-5s  %-6s  %-8s  %-6s${RST}\n" \
                "NID" "Device" "Conn" "CType" "Location" "Color" "AS" "Seq" "State" "PCM" "Mod?"
            printf "  ${DIM}%-5s  %-14s  %-6s  %-8s  %-10s  %-8s  %-5s  %-5s  %-6s  %-8s  %-6s${RST}\n" \
                "───" "──────────────" "──────" "────────" "──────────" "────────" "─────" "─────" "──────" "────────" "──────"
            _prev_codec="$codec"
        fi

        # Color the state
        case "$state" in
            active)   _st="${GRN}active${RST}" ;;
            disabled) _st="${RED}off${RST}   " ;;
            *)        _st="$state" ;;
        esac

        # Color the device type
        case "$device" in
            Headphones)  _dev="${MAG}${BOLD}Headphones${RST}    " ;;
            Speaker)     _dev="${BLU}${BOLD}Speaker${RST}       " ;;
            Mic)         _dev="${YLW}Mic${RST}           " ;;
            Digital-out) _dev="${CYN}Digital-out${RST}   " ;;
            Line-out)    _dev="${WHT}Line-out${RST}      " ;;
            Modem-line)  _dev="${DIM}Modem-line${RST}    " ;;
            *)           _dev="$(printf '%-14s' "$device")" ;;
        esac

        # Highlight modified configs
        case "$modified" in
            yes) _mod="${YLW}yes${RST}   " ;;
            *)   _mod="${DIM}no${RST}    " ;;
        esac

        printf "  %-5s  %s  %-6s  %-8s  %-10s  %-8s  %-5s  %-5s  %s  %-8s  %s\n" \
            "$nid" "$_dev" "$conn" "$ctype" "$loc" "$color" "$as" "$seq" \
            "$_st" "$pcm" "$_mod"

    done < "$_topofile"
}

# ── Print PCM → NID mapping ───────────────────────────────────────────────
print_pcm_map() {
    section "PCM Device → NID Mapping"
    printf "\n"

    _pcm_units=$(sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un)

    printf "  ${BOLD}${DIM}%-8s  %-45s  %-10s  %-10s${RST}\n" \
        "Device" "Description" "Parent" "Location"
    printf "  ${DIM}%-8s  %-45s  %-10s  %-10s${RST}\n" \
        "────────" "─────────────────────────────────────────────" "──────────" "──────────"

    for pu in $_pcm_units; do
        _desc=$(sysctl -n dev.pcm.${pu}.%desc 2>/dev/null || echo "(unknown)")
        _parent=$(sysctl -n dev.pcm.${pu}.%parent 2>/dev/null || echo "-")
        _loc=$(sysctl -n dev.pcm.${pu}.%location 2>/dev/null || echo "-")
        printf "  ${GRN}pcm%-5s${RST}  %-45s  %-10s  %-10s\n" \
            "$pu" "$_desc" "$_parent" "$_loc"
    done
}

# ── Print existing loader.conf hints ──────────────────────────────────────
print_existing_hints() {
    section "Current /boot/loader.conf HDA Hints"
    printf "\n"

    if [ ! -r /boot/loader.conf ]; then
        warn "/boot/loader.conf not readable"
        return
    fi

    _hints=$(grep -nE '^[^#]*hint\.(hdac|hdaa|hdacc)\.' /boot/loader.conf 2>/dev/null || true)
    _commented=$(grep -nE '^#.*hint\.(hdac|hdaa|hdacc)\.' /boot/loader.conf 2>/dev/null || true)

    if [ -n "$_hints" ]; then
        ok "Active hints:"
        printf "%s\n" "$_hints" | while IFS= read -r line; do
            dim "${GRN}${line}${RST}"
        done
    else
        info "No active HDA hints found"
    fi

    if [ -n "$_commented" ]; then
        info "Commented-out hints:"
        printf "%s\n" "$_commented" | while IFS= read -r line; do
            dim "${DIM}${line}${RST}"
        done
    fi
}

# ── Generate hint lines for active output pins ───────────────────────────
# Uses the hint.hdaa.X.nidN.config= format (modern FreeBSD ≥ 13)
generate_hints() {
    _topofile=$1
    _generated=""
    _count=0

    while IFS='	' read -r ctrl ctrl_desc codec codec_desc cad afg nid hex \
            device conn ctype loc color as seq misc state pcm modified orig_hex; do

        # Only generate for active, connected pin widgets
        case "$conn" in
            None) continue ;;
        esac
        case "$state" in
            disabled) continue ;;
        esac

        # Include output devices (Headphones, Speaker, Digital-out, Line-out) and input (Mic)
        case "$device" in
            Headphones|Speaker|Digital-out|Line-out|Mic) ;;
            *) continue ;;
        esac

        _line="hint.hdaa.${afg}.nid${nid}.config=\"${hex}\""
        _generated="${_generated}${_line}
"
        _count=$((_count + 1))

    done < "$_topofile"

    echo "$_generated"
}

# ── Interactive pin role editor ───────────────────────────────────────────
interactive_edit() {
    _topofile=$1

    printf "\n${BOLD}${CYN}━━ Interactive Pin Role Editor ━━${RST}\n\n"
    printf "  You can reassign pin roles to fix headphone/speaker detection.\n"
    printf "  Common adjustments:\n"
    printf "    ${MAG}Headphones${RST}  → The jack you plug headphones into\n"
    printf "    ${BLU}Speaker${RST}     → Built-in / fixed speakers\n"
    printf "    ${YLW}Mic${RST}         → Microphone input\n\n"

    # List editable pins
    _editable_count=0
    _editable_nids=""
    while IFS='	' read -r ctrl ctrl_desc codec codec_desc cad afg nid hex \
            device conn ctype loc color as seq misc state pcm modified orig_hex; do
        case "$conn" in None) continue ;; esac
        case "$state" in disabled) continue ;; esac
        case "$device" in Headphones|Speaker|Mic|Line-out|Digital-out) ;; *) continue ;; esac

        _editable_count=$((_editable_count + 1))
        _editable_nids="${_editable_nids} ${afg}:${nid}:${device}:${hex}:${as}:${seq}"
        printf "  ${BOLD}%2d)${RST}  hdaa%s nid%-3s  currently: ${BOLD}%-12s${RST}  conn=%-5s  as=%s seq=%s\n" \
            "$_editable_count" "$afg" "$nid" "$device" "$conn" "$as" "$seq"
    done < "$_topofile"

    if [ "$_editable_count" -eq 0 ]; then
        warn "No editable pins found"
        return
    fi

    printf "\n  ${DIM}Enter pin number to edit, or press Enter to skip: ${RST}"
    read -r _choice
    [ -z "$_choice" ] && return

    # Validate choice
    _idx=0
    _sel_afg="" _sel_nid="" _sel_device="" _sel_hex="" _sel_as="" _sel_seq=""
    for _entry in $_editable_nids; do
        _idx=$((_idx + 1))
        if [ "$_idx" -eq "$_choice" ] 2>/dev/null; then
            _sel_afg=$(echo "$_entry" | cut -d: -f1)
            _sel_nid=$(echo "$_entry" | cut -d: -f2)
            _sel_device=$(echo "$_entry" | cut -d: -f3)
            _sel_hex=$(echo "$_entry" | cut -d: -f4)
            _sel_as=$(echo "$_entry" | cut -d: -f5)
            _sel_seq=$(echo "$_entry" | cut -d: -f6)
            break
        fi
    done

    if [ -z "$_sel_nid" ]; then
        fail "Invalid selection"
        return
    fi

    printf "\n  Selected: ${BOLD}hdaa%s nid%s${RST} (currently %s)\n" \
        "$_sel_afg" "$_sel_nid" "$_sel_device"
    printf "  Change device role to:\n"
    printf "    ${BOLD}1)${RST}  Headphones\n"
    printf "    ${BOLD}2)${RST}  Speaker\n"
    printf "    ${BOLD}3)${RST}  Line-out\n"
    printf "    ${BOLD}4)${RST}  Mic\n"
    printf "    ${BOLD}5)${RST}  Cancel\n"
    printf "\n  ${DIM}Choice: ${RST}"
    read -r _role

    case "$_role" in
        1) _new_device="Headphones" ;;
        2) _new_device="Speaker"    ;;
        3) _new_device="Line-out"   ;;
        4) _new_device="Mic"        ;;
        *) info "Cancelled"; return ;;
    esac

    # Build new config hex based on the device role change
    # The device field is bits 24-20 of the config default:
    #   0x0 = Line-out   0x1 = Speaker   0x2 = Headphones
    #   0x4 = S/PDIF out 0x5 = Digital-out
    #   0x8 = Line-in    0x9 = Aux       0xa = Mic
    _base_hex=$(printf "%d" "$_sel_hex")
    # Clear device field (bits 24-20): mask = ~(0xF << 20) = ~0x00F00000 = 0xFF0FFFFF
    _cleared=$(( _base_hex & 0xFF0FFFFF ))
    case "$_new_device" in
        Line-out)    _dev_bits=0x00000000 ;;
        Speaker)     _dev_bits=0x00100000 ;;
        Headphones)  _dev_bits=0x00200000 ;;
        Mic)         _dev_bits=0x00A00000 ;;
    esac
    _new_hex=$(printf "0x%08x" $(( _cleared | _dev_bits )) )

    printf "\n"
    ok "New config for hdaa${_sel_afg}.nid${_sel_nid}: ${_new_hex} (device=${_new_device})"

    # Offer to apply via sysctl (runtime) or save to loader.conf (persistent)
    printf "\n  ${BOLD}Apply this change?${RST}\n"
    printf "    ${BOLD}1)${RST}  Runtime only (sysctl, lost on reboot)\n"
    printf "    ${BOLD}2)${RST}  Persistent (/boot/loader.conf, needs reboot)\n"
    printf "    ${BOLD}3)${RST}  Both\n"
    printf "    ${BOLD}4)${RST}  Just show the commands (do nothing)\n"
    printf "\n  ${DIM}Choice: ${RST}"
    read -r _apply

    _sysctl_cmd="sysctl dev.hdaa.${_sel_afg}.nid${_sel_nid}_config=\"${_new_hex}\""
    _reconfig_cmd="sysctl dev.hdaa.${_sel_afg}.reconfig=1"
    _hint_line="hint.hdaa.${_sel_afg}.nid${_sel_nid}.config=\"${_new_hex}\""

    case "$_apply" in
        1)
            printf "\n"
            info "Applying runtime change..."
            eval "$_sysctl_cmd"
            eval "$_reconfig_cmd"
            ok "Runtime config applied. Run 'cat /dev/sndstat' to verify."
            ;;
        2)
            printf "\n"
            _apply_loader_hint "$_sel_afg" "$_sel_nid" "$_new_hex"
            ok "Hint written to /boot/loader.conf. Reboot to activate."
            ;;
        3)
            printf "\n"
            info "Applying runtime change..."
            eval "$_sysctl_cmd"
            eval "$_reconfig_cmd"
            _apply_loader_hint "$_sel_afg" "$_sel_nid" "$_new_hex"
            ok "Applied both. Runtime is active; loader.conf updated for persistence."
            ;;
        4)
            printf "\n"
            info "Runtime commands:"
            printf "    ${GRN}%s${RST}\n" "$_sysctl_cmd"
            printf "    ${GRN}%s${RST}\n" "$_reconfig_cmd"
            info "Loader hint:"
            printf "    ${GRN}%s${RST}\n" "$_hint_line"
            ;;
        *)
            info "Cancelled"
            ;;
    esac
}

# ── Write/update a hint in /boot/loader.conf ──────────────────────────────
_apply_loader_hint() {
    _l_afg=$1
    _l_nid=$2
    _l_hex=$3
    _l_pattern="hint.hdaa.${_l_afg}.nid${_l_nid}.config="
    _l_line="hint.hdaa.${_l_afg}.nid${_l_nid}.config=\"${_l_hex}\""

    if [ ! -w /boot/loader.conf ]; then
        fail "/boot/loader.conf is not writable (run as root)"
        info "Manual addition:"
        printf "    ${GRN}%s${RST}\n" "$_l_line"
        return 1
    fi

    if grep -q "^${_l_pattern}" /boot/loader.conf 2>/dev/null; then
        # Update existing line in-place
        _escaped_line=$(printf '%s\n' "$_l_line" | sed 's/[&/\]/\\&/g')
        sed -i '' "s|^${_l_pattern}.*|${_escaped_line}|" /boot/loader.conf
        ok "Updated existing hint in /boot/loader.conf"
    elif grep -q "^#.*${_l_pattern}" /boot/loader.conf 2>/dev/null; then
        # Replace commented-out version
        _escaped_line=$(printf '%s\n' "$_l_line" | sed 's/[&/\]/\\&/g')
        sed -i '' "s|^#.*${_l_pattern}.*|${_escaped_line}|" /boot/loader.conf
        ok "Uncommented and updated hint in /boot/loader.conf"
    else
        # Append
        printf "\n# HDA pin hint — auto-generated by configure-hda-hints.sh\n%s\n" \
            "$_l_line" >> /boot/loader.conf
        ok "Appended hint to /boot/loader.conf"
    fi
}

# ── Summary section with recommended hints ─────────────────────────────────
print_recommendations() {
    _topofile=$1

    section "Recommended /boot/loader.conf Hints"
    printf "\n"
    info "Based on detected topology — copy these into /boot/loader.conf:"
    printf "\n"

    _hints=$(generate_hints "$_topofile")
    if [ -z "$_hints" ]; then
        warn "No active output/input pins detected"
        return
    fi

    printf "${DIM}  # ── HDA pin widget hints (auto-detected) ──────────────────${RST}\n"
    printf "%s" "$_hints" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf "  ${GRN}%s${RST}\n" "$line"
    done
    printf "\n"

    # Check for differences with current loader.conf
    _current_hints=$(grep -E '^[^#]*hint\.hdaa\.' /boot/loader.conf 2>/dev/null || true)
    if [ -n "$_current_hints" ]; then
        _diff_found=0
        printf "%s" "$_hints" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            _key=$(echo "$line" | cut -d= -f1)
            _existing=$(echo "$_current_hints" | grep "^${_key}=" || true)
            if [ -z "$_existing" ]; then
                warn "NEW: ${line}"
                _diff_found=1
            elif [ "$_existing" != "$line" ]; then
                warn "CHANGED: ${_existing} → ${line}"
                _diff_found=1
            fi
        done
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TOPO_FILE=$(mktemp /tmp/hda_topo.XXXXXX)
trap 'rm -f "$TOPO_FILE"' EXIT

printf "\n${BOLD}${CYN}FreeBSD HDA Pin Widget Configurator${RST}\n"
printf "${DIM}  Scanning hardware...${RST}\n"

build_topology "$TOPO_FILE"

if [ ! -s "$TOPO_FILE" ]; then
    fail "No pin widgets discovered. Is snd_hda loaded?"
    exit 1
fi

case "$MODE" in
    dump)
        print_topology "$TOPO_FILE"
        printf "\n"
        print_pcm_map
        print_existing_hints
        print_recommendations "$TOPO_FILE"
        ;;
    interactive)
        print_topology "$TOPO_FILE"
        printf "\n"
        print_pcm_map
        print_existing_hints
        print_recommendations "$TOPO_FILE"
        interactive_edit "$TOPO_FILE"
        ;;
    apply)
        printf "\n"
        info "Auto-applying detected pin hints to /boot/loader.conf..."
        _hints=$(generate_hints "$TOPO_FILE")
        if [ -z "$_hints" ]; then
            fail "No hints to apply"
            exit 1
        fi
        printf "%s" "$_hints" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            _afg=$(echo "$line" | grep -oE 'hdaa\.[0-9]+' | sed 's/hdaa\.//')
            _nid=$(echo "$line" | grep -oE 'nid[0-9]+' | sed 's/nid//')
            _hex=$(echo "$line" | grep -oE '"[^"]*"' | tr -d '"')
            _apply_loader_hint "$_afg" "$_nid" "$_hex"
        done
        ok "All hints applied. Reboot to activate."
        ;;
esac

printf "\n"
