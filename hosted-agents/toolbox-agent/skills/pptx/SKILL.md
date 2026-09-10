---
name: pptx
description: Create polished PowerPoint presentations and downloadable .pptx files with native Code Interpreter.
---

# PowerPoint presentation creation

Use this skill when the user asks to create a presentation, slide deck, or
PowerPoint file.

## Workflow

1. Clarify the audience, purpose, slide count, tone, and required content when
   the request does not provide enough direction.
2. Plan the narrative before generating the file. Use a clear opening,
   logically ordered content slides, and a conclusion or call to action.
3. Use the native Code Interpreter tool to generate the presentation as a
   `.pptx` file. Prefer `python-pptx` and create the file under `/mnt/data`.
4. Use a consistent visual system:
   - 16:9 widescreen layout
   - readable type sizes and strong contrast
   - consistent margins, colors, and typography
   - varied but coherent slide layouts
   - charts, diagrams, or visual callouts where they improve understanding
5. Validate the generated package with `python-pptx` by reopening it and
   checking the expected slide count, titles, and speaker notes when present.
6. Cite the generated `.pptx` file in the final response so Foundry exposes it
   as a downloadable Code Interpreter artifact.

## Content and design requirements

- Do not invent facts, metrics, citations, or customer claims.
- Keep slide text concise; move supporting detail into speaker notes when
  useful.
- Avoid text-only slides when a chart, diagram, timeline, comparison, or
  process flow communicates the idea more clearly.
- Use accessible color contrast and never rely on color alone to communicate
  meaning.
- Do not overwrite an uploaded presentation unless the user explicitly asks
  for an in-place replacement.

## Completion

State the generated filename, briefly describe the deck, and include the file
citation. If Code Interpreter cannot create or validate the file, report the
failure rather than presenting a non-existent download.
