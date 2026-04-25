#!/bin/sh
# configure-sysctl-audio.sh — FreeBSD Audio Sysctl Tuner
# Inspects current hw.snd.* and dev.pcm.* tunables, shows their meaning,
# lets you interactively adjust them, and writes changes to /etc/sysctl.conf.
#
# Usage:
#   ./configure-sysctl-audio.sh              — Interactive tuning wizard
#   ./configure-sysctl-audio.sh --dump       — Read-only: show current state
#   ./configure-sysctl-audio.sh --profile X  — Apply a preset profile (see below)
#   ./configure-sysctl-audio.sh --help       — Show this help
#
# Profiles:
#   low-latency    — For real-time audio / music production
#   desktop        — Balanced for daily use
#   server         — Conservative, high buffer headroom
#   bitperfect     — Bypass mixing, direct hardware passthrough

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
section() { printf "\n${BOLD}${CYN}══ %s ══${RST}\n" "$1"; }
info()    { printf "  ${BOLD}[·]${RST}  %s\n" "$1"; }
ok()      { printf "  ${GRN}[✓]${RST}  %s\n" "$1"; }
warn()    { printf "  ${YLW}[!]${RST}  %s\n" "$1"; }
fail()    { printf "  ${RED}[✗]${RST}  %s\n" "$1"; }
dim()     { printf "  ${DIM}     %s${RST}\n" "$1"; }

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}configure-sysctl-audio.sh${RST} — FreeBSD Audio Sysctl Tuner

${BOLD}Usage:${RST}
  $0                     Interactive tuning wizard
  $0 --dump              Read-only: display all audio sysctls with annotations
  $0 --profile <name>    Apply a preset profile

${BOLD}Profiles:${RST}
  ${GRN}low-latency${RST}    Minimum buffer, aggressive timing — for DAWs / real-time
  ${GRN}desktop${RST}        Balanced latency and stability — daily use
  ${GRN}server${RST}         Maximum buffer, high stability — headless / streaming
  ${GRN}bitperfect${RST}     Bypass software mixing — audiophile direct-to-DAC

${BOLD}What it tunes:${RST}
  hw.snd.default_unit      — Which PCM device is the default
  hw.snd.latency           — Buffer depth (0=low .. 10=high)
  hw.snd.latency_profile   — Buffer strategy (0=aggressive, 1=safe)
  hw.snd.feeder_rate_quality — Sample rate conversion quality (0..4)
  hw.snd.vpc_0db           — 0dB reference level for VPC
  dev.pcm.X.play.vchans    — Virtual channels per playback device
  dev.pcm.X.rec.vchans     — Virtual channels per recording device
  dev.pcm.X.play.vchanrate — Mixing sample rate
  dev.pcm.X.play.vchanformat — Mixing format (bit depth / channels)
  dev.pcm.X.play.vchanmode — Channel mode (fixed/passthrough/adaptive)
  dev.pcm.X.bitperfect     — Hardware passthrough (bypass mixing)

${BOLD}Requires:${RST} FreeBSD with snd(4) loaded.
EOF
    exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
MODE="interactive"
PROFILE=""
case "${1:-}" in
    --dump)       MODE="dump"    ;;
    --profile)
        MODE="profile"
        PROFILE="${2:-}"
        if [ -z "$PROFILE" ]; then
            fail "Missing profile name. Options: low-latency, desktop, server, bitperfect"
            exit 1
        fi
        ;;
    --help|-h)    usage          ;;
    "")           MODE="interactive" ;;
    *)            printf "${RED}Unknown option: %s${RST}\n" "$1"; usage ;;
esac

# ── Preflight ───────────────────────────────────────────────────────────────
_snd_check=$(sysctl hw.snd.latency 2>/dev/null || true)
if [ -z "$_snd_check" ]; then
    fail "hw.snd sysctl tree not available — is snd(4) loaded?"
    exit 1
fi

# ── Discover PCM devices ───────────────────────────────────────────────────
discover_pcm_units() {
    sysctl -N dev.pcm 2>/dev/null \
        | grep -oE 'dev\.pcm\.[0-9]+' \
        | sed 's/dev\.pcm\.//' \
        | sort -un
}

