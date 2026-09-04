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

## Construction rules

- Reuse the template's existing fonts, colors, and placeholder positions.
- Prefer one message per slide and short supporting text.
- Use the example slides as composition references, but remove examples that are not part of the requested deck.
- Do not hard-code a numeric layout index because indexes can change when the template evolves.
- Keep citations in a `Source List` slide and put direct resources in `Link Appendix`.
