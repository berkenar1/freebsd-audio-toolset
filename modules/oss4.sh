#!/bin/sh
# modules/oss4.sh — OSS 4Front Technologies diagnostics

diag_oss4() {
    section "OSS (4Front)"
    if [ -x /usr/local/sbin/ossinfo ] || cmd_exists ossinfo; then
        ok "OSS 4Front tools installed"
        _ossd_pid=$(pgrep -f ossdevlinks 2>/dev/null || true)
        if cmd_exists ossinfo; then
            info "ossinfo output:"
            ossinfo 2>/dev/null | head -20 | while IFS= read -r line; do info "  $line"; done
        fi
    else
        info "OSS 4Front (oss-4.x) not installed (FreeBSD native OSS is used via kernel)"
    fi
}
