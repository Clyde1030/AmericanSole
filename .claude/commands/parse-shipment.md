Run the shipment extraction agent against an Excel file.

## Steps

1. The user will pass the Excel file path as an argument: `$ARGUMENTS`
2. Verify the file exists and has a `.xlsx` extension. If not, tell the user clearly.
3. Read the Excel file by running:
   ```
   uv run python -c "
      import sys; sys.path.insert(0, 'skills/sort-shipment/scripts')
      from extractor import excel_to_text
      sheets = excel_to_text('$ARGUMENTS')
      for name, text in sheets:
         print(f'=== SHEET: {name} ===')
         print(text)
         print()
   "
   ```
4. Apply the extraction rules from `skills/sort-shipment/SKILL.md` to the raw text output.
5. Return the extracted shipment data as a clean CSV following the SKILL.md output schema.
6. Save the CSV to the `output/` directory.

## Notes
- Always run from the project root (`/Users/yu-shenglee/Desktop/dev/AmericanSole`)
- The extraction rules are defined in `skills/sort-shipment/SKILL.md`
- If the file has messy merged cells or unusual formatting, mention it to the user after extraction
