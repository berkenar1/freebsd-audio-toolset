#!/bin/sh
# diagnose-sound.sh — FreeBSD Sound System Diagnostic Script
# Inspects kernel drivers, hardware devices, DSP layer, and userspace sound
# servers to produce a comprehensive report of the audio stack.
#
# Structure:
#   lib/common.sh       — shared helpers (colours, output functions)
#   modules/system.sh   — system overview
#   modules/kernel.sh   — kernel modules, /dev/sndstat, DSP nodes, sysctls
#   modules/virtual_oss.sh — virtual_oss daemon
#   modules/pipewire.sh — PipeWire + WirePlumber
#   modules/pulseaudio.sh — PulseAudio / pipewire-pulse
#   modules/jack.sh     — JACK Audio Connection Kit
#   modules/sndio.sh    — sndio / sndiod
#   modules/oss4.sh     — OSS 4Front Technologies
#   modules/alsa.sh     — ALSA compatibility layer
#   modules/environment.sh — env vars, sockets, packages, test hints

set -u

# Resolve the directory this script lives in
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Load shared helpers ─────────────────────────────────────────────────────
. "${SCRIPT_DIR}/lib/common.sh"

# ── Load all diagnostic modules ─────────────────────────────────────────────
for _mod in \
    system \
    kernel \
    virtual_oss \
    pipewire \
    pulseaudio \
    jack \
    sndio \
    oss4 \
    alsa \
    environment \
; do
    . "${SCRIPT_DIR}/modules/${_mod}.sh"
done

# ── Run diagnostics ─────────────────────────────────────────────────────────
diag_system
diag_kernel
diag_virtual_oss
diag_pipewire
diag_pulseaudio
diag_jack
diag_sndio
diag_oss4
diag_alsa
diag_environment

section "Diagnostic Complete"
printf "\n"
