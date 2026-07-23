"""Regression test for the ``page_breaks`` option.

Guards against the bug where the footer-artefact stripping regex in
``render.render_document`` silently ate the ``---`` thematic breaks inserted
between pages, making ``insert_page_breaks`` a no-op (repro'd 2026-07-23 on
the v1.6.0 fork via both the CLI ``--page-breaks`` and the MCP tool).

For an N-page PDF converted with ``insert_page_breaks=True`` we expect exactly
N-1 standalone ``---`` separators; with the option off we expect zero.
"""
from __future__ import annotations

import re
from pathlib import Path

import fitz  # PyMuPDF
import pytest

from pdfmd import Options, pdf_to_markdown

N_PAGES = 3


def _count_page_rules(md: str) -> int:
    """Count standalone ``---`` thematic-break lines (page separators)."""
    return len(re.findall(r"^---$", md, flags=re.MULTILINE))


@pytest.fixture()
def multipage_pdf(tmp_path: Path) -> Path:
    """A deterministic multi-page PDF with distinct body text per page.

    Each page carries a long, unique sentence so nothing is mistaken for a
    repeating header/footer or a short orphan line during transformation.
    """
    pdf_path = tmp_path / "multipage.pdf"
    doc = fitz.open()
    for n in range(1, N_PAGES + 1):
        page = doc.new_page()
        page.insert_text(
            (72, 96),
            f"This is a full sentence of body content that belongs to page "
            f"number {n} of the document and is deliberately long.",
            fontsize=12,
        )
    doc.save(pdf_path)
    doc.close()
    return pdf_path


def test_page_breaks_inserts_separators(multipage_pdf: Path, tmp_path: Path) -> None:
    out = tmp_path / "with_breaks.md"
    pdf_to_markdown(str(multipage_pdf), str(out), Options(insert_page_breaks=True))
    md = out.read_text(encoding="utf-8")

    assert _count_page_rules(md) == N_PAGES - 1, (
        f"expected {N_PAGES - 1} '---' separators for {N_PAGES} pages, "
        f"got {_count_page_rules(md)}\n---\n{md}"
    )


def test_no_page_breaks_has_no_separators(multipage_pdf: Path, tmp_path: Path) -> None:
    out = tmp_path / "no_breaks.md"
    pdf_to_markdown(str(multipage_pdf), str(out), Options(insert_page_breaks=False))
    md = out.read_text(encoding="utf-8")

    assert _count_page_rules(md) == 0, (
        f"expected 0 '---' separators with page breaks off, "
        f"got {_count_page_rules(md)}\n---\n{md}"
    )
