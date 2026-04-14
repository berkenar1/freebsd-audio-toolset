"""
audiograph/collectors.py — Gather live audio system data into an AudioGraph.

Each collect_*() function probes one subsystem and populates the graph.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from typing import Any

from . import AudioGraph, Node

# ── helpers ─────────────────────────────────────────────────────────────────

def _run(cmd: list[str], **kw: Any) -> str | None:
    """Run a command, return stdout or None on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10, **kw)
        return r.stdout if r.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _sysctl(name: str) -> str | None:
    out = _run(["sysctl", "-n", name])
    return out.strip() if out else None


def _sysctl_names(prefix: str) -> list[str]:
    out = _run(["sysctl", "-N", prefix])
    return out.strip().splitlines() if out else []


# ── Hardware / Kernel layer ─────────────────────────────────────────────────

def collect_kernel(g: AudioGraph) -> None:
    """Populate hardware devices, PCM units, DSP nodes from the kernel."""

    # /dev/sndstat
    sndstat_raw = None
    try:
        with open("/dev/sndstat") as f:
            sndstat_raw = f.read()
    except OSError:
        pass

    # Discover pcm units from sysctl dev.pcm.*
    pcm_units: set[str] = set()
    for name in _sysctl_names("dev.pcm"):
        m = re.match(r"dev\.pcm\.(\d+)", name)
        if m:
            pcm_units.add(m.group(1))

    for unit in sorted(pcm_units, key=int):
        desc = _sysctl(f"dev.pcm.{unit}.%desc") or "(unknown)"
        parent_dev = _sysctl(f"dev.pcm.{unit}.%parent") or ""

        # Determine capabilities from sndstat or sysctl
        can_play = _sysctl(f"dev.pcm.{unit}.play.vchanformat") is not None
        can_rec  = _sysctl(f"dev.pcm.{unit}.rec.vchanformat") is not None
        caps = []
        if can_play: caps.append("play")
        if can_rec:  caps.append("rec")

        play_fmt = _sysctl(f"dev.pcm.{unit}.play.vchanformat") or ""
        rec_fmt  = _sysctl(f"dev.pcm.{unit}.rec.vchanformat") or ""
        bitperf  = _sysctl(f"dev.pcm.{unit}.bitperfect") or ""

        # Hardware parent device node (e.g. hdaa0)
        hw_id = f"hw:{parent_dev}" if parent_dev else f"hw:pcm{unit}"
        if hw_id not in g.nodes:
            g.add_node(Node(
                id=hw_id, label=parent_dev or f"pcm{unit}-hw",
                kind="hw_device", layer="hardware",
                meta={"desc": desc},
            ))

        # Kernel PCM node
        pcm_id = f"pcm:{unit}"
        g.add_node(Node(
            id=pcm_id,
            label=f"pcm{unit} — {desc}",
            kind="pcm",
            layer="kernel",
            meta={
                "unit": unit, "caps": caps,
                "play_fmt": play_fmt, "rec_fmt": rec_fmt,
                "bitperfect": bitperf,
            },
        ))
        g.add_edge(hw_id, pcm_id, relation="provides")

        # DSP device nodes
        dsp_path = f"/dev/dsp{unit}"
        if os.path.exists(dsp_path):
            dsp_id = f"dsp:{unit}"
            g.add_node(Node(
                id=dsp_id, label=f"/dev/dsp{unit}",
                kind="dsp_node", layer="dsp",
            ))
            g.add_edge(pcm_id, dsp_id, relation="provides")


# ── PipeWire ────────────────────────────────────────────────────────────────

