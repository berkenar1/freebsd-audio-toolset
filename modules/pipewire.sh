#!/bin/sh
# modules/pipewire.sh — PipeWire + WirePlumber diagnostics

diag_pipewire() {
    section "PipeWire"
    if cmd_exists pipewire; then
        ok "pipewire binary found: $(which pipewire)"
        _pw_pid=$(pgrep -x pipewire 2>/dev/null | head -1 || true)
        if [ -n "$_pw_pid" ]; then
            ok "pipewire is RUNNING (PID: $_pw_pid)"
        else
            warn "pipewire is NOT running"
        fi

        # WirePlumber
        if cmd_exists wireplumber; then
            ok "wireplumber binary found"
            _wp_pid=$(pgrep -x wireplumber 2>/dev/null || true)
            if [ -n "$_wp_pid" ]; then
                ok "wireplumber is RUNNING (PID: $_wp_pid)"
            else
                warn "wireplumber is NOT running"
            fi
        else
            warn "wireplumber not installed (PipeWire session manager)"
        fi

        # pipewire-pulse (PulseAudio compat)
        _pwpulse_pid=$(pgrep -f 'pipewire-pulse\|pipewire.*-c.*pipewire-pulse' 2>/dev/null || true)
        if [ -n "$_pwpulse_pid" ]; then
            ok "pipewire-pulse is RUNNING (PID: $_pwpulse_pid)"
        else
            info "pipewire-pulse is not running (PulseAudio compat layer)"
        fi

        # List PipeWire nodes if pw-cli available
        if cmd_exists pw-cli && [ -n "$_pw_pid" ]; then
            info "PipeWire object counts:"
            _node_ct=$(pw-cli ls Node 2>/dev/null | grep -c 'id' || true)
            _link_ct=$(pw-cli ls Link 2>/dev/null | grep -c 'id' || true)
            info "  Nodes: ${_node_ct:-0}  Links: ${_link_ct:-0}"
        fi

        # PipeWire config locations
        for cfg in /usr/local/etc/pipewire /usr/local/share/pipewire ~/.config/pipewire; do
            if [ -d "$cfg" ]; then
                info "Config dir: $cfg"
                ls "$cfg" 2>/dev/null | while IFS= read -r f; do info "  $f"; done
            fi
        done
    else
        fail "PipeWire not installed"
    fi
}