# ── Sysctl value with fallback ─────────────────────────────────────────────
sval() { sysctl -n "$1" 2>/dev/null || echo "${2:--}"; }

# ── Pretty-print a tunable with context ────────────────────────────────────
show_tunable() {
    _key=$1
    _val=$(sval "$_key")
    _desc=$2
    _range=$3
    _assess=$4

    printf "  ${BOLD}%-42s${RST} = ${WHT}%-10s${RST}" "$_key" "$_val"

    # Assessment coloring
    case "$_assess" in
        good) printf " ${GRN}●${RST}" ;;
        warn) printf " ${YLW}●${RST}" ;;
        bad)  printf " ${RED}●${RST}" ;;
        *)    printf " ${DIM}○${RST}" ;;
    esac

    printf "\n"
    dim "$_desc"
    [ -n "$_range" ] && dim "${DIM}Range: ${_range}${RST}"
}

# ── Assess a tunable value ─────────────────────────────────────────────────
assess_latency() {
    _v=$1
    if [ "$_v" -le 2 ] 2>/dev/null; then echo "good"
    elif [ "$_v" -le 5 ] 2>/dev/null; then echo "neutral"
    else echo "warn"
    fi
}

assess_rate_quality() {
    _v=$1
    if [ "$_v" -ge 2 ] 2>/dev/null; then echo "good"
    elif [ "$_v" -ge 1 ] 2>/dev/null; then echo "neutral"
    else echo "warn"
    fi
}

# ── Print global tunables ──────────────────────────────────────────────────
print_global_tunables() {
    section "Global Audio Tunables (hw.snd.*)"
    printf "\n"

    _lat=$(sval hw.snd.latency)
    _latprof=$(sval hw.snd.latency_profile)
    _defunit=$(sval hw.snd.default_unit)
    _defauto=$(sval hw.snd.default_auto)
    _rateq=$(sval hw.snd.feeder_rate_quality)
    _vpc0db=$(sval hw.snd.vpc_0db)
    _vpcrst=$(sval hw.snd.vpc_autoreset)
    _vpcbyp=$(sval hw.snd.vpc_mixer_bypass)
    _verbose=$(sval hw.snd.verbose)
    _vchans=$(sval hw.snd.vchans_enable)
    _timeout=$(sval hw.snd.timeout)

    show_tunable "hw.snd.default_unit" \
        "Default output device (pcm unit number)" \
        "0..N (see PCM devices below)" \
        "neutral"

    # Show what the default unit actually is
    _def_desc=$(sval "dev.pcm.${_defunit}.%desc" "(unknown)")
    dim "${CYN}Currently: pcm${_defunit} = ${_def_desc}${RST}"
    printf "\n"

    show_tunable "hw.snd.default_auto" \
        "Auto-assign default to newly attached device (e.g. USB headset)" \
        "0=disabled, 1=enabled" \
        "neutral"
    printf "\n"

    show_tunable "hw.snd.latency" \
        "Buffer depth — lower = less delay, higher = fewer underruns" \
        "0 (lowest) .. 10 (highest)" \
        "$(assess_latency "$_lat")"

    show_tunable "hw.snd.latency_profile" \
        "Buffer sizing strategy" \
        "0=aggressive (tight), 1=safe (padded)" \
        "neutral"
    printf "\n"

    show_tunable "hw.snd.feeder_rate_quality" \
        "SRC (sample rate converter) interpolation quality" \
        "0=low .. 4=high (higher = more CPU, better quality)" \
        "$(assess_rate_quality "$_rateq")"
    printf "\n"

    show_tunable "hw.snd.vchans_enable" \
        "Master switch for virtual channels (software mixing)" \
        "0=disabled, 1=enabled" \
        "$([ "$_vchans" = "1" ] && echo "good" || echo "warn")"
    printf "\n"

    show_tunable "hw.snd.vpc_0db" \
        "0dB reference level for volume per-channel" \
        "0=hardware max, 1=software max" \
        "neutral"

    show_tunable "hw.snd.vpc_autoreset" \
        "Auto-reset channel volume to 0dB on open" \
        "0=keep last, 1=reset" \
        "neutral"

    show_tunable "hw.snd.vpc_mixer_bypass" \
        "Bypass real mixer for per-channel volume control" \
        "0=use hardware mixer, 1=software VPC only" \
        "neutral"
    printf "\n"

    show_tunable "hw.snd.verbose" \
        "Verbosity in /dev/sndstat (0=quiet, 1..4=increasing detail)" \
        "0..4" \
        "neutral"

    show_tunable "hw.snd.timeout" \
        "Interrupt timeout in seconds" \
        "1..10" \
        "neutral"
}

