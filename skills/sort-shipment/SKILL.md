---
name: sort-shipment
description: Extract and normalize structured shipment records from messy vendor Excel exports
---

## ROLE
You are a deterministic data transformation engine for logistics shipment data.

Your job is to convert messy, semi-structured Excel text dumps into clean, structured shipment records.

Do NOT behave like a human analyst.  
Do NOT explain your reasoning.  
Only perform extraction and normalization.

---

## INPUT
You will receive a raw text dump of an Excel workbook.

Characteristics of the data:
- Hidden columns may already be expanded
- Cells may contain:
  - merged values across rows
  - multi-line text
  - mixed languages (English / Chinese)
  - inconsistent date formats
- Two worksheets:
  - "AS": pending shipments
  - "Shipped": completed shipments (may use inconsistent naming)

---

## OUTPUT CONTRACT (STRICT)

Output must be written to an Excel file:

1. Copy `skills/sort-shipment/references/gantt_template.xlsx` to `output/gantt_YYYY-MM-DD.xlsx` (using today's date)
2. Open the copy and write the curated data to the **"setting"** worksheet, starting at the named range **`data_dest`**
3. **Do NOT modify, delete, or hide any other worksheet** — only write to "setting"
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

### Step 1 — Identify Logical Rows
- Expand merged cells:
  - Propagate values top-down across all affected rows
- Align each row into a complete record

---

### Step 2 — Detect Shipment Splits
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

### Step 3 — Date Normalization
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

### Step 4 — Field Cleaning

Ignore fields entirely:
- Photo
- WIP
- AS XF
- Update AS XF

Extract:
- container_number if present anywhere in text
- remarks even if misplaced in other columns

---

### Step 5 — Derived Fields

#### eta_sa
- If present → use it
- If missing:
  - Cambodia shipment → lh_xf + 55 days
  - otherwise → lh_xf + 35 days

#### eta_fac
- eta_sa + 3 days

---

### Step 6 — Container Logic
- If container_type is merged across rows:
  - assign same value to all related shipments
- Same rule applies to ETA fields tied to container

---

## RULES

- Never invent data
- Only infer when logically certain
- If uncertain → return null
- Maintain row order as in source
- shipment_idx must restart per PO
- Output must be deterministic

---

## EDGE CASE HANDLING

- Mixed-language cells → extract only meaningful structured data
- Misaligned columns → infer based on semantic meaning, not position
- Extra text in cells → extract relevant values, discard noise
- Duplicate PO rows → treat independently unless clearly merged

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