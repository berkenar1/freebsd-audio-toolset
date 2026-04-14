#!/bin/sh
# modules/alsa.sh — ALSA compatibility layer diagnostics

diag_alsa() {
    section "ALSA Compatibility (alsa-lib)"
    _alsa_pkg=$(pkg info alsa-lib 2>/dev/null | head -1 || true)
    if [ -n "$_alsa_pkg" ]; then
        ok "$_alsa_pkg"

        for acfg in /usr/local/etc/asound.conf ~/.asoundrc; do
            if [ -f "$acfg" ]; then
                info "ALSA config: $acfg"
                head -20 "$acfg" | while IFS= read -r line; do info "  $line"; done
            fi
        done

        _alsa_plugins=$(pkg info alsa-plugins 2>/dev/null | head -1 || true)
        [ -n "$_alsa_plugins" ] && ok "$_alsa_plugins"

        _alsa_sndio=$(pkg info alsa-sndio 2>/dev/null | head -1 || true)
        [ -n "$_alsa_sndio" ] && ok "$_alsa_sndio"
    else
        info "alsa-lib not installed"
    fi
}
