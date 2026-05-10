# Pipeline invocations

Common commands. Run from project root.

## sort-shipment skill (full pipeline)

End-to-end: preprocess vendor Excel → run LLM extraction → write gantt.

```bash
bash skills/sort-shipment/scripts/run.sh
```

Defaults to `data/raw/reports/AS_report_input.xlsx`. Pass a different file as the first argument.

## Preprocess only

```bash
uv run python -m skills.sort-shipment.scripts.preprocessor "data/raw/reports/AS_report_input.xlsx"
```

Output lands in `data/bronze/preprocessed_<YYYY-MM-DD>.xlsx`.

## Parse a packing list PDF

```bash
uv run python src/american_sole/packing_list/parser.py "data/raw/packing_lists/Weinbrenner#671558 Packing List.pdf"
```

Output: `output/packing_list.csv` (override with a second argument).

## Build the local SQLite DB

```bash
uv run python database/build_db.py
```

Reads `database/ddl.sql` and writes `database/american_sole.db`.