# ── Print per-device tunables ──────────────────────────────────────────────
print_per_device_tunables() {
    section "Per-Device Tunables (dev.pcm.*)"
    printf "\n"

    # Table header
    printf "  ${BOLD}${DIM}%-7s  %-40s  %-5s  %-5s  %-8s  %-8s  %-10s  %-4s${RST}\n" \
        "Device" "Description" "P.Vch" "R.Vch" "Rate" "Format" "Mode" "Perf"
    printf "  ${DIM}%-7s  %-40s  %-5s  %-5s  %-8s  %-8s  %-10s  %-4s${RST}\n" \
        "───────" "────────────────────────────────────────" "─────" "─────" "────────" "────────" "──────────" "────"

    for unit in $(discover_pcm_units); do
        _desc=$(sval "dev.pcm.${unit}.%desc" "(unknown)")
        _pvch=$(sval "dev.pcm.${unit}.play.vchans" "-")
        _rvch=$(sval "dev.pcm.${unit}.rec.vchans" "-")
        _prate=$(sval "dev.pcm.${unit}.play.vchanrate" "-")
        _pfmt=$(sval "dev.pcm.${unit}.play.vchanformat" "-")
        _pmode=$(sval "dev.pcm.${unit}.play.vchanmode" "-")
        _bp=$(sval "dev.pcm.${unit}.bitperfect" "-")

        # Translate mode number
        case "$_pmode" in
            0|fixed)       _pmode_s="fixed" ;;
            1|passthrough) _pmode_s="passthru" ;;
            2|adaptive)    _pmode_s="adaptive" ;;
            *)             _pmode_s="$_pmode" ;;
        esac

        # Color the bitperfect flag
        case "$_bp" in
            1) _bp_s="${MAG}on${RST} " ;;
            0) _bp_s="${DIM}off${RST}" ;;
            *) _bp_s="$_bp" ;;
        esac

        # Highlight default unit
        _unit_s="pcm${unit}"
        _defunit=$(sval hw.snd.default_unit)
        if [ "$unit" = "$_defunit" ]; then
            _unit_s="${GRN}pcm${unit}*${RST} "
        fi

        printf "  %-7s  %-40s  %-5s  %-5s  %-8s  %-8s  %-10s  %s\n" \
            "$_unit_s" "$_desc" "$_pvch" "$_rvch" "$_prate" "$_pfmt" "$_pmode_s" "$_bp_s"
    done

    printf "\n"
    dim "${GRN}*${RST} = default unit"
}

# ── Print current /etc/sysctl.conf audio entries ──────────────────────────
print_existing_sysctl_conf() {
    section "Current /etc/sysctl.conf Audio Entries"
    printf "\n"

    if [ ! -r /etc/sysctl.conf ]; then
        warn "/etc/sysctl.conf not readable"
        return
    fi

    _audio=$(grep -nE '^[^#]*(hw\.snd\.|dev\.pcm\.)' /etc/sysctl.conf 2>/dev/null || true)
    _commented=$(grep -nE '^#.*(hw\.snd\.|dev\.pcm\.)' /etc/sysctl.conf 2>/dev/null || true)

    if [ -n "$_audio" ]; then
        ok "Active entries:"
        printf "%s\n" "$_audio" | while IFS= read -r line; do
            printf "    ${GRN}%s${RST}\n" "$line"
        done
    else
        info "No active audio sysctls found"
    fi

    if [ -n "$_commented" ]; then
        info "Commented-out entries:"
        printf "%s\n" "$_commented" | while IFS= read -r line; do
            printf "    ${DIM}%s${RST}\n" "$line"
        done
    fi
}

