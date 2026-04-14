#!/usr/bin/env python3
"""
visualize-audio.py — Build a graph of the FreeBSD audio stack and render it.

Usage:
    python3 visualize-audio.py [OPTIONS]

Options:
    -f, --format FMT    Output format: svg (default), png, pdf
    -o, --output NAME   Output filename stem (default: audio-topology)
    --no-ports          Hide individual PipeWire/JACK ports (less clutter)
    --json              Also dump the graph as JSON
    --summary           Print a text summary to stdout
    --view              Open the result in the default viewer
"""

from __future__ import annotations

import argparse
import json
import sys
import os

# Allow running from the project root
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audiograph import AudioGraph
from audiograph.collectors import collect_all
from audiograph.visualize import render


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Visualize the FreeBSD audio stack topology.")
    parser.add_argument("-f", "--format", default="svg",
                        choices=["svg", "png", "pdf"],
                        help="Output image format (default: svg)")
    parser.add_argument("-o", "--output", default="audio-topology",
                        help="Output filename stem")
    parser.add_argument("--no-ports", action="store_true",
                        help="Hide individual ports for a cleaner overview")
    parser.add_argument("--json", action="store_true",
                        help="Dump the graph data as JSON")
    parser.add_argument("--summary", action="store_true",
                        help="Print a text summary")
    parser.add_argument("--view", action="store_true",
                        help="Open the rendered image in the default viewer")
    args = parser.parse_args()

    # Build the graph
    g = AudioGraph()
    collect_all(g)

    if args.summary:
        print(g.summary())
        print()

    if args.json:
        json_path = args.output + ".json"
        with open(json_path, "w") as f:
            json.dump(g.to_dict(), f, indent=2)
        print(f"Graph JSON written to {json_path}")

    # Render
    out_path = render(
        g,
        filename=args.output,
        fmt=args.format,
        view=args.view,
        show_ports=not args.no_ports,
    )
    print(f"Rendered to {out_path}")


if __name__ == "__main__":
    main()