def collect_pipewire(g: AudioGraph) -> None:
    """Populate PipeWire devices, nodes, ports and links from pw-dump."""

    if not shutil.which("pw-dump"):
        return

    raw = _run(["pw-dump"])
    if not raw:
        # pipewire not running
        if shutil.which("pipewire"):
            g.add_node(Node(id="pw:server", label="PipeWire (not running)",
                            kind="server", layer="server", status="inactive"))
        return

    try:
        objects = json.loads(raw)
    except json.JSONDecodeError:
        return

    # Add server node
    g.add_node(Node(id="pw:server", label="PipeWire", kind="server",
                    layer="server", status="active"))

    pw_nodes: dict[int, dict] = {}  # pw-id → props

    for obj in objects:
        otype = obj.get("type", "")
        oid = obj.get("id")
        props = obj.get("info", {}).get("props", {})

        if "Device" in otype:
            dev_name = props.get("device.name", f"dev-{oid}")
            dev_desc = props.get("device.description", dev_name)
            nid = f"pw:device:{oid}"
            g.add_node(Node(
                id=nid, label=dev_desc, kind="pw_device", layer="server",
                meta={"pw_id": oid, "device.name": dev_name},
            ))
            g.add_edge("pw:server", nid, relation="owns")

            # Link to kernel PCM if we can match
            bus_path = props.get("device.bus-path", "")
            # Try matching by sysctl parent name
            sysdev = props.get("device.name", "")
            hw_id = f"hw:{sysdev}"
            if hw_id in g.nodes:
                g.add_edge(hw_id, nid, relation="feeds")

        elif "Node" in otype:
            node_name = props.get("node.name", f"node-{oid}")
            node_desc = props.get("node.description", node_name)
            media_class = props.get("media.class", "")
            device_id = props.get("device.id")

            # Determine kind
            if "Sink" in media_class:
                kind = "sink"
            elif "Source" in media_class:
                kind = "source"
            else:
                kind = "pw_node"

            # Skip internal driver nodes for cleaner graph
            if node_name in ("Dummy-Driver", "Freewheel-Driver"):
                continue

            nid = f"pw:node:{oid}"
            g.add_node(Node(
                id=nid, label=node_desc, kind=kind, layer="server",
                meta={"pw_id": oid, "node.name": node_name,
                      "media.class": media_class},
            ))
            pw_nodes[oid] = props

            # Edge from parent device
            if device_id is not None:
                dev_nid = f"pw:device:{device_id}"
                if dev_nid in g.nodes:
                    g.add_edge(dev_nid, nid, relation="owns")
                else:
                    g.add_edge("pw:server", nid, relation="owns")
            else:
                g.add_edge("pw:server", nid, relation="owns")

            # Link PipeWire sink/source back to corresponding DSP node
            # pw node names like "pcm0.play" map to /dev/dsp0
            m = re.match(r"pcm(\d+)\.(play|rec)", node_name)
            if m:
                pcm_unit = m.group(1)
                dsp_id = f"dsp:{pcm_unit}"
                if dsp_id in g.nodes:
                    g.add_edge(dsp_id, nid, relation="feeds")

        elif "Port" in otype:
            port_name = props.get("port.name", f"port-{oid}")
            node_id = props.get("node.id")
            direction = props.get("port.direction", "")

            parent_nid = f"pw:node:{node_id}" if node_id else None

            nid = f"pw:port:{oid}"
            kind = "port_in" if direction == "in" else "port_out"
            g.add_node(Node(
                id=nid, label=port_name, kind=kind, layer="server",
                meta={"pw_id": oid, "direction": direction,
                      "node_id": node_id},
            ))

            if parent_nid and parent_nid in g.nodes:
                # Node owns its ports; arrow flows left→right (node → port)
                g.add_edge(parent_nid, nid, relation="owns")

        elif "Link" in otype:
            link_info = obj.get("info", {})
            out_port = link_info.get("output-port-id")
            in_port = link_info.get("input-port-id")
            if out_port is not None and in_port is not None:
                src_id = f"pw:port:{out_port}"
                dst_id = f"pw:port:{in_port}"
                if src_id in g.nodes and dst_id in g.nodes:
                    g.add_edge(src_id, dst_id, relation="linked")

        elif "Client" in otype:
            app_name = props.get("application.name",
                       props.get("pipewire.access.portal.app_id",
                       f"client-{oid}"))
            nid = f"pw:client:{oid}"
            g.add_node(Node(
                id=nid, label=app_name, kind="client", layer="client",
                meta={"pw_id": oid},
            ))
            g.add_edge("pw:server", nid, relation="serves")


# ── PulseAudio (pactl) ─────────────────────────────────────────────────────