# ── Profile definitions ───────────────────────────────────────────────────
# Each profile is a set of key=value pairs
profile_low_latency() {
    cat <<'EOF'
hw.snd.latency=0
hw.snd.latency_profile=0
hw.snd.feeder_rate_quality=4
hw.snd.vpc_0db=1
hw.snd.vpc_autoreset=1
EOF
    for unit in $(discover_pcm_units); do
        _has_play=$(sysctl -N dev.pcm.${unit}.play.vchans 2>/dev/null || true)
        _has_rec=$(sysctl -N dev.pcm.${unit}.rec.vchans 2>/dev/null || true)
        if [ -n "$_has_play" ]; then
            echo "dev.pcm.${unit}.play.vchans=4"
            echo "dev.pcm.${unit}.play.vchanrate=48000"
            echo "dev.pcm.${unit}.play.vchanmode=adaptive"
        fi
        if [ -n "$_has_rec" ]; then
            echo "dev.pcm.${unit}.rec.vchans=2"
            echo "dev.pcm.${unit}.rec.vchanrate=48000"
            echo "dev.pcm.${unit}.rec.vchanmode=adaptive"
        fi
    done
}

profile_desktop() {
    cat <<'EOF'
hw.snd.latency=2
hw.snd.latency_profile=1
hw.snd.feeder_rate_quality=2
hw.snd.vpc_0db=1
hw.snd.vpc_autoreset=1
EOF
    for unit in $(discover_pcm_units); do
        _has_play=$(sysctl -N dev.pcm.${unit}.play.vchans 2>/dev/null || true)
        _has_rec=$(sysctl -N dev.pcm.${unit}.rec.vchans 2>/dev/null || true)
        if [ -n "$_has_play" ]; then
            echo "dev.pcm.${unit}.play.vchans=4"
            echo "dev.pcm.${unit}.play.vchanrate=48000"
            echo "dev.pcm.${unit}.play.vchanformat=s16le:2.0"
            echo "dev.pcm.${unit}.play.vchanmode=fixed"
        fi
        if [ -n "$_has_rec" ]; then
            echo "dev.pcm.${unit}.rec.vchans=2"
            echo "dev.pcm.${unit}.rec.vchanrate=48000"
            echo "dev.pcm.${unit}.rec.vchanmode=fixed"
        fi
    done
}

profile_server() {
    cat <<'EOF'
hw.snd.latency=7
hw.snd.latency_profile=1
hw.snd.feeder_rate_quality=1
hw.snd.vpc_0db=1
hw.snd.vpc_autoreset=0
EOF
    for unit in $(discover_pcm_units); do
        _has_play=$(sysctl -N dev.pcm.${unit}.play.vchans 2>/dev/null || true)
        if [ -n "$_has_play" ]; then
            echo "dev.pcm.${unit}.play.vchans=2"
            echo "dev.pcm.${unit}.play.vchanrate=48000"
            echo "dev.pcm.${unit}.play.vchanmode=fixed"
        fi
    done
}

profile_bitperfect() {
    cat <<'EOF'
hw.snd.latency=0
hw.snd.latency_profile=0
hw.snd.feeder_rate_quality=4
hw.snd.vpc_0db=1
EOF
    for unit in $(discover_pcm_units); do
        echo "dev.pcm.${unit}.bitperfect=1"
        _has_play=$(sysctl -N dev.pcm.${unit}.play.vchans 2>/dev/null || true)
        if [ -n "$_has_play" ]; then
            echo "dev.pcm.${unit}.play.vchans=0"
            echo "dev.pcm.${unit}.play.vchanmode=passthrough"
        fi
        _has_rec=$(sysctl -N dev.pcm.${unit}.rec.vchans 2>/dev/null || true)
        if [ -n "$_has_rec" ]; then
            echo "dev.pcm.${unit}.rec.vchans=0"
            echo "dev.pcm.${unit}.rec.vchanmode=passthrough"
        fi
    done
}

