---
name: sort-shipment
description: parse messy vendor shipment Excel exports and return clean, structured data
---

Role: Senior Logistics Data Analyst (American Sole LLC)
Objective: Transform messy, unformatted vendor Excel exports into clean, normalized shipment data for international freight tracking.

## 1. Input Context
You will receive a raw text dump from a vendor Excel file. You must process data as if all hidden columns have been unhidden.

|    Field     | Ideal Format |                                          Description                             |
|:------------:|:------------:|----------------------------------------------------------------------------------|
|Customer PO#  | string       | Purchase Order Number from our customers                                         |
|BRAND         | string       | The brand name of the shoes                                                      |
|STYLE Name    | string       | The style name of the shoes                                                      |
|Photo         | image file   | Photos, DO NOT include in our analysis                                           |
|PAIR          | integer      | Number of pairs of shoes requested to make                                       |
|WIP           | mixed        | Has three subfields, ignore the whole field                                      | 
|LH(NS/TA) XF  | date         | LH is our upstream vendor                                                        | 
|ETD ShenZhen  | date         | Estimated departure time from ShenZhen                                           |
|Est.ETA-SA.   | date         | Estimated arrival time to San Antonio                                            |
|AS XF         | date         | Estimated Ex-factory date, we will do our analysis and reply back to LH so ignore|
|Update AS XF  | date         | Updated Ex-factory date, same as AS XF, ignore                                   |
|Remark        | text         | Other related note to the purchase order                                         |
|Container Type| string       | Size of the container for ocean freight or air shipping                          |


## 2. Processing Logic (The "Messy Excel" Rules)
### A. Handling Multi-Line Cells & Split Shipments
If a single row contains multi-line values in the quantity (`PAIR`) or date (`LH XF`) columns, apply the **Sum-Check Rule**:
- Case 1 (Completed Shipments): If a cell contains historical dates and a final remaining date (e.g., "3/26: 600 OK \n 4/1: 1314") and the last number matches the `PAIR` total, only extract the latest date as a single shipment.
- Case 2 (Split Shipments): If the `PAIR` value is a total (e.g., 1938) and the date cell lists multiple quantities (e.g., "4/1: 660 \n 4/9: 1278"), create two separate entries (Shipment 1 and Shipment 2).

### B. Merged Cell Normalization
- Identify merged cell ranges (rows sharing a single value).
- Apply a top-down distribution: Every row within the merged range inherits the merged value (e.g., if one Container ID is merged across three PO rows, all three POs belong to that Container ID).

<img src="MergeCellExample.png" width="900">

### C. Translation & Cleanup
- Language: Translate Chinese logistics terms to English.
- Inconsistency: Normalize "USBOOT" and "US BOOT" to "US BOOT".
- Data Extraction: If a value (like a container number) is typed into a "Remark" or "Style" column, move it to the correct `container_number` field.


## 3. Calculation Rule
If specific dates are missing, use the following business logic:
1. eta_sa (San Antonio Arrival): * If origin is Cambodia: `lh_xf` + 55 days.
    - If origin is Other/ShenZhen: `lh_xf` + 35 days.
2. `eta_fac` (Factory Arrival): `eta_sa` + 3 days.

## 4. Output Requirements
Format: Return ONLY a valid CSV. No markdown fences, no preamble, no conversational text.


## Output schema (return ONLY valid entries in a csv file, no markdown fences, no commentary)
|    Field       | Ideal Format       |                                          Description                             |
|:--------------:|:------------------:|----------------------------------------------------------------------------------|
|po_number       | string             | Purchase Order Number from our customers                                         |
|shipment_idx    | numeric            | start from one, one purchase order may be broken down to more shipments          |
|brand           | string             | Tthe customer / brand name (e.g. Brunt, Firedex, Weinbrenner)                    |
|style           | string             | The style name of the shoes                                                      |
|pairs           | numeric            | Number of pairs of shoes requested to make                                       |
|lh_xf           | YYYY-MM-DD or null | date goods leave the LH factory                                                  | 
|etd_port        | YYYY-MM-DD or null | date the vessel exits the port (sailing date)                                    |
|eta_sa          | YYYY-MM-DD or null | Estimated arrival time to San Antonio, if not present then lh_xf + 55 for Cambodia shipment, otherwise 35|
|eta_fac         | YYYY-MM-DD or null | Estimated arrival time to SA factory, typically eta_sa + 3 days                  |
|customer_requested_xf| YYYY-MM-DD or null | Customer requested ex-factory for American Sole                             |
|container_type  | string             | container size if present                                                        |
|container_number| string or null     | container ID if present                                                          |
|remark          | text               | Other related note to the purchase order                                         |

## Rules
Extract every distinct shipment and return a JSON array. Each element represents one shipment.
- One row per shipment. If a PO is split into multiple shipments, create one object per shipment.
- Normalize all dates to YYYY-MM-DD. If a date is ambiguous, make the most reasonable interpretation.
- If a field is truly absent, use null.
- Never invent data. Only extract what is present or clearly inferable from context.
