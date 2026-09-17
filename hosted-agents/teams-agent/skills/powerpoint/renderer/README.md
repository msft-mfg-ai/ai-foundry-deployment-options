# Deterministic Zava PowerPoint renderer

This is an isolated prototype. It is not wired into the hosted agent or any
deployment service.

The renderer accepts a constrained JSON `DeckSpec` and owns all layout names,
coordinates, fonts, colors, placeholder cleanup, and geometry checks. The
language model supplies content but does not generate presentation code.

Supported compositions:

- `cover` using `Title 1`;
- `card_grid` using `Title Only (Original)`.

Run locally:

```bash
uv sync
uv run zava-render \
  --template ../assets/template.pptx \
  examples/smart-textile-safety.json \
  output/smart-textile-safety.pptx
```

Run tests:

```bash
uv run pytest
```

Render the generated deck for visual QA:

```bash
uv run python scripts/render_slides.py \
  output/smart-textile-safety.pptx \
  --output-dir output
```

The next compositions should be added only with a representative fixture,
package validation, LibreOffice rendering, and visual inspection.
