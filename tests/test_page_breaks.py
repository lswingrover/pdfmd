"""Regression tests for the ``page_breaks`` option.

``insert_page_breaks`` was a silent no-op on the v1.6.0 fork: the ``---`` page
rule inserted between pages was destroyed by the post-assembly cleanup in
``render.render_document`` before reaching the output (repro'd 2026-07-23 via
both the CLI ``--page-breaks`` and the MCP ``pdf_to_markdown`` tool).

Three distinct swallow paths existed; each has an anchor below:

1. ``_defragment_orphans`` merged the short ``---`` line (sandwiched by blanks)
   *up* into the preceding paragraph  -> covered by the end-to-end tests and
   ``test_defragment_leaves_rule_standalone``.
2. ``_defragment_orphans`` merged an orphan at the *top of a page* *into* the
   ``---`` line ("--- Notes")  -> ``test_page_break_survives_orphan_at_page_top``
   and ``test_defragment_does_not_merge_orphan_into_rule``.
3. The trailing footer-artefact regex matched a bare ``---`` and stripped it
   -> ``test_footer_pattern_spares_thematic_break``.

Contract: for an N-page PDF converted with ``insert_page_breaks=True`` we expect
exactly N-1 standalone ``---`` separators and no corrupted "--- text" lines;
with the option off we expect zero.
"""
from __future__ import annotations

import re
from pathlib import Path

import fitz  # PyMuPDF
import pytest

from pdfmd import Options, pdf_to_markdown
from pdfmd.render import (
    _PAGE_BREAK,
    _TRAILING_FOOTER_PATTERN,
    _defragment_orphans,
    _is_thematic_break,
)

N_PAGES = 3


def _count_page_rules(md: str) -> int:
    """Count standalone ``---`` thematic-break lines (page separators)."""
    return len(re.findall(r"^---$", md, flags=re.MULTILINE))


def _corrupted_rule_lines(md: str) -> list[str]:
    """Lines that start with the rule but carry glued-on text, e.g. "--- Notes".

    Uses horizontal whitespace ([ \\t]) only — a legitimate standalone "---"
    followed by "\\n\\nText" must not count as corruption.
    """
    return re.findall(r"^---[ \t]+\S.*$", md, flags=re.MULTILINE)


def _make_pdf(path: Path, page_texts: list[str]) -> Path:
    """Write a PDF whose pages contain the given wrapped text blocks."""
    doc = fitz.open()
    for text in page_texts:
        page = doc.new_page()
        page.insert_textbox(fitz.Rect(72, 72, 520, 720), text, fontsize=12)
    doc.save(path)
    doc.close()
    return path


@pytest.fixture()
def multipage_pdf(tmp_path: Path) -> Path:
    """A deterministic N-page PDF with a distinct long paragraph per page."""
    return _make_pdf(
        tmp_path / "multipage.pdf",
        [
            f"Section {n}. "
            + ("Lorem ipsum dolor sit amet consectetur adipiscing elit. " * 6)
            for n in range(1, N_PAGES + 1)
        ],
    )


# --------------------------------------------------------------------------- #
# End-to-end (full pdf_to_markdown pipeline)
# --------------------------------------------------------------------------- #
def test_page_breaks_inserts_separators(multipage_pdf: Path, tmp_path: Path) -> None:
    out = tmp_path / "with_breaks.md"
    pdf_to_markdown(str(multipage_pdf), str(out), Options(insert_page_breaks=True))
    md = out.read_text(encoding="utf-8")

    assert _count_page_rules(md) == N_PAGES - 1, (
        f"expected {N_PAGES - 1} '---' separators for {N_PAGES} pages, "
        f"got {_count_page_rules(md)}\n---\n{md}"
    )
    assert not _corrupted_rule_lines(md), f"rule corrupted: {_corrupted_rule_lines(md)}"


def test_no_page_breaks_has_no_separators(multipage_pdf: Path, tmp_path: Path) -> None:
    out = tmp_path / "no_breaks.md"
    pdf_to_markdown(str(multipage_pdf), str(out), Options(insert_page_breaks=False))
    md = out.read_text(encoding="utf-8")

    assert _count_page_rules(md) == 0, (
        f"expected 0 '---' separators with page breaks off, "
        f"got {_count_page_rules(md)}\n---\n{md}"
    )