def collect_pulseaudio(g: AudioGraph) -> None:
    """Add PulseAudio/pipewire-pulse info via pactl."""

    if not shutil.which("pactl"):
        return

    info_raw = _run(["pactl", "info"])
    if not info_raw:
        return

    server_name = ""
    for line in info_raw.splitlines():
        if "Server Name" in line:
            server_name = line.split(":", 1)[1].strip()
        elif "Default Sink" in line:
            g.nodes.setdefault("pa:server", Node(
                id="pa:server", label=server_name or "PulseAudio",
                kind="server", layer="server", status="active",
            ))
            g.nodes["pa:server"].meta["default_sink"] = line.split(":", 1)[1].strip()
        elif "Default Source" in line:
            g.nodes.setdefault("pa:server", Node(
                id="pa:server", label=server_name or "PulseAudio",
                kind="server", layer="server", status="active",
            ))
            g.nodes["pa:server"].meta["default_source"] = line.split(":", 1)[1].strip()

    # If PulseAudio is actually PipeWire, link them
    if "pa:server" in g.nodes and "PipeWire" in server_name:
        if "pw:server" in g.nodes:
            g.add_edge("pw:server", "pa:server", relation="provides")


# ── JACK ────────────────────────────────────────────────────────────────────

def collect_jack(g: AudioGraph) -> None:
    """Add JACK server and port info via jack_lsp."""

    if not shutil.which("jack_lsp"):
        return

    raw = _run(["jack_lsp", "-c"])
    if not raw:
        if shutil.which("jackd"):
            g.add_node(Node(id="jack:server", label="JACK (not running)",
                            kind="server", layer="server", status="inactive"))
        return

    g.add_node(Node(id="jack:server", label="JACK", kind="server",
                    layer="server", status="active"))

    # If PipeWire is running, JACK likely goes through it
    if "pw:server" in g.nodes:
        g.add_edge("pw:server", "jack:server", relation="provides")

    current_port = None
    for line in raw.splitlines():
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("\t") or line.startswith("   "):
            # connection target — edge
            target = line.strip()
            if current_port:
                src_id = f"jack:port:{current_port}"
                dst_id = f"jack:port:{target}"
                if dst_id not in g.nodes:
                    g.add_node(Node(id=dst_id, label=target,
                                    kind="jack_port", layer="server"))
                    g.add_edge("jack:server", dst_id, relation="owns")
                g.add_edge(src_id, dst_id, relation="linked")
        else:
            current_port = line
            pid = f"jack:port:{line}"
            g.add_node(Node(id=pid, label=line, kind="jack_port",
                            layer="server"))
            g.add_edge("jack:server", pid, relation="owns")


# ── virtual_oss ─────────────────────────────────────────────────────────────

def collect_virtual_oss(g: AudioGraph) -> None:
    """Detect virtual_oss daemon and its device nodes."""

    if not shutil.which("virtual_oss"):
        return

    pid_raw = _run(["pgrep", "-x", "virtual_oss"])
    running = bool(pid_raw and pid_raw.strip())

    nid = "voss:server"
    g.add_node(Node(
        id=nid, label="virtual_oss",
        kind="server", layer="server",
        status="active" if running else "inactive",
    ))

    # Find vdsp device nodes
    if os.path.exists("/dev"):
        import glob
        for dev in sorted(glob.glob("/dev/vdsp*")):
            did = f"voss:dev:{os.path.basename(dev)}"
            g.add_node(Node(id=did, label=dev, kind="dsp_node", layer="dsp"))
            g.add_edge(nid, did, relation="provides")


# ── sndio ───────────────────────────────────────────────────────────────────

def collect_sndio(g: AudioGraph) -> None:
    """Detect sndiod."""

    if not shutil.which("sndiod"):
        return

    pid_raw = _run(["pgrep", "-x", "sndiod"])
    running = bool(pid_raw and pid_raw.strip())

    g.add_node(Node(
        id="sndio:server", label="sndio (sndiod)",
        kind="server", layer="server",
        status="active" if running else "inactive",
    ))


# ── Master collector ────────────────────────────────────────────────────────

def collect_all(g: AudioGraph) -> AudioGraph:
    """Run every collector in order and return the populated graph."""
    collect_kernel(g)
    collect_pipewire(g)
    collect_pulseaudio(g)
    collect_jack(g)
    collect_virtual_oss(g)
    collect_sndio(g)
    return g
