#!/bin/sh
# modules/virtual_oss.sh — virtual_oss diagnostics

diag_virtual_oss() {
    section "virtual_oss"
    if cmd_exists virtual_oss; then
        ok "virtual_oss binary found: $(which virtual_oss)"
        _vo_pid=$(pgrep -x virtual_oss 2>/dev/null || true)
        if [ -n "$_vo_pid" ]; then
            ok "virtual_oss is RUNNING (PID: $_vo_pid)"
            _vo_cmd=$(ps -p "$_vo_pid" -o args= 2>/dev/null || true)
            [ -n "$_vo_cmd" ] && info "  cmdline: $_vo_cmd"
        else
            warn "virtual_oss is NOT running"
        fi

        if sysrc -n virtual_oss_enable 2>/dev/null | grep -qi yes; then
            ok "virtual_oss_enable=YES in rc.conf"
        else
            warn "virtual_oss not enabled in rc.conf"
        fi

        _vodsp=$(ls /dev/vdsp* 2>/dev/null || true)
        if [ -n "$_vodsp" ]; then
            info "virtual_oss device nodes:"
            printf "%s\n" "$_vodsp" | while IFS= read -r f; do info "  $f"; done
        fi
    else
        fail "virtual_oss not installed"
    fi
}
