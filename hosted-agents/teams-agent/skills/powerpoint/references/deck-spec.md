# Semantic deck specification

Define the complete presentation as JSON before writing PowerPoint code. Treat
this specification as the source of truth for narrative, layout selection,
content budgets, assets, and validation.

## Contract

```json
{
  "title": "Required presentation title",
  "audience": "Required audience description",
  "objective": "Required decision, understanding, or action",
  "visual_direction": {
    "tone": "executive",
    "image_style": "editorial_photography",
    "motif": "short description of one repeated visual device",
    "density": "balanced"
  },
  "slides": [
    {
      "id": "01",
      "role": "cover",
      "takeaway": "One complete sentence stating the slide's message",
      "composition": "cover",
      "title": "Concise slide title",
      "body": [],
      "visual": {
        "kind": "hero_image",
        "purpose": "Why this visual strengthens the takeaway",
        "asset_path": "/mnt/data/hero.png",
        "crop": "cover"
      },
      "evidence": [],
      "speaker_notes": ""
    }
  ]
}
```

## Allowed values

Use these exact values instead of inventing similar labels.

| Field | Allowed values |
|---|---|
| `visual_direction.tone` | `executive`, `editorial`, `technical`, `energetic`, `minimal` |
| `visual_direction.image_style` | `editorial_photography`, `documentary_photography`, `technical_illustration`, `abstract_illustration`, `diagram_only` |
| `visual_direction.density` | `spacious`, `balanced`, `dense` |
| `role` | `cover`, `agenda`, `context`, `insight`, `evidence`, `comparison`, `process`, `timeline`, `recommendation`, `summary`, `sources`, `appendix` |
| `composition` | `cover`, `section_divider`, `agenda`, `editorial`, `hero_left`, `hero_right`, `two_column`, `metric`, `comparison`, `timeline`, `process`, `numbered_actions`, `card_grid`, `chart`, `statement`, `quote`, `conclusion`, `source_list`, `link_appendix`, `custom` |
| `visual.kind` | `none`, `hero_image`, `supporting_image`, `chart`, `diagram`, `timeline`, `process`, `metric`, `quote` |
| `visual.crop` | `cover`, `contain`, `none` |

## Content objects

Each `body` entry has one of these shapes:

```json
{"kind": "paragraph", "text": "Up to 40 words"}
{"kind": "bullet", "title": "Optional label", "text": "One concise point"}
{"kind": "metric", "value": "42%", "label": "Short sourced label"}
{"kind": "comparison", "label": "Attribute", "left": "Option A", "right": "Option B"}
{"kind": "step", "number": 1, "title": "Stage", "text": "Concise explanation"}
```

Each `evidence` entry uses:

```json
{
  "claim": "Claim supported on this slide",
  "source": "Publisher or document",
  "url": "https://...",
  "accessed": "YYYY-MM-DD"
}
```

Do not include a chart unless its values and units are present in the
specification and supported by evidence. Mark user-provided estimates or
hypothetical values explicitly.

## Capacity rules

- One takeaway and one primary composition per slide.
- Cover: title, subtitle, and at most three short metadata fields.
- Hero/editorial: at most 80 total body words.
- Agenda: three to six concise sections.
- Two-column: two parallel ideas with at most 60 words per column.
- Comparison: two options and at most five comparable rows.
- Timeline/process: three to six stages.
- Card grid: two to six genuinely parallel items and no more than one third
  of the deck's content slides.
- Numbered actions: three to seven prioritized actions.
- Metric: one dominant value and one short sourced label.
- Chart: one primary chart and at most three supporting metrics.
- Statement: one thesis of at most 45 words.
- Quote: one quote, attribution, and one short contextual statement.
- Conclusion: no more than three recommendations or summary points.
- Sources: continue onto additional source slides instead of shrinking text.

When content exceeds a composition's capacity, shorten it, choose another
composition, or split the slide. Never reduce body text below 14 pt.

## Compilation rules

1. Validate required fields and allowed values before creating slides.
2. Map each composition to a named template layout when one exists.
3. Use a custom composition only when the named layouts cannot express the
   specification without weakening the story.
4. Keep slide IDs stable through repair iterations.
5. Render from the specification rather than embedding presentation content
   directly throughout ad hoc drawing code.
6. Save the specification as a working JSON artifact, but do not select it
   with `return_file` unless the user requests it.
