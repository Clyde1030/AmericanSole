"""
Weinbrenner-format packing list PDF parser.

Extracts item type (upper/outsole/sample), style numbers, and size-quantity
breakdowns from packing list PDFs, then writes a structured CSV.

Usage:
    uv run python packing_list/parse_packing_list.py <pdf_path> [output_csv]
"""

import csv
import logging
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import pdfplumber

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------


@dataclass
class PackingItem:
    """One logical item: a (PO, style, item_type) with its size breakdown."""

    po_number: str
    style: str
    item_type: str  # "upper", "outsole", or "sample"
    size_breakdown: dict[str, int] = field(default_factory=dict)

    @property
    def total_pairs(self) -> int:
        return sum(self.size_breakdown.values())

    def merge(self, other: "PackingItem") -> None:
        """Accumulate another block's sizes into this item."""
        for size, qty in other.size_breakdown.items():
            self.size_breakdown[size] = self.size_breakdown.get(size, 0) + qty


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

# Matches lines like:
#   P/O# 671558                STYLE# 804-6301-M
#   P/O# 671558 TESTING SAMPLE STYLE# 804-6301-M
#   P/O# 671558                STYLE# 804-6301-M (OUTSOLE)
HEADER_RE = re.compile(
    r"P/O#\s*(\d+)\s*(TESTING SAMPLE)?\s*STYLE#\s*([\w.-]+(?:\s*\(OUTSOLE\))?)",
    re.IGNORECASE,
)


class PackingListParser:
    """Parses a Weinbrenner-format packing list PDF into :class:`PackingItem` objects.

    Strategy
    --------
    1. On each page, extract **headers** (``P/O# … STYLE# …`` lines) from the
       plain-text layer and **tables** via ``pdfplumber.extract_tables()``.
    2. The first table on page 1 is the *summary* table (has an ``ITEM NO.``
       column) — skip it.  Every other table is a *detail* table whose first
       column contains ``SIZES / PAIRS / …`` labels.
    3. Headers and detail tables appear in the same order on each page, giving
       a 1-to-1 mapping.
    4. Tables that share the same ``(po_number, style, item_type)`` key are
       merged (their size breakdowns are combined).
    """

    def __init__(self, pdf_path: str | Path) -> None:
        self.pdf_path = Path(pdf_path)

    # -- public API ---------------------------------------------------------

    def parse(self) -> list[PackingItem]:
        """Return de-duplicated, merged list of :class:`PackingItem`."""
        raw_items: list[PackingItem] = []

        with pdfplumber.open(self.pdf_path) as pdf:
            for page in pdf.pages:
                headers = self._extract_headers(page)
                tables = self._extract_detail_tables(page)

                if len(headers) != len(tables):
                    logger.warning(
                        "Page %s: %d headers vs %d tables — skipping page",
                        page.page_number,
                        len(headers),
                        len(tables),
                    )
                    continue

                for (po, style, item_type), table in zip(headers, tables):
                    size_bd = self._parse_size_breakdown(table)
                    raw_items.append(
                        PackingItem(
                            po_number=po,
                            style=style,
                            item_type=item_type,
                            size_breakdown=size_bd,
                        )
                    )

        return self._merge_items(raw_items)

    # -- header extraction --------------------------------------------------

    @staticmethod
    def _extract_headers(page) -> list[tuple[str, str, str]]:
        """Return ``[(po_number, style, item_type), …]`` from the text layer."""
        text = page.extract_text() or ""
        results: list[tuple[str, str, str]] = []

        for line in text.split("\n"):
            m = HEADER_RE.search(line)
            if not m:
                continue

            po_number = m.group(1)
            is_sample = m.group(2) is not None
            style_raw = m.group(3).strip()

            if is_sample:
                item_type = "sample"
                style = style_raw
            elif "(OUTSOLE)" in style_raw.upper():
                item_type = "outsole"
                style = re.sub(r"\s*\(OUTSOLE\)", "", style_raw, flags=re.IGNORECASE).strip()
            else:
                item_type = "upper"
                style = style_raw

            results.append((po_number, style, item_type))

        return results

    # -- table extraction ---------------------------------------------------

    @staticmethod
    def _extract_detail_tables(page) -> list[list[list[str]]]:
        """Return only the *detail* tables (SIZES/PAIRS/…), skipping summaries."""
        raw_tables = page.extract_tables() or []
        detail: list[list[list[str]]] = []

        for table in raw_tables:
            if not table or not table[0]:
                continue
            first_cell = (table[0][0] or "").strip().upper()
            # Summary table starts with ITEM NO.; detail tables start with SIZES
            if first_cell == "SIZES":
                detail.append(table)

        return detail

    # -- size breakdown -----------------------------------------------------

    @staticmethod
    def _parse_size_breakdown(table: list[list[str]]) -> dict[str, int]:
        """Extract ``{size: pairs}`` from a detail table.

        Row 0 = SIZES, Row 1 = PAIRS.  The last column is always ``TOTAL``
        which we skip.
        """
        sizes_row = table[0]  # ['SIZES', '5', '5.5', ..., 'TOTAL']
        pairs_row = table[1]  # ['PAIRS', '8', '4',   ..., '236']

        breakdown: dict[str, int] = {}
        # Skip column 0 (label) and last column (TOTAL)
        for col_idx in range(1, len(sizes_row)):
            size_val = (sizes_row[col_idx] or "").strip()
            pair_val = (pairs_row[col_idx] or "").strip()

            if not size_val or size_val.upper() == "TOTAL":
                continue
            try:
                qty = int(pair_val)
                breakdown[size_val] = breakdown.get(size_val, 0) + qty
            except (ValueError, TypeError):
                logger.warning("Skipping unparseable pair value %r for size %r", pair_val, size_val)
        return breakdown

    # -- merging ------------------------------------------------------------

    @staticmethod
    def _merge_items(items: list[PackingItem]) -> list[PackingItem]:
        """Merge items that share the same (po, style, item_type) key."""
        merged: dict[tuple[str, str, str], PackingItem] = {}
        for item in items:
            key = (item.po_number, item.style, item.item_type)
            if key in merged:
                merged[key].merge(item)
            else:
                merged[key] = item
        return list(merged.values())


# ---------------------------------------------------------------------------
# Report / CSV writer
# ---------------------------------------------------------------------------


class PackingListReport:
    """Writes parsed packing items to a structured CSV."""

    def __init__(self, items: list[PackingItem]) -> None:
        self.items = items

    def to_csv(self, output_path: str | Path) -> Path:
        """Write a long-format CSV: one row per (item, size).

        Columns: po_number, style, item_type, size, quantity
        """
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        with open(output_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["po_number", "style", "item_type", "size", "quantity"])

            for item in self.items:
                for size in sorted(item.size_breakdown, key=_size_sort_key):
                    writer.writerow([
                        item.po_number,
                        item.style,
                        item.item_type,
                        size,
                        item.size_breakdown[size],
                    ])

        return output_path


def _size_sort_key(size: str) -> float:
    """Sort sizes numerically."""
    try:
        return float(size)
    except ValueError:
        return 999.0


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: uv run python packing_list/parse_packing_list.py <pdf_path> [output_csv]")
        sys.exit(1)

    pdf_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else "output/packing_list.csv"

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = PackingListParser(pdf_path)
    items = parser.parse()

    report = PackingListReport(items)
    csv_path = report.to_csv(output_path)

    print(f"\nParsed {len(items)} items:")
    for item in items:
        print(f"  [{item.item_type:>7}] {item.style} — {item.total_pairs} pairs, {len(item.size_breakdown)} sizes")
    print(f"\nCSV saved to: {csv_path}")


if __name__ == "__main__":
    main()
