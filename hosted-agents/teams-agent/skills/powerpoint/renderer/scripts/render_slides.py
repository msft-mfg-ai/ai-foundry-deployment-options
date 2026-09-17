import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

import pymupdf


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render a PPTX to full-resolution PNG slides."
    )
    parser.add_argument("presentation", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()

    presentation = args.presentation.resolve()
    if not presentation.is_file():
        raise FileNotFoundError(f"Presentation not found: {presentation}")
    output_dir = (args.output_dir or presentation.parent).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    pdf_path = output_dir / f"{presentation.stem}.pdf"
    for stale_slide in output_dir.glob("slide-*.png"):
        stale_slide.unlink()

    with tempfile.TemporaryDirectory(prefix="zava-render-") as temporary_directory:
        temporary_output = Path(temporary_directory)
        result = subprocess.run(
            [
                "soffice",
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                str(temporary_output),
                str(presentation),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        generated_pdf = temporary_output / f"{presentation.stem}.pdf"
        if not generated_pdf.is_file():
            details = "\n".join(part for part in (result.stdout, result.stderr) if part)
            raise RuntimeError(
                f"LibreOffice did not create {generated_pdf.name}.\n{details}"
            )
        shutil.copy2(generated_pdf, pdf_path)

    with pymupdf.open(pdf_path) as document:
        for slide_number, page in enumerate(document, start=1):
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(2, 2), alpha=False)
            pixmap.save(output_dir / f"slide-{slide_number:02d}.png")


if __name__ == "__main__":
    main()
