# Branded template layouts

The packaged `assets/template.pptx` is a 16:9 starter deck with filled example slides. Inspect those examples for spacing, typography, and shape placement before creating new slides.

Select layouts by name:

```python
from pptx import Presentation

prs = Presentation("template.pptx")
layout = next(item for item in prs.slide_layouts if item.name == "Cover")
slide = prs.slides.add_slide(layout)
```

Available named layouts:

| Layout | Recommended use |
|---|---|
| `Cover` | Presentation title, subtitle, owner, and date |
| `Section Divider` | Major topic transition |
| `Timeline + Callouts` | Roadmaps, milestones, and dated sequences |
| `Six Card Grid` | Six parallel concepts, metrics, or workstreams |
| `Comparison Rows` | Side-by-side options or before/after comparison |
| `Four Step Process` | Four-stage process or operating model |
| `Numbered Action List` | Prioritized recommendations or next steps |
| `Six Card Grid - Alt` | Alternate six-item visual treatment |
| `Four Card Grid - Alt` | Four concepts with more space per item |
| `Link Appendix` | Useful links and supporting resources |
| `Source List` | Citations and research sources |

## Selection rules

- Choose a layout from the content shape and item count, not from the topic.
- `Six Card Grid` and its alternate are appropriate only for six genuinely
  parallel, concise items. Do not stretch a narrative into six boxes.
- `Four Card Grid - Alt` is better when each item needs more than a label and
  one short sentence.
- `Comparison Rows` is for consistent attributes across options. It is not a
  generic text table.
- `Timeline + Callouts` requires a real sequence or chronology.
- `Four Step Process` requires four ordered stages.
- `Numbered Action List` requires prioritized actions, not general bullets.
- Use `Section Divider` sparingly at meaningful transitions.

## Template limitation

The current template is strongest for structured business content and contains
many card-based compositions. It does not provide a complete image-led or
chart-led layout library. When cards would weaken the story, use the template
as the brand and theme source and create a custom composition with:

- a half-bleed or full-bleed image;
- a large metric with a supporting chart;
- a simple diagram or annotated process;
- a two-column editorial layout;
- a quote or conclusion with one strong visual.

Custom compositions must preserve the template's slide size, typography,
brand colors, margins, footer style, and spacing rhythm.

## Construction rules

- Reuse the template's existing fonts, colors, and placeholder positions.
- Prefer one message per slide and short supporting text.
- Use the example slides as composition references, but remove examples that are not part of the requested deck.
- Do not hard-code a numeric layout index because indexes can change when the template evolves.
- Do not repeat the same named layout on consecutive slides.
- Do not use card grids for more than one third of content slides.
- Remove unused shapes and placeholders rather than clearing only their text.
- Keep citations in a `Source List` slide and put direct resources in `Link Appendix`.
