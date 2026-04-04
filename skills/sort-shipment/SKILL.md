---
name: sort-shipment
description: Extract and normalize structured shipment records from preprocessed vendor Excel data
---

## ROLE
You are a deterministic data transformation engine for logistics shipment data.

Your job is to convert messy, semi-structured Excel text dumps into clean, structured shipment records.

Do NOT behave like a human analyst.  
Do NOT explain your reasoning.  
Only perform extraction and normalization.

---

## INPUT
You will receive a preprocessed Excel workbook from `data/bronze/preprocessed_YYYY-MM-DD.xlsx` (using today's date).

The preprocessor has already:
- Unhidden all columns
- Unmerged cells and propagated values
- Removed irrelevant columns (Photo, WIP, AS XF, Update AS XF, etc.)

Remaining characteristics of the data:
- Cells may contain:
  - multi-line text
  - mixed languages (English / Chinese)
  - inconsistent date formats
- PO numbers are always strings — never cast them to integers or floats
- Two worksheets:
  - "AS": pending shipments
  - "Shipped": completed shipments (may use inconsistent naming)

**IMPORTANT:** Process BOTH worksheets. Extract shipment records from AS and
Shipped, then concatenate all rows into a single result written to `data_dest`.

---

## OUTPUT CONTRACT (STRICT)

Output must be written to an Excel file:

1. Copy `skills/sort-shipment/references/gantt_template.xlsx` to `data/silver/gantt_YYYY-MM-DD.xlsx` (using today's date)
2. Open the copy and write the curated data to the **"data"** worksheet, starting at the named range **`data_dest`**
3. **Do NOT modify, delete, or hide any other worksheet** — only write to "data"
4. Save and close the file

Data rules:
- One row per shipment
- All rows must follow the schema exactly
- Invalid or unresolvable rows must be skipped
- Column order must match the output schema below

---

## OUTPUT SCHEMA

po_number,shipment_idx,brand,style,pairs,lh_xf,etd_port,eta_sa,eta_fac,customer_requested_xf,container_type,container_number,remark

---

## NORMALIZATION PIPELINE

### Step 1 — Detect Shipment Splits
A PO may represent multiple shipments.

#### Case A — Multi-line XF with matching total
Example:
- pairs = 1938
- LH XF = "4/1:660\n4/9:1278"

Rule:
- If quantities sum to total pairs → split into multiple shipments
- Assign shipment_idx sequentially starting at 1

---

#### Case B — Partial shipments already completed
Example:
- pairs = 1314
- XF:
  "3/26:600 OK\n3/27:396 OK\n2026/4/1:1314"

Rule:
- Ignore completed shipments ("OK")
- Select remaining shipment where quantity matches total pairs for both LH XF and ETA-SA

---

### Step 2 — Date Normalization
Convert all dates to:
YYYY-MM-DD

Handle:
- YYYY/MM/DD
- MM/DD
- MM-DD
- mixed formats

Heuristics:
- Assume current year if missing
- Prefer ISO-like formats when ambiguous

---

### Step 3 — Derived Fields

#### eta_sa
- If present and is an actual date → use it
- If the cell contains a formula (e.g., a value plus 35 or plus 55) or is missing,
  compute it from scratch:
  - Determine the shipment's origin location. Check the **Remark** column for
    country/factory clues (e.g., "Cambodia", "柬埔寨").
  - Cambodia shipments → lh_xf + 55 days
  - All other origins → lh_xf + 35 days

#### eta_fac
- eta_sa + 3 days

---

### Step 4 — Container Logic
- If container_type is merged across rows:
  - assign same value to all related shipments
- Same rule applies to ETA fields tied to container

---

## RULES

- Never invent data
- Only infer when logically certain
- If uncertain → return null
- PO numbers must always be written as strings (text), never as numbers
- Maintain row order as in source — AS rows first, then Shipped rows
- shipment_idx must restart per PO
- Output must be deterministic

---

## EDGE CASE HANDLING

- Multi-line text in cells → parse each line separately for shipment splits and dates
- Mixed-language cells → extract only meaningful structured data
- Extra text in cells → extract relevant values, discard noise
- Duplicate PO rows → treat independently unless clearly merged
- **customer_requested_xf** — this field may not have its own column. When it
  is absent, check the **Remark** column for date-like references that indicate
  a customer-requested ex-factory date (e.g., "客人要求4/15出", "cust req XF 4/15",
  or similar patterns). Parse and normalize these dates. If no such information
  exists, return null.

---

## FAILURE POLICY

Skip a row if:
- PO number is missing
- pairs cannot be determined
- shipment structure cannot be resolved

---

## SUCCESS CRITERIA

- Each row represents exactly one shipment
- Totals across shipments match original PO quantity (when splittable)
- All dates are normalized
- Output is machine-ingestable without cleanup