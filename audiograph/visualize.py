"""
audiograph/visualize.py — Render an AudioGraph to Graphviz dot / SVG / PNG.

Uses the `graphviz` Python package (wrapper for the `dot` binary).
"""

from __future__ import annotations

import graphviz as gv

from . import AudioGraph, LAYERS

# ── Helpers ─────────────────────────────────────────────────────────────────

def _dot_id(raw_id: str) -> str:
    """Sanitize a node ID so Graphviz doesn't interpret colons as ports."""
    return raw_id.replace(":", "_")


# ── Style maps ──────────────────────────────────────────────────────────────

LAYER_COLORS = {
    "hardware": "#4a6fa5",  # steel blue
    "kernel":   "#6b8e23",  # olive
    "dsp":      "#b8860b",  # dark goldenrod
    "server":   "#8b5cf6",  # violet
    "client":   "#0891b2",  # cyan-ish
}

KIND_SHAPES = {
    "hw_device":  "box3d",
    "pcm":        "record",
    "dsp_node":   "folder",
    "server":     "doubleoctagon",
    "pw_device":  "component",
    "sink":       "invhouse",
    "source":     "house",
    "port_in":    "rarrow",
    "port_out":   "larrow",
    "pw_node":    "ellipse",
    "jack_port":  "diamond",
    "client":     "note",
}

STATUS_BORDER = {
    "active":   "#22c55e",
    "inactive": "#9ca3af",
    "error":    "#ef4444",
}


def render(ag: AudioGraph, *, filename: str = "audio-topology",
           fmt: str = "svg", view: bool = False,
           show_ports: bool = True) -> str:
    """
    Render the AudioGraph to a file via Graphviz.

    Returns the output file path.
    """

    dot = gv.Digraph(
        name="audio_topology",
        format=fmt,
        graph_attr={
            "rankdir": "LR",
            "newrank": "true",
            "fontname": "Helvetica",
            "fontsize": "14",
            "bgcolor": "#1e1e2e",
            "pad": "0.5",
            "nodesep": "0.35",
            "ranksep": "1.4",
            "style": "filled",
            "color": "#313244",
            "label": "FreeBSD Audio Topology",
            "labelloc": "t",
            "fontcolor": "#cdd6f4",
            "compound": "true",
        },
        node_attr={
            "fontname": "Helvetica",
            "fontsize": "11",
            "fontcolor": "#cdd6f4",
            "style": "filled",
            "fillcolor": "#313244",
            "color": "#585b70",
        },
        edge_attr={
            "fontname": "Helvetica",
            "fontsize": "9",
            "fontcolor": "#a6adc8",
            "color": "#585b70",
        },
    )

    # ── Build layer subgraphs with explicit rank constraints ────────────
    # Track one anchor node per layer so we can chain invisible edges to
    # enforce strict top-to-bottom ordering of the layers.
    layer_anchors: dict[str, str] = {}   # layer → dot-id of first node

    for layer in LAYERS:
        nodes = ag.nodes_by_layer(layer)
        if not nodes:
            continue

        if not show_ports:
            nodes = [n for n in nodes if n.kind not in ("port_in", "port_out")]
        if not nodes:
            continue

        layer_color = LAYER_COLORS.get(layer, "#585b70")

        with dot.subgraph(name=f"cluster_{layer}") as sub:
            sub.attr(
                rank="same",
                label=layer.upper(),
                style="rounded,filled",
                fillcolor="#181825",
                color=layer_color,
                fontcolor=layer_color,
                fontsize="13",
            )
            for node in nodes:
                shape = KIND_SHAPES.get(node.kind, "ellipse")
                border = STATUS_BORDER.get(node.status, "#585b70")

                # Build a concise label
                label = node.label
                if node.meta.get("caps"):
                    label += f"\n[{', '.join(node.meta['caps'])}]"
                if node.meta.get("play_fmt"):
                    label += f"\n▶ {node.meta['play_fmt']}"
                if node.meta.get("rec_fmt"):
                    label += f"\n● {node.meta['rec_fmt']}"
                if node.meta.get("media.class"):
                    label += f"\n({node.meta['media.class']})"

                sub.node(
                    _dot_id(node.id),
                    label=label,
                    shape=shape,
                    color=border,
                    fillcolor="#313244" if node.status == "active" else "#1e1e2e",
                )

            # Remember the first node as anchor for this layer
            if layer not in layer_anchors:
                layer_anchors[layer] = _dot_id(nodes[0].id)

    # ── Invisible edges to enforce strict vertical layer order ─────────
    prev_anchor = None
    for layer in LAYERS:
        if layer in layer_anchors:
            if prev_anchor is not None:
                dot.edge(prev_anchor, layer_anchors[layer],
                         style="invis", weight="100")
            prev_anchor = layer_anchors[layer]

    # Edges
    RELATION_STYLE = {
        "provides": {"style": "dashed", "color": "#6c7086"},
        "owns":     {"style": "solid",  "color": "#585b70"},
        "feeds":    {"style": "bold",   "color": "#89b4fa"},
        "linked":   {"style": "bold",   "color": "#a6e3a1", "penwidth": "2"},
        "monitors": {"style": "dotted", "color": "#fab387"},
        "connected":{"style": "dotted", "color": "#74c7ec"},
        "serves":   {"style": "dotted", "color": "#74c7ec"},
    }

    for edge in ag.edges:
        # Skip edges to/from ports we filtered out
        if not show_ports and (edge.src not in ag.nodes or edge.dst not in ag.nodes):
            continue
        if edge.src not in ag.nodes or edge.dst not in ag.nodes:
            continue

        attrs = dict(RELATION_STYLE.get(edge.relation, {}))
        attrs.setdefault("color", "#585b70")
        dot.edge(_dot_id(edge.src), _dot_id(edge.dst), **attrs)

    path = dot.render(filename=filename, cleanup=True, view=view)
    return path