# ── Apply a set of sysctl values at runtime ───────────────────────────────
apply_runtime() {
    _settings=$1
    _failures=0

    printf "%s\n" "$_settings" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        _key=$(echo "$line" | cut -d= -f1)
        _val=$(echo "$line" | cut -d= -f2-)
        _cur=$(sysctl -n "$_key" 2>/dev/null || echo "MISSING")

        if [ "$_cur" = "MISSING" ]; then
            warn "Skipped ${_key} (sysctl not available)"
            continue
        fi

        if [ "$_cur" = "$_val" ]; then
            dim "${_key} already set to ${_val}"
            continue
        fi

        if sysctl "${_key}=${_val}" >/dev/null 2>&1; then
            ok "${_key}: ${_cur} → ${_val}"
        else
            fail "Failed to set ${_key}=${_val}"
            _failures=$((_failures + 1))
        fi
    done

    return 0
}

# ── Write settings to /etc/sysctl.conf ────────────────────────────────────
write_sysctl_conf() {
    _settings=$1

    if [ ! -w /etc/sysctl.conf ]; then
        fail "/etc/sysctl.conf is not writable (run as root)"
        info "Manual additions:"
        printf "%s\n" "$_settings" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            printf "    ${GRN}%s${RST}\n" "$line"
        done
        return 1
    fi

    printf "%s\n" "$_settings" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        _key=$(echo "$line" | cut -d= -f1)

        if grep -q "^${_key}=" /etc/sysctl.conf 2>/dev/null; then
            # Update existing
            _escaped=$(printf '%s\n' "$line" | sed 's/[&/\]/\\&/g')
            sed -i '' "s|^${_key}=.*|${_escaped}|" /etc/sysctl.conf
            ok "Updated: ${line}"
        elif grep -q "^#.*${_key}=" /etc/sysctl.conf 2>/dev/null; then
            # Uncomment and update
            _escaped=$(printf '%s\n' "$line" | sed 's/[&/\]/\\&/g')
            sed -i '' "s|^#.*${_key}=.*|${_escaped}|" /etc/sysctl.conf
            ok "Uncommented: ${line}"
        else
            # Append
            echo "$line" >> /etc/sysctl.conf
            ok "Appended: ${line}"
        fi
    done
}

