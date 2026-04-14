#!/bin/sh
# modules/jack.sh — JACK Audio Connection Kit diagnostics

diag_jack() {
    section "JACK"
    if cmd_exists jackd; then
        ok "jackd binary found: $(which jackd)"
        _jk_pid=$(pgrep -x jackd 2>/dev/null || pgrep -x jackdbus 2>/dev/null || true)
        if [ -n "$_jk_pid" ]; then
            ok "jackd is RUNNING (PID: $_jk_pid)"
        else
            info "jackd is NOT running"
        fi

        if cmd_exists jack_lsp; then
            _jports=$(jack_lsp 2>/dev/null || true)
            if [ -n "$_jports" ]; then
                _jp_count=$(echo "$_jports" | wc -l | tr -d ' ')
                ok "JACK ports visible: $_jp_count"
                printf "%s\n" "$_jports" | head -20 | while IFS= read -r line; do info "  $line"; done
                _jp_total=$(echo "$_jports" | wc -l | tr -d ' ')
                if [ "$_jp_total" -gt 20 ]; then
                    info "  ... and $((_jp_total - 20)) more"
                fi
            else
                info "No JACK ports available (server may not be running)"
            fi
        fi
    else
        fail "JACK not installed"
    fi
}
