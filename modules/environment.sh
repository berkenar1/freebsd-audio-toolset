#!/bin/sh
# modules/environment.sh — Audio environment variables, sockets, packages

diag_environment() {
    section "Audio Environment Variables"
    for var in AUDIODEV AUDIODEVICE SNDIO_ARGS PULSE_SERVER PULSE_SINK PULSE_SOURCE \
               PIPEWIRE_RUNTIME_DIR XDG_RUNTIME_DIR JACK_DEFAULT_SERVER \
               SDL_AUDIODRIVER ALSA_CARD OSSv4_AUDIODEV; do
        eval _val=\${${var}:-}
        if [ -n "$_val" ]; then
            ok "${var}=${_val}"
        fi
    done

    # XDG_RUNTIME_DIR is critical for PipeWire
    _xdg="${XDG_RUNTIME_DIR:-}"
    if [ -n "$_xdg" ]; then
        if [ -d "$_xdg" ]; then
            ok "XDG_RUNTIME_DIR=$_xdg (exists)"
            if [ -e "${_xdg}/pipewire-0" ]; then
                ok "PipeWire socket: ${_xdg}/pipewire-0"
            fi
            if [ -e "${_xdg}/pulse" ] || [ -e "${_xdg}/pulse/native" ]; then
                ok "PulseAudio socket: ${_xdg}/pulse/"
            fi
        else
            fail "XDG_RUNTIME_DIR=$_xdg does NOT exist"
        fi
    else
        warn "XDG_RUNTIME_DIR is not set — PipeWire/PulseAudio may not work"
    fi

    section "Installed Audio Packages"
    pkg info 2>/dev/null | grep -iE 'pipewire|pulseaudio|pulse-|^jack|virtual.oss|sndio|^alsa|^oss-|wireplumber|helvum|qpwgraph|pavucontrol|pamixer|fossmixer' | \
        while IFS= read -r line; do info "$line"; done

    section "Quick Tests You Can Run"
    info "OSS playback   : cat /dev/urandom | head -c 100000 > /dev/dsp    (noise = working)"
    info "PulseAudio test: paplay /usr/local/share/sounds/freedesktop/stereo/bell.oga"
    info "sndio test     : aucat -i /path/to/file.wav"
    info "JACK test      : jack_simple_client (if jack-example-tools installed)"
    info "PipeWire test  : pw-play /path/to/file.wav"
}