def test_single_page_has_no_separators(tmp_path: Path) -> None:
    pdf = _make_pdf(tmp_path / "one.pdf", ["Only one page here, so no page rule is expected."])
    out = tmp_path / "one.md"
    pdf_to_markdown(str(pdf), str(out), Options(insert_page_breaks=True))
    assert _count_page_rules(out.read_text(encoding="utf-8")) == 0


def test_page_break_survives_orphan_at_page_top(tmp_path: Path) -> None:
    """A short line at the top of a page must not be glued onto the rule above it.

    Regression for the "--- Notes" corruption: the second page starts with a
    short orphan line, which previously merged *into* the page-break rule.
    """
    pdf = tmp_path / "orphan_top.pdf"
    doc = fitz.open()
    p1 = doc.new_page()
    p1.insert_textbox(
        fitz.Rect(72, 72, 520, 720),
        "Introduction. " + ("A nice long flowing paragraph of prose on page one. " * 5),
        fontsize=12,
    )
    p2 = doc.new_page()
    p2.insert_text((72, 96), "Notes", fontsize=12)  # short orphan at the very top
    p2.insert_textbox(
        fitz.Rect(72, 140, 520, 720),
        "Body text of the second page continues with more flowing prose here. " * 5,
        fontsize=12,
    )
    doc.save(pdf)
    doc.close()

    out = tmp_path / "orphan_top.md"
    pdf_to_markdown(str(pdf), str(out), Options(insert_page_breaks=True))
    md = out.read_text(encoding="utf-8")

    assert _count_page_rules(md) == 1, f"expected 1 standalone rule\n---\n{md}"
    assert not _corrupted_rule_lines(md), f"rule corrupted: {_corrupted_rule_lines(md)}\n---\n{md}"


# --------------------------------------------------------------------------- #
# Unit anchors on the render internals (the exact loci of the bugs)
# --------------------------------------------------------------------------- #
def test_defragment_leaves_rule_standalone() -> None:
    md = "Body paragraph one that is long enough.\n\n---\n\nBody paragraph two."
    out = _defragment_orphans(md, max_len=45)
    assert re.search(r"^---$", out, flags=re.MULTILINE), out
    assert "one.\n\n---" in out or "\n\n---\n\n" in out, out


def test_defragment_does_not_merge_orphan_into_rule() -> None:
    md = "Long enough first page paragraph of prose here.\n\n---\n\nNotes.\n\nSecond real paragraph."
    out = _defragment_orphans(md, max_len=45)
    assert not re.search(r"^---[ \t]+\S", out, flags=re.MULTILINE), f"orphan merged into rule: {out!r}"
    assert re.search(r"^---$", out, flags=re.MULTILINE), out
    assert re.search(r"^Notes\.$", out, flags=re.MULTILINE), out


def test_defragment_still_merges_normal_orphan() -> None:
    """Guard the fix didn't over-correct: real orphans still merge into prose."""
    md = "This sentence runs into the next\n\nline.\n\nAnother paragraph follows here."
    out = _defragment_orphans(md, max_len=45)
    assert "runs into the next line." in out, out


@pytest.mark.parametrize(
    "line, stays",
    [
        ("---", True),          # page-break rule survives
        ("-----", True),        # longer rule survives
        ("Body text - - 1", False),   # trailing footer stripped
        ("- -", False),               # bare dash-space-dash footer stripped
        ("text - - 12", False),       # trailing footer with page number stripped
    ],
)
def test_footer_pattern_spares_thematic_break(line: str, stays: bool) -> None:
    stripped = _TRAILING_FOOTER_PATTERN.sub("", line)
    if stays:
        assert stripped == line, f"{line!r} should be untouched, got {stripped!r}"
    else:
        assert stripped != line, f"{line!r} should have footer stripped, got {stripped!r}"


def test_thematic_break_helper() -> None:
    assert _is_thematic_break(_PAGE_BREAK)
    assert _is_thematic_break("  ---  ")
    assert _is_thematic_break("***")
    assert not _is_thematic_break("-- text")
    assert not _is_thematic_break("- - 1")
