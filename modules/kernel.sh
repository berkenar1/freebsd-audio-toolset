#!/bin/sh
# modules/kernel.sh — Kernel sound modules, OSS devices, DSP nodes, sysctls

diag_kernel() {
    section "Kernel Sound Modules (kldstat)"
    _kld=$(kldstat 2>/dev/null | grep -iE 'snd|oss|pcm|hdac|hda|cuse|audio' || true)
    if [ -n "$_kld" ]; then
        printf "%s\n" "$_kld" | while IFS= read -r line; do ok "$line"; done
    else
        fail "No sound-related kernel modules detected"
    fi

    # Check for cuse (needed by virtual_oss / OSS)
    if kldstat -q -m cuse 2>/dev/null; then
        ok "cuse module loaded (needed by virtual_oss / OSS4)"
    else
        warn "cuse module NOT loaded — virtual_oss and OSS4 require it"
    fi

    section "OSS Devices (/dev/sndstat)"
    if [ -r /dev/sndstat ]; then
        cat /dev/sndstat | while IFS= read -r line; do info "$line"; done
    else
        fail "/dev/sndstat not readable (kernel PCM driver may not be loaded)"
    fi

    section "DSP Device Nodes (/dev/dsp*)"
    _dsp=$(ls -la /dev/dsp* 2>/dev/null || true)
    if [ -n "$_dsp" ]; then
        printf "%s\n" "$_dsp" | while IFS= read -r line; do info "$line"; done
    else
        fail "No /dev/dsp* device nodes found"
    fi

    _mixer=$(ls -la /dev/mixer* 2>/dev/null || true)
    if [ -n "$_mixer" ]; then
        printf "%s\n" "$_mixer" | while IFS= read -r line; do info "$line"; done
    fi

    section "Kernel Sound Sysctls (hw.snd.*)"
    _sysctls=$(sysctl hw.snd 2>/dev/null || true)
    if [ -n "$_sysctls" ]; then
        for key in default_unit default_auto verbose latency latency_profile vpc_0db feeder_rate_quality vchans_enable; do
            _val=$(echo "$_sysctls" | grep "hw.snd.${key}:" || true)
            if [ -n "$_val" ]; then
                info "$_val"
            fi
        done
    else
        fail "hw.snd sysctl tree not available"
    fi

    _pcm_devs=$(sysctl -N dev.pcm 2>/dev/null | grep -oE 'dev\.pcm\.[0-9]+' | sed 's/dev\.pcm\.//' | sort -un || true)
    if [ -n "$_pcm_devs" ]; then
        section "Per-Device PCM Info (dev.pcm.*)"
        for unit in $_pcm_devs; do
            _desc=$(sysctl -n dev.pcm.${unit}.%desc 2>/dev/null || echo "(unknown)")
            info "pcm${unit}: ${_desc}"

            _play=$(sysctl -n dev.pcm.${unit}.play.vchanformat 2>/dev/null || true)
            _rec=$(sysctl -n dev.pcm.${unit}.rec.vchanformat 2>/dev/null || true)
            _bitperf=$(sysctl -n dev.pcm.${unit}.bitperfect 2>/dev/null || true)

            [ -n "$_play" ]    && info "  play vchanformat : $_play"
            [ -n "$_rec" ]     && info "  rec vchanformat  : $_rec"
            [ -n "$_bitperf" ] && info "  bitperfect       : $_bitperf"
        done
    fi
}
