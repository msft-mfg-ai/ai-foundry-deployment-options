# Zava corporate template layouts

The packaged `assets/template.pptx` is the 16:9 Zava corporate template. It
contains 36 named layouts and one master. It intentionally contains no
existing slides, so start adding final slides immediately. The layout names
and intended uses below were derived from the original 33-slide Zava layout
gallery.

The theme uses:

- `Aptos Display` for headings and `Aptos` for body text;
- ink `#0A0C0C`, deep teal `#183D4C`, and light gray `#EBEFF3`;
- supporting teal `#3D7288`, sky `#97CCE3`, and pale blue `#BBD5E1`;
- the Zava logo, restrained rules, and the `INTELLIGENCE WOVEN IN.` footer.

Select layouts by name:

```python
from pptx import Presentation

prs = Presentation("template.pptx")
layout = next(item for item in prs.slide_layouts if item.name == "Title 1")
slide = prs.slides.add_slide(layout)
```

Available named layouts:

| Layout | `DeckSpec` composition | Recommended use |
|---|---|---|
| `Title 1` | `cover` | Image-led dark cover |
| `Title 3` | `cover` | Light cover with strong logo and title |
| `Title Photo 1` | `cover` | Landscape-photo cover |
| `Title Photo 2` | `cover` | Alternate landscape-photo cover |
| `Section Header 1` | `section_divider` | Light section transition |
| `Section Header 4` | `section_divider` | Dark section transition |
| `Section Header 2` | `section_divider` | Photo-led section transition |
| `Section Header 3 (Original)` | `section_divider` | Split photo transition |
| `Agenda` | `agenda` | Text agenda with large Z motif |
| `Agenda 2` | `agenda` | Alternate agenda orientation |
| `Agenda Photo 2` | `agenda` | Photo-led agenda |
| `Content 1`, `Content 3`, `Content 4`, `Content 5`, `Content 6` | `editorial` | General light/dark editorial content |
| `Content 7 (Original)` | `editorial` | Original single-content layout |
| `Content Photo 1`, `Content Photo 3`, `Content Photo 4`, `Content Photo 5`, `Content Photo 9`, `Content Photo 10` | `hero_left` or `hero_right` | Image-and-text content; choose by actual image placement |
| `Two Content (Original)` | `two_column` | Two parallel content regions |
| `Comparison (Original)` | `comparison` | Two-option comparison |
| `Title Only (Original)` | `custom` | Brand-preserving custom composition |
| `Content with Caption (Original)` | `editorial` | Main content plus a supporting caption |
| `Picture with Caption (Original)` | `hero_left` or `hero_right` | Picture with explanatory caption |
| `Conclusion 1`, `Conclusion 2`, `Conclusion 3` | `conclusion` | Summary, recommendation, or closing |
| `Number Large`, `Number Large 2` | `metric` | One dominant metric and short label |
| `Statement` | `statement` | Mission, thesis, or decisive takeaway |
| `Quote`, `Quote 3` | `quote` | Quotation with attribution |

## Selection rules

- Choose a layout from the content shape and item count, not from the topic.
- Use a photo layout only when the image advances the slide's argument.
- Use `Comparison (Original)` only for two options with comparable attributes.
- Use `Number Large` variants for one dominant sourced metric, not several
  unrelated numbers.
- Use `Statement` for one concise thesis and `Quote` variants only for an
  attributed quotation.
- Use section dividers sparingly at meaningful transitions.
- Do not select layouts whose names contain `(Original)` unless the more
  specific Zava layout variants do not fit.

## Template limitation

The Zava template is strongest for editorial, photo-led, metric, statement,
and quote slides. It does not provide dedicated timeline, process, card-grid,
chart, dashboard, source-list, or link-appendix layouts. For those
compositions, use `Title Only (Original)` or another suitable base and create a
custom composition with:

- Zava theme colors and typography;
- the existing title, logo, rule, footer, and slide-number treatment;
- editable PowerPoint shapes and native charts;
- the spacing and alignment rhythm demonstrated by the example slides.

Custom compositions must preserve the template's slide size, typography,
brand colors, margins, footer style, and spacing rhythm.

## Construction rules

- Reuse the template's existing fonts, colors, and placeholder positions.
- Use layout names exactly as listed; never infer names from slide numbers.
- Prefer one message per slide and short supporting text.
- The template starts with zero slides. Do not copy slides from another
  presentation or manipulate the private `_sldIdLst`; add slides only through
  `prs.slides.add_slide(layout)`.
- Do not hard-code a numeric layout index because indexes can change when the template evolves.
- Do not repeat the same named layout on consecutive slides.
- Reject a named layout when the content exceeds the capacity defined in
  `deck-spec.md`; do not force extra content into smaller text.
- Remove unused shapes and placeholders rather than clearing only their text.
- Keep citations in a `Source List` slide and put direct resources in `Link Appendix`.
