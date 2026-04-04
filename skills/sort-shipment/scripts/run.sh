#!/bin/bash
# Runner — preprocesses a vendor shipment Excel file, then invokes the LLM
# extraction skill to produce the structured gantt output.
#
# Usage:
#   ./skills/sort-shipment/scripts/run.sh [input.xlsx]
#
# Defaults to data/raw/AS_report_input.xlsx if no argument is provided.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILL_FILE="$PROJECT_DIR/skills/sort-shipment/SKILL.md"

INPUT="${1:-data/raw/AS_report_input.xlsx}"

echo "=== Step 1: Preprocessing ==="
uv run python -m skills.sort-shipment.scripts.preprocessor "$INPUT"

echo ""
echo "=== Step 2: LLM Extraction ==="
TODAY=$(date +%Y-%m-%d)
BRONZE_FILE="data/bronze/preprocessed_${TODAY}.xlsx"
echo "Running claude on ${BRONZE_FILE}... (this may take a minute)"

PROMPT="$(cat "$SKILL_FILE")

---
Process the file at: ${BRONZE_FILE}
Today's date is: ${TODAY}"

echo "$PROMPT" | claude --verbose -p -
