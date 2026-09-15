---
name: image-generation
description: Generate and return standalone original images, or create visual assets for presentations and other generated files.
---

# Image generation

Use this skill whenever the user asks to generate an image, illustration,
visual, or picture. For a standalone image request, call `generate_image` and
return the generated image file directly; do not load the PowerPoint skill or
create a presentation unless the user explicitly requests slides or a deck.
The tool is deployment-dependent and is absent when no compatible GPT Image
or MAI Image deployment was discovered.

## Prompting

- Describe the subject, setting, composition, camera or illustration style,
  lighting, color palette, and intended slide role.
- State the desired negative space for titles or labels.
- Prefer a single clear subject and presentation-safe composition over dense
  scenes.
- Do not request logos, trademarks, signatures, watermarks, or imitation of a
  living artist.
- Use landscape dimensions for slide heroes, portrait dimensions for side
  panels, and square dimensions for tiles only when the active model profile
  supports them.

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
