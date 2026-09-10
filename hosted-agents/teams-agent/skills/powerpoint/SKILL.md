---
name: powerpoint
description: Create polished PowerPoint presentations using the packaged branded template and Code Interpreter.
---

# PowerPoint presentation generation

Use this skill whenever the user asks to create or revise a PowerPoint presentation.

## Quality standard

A valid PowerPoint file is not necessarily a good presentation. Optimize
separately for:

- a clear narrative and accurate content;
- strong visual hierarchy and topic-specific design;
- coherence across the complete deck;
- reliable rendering without overflow, collisions, or missing assets.

Do not return the first file that opens successfully.

## Required workflow

1. Read `references/layouts.md`.
2. Load `/mnt/data/template.pptx`. It is staged automatically in the current
   user's Code Interpreter container. Never start from a blank
   `Presentation()` when this template is available.
3. Inspect the template's slides, layouts, fonts, colors, dimensions, and
   example compositions before editing it.
4. Create a short storyboard before writing presentation code. For every
   slide, define:
   - its purpose and single takeaway;
   - the content shape, such as hero image, comparison, timeline, process,
     chart, metric, or recommendation;
   - the selected named layout or custom composition;
   - required evidence, visual assets, and source;
   - a title and text budget.
5. Choose a topic-specific visual direction:
   - one dominant color, one or two supporting tones, and one accent;
   - one repeated visual motif;
   - an intentional image style;
   - a light/dark rhythm appropriate to the story.
   Preserve the template's brand colors and typography as the base. Do not
   replace them with a generic blue palette.
6. Research or create the required content and visual assets before laying out
   slides. Never invent factual chart values.
7. Use Code Interpreter for all PowerPoint and image manipulation. Install
   `python-pptx` and `Pillow` when they are not importable.
8. Build the deck using named layouts and placeholders when they fit the
   content. If the available layout would force the story into generic cards,
   create a custom composition on a suitable template layout while preserving
   the theme, margins, footer treatment, and visual language.
9. Run structural and geometry checks.
10. Render the deck to PDF and slide images with LibreOffice or another real
    presentation renderer. Inspect every rendered slide critically.
11. Fix the issues found, render the affected slides again, and inspect them
    again. At least one fix-and-verify cycle is required.
12. Reopen the final file with `python-pptx`, save it under `/mnt/data`, and
    return the `.pptx` as a generated file rather than only a path or base64.

When revising an existing presentation, preserve its working container,
story, and useful assets. Modify the existing file instead of rebuilding it
from scratch unless the user asks for a redesign.

## Slide design rules

- Use one message per slide. The title should state the takeaway, not merely
  name the topic.
- Every substantive slide needs a meaningful visual element: a photo,
  illustration, chart, diagram, timeline, process, icon system, or strong
  typographic data callout.
- Do not use a card grid on more than one third of the content slides. Never
  repeat the same layout on consecutive slides unless repetition is the point.
- Use layouts because their slot count and geometry match the content, not
  because their names sound related.
- Prefer four strong items over six weak ones. Remove unused shapes and
  placeholders instead of leaving empty boxes.
- Use charts only for sourced data. Label illustrative or hypothetical values
  explicitly.
- Avoid decorative lines under titles, dense bullet walls, tiny captions,
  arbitrary gradients, clip-art styling, and irrelevant stock imagery.

## Text and spacing budgets

- Slide title: normally 36-44 pt, no more than two lines.
- Section heading: normally 20-24 pt.
- Body text: normally 16-20 pt; never below 14 pt to make content fit.
- Caption or source text: normally 10-12 pt.
- Keep at least 0.5 inch from slide edges and 0.3 inch between independent
  content blocks.
- Keep paragraphs short. Aim for no more than 40 words in a body region and no
  more than six parallel items on a slide.
- If content does not fit at the minimum font size, shorten it, change the
  layout, or split the slide. Do not solve overflow by shrinking text.

## Images

- Use imagery that supports the slide's argument rather than merely matching a
  keyword.
- Prefer one strong hero image or a small coherent image set over many
  unrelated thumbnails.
- Transfer image bytes into Code Interpreter as input files before using
  `python-pptx`.
- Use Pillow to validate dimensions, normalize to PNG or JPEG, and crop with a
  deliberate contain or cover strategy. Never stretch an image.
- Keep important subjects away from crop edges and text overlays.
- Never paste a remote URL into the presentation as though it were embedded.
- Add concise alt text or an adjacent caption when an image carries meaning.

## Validation

### Structural checks

- Reopen the saved file with `python-pptx`.
- Confirm that it contains the intended slide count and no empty placeholder-only slides.
- Confirm that every referenced image is embedded in the package.
- Confirm that the file begins with the ZIP signature expected for a valid `.pptx`.
- Check that shapes stay within slide bounds.
- Check text boxes for overflow risk using font size, line count, box height,
  and the selected layout's text budget.
- Check unintended overlaps while allowing deliberate backgrounds and overlays.
- Search for leftover template text such as `Headline goes here`, `Card title`,
  `Source label`, and `stat label`.

### Visual checks

- Render the complete deck with a real presentation renderer.
- Inspect full-resolution slide images, not only a thumbnail contact sheet.
- Assume the first render contains problems. Check for:
  - clipped or wrapped titles;
  - text overflow and fonts below the minimum size;
  - poor contrast;
  - distorted or awkwardly cropped images;
  - collisions and inconsistent alignment;
  - uneven spacing or excessive empty space;
  - repetitive layouts;
  - weak hierarchy or slides that read like documents;
  - leftover template content.
- Record concrete issues by slide number, fix them, and re-render the affected
  slides. A second inspection of an unchanged file does not count as a repair
  cycle.
- If no real renderer is available, perform the structural checks and state
  that visual rendering could not be completed. Do not claim that visual QA
  passed.

Return a short summary and the generated PowerPoint file.
