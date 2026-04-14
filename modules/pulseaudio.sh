#!/bin/sh
# modules/pulseaudio.sh — PulseAudio (standalone & pipewire-pulse) diagnostics

diag_pulseaudio() {
    section "PulseAudio"
    if cmd_exists pulseaudio; then
        ok "pulseaudio binary found: $(which pulseaudio)"
        _pa_pid=$(pgrep -x pulseaudio 2>/dev/null || true)
        if [ -n "$_pa_pid" ]; then
            ok "pulseaudio daemon is RUNNING (PID: $_pa_pid)"
        else
            info "pulseaudio daemon is NOT running (may be replaced by pipewire-pulse)"
        fi
    else
        fail "pulseaudio not installed"
    fi

    # pactl info (works with both PulseAudio & pipewire-pulse)
    if cmd_exists pactl; then
        _painfo=$(pactl info 2>/dev/null || true)
        if [ -n "$_painfo" ]; then
            info "pactl info (Pulse/PipeWire-pulse):"
            _server=$(echo "$_painfo" | grep 'Server Name' || true)
            _ver=$(echo "$_painfo" | grep 'Server Version' || true)
            _defsink=$(echo "$_painfo" | grep 'Default Sink' || true)
            _defsrc=$(echo "$_painfo" | grep 'Default Source' || true)
            [ -n "$_server" ]  && info "  $_server"
            [ -n "$_ver" ]     && info "  $_ver"
            [ -n "$_defsink" ] && info "  $_defsink"
            [ -n "$_defsrc" ]  && info "  $_defsrc"
        fi

        _sinks=$(pactl list short sinks 2>/dev/null || true)
        if [ -n "$_sinks" ]; then
            info "Pulse sinks:"
            printf "%s\n" "$_sinks" | while IFS= read -r line; do info "  $line"; done
        fi

        _srcs=$(pactl list short sources 2>/dev/null || true)
        if [ -n "$_srcs" ]; then
            info "Pulse sources:"
            printf "%s\n" "$_srcs" | while IFS= read -r line; do info "  $line"; done
        fi
    fi
}