# ── Interactive tuning wizard ─────────────────────────────────────────────
interactive_tune() {
    printf "\n${BOLD}${CYN}━━ Interactive Audio Tuning Wizard ━━${RST}\n\n"

    # ── 1. Default unit ──
    printf "  ${BOLD}1) Default Output Device${RST}\n"
    printf "     Current: ${WHT}pcm%s${RST}\n" "$(sval hw.snd.default_unit)"
    printf "\n     Available devices:\n"

    for unit in $(discover_pcm_units); do
        _desc=$(sval "dev.pcm.${unit}.%desc" "(unknown)")
        _mode=$(sval "dev.pcm.${unit}.mode" "0")
        _caps=""
        case "$_mode" in
            7) _caps="play/rec/mix" ;;
            3) _caps="play/mix" ;;
            5) _caps="rec/mix" ;;
            6) _caps="play/rec" ;;
            2) _caps="play" ;;
            4) _caps="rec" ;;
            *) _caps="mode=${_mode}" ;;
        esac
        _defmark=""
        if [ "$unit" = "$(sval hw.snd.default_unit)" ]; then
            _defmark=" ${GRN}← current default${RST}"
        fi
        printf "       ${BOLD}%s)${RST}  pcm%-3s  %-40s  [%s]%s\n" \
            "$unit" "$unit" "$_desc" "$_caps" "$_defmark"
    done

    printf "\n     ${DIM}Enter device number (or press Enter to keep current): ${RST}"
    read -r _new_unit
    if [ -n "$_new_unit" ]; then
        _check=$(sysctl -n dev.pcm.${_new_unit}.%desc 2>/dev/null || true)
        if [ -n "$_check" ]; then
            TUNE_default_unit="$_new_unit"
            ok "Will set default_unit=${_new_unit}"
        else
            fail "Invalid device: pcm${_new_unit}"
        fi
    fi

    # ── 2. Latency ──
    printf "\n  ${BOLD}2) Latency Settings${RST}\n"
    printf "     Current: latency=${WHT}%s${RST}, latency_profile=${WHT}%s${RST}\n" \
        "$(sval hw.snd.latency)" "$(sval hw.snd.latency_profile)"
    printf "\n     Presets:\n"
    printf "       ${BOLD}1)${RST}  Ultra-low   (latency=0, profile=0)  — real-time, may glitch\n"
    printf "       ${BOLD}2)${RST}  Low         (latency=0, profile=1)  — low latency, safe buffers\n"
    printf "       ${BOLD}3)${RST}  Balanced    (latency=2, profile=1)  — good for desktop\n"
    printf "       ${BOLD}4)${RST}  Medium      (latency=5, profile=1)  — safe default\n"
    printf "       ${BOLD}5)${RST}  High        (latency=7, profile=1)  — for problematic hardware\n"
    printf "       ${BOLD}6)${RST}  Custom\n"

    printf "\n     ${DIM}Choice (or Enter to keep current): ${RST}"
    read -r _lat_choice
    case "$_lat_choice" in
        1) TUNE_latency=0; TUNE_latency_profile=0 ;;
        2) TUNE_latency=0; TUNE_latency_profile=1 ;;
        3) TUNE_latency=2; TUNE_latency_profile=1 ;;
        4) TUNE_latency=5; TUNE_latency_profile=1 ;;
        5) TUNE_latency=7; TUNE_latency_profile=1 ;;
        6)
            printf "     ${DIM}Latency (0-10): ${RST}"
            read -r TUNE_latency
            printf "     ${DIM}Profile (0=aggressive, 1=safe): ${RST}"
            read -r TUNE_latency_profile
            ;;
        *) ;;
    esac

    # ── 3. Sample rate quality ──
    printf "\n  ${BOLD}3) Sample Rate Converter Quality${RST}\n"
    printf "     Current: ${WHT}%s${RST}\n" "$(sval hw.snd.feeder_rate_quality)"
    printf "       0=fastest/lowest  1=low  2=medium  3=high  4=sinc/best\n"
    printf "\n     ${DIM}Quality level (0-4, or Enter to keep): ${RST}"
    read -r _rq
    [ -n "$_rq" ] && TUNE_feeder_rate_quality="$_rq"

    # ── 4. Virtual channels ──
    printf "\n  ${BOLD}4) Virtual Channels (per-device)${RST}\n"
    printf "     Controls how many applications can share a device simultaneously.\n"
    printf "\n     Presets:\n"
    printf "       ${BOLD}1)${RST}  Minimal   (1 play, 1 rec)   — single app, low overhead\n"
    printf "       ${BOLD}2)${RST}  Standard  (4 play, 2 rec)   — desktop multitasking\n"
    printf "       ${BOLD}3)${RST}  Heavy     (8 play, 4 rec)   — many concurrent apps\n"
    printf "       ${BOLD}4)${RST}  Maximum   (16 play, 8 rec)  — DAW / complex routing\n"

    printf "\n     ${DIM}Choice (or Enter to keep current): ${RST}"
    read -r _vch_choice
    case "$_vch_choice" in
        1) TUNE_pvchans=1;  TUNE_rvchans=1 ;;
        2) TUNE_pvchans=4;  TUNE_rvchans=2 ;;
        3) TUNE_pvchans=8;  TUNE_rvchans=4 ;;
        4) TUNE_pvchans=16; TUNE_rvchans=8 ;;
        *) ;;
    esac

    # ── 5. VChan mode ──
    printf "\n  ${BOLD}5) VChan Mixing Mode${RST}\n"
    printf "     Controls how the mixer handles format/rate differences.\n"
    printf "       ${BOLD}1)${RST}  fixed        — always mix at configured rate (most compatible)\n"
    printf "       ${BOLD}2)${RST}  passthrough  — bypass mixing when single stream (least latency)\n"
    printf "       ${BOLD}3)${RST}  adaptive     — match first stream's rate (best quality)\n"

    printf "\n     ${DIM}Choice (or Enter to keep current): ${RST}"
    read -r _vmode_choice
    case "$_vmode_choice" in
        1) TUNE_vchanmode="fixed" ;;
        2) TUNE_vchanmode="passthrough" ;;
        3) TUNE_vchanmode="adaptive" ;;
        *) ;;
    esac

    # ── 6. Bitperfect ──
    printf "\n  ${BOLD}6) Bitperfect Mode${RST}\n"
    printf "     Bypass all software mixing — audio goes directly to hardware.\n"
    printf "     ${YLW}Only one app can use the device at a time when enabled.${RST}\n"
    printf "       ${BOLD}1)${RST}  Disable (default — software mixing)\n"
    printf "       ${BOLD}2)${RST}  Enable  (audiophile / DAC passthrough)\n"

    printf "\n     ${DIM}Choice (or Enter to keep current): ${RST}"
    read -r _bp_choice
    case "$_bp_choice" in
        1) TUNE_bitperfect=0 ;;
        2) TUNE_bitperfect=1 ;;
        *) ;;
    esac

    # ── Build final settings ──
    _settings=""

    [ -n "${TUNE_default_unit:-}" ] && \
        _settings="${_settings}hw.snd.default_unit=${TUNE_default_unit}
