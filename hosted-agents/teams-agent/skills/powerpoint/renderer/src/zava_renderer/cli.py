import argparse
import json
from pathlib import Path

from .renderer import render_deck


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render a validated DeckSpec with the Zava template."
    )
    parser.add_argument("spec", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--template",
        type=Path,
        required=True,
        help="Path to the clean zero-slide Zava template.",
    )
    args = parser.parse_args()

    with args.spec.open(encoding="utf-8") as stream:
        spec = json.load(stream)

    render_deck(spec, args.template, args.output)


if __name__ == "__main__":
    main()
