---
name: powerpoint
description: Create polished PowerPoint presentations using the packaged branded template and Code Interpreter.
---

# PowerPoint presentation generation

Use this skill whenever the user asks to create or revise a PowerPoint presentation.

## Required workflow

1. Read `references/layouts.md` before constructing the deck.
2. Load `/mnt/data/template.pptx` as the source presentation. It is staged
   automatically in the current user's Code Interpreter container. Do not start
   from a blank `Presentation()`.
4. Use Code Interpreter for all PowerPoint and image manipulation.
5. Install `python-pptx` and `Pillow` in Code Interpreter when they are not already importable.
6. Preserve the template's 16:9 dimensions, theme, layouts, and visual language.
7. Use named layouts rather than relying on numeric layout indexes.
8. Keep text concise, readable, and within slide boundaries.
9. Save the final presentation as a `.pptx` file and return it as a generated file, not only as base64 or a filesystem path.

## Images

- Prefer a relevant generated or researched image when it materially improves a slide.
- Transfer image bytes into Code Interpreter as an input file before using `python-pptx`.
- Use Pillow to validate the image, normalize it to PNG or JPEG, and crop it without distortion.
- Never paste a remote URL into the presentation as though it were an embedded image.
- Add concise alt text or an adjacent caption when the image carries meaning.

## Validation

Before returning the deck:

- Reopen the saved file with `python-pptx`.
- Confirm that it contains the intended slide count and no empty placeholder-only slides.
- Confirm that every referenced image is embedded in the package.
- Confirm that the file begins with the ZIP signature expected for a valid `.pptx`.

Return a short summary and the generated PowerPoint file.
