#!/bin/sh
# modules/sndio.sh — sndio / sndiod diagnostics

diag_sndio() {
    section "sndio"
    if cmd_exists sndiod; then
        ok "sndiod binary found: $(which sndiod)"
        _sn_pid=$(pgrep -x sndiod 2>/dev/null || true)
        if [ -n "$_sn_pid" ]; then
            ok "sndiod is RUNNING (PID: $_sn_pid)"
        else
            info "sndiod is NOT running"
        fi

        if sysrc -n sndiod_enable 2>/dev/null | grep -qi yes; then
            ok "sndiod_enable=YES in rc.conf"
        else
            info "sndiod not enabled in rc.conf"
        fi
    else
        fail "sndio not installed"
    fi
}
