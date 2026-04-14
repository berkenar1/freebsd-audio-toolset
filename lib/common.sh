#!/bin/sh
# lib/common.sh — Shared helpers for sound diagnostic modules.
# Sourced by diagnose-sound.sh and every modules/*.sh script.

# ── Colours (disabled when not a terminal) ──────────────────────────────────
if [ -t 1 ]; then
    BOLD='\033[1m'    RST='\033[0m'
    GRN='\033[32m'    RED='\033[31m'    YLW='\033[33m'    CYN='\033[36m'
else
    BOLD='' RST='' GRN='' RED='' YLW='' CYN=''
fi

section() { printf "\n${BOLD}${CYN}══════ %s ══════${RST}\n" "$1"; }
ok()      { printf "  ${GRN}[OK]${RST}  %s\n" "$1"; }
warn()    { printf "  ${YLW}[!!]${RST}  %s\n" "$1"; }
fail()    { printf "  ${RED}[NO]${RST}  %s\n" "$1"; }
info()    { printf "  ${BOLD}[..]${RST}  %s\n" "$1"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }
