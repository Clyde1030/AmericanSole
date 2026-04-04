"""
Preprocessor — cleans a vendor shipment Excel file before LLM extraction.

AS worksheet:
  - Remove: Photo, WIP (cutting/stitching/last), ETD ShenZhen, AS XF, Update AS XF
Shipped worksheet:
  - Unmerge & fill: Container Type, ETD-ShenZhen, ETA-SA, Remark
  - Remove: Photo, WIP (stitching/last/pack), Factory, Order Received Date, AS XF

Usage:
  uv run python -m skills.sort-shipment.scripts.preprocessor <input.xlsx> [output.xlsx]
  uv run python -m skills.sort-shipment.scripts.preprocessor "skills/sort-shipment/references/AS_report_input.xlsx" "output/AS_report_output.xlsx"
"""

from datetime import date
from pathlib import Path

import openpyxl


def _find_columns_by_header(ws, targets: list[str]) -> list[int]:
    """
    Scan the first 2 header rows and return 1-based column indices
    whose header text matches any of the targets (case-insensitive substring).
    """
    matched: list[int] = []
    for row_idx in range(1, 3):
        for col_idx in range(1, ws.max_column + 1):
            val = ws.cell(row_idx, col_idx).value
            if val is None:
                continue
            val_lower = str(val).strip().lower()
            for t in targets:
                if t.lower() in val_lower and col_idx not in matched:
                    matched.append(col_idx)
    return sorted(matched)


def _unmerge_and_fill(ws, col_indices: list[int]) -> None:
    """
    For each merged range that overlaps the given columns,
    unmerge and propagate the top-left value into every cell of the range.
    """
    target_cols = set(col_indices)
    for merged_range in list(ws.merged_cells.ranges):
        if merged_range.min_col not in target_cols:
            continue
        top_value = ws.cell(merged_range.min_row, merged_range.min_col).value
        ws.unmerge_cells(str(merged_range))
        for row in range(merged_range.min_row, merged_range.max_row + 1):
            for col in range(merged_range.min_col, merged_range.max_col + 1):
                ws.cell(row, col).value = top_value


def _remove_images_in_columns(ws, col_indices: list[int]) -> None:
    """Remove embedded images whose anchor falls within the given 1-based columns."""
    cols_0based = {c - 1 for c in col_indices}  # openpyxl anchors use 0-based col
    ws._images = [
        img for img in ws._images
        if not (hasattr(img, "anchor") and hasattr(img.anchor, "_from")
                and img.anchor._from.col in cols_0based)
    ]


def _delete_columns(ws, col_indices: list[int]) -> None:
    """Delete columns by 1-based index, right-to-left to avoid shifting."""
    _remove_images_in_columns(ws, col_indices)
    for col_idx in sorted(col_indices, reverse=True):
        ws.delete_cols(col_idx)


def _unmerge_header_rows(ws) -> None:
    """Unmerge all merged cells in header rows (1-2) and fill with top-left value."""
    for merged_range in list(ws.merged_cells.ranges):
        if merged_range.min_row > 2:
            continue
        top_value = ws.cell(merged_range.min_row, merged_range.min_col).value
        ws.unmerge_cells(str(merged_range))
        for row in range(merged_range.min_row, merged_range.max_row + 1):
            for col in range(merged_range.min_col, merged_range.max_col + 1):
                ws.cell(row, col).value = top_value


def _process_as_sheet(ws) -> None:
    """Clean the AS worksheet."""
    _unmerge_header_rows(ws)
    remove_headers = ["photo", "wip", "cutting", "stitching", "last",
                      "etd shenzhen", "as xf", "update as xf"]
    cols_to_remove = _find_columns_by_header(ws, remove_headers)
    _delete_columns(ws, cols_to_remove)


def _process_shipped_sheet(ws) -> None:
    """Clean the Shipped worksheet."""
    # Step 1: Unhide all columns
    for col_letter, dim in ws.column_dimensions.items():
        if dim.hidden:
            dim.hidden = False

    # Step 2: Unmerge header rows so labels survive column deletion
    _unmerge_header_rows(ws)

    # Step 3: Unmerge and fill merge-sensitive columns BEFORE deletion
    fill_headers = ["container type", "etd-shenzhen", "eta-sa", "remark"]
    fill_cols = _find_columns_by_header(ws, fill_headers)
    _unmerge_and_fill(ws, fill_cols)

    # Step 4: Remove unwanted columns
    remove_headers = ["photo", "stitching", "last", "pack",
                      "factory", "order received date", "as xf"]
    cols_to_remove = _find_columns_by_header(ws, remove_headers)
    _delete_columns(ws, cols_to_remove)


def preprocess(input_path: str | Path, output_path: str | Path | None = None) -> Path:
    """
    Read a vendor Excel file, clean both sheets, and save a preprocessed copy.

    Args:
        input_path: Path to the raw .xlsx file.
        output_path: Where to save. Defaults to output/preprocessed_YYYY-MM-DD.xlsx.

    Returns:
        Path to the saved preprocessed file.
    """
    input_path = Path(input_path)
    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    if output_path is None:
        out_dir = Path("output")
        out_dir.mkdir(exist_ok=True)
        output_path = out_dir / f"preprocessed_{date.today().isoformat()}.xlsx"
    else:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

    wb = openpyxl.load_workbook(input_path)

    for idx, ws in enumerate(wb.worksheets):
        if idx == 0:
            _process_as_sheet(ws)
        elif idx == 1:
            _process_shipped_sheet(ws)

    wb.save(output_path)
    print(f"Preprocessed file saved to: {output_path}")
    return output_path


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: uv run python -m skills.sort-shipment.scripts.preprocessor <input.xlsx> [output.xlsx]")
        sys.exit(1)

    in_file = sys.argv[1]
    out_file = sys.argv[2] if len(sys.argv) > 2 else None
    preprocess(in_file, out_file)
