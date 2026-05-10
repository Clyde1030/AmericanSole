# American Sole — Internal Data Platform

Internal data and AI workflows for American Sole, a made-in-USA worker boot factory in San Antonio, TX. Replaces manual Excel-driven processes with reproducible pipelines while keeping Excel as the office-facing surface.

See [docs/context.md](docs/context.md) for business context and [docs/architecture/aws.md](docs/architecture/aws.md) for the target cloud architecture.

## Folder map

```
docs/                  Documentation, ERDs, architecture diagrams
src/american_sole/     Application Python package
  integrations/        External API clients (e.g., All-Ways shipment tracking)
  packing_list/        Packing-list PDF parser
database/              PostgreSQL schema + local SQLite bootstrap
skills/                Claude Code Skills (sort-shipment, organize-container)
templates/excel/       Office-facing Excel and VBA templates
data/                  Local data lake (gitignored)
  raw/                   Source-of-truth inputs from upstream
    reports/             Vendor shipment reports (xlsx)
    packing_lists/       Customer packing list PDFs
  bronze/                Preprocessed (cleaned, unmerged)
  silver/                Curated (gantt-ready)
  local/                 Scratch (sqlite, etc.)
output/                Final deliverables (csvs, reports) — gitignored
scripts/               Shell entrypoints and run docs
.archive/              Historical / abandoned material
```

## Quickstart

```bash
uv sync                                          # install deps
bash skills/sort-shipment/scripts/run.sh         # weekly shipment pipeline
uv run python database/build_db.py               # build local sqlite copy
```

See [scripts/invoke.md](scripts/invoke.md) for the full command reference.

## Stack

- Python 3.12 + uv
- PostgreSQL (target) / SQLite (local dev)
- Claude Code Skills for LLM-assisted extraction
- AWS (ECS Fargate, RDS, S3, Airflow) — see architecture doc
