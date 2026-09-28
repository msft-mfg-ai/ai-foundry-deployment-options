---
name: image-generation
description: Generate and return standalone original images, or create visual assets for presentations and other generated files.
---

# Image generation

Use this skill whenever the user asks to generate an image, illustration,
visual, or picture. For a standalone image request, call `generate_image` and
then call `return_file` with the generated filename so the image is returned
directly. Do not load the PowerPoint skill or create a presentation unless the
user explicitly requests slides or a deck. When an image is a supporting asset
for another deliverable, do not call `return_file` for the image unless the
user also asks to receive it separately.
The tool is deployment-dependent and is absent when no compatible GPT Image
or MAI Image deployment was discovered.

## Prompting

- Set `aspect_ratio` to exactly one of `square`, `landscape`, or `portrait`.
- For GPT Image, set `quality` to exactly one of `low`, `medium`, or `high`.
  Prefer `medium` for normal requests and `high` when presentation-quality
  detail matters. MAI Image does not expose a quality parameter.
- Describe the subject, setting, composition, camera or illustration style,
  lighting, color palette, and intended slide role.
- State the desired negative space for titles or labels.
- Prefer a single clear subject and presentation-safe composition over dense
  scenes.
- Do not request logos, trademarks, signatures, watermarks, or imitation of a
  living artist.
- Use `landscape` for slide heroes, `portrait` for side panels, and `square`
  for tiles or standalone square images. The tool maps these semantic choices
  to dimensions supported by the active image deployment.

## Files and PowerPoint

1. Supply a short safe filename stem such as `factory-digital-twin`; never use
   directories or `/mnt/data` in the filename argument.
2. The tool returns the exact staged path, media type, width, and height, for
   example `/mnt/data/factory-digital-twin-a1b2c3d4.png`.
3. Pass that exact path to Code Interpreter. Do not use base64 or a remote URL.
4. Open the image with Pillow, validate dimensions, and choose a deliberate:
   - **contain** treatment when the complete image must remain visible;
   - **cover** crop for full-bleed or hero regions.
5. Never stretch an image. Keep key subjects away from crop boundaries and
   text overlays.
6. Embed the local file with `python-pptx`, add concise alt text or an adjacent
   descriptive caption, and verify the image is present in the final package.

When the image tool is unavailable, continue with diagrams, charts, typography,
or user-provided assets rather than failing the presentation workflow.
