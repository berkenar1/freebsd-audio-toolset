"""
audiograph/graph.py — Directed graph data structure for the audio system.

Every component (hardware device, kernel pcm, sound-server node, port, client)
is a *node* in the graph.  Edges represent data-flow or ownership relationships
(e.g. device→pcm, pcm→pipewire-sink, sink→port).

Node attrs:   id, label, kind, layer, status, meta (dict)
Edge attrs:   relation, meta (dict)

Layers (bottom-to-top):
    hardware → kernel → dsp → server → client
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


# ── Node / Edge data classes ────────────────────────────────────────────────

LAYERS = ("hardware", "kernel", "dsp", "server", "client")

@dataclass
class Node:
    id: str
    label: str
    kind: str               # e.g. "hw_device", "pcm", "sink", "source", "port", "server", "client"
    layer: str              # one of LAYERS
    status: str = "active"  # active | inactive | error
    meta: dict[str, Any] = field(default_factory=dict)

@dataclass
class Edge:
    src: str                # source node id
    dst: str                # dest node id
    relation: str           # "owns", "feeds", "monitors", "provides"
    meta: dict[str, Any] = field(default_factory=dict)


# ── AudioGraph ──────────────────────────────────────────────────────────────

class AudioGraph:
    """Lightweight directed graph holding the full audio topology."""

    def __init__(self) -> None:
        self.nodes: dict[str, Node] = {}
        self.edges: list[Edge] = []

    # -- mutators -------------------------------------------------------------

    def add_node(self, node: Node) -> Node:
        self.nodes[node.id] = node
        return node

    def add_edge(self, src: str, dst: str, relation: str = "feeds",
                 **meta: Any) -> Edge:
        edge = Edge(src=src, dst=dst, relation=relation, meta=meta)
        self.edges.append(edge)
        return edge

    # -- queries --------------------------------------------------------------

    def get_node(self, node_id: str) -> Node | None:
        return self.nodes.get(node_id)

    def children(self, node_id: str) -> list[Node]:
        """Nodes reachable via outgoing edges from *node_id*."""
        return [self.nodes[e.dst] for e in self.edges
                if e.src == node_id and e.dst in self.nodes]

    def parents(self, node_id: str) -> list[Node]:
        """Nodes with edges pointing to *node_id*."""
        return [self.nodes[e.src] for e in self.edges
                if e.dst == node_id and e.src in self.nodes]

    def nodes_by_layer(self, layer: str) -> list[Node]:
        return [n for n in self.nodes.values() if n.layer == layer]

    def nodes_by_kind(self, kind: str) -> list[Node]:
        return [n for n in self.nodes.values() if n.kind == kind]

    # -- serialisation --------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "nodes": {nid: {
                "label": n.label, "kind": n.kind, "layer": n.layer,
                "status": n.status, "meta": n.meta,
            } for nid, n in self.nodes.items()},
            "edges": [{"src": e.src, "dst": e.dst,
                       "relation": e.relation, "meta": e.meta}
                      for e in self.edges],
        }

    def summary(self) -> str:
        by_layer = {}
        for n in self.nodes.values():
            by_layer.setdefault(n.layer, []).append(n)
        lines = [f"AudioGraph: {len(self.nodes)} nodes, {len(self.edges)} edges"]
        for layer in LAYERS:
            ns = by_layer.get(layer, [])
            if ns:
                lines.append(f"  {layer}: {len(ns)} — "
                             + ", ".join(n.label for n in ns))
        return "\n".join(lines)