"
    [ -n "${TUNE_latency:-}" ] && \
        _settings="${_settings}hw.snd.latency=${TUNE_latency}
"
    [ -n "${TUNE_latency_profile:-}" ] && \
        _settings="${_settings}hw.snd.latency_profile=${TUNE_latency_profile}
"
    [ -n "${TUNE_feeder_rate_quality:-}" ] && \
        _settings="${_settings}hw.snd.feeder_rate_quality=${TUNE_feeder_rate_quality}
"

    # Per-device settings
    for unit in $(discover_pcm_units); do
        _has_play=$(sysctl -N dev.pcm.${unit}.play.vchans 2>/dev/null || true)
        _has_rec=$(sysctl -N dev.pcm.${unit}.rec.vchans 2>/dev/null || true)

        [ -n "${TUNE_bitperfect:-}" ] && \
            _settings="${_settings}dev.pcm.${unit}.bitperfect=${TUNE_bitperfect}
"

        if [ -n "$_has_play" ]; then
            [ -n "${TUNE_pvchans:-}" ] && \
                _settings="${_settings}dev.pcm.${unit}.play.vchans=${TUNE_pvchans}
"
            [ -n "${TUNE_vchanmode:-}" ] && \
                _settings="${_settings}dev.pcm.${unit}.play.vchanmode=${TUNE_vchanmode}
"
        fi
        if [ -n "$_has_rec" ]; then
            [ -n "${TUNE_rvchans:-}" ] && \
                _settings="${_settings}dev.pcm.${unit}.rec.vchans=${TUNE_rvchans}
"
            [ -n "${TUNE_vchanmode:-}" ] && \
                _settings="${_settings}dev.pcm.${unit}.rec.vchanmode=${TUNE_vchanmode}
"
        fi
    done

    if [ -z "$_settings" ]; then
        info "No changes selected"
        return
    fi

    # ── Show summary and confirm ──
    section "Proposed Changes"
    printf "\n"
    printf "%s" "$_settings" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        _key=$(echo "$line" | cut -d= -f1)
        _new=$(echo "$line" | cut -d= -f2-)
        _cur=$(sval "$_key" "N/A")
        if [ "$_cur" = "$_new" ]; then
            dim "${_key} = ${_new} (no change)"
        else
            printf "    ${YLW}%s${RST}: %s → ${GRN}%s${RST}\n" "$_key" "$_cur" "$_new"
        fi
    done

    printf "\n  ${BOLD}Apply these changes?${RST}\n"
    printf "    ${BOLD}1)${RST}  Runtime only (immediate, lost on reboot)\n"
    printf "    ${BOLD}2)${RST}  Persistent (/etc/sysctl.conf, applied on next boot)\n"
    printf "    ${BOLD}3)${RST}  Both (recommended)\n"
    printf "    ${BOLD}4)${RST}  Just print the sysctl.conf lines (do nothing)\n"
    printf "    ${BOLD}5)${RST}  Cancel\n"

    printf "\n  ${DIM}Choice: ${RST}"
    read -r _apply

    case "$_apply" in
        1)
            printf "\n"
            apply_runtime "$_settings"
            ok "Runtime settings applied"
            ;;
        2)
            printf "\n"
            write_sysctl_conf "$_settings"
            ok "Written to /etc/sysctl.conf (takes effect on next boot)"
            ;;
        3)
            printf "\n"
            apply_runtime "$_settings"
            write_sysctl_conf "$_settings"
            ok "Applied now and persisted to /etc/sysctl.conf"
            ;;
        4)
            printf "\n"
            info "Add these to /etc/sysctl.conf:"
            printf "\n${DIM}# ── Audio tuning (auto-generated by configure-sysctl-audio.sh) ──${RST}\n"
            printf "%s" "$_settings" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                printf "${GRN}%s${RST}\n" "$line"
            done
            ;;
        *)
            info "Cancelled"
            ;;
    esac
}

