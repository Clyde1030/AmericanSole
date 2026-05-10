# Database

PostgreSQL schema for the American Sole ERP. The schema is the source of truth; `build_db.py` produces a SQLite copy for local development.

## Files

- `ddl.sql` — PostgreSQL `CREATE SCHEMA` / `CREATE TABLE` definitions across the eight functional schemas (core, sales, product, inventory, operations, hr, finance, logistics).
- `insert.sql` — sample/seed data.
- `build_db.py` — converts `ddl.sql` to SQLite-compatible SQL and writes `american_sole.db` (gitignored).

## Build the local SQLite copy

```bash
uv run python database/build_db.py
```

The script flattens schema-qualified names (`sales.purchase_order` → `sales__purchase_order`) and rewrites Postgres-only types (`TIMESTAMPTZ`, `BOOLEAN`, `NUMERIC(p,s)`, `BIGINT GENERATED ALWAYS AS IDENTITY`) to SQLite equivalents.

## ERD

See [docs/architecture/erd.png](../docs/architecture/erd.png).
