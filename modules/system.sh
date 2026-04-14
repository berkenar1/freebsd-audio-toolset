#!/bin/sh
# modules/system.sh — System overview

diag_system() {
    section "System Overview"
    info "Hostname : $(hostname)"
    info "OS       : $(uname -sr)"
    if cmd_exists freebsd-version; then
        info "Version  : $(freebsd-version)"
    fi
    info "Arch     : $(uname -m)"
    info "Date     : $(date)"
}