# ── Apply a named profile ─────────────────────────────────────────────────
apply_profile() {
    _pname=$1

    case "$_pname" in
        low-latency) _psettings=$(profile_low_latency) ;;
        desktop)     _psettings=$(profile_desktop) ;;
        server)      _psettings=$(profile_server) ;;
        bitperfect)  _psettings=$(profile_bitperfect) ;;
        *)
            fail "Unknown profile: ${_pname}"
            info "Available: low-latency, desktop, server, bitperfect"
            exit 1
            ;;
    esac

    section "Profile: ${_pname}"
    printf "\n"
    info "Settings for this profile:"
    printf "\n"

    printf "%s\n" "$_psettings" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        _key=$(echo "$line" | cut -d= -f1)
        _new=$(echo "$line" | cut -d= -f2-)
        _cur=$(sval "$_key" "N/A")
        if [ "$_cur" = "$_new" ]; then
            dim "${_key} = ${_new} (no change)"
        else
            printf "    ${YLW}%s${RST}: %s → ${GRN}%s${RST}\n" "$_key" "$_cur" "$_new"
        fi
    done

    printf "\n  ${BOLD}Apply profile '${_pname}'?${RST}\n"
    printf "    ${BOLD}1)${RST}  Runtime only\n"
    printf "    ${BOLD}2)${RST}  Persistent (/etc/sysctl.conf)\n"
    printf "    ${BOLD}3)${RST}  Both\n"
    printf "    ${BOLD}4)${RST}  Just show (do nothing)\n"
    printf "    ${BOLD}5)${RST}  Cancel\n"

    printf "\n  ${DIM}Choice: ${RST}"
    read -r _apply

    case "$_apply" in
        1)
            printf "\n"
            apply_runtime "$_psettings"
            ok "Profile '${_pname}' applied at runtime"
            ;;
        2)
            printf "\n"
            write_sysctl_conf "$_psettings"
            ok "Profile '${_pname}' written to /etc/sysctl.conf"
            ;;
        3)
            printf "\n"
            apply_runtime "$_psettings"
            write_sysctl_conf "$_psettings"
            ok "Profile '${_pname}' applied and persisted"
            ;;
        4)
            printf "\n"
            info "sysctl.conf lines for profile '${_pname}':"
            printf "\n${DIM}# ── Audio profile: ${_pname} ──${RST}\n"
            printf "%s\n" "$_psettings" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                printf "${GRN}%s${RST}\n" "$line"
            done
            ;;
        *)
            info "Cancelled"
            ;;
    esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              MAIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "\n${BOLD}${CYN}FreeBSD Audio Sysctl Tuner${RST}\n"
printf "${DIM}  FreeBSD $(uname -r) — $(date '+%Y-%m-%d %H:%M')${RST}\n"

case "$MODE" in
    dump)
        print_global_tunables
        print_per_device_tunables
        print_existing_sysctl_conf
        ;;
    interactive)
        print_global_tunables
        print_per_device_tunables
        print_existing_sysctl_conf
        interactive_tune
        ;;
    profile)
        print_global_tunables
        print_per_device_tunables
        apply_profile "$PROFILE"
        ;;
esac

printf "\n"
