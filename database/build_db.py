"""Build a SQLite database from ddl.sql.

Reads the PostgreSQL DDL, converts syntax to SQLite-compatible SQL,
and creates american_sole.db in the same directory.

Schema-qualified names (e.g. sales.purchase_order) are flattened to
underscored names (e.g. sales__purchase_order) since SQLite has no
schema support.
"""

import re
import sqlite3
from pathlib import Path

HERE = Path(__file__).resolve().parent
DDL_PATH = HERE / "ddl.sql"
DB_PATH = HERE / "american_sole.db"


def pg_to_sqlite(sql: str) -> str:
    """Convert PostgreSQL DDL to SQLite-compatible SQL."""
    # Strip comment lines
    lines = sql.splitlines()
    cleaned = "\n".join(line for line in lines if not line.strip().startswith("--"))

    # Remove CREATE SCHEMA statements (not supported in SQLite)
    cleaned = re.sub(r"CREATE\s+SCHEMA\s+IF\s+NOT\s+EXISTS\s+\w+\s*;", "", cleaned, flags=re.IGNORECASE)

    # Flatten schema.table -> schema__table (in CREATE TABLE, REFERENCES, ON clauses)
    # Matches word.word patterns that are schema-qualified identifiers
    cleaned = re.sub(r"\b(\w+)\.(\w+)\b", r"\1__\2", cleaned)

    # BIGINT GENERATED ALWAYS AS IDENTITY -> INTEGER
    cleaned = re.sub(
        r"BIGINT\s+GENERATED\s+ALWAYS\s+AS\s+IDENTITY",
        "INTEGER",
        cleaned,
        flags=re.IGNORECASE,
    )
    # SMALLINT GENERATED ALWAYS AS IDENTITY -> INTEGER
    cleaned = re.sub(
        r"SMALLINT\s+GENERATED\s+ALWAYS\s+AS\s+IDENTITY",
        "INTEGER",
        cleaned,
        flags=re.IGNORECASE,
    )

    # SMALLINT -> INTEGER
    cleaned = re.sub(r"\bSMALLINT\b", "INTEGER", cleaned, flags=re.IGNORECASE)

    # NUMERIC(p,s) -> REAL
    cleaned = re.sub(r"\bNUMERIC\s*\(\d+\s*,\s*\d+\)", "REAL", cleaned, flags=re.IGNORECASE)

    # TIMESTAMPTZ / TIMESTAMP -> TEXT
    cleaned = re.sub(r"\bTIMESTAMPTZ\b", "TEXT", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\bTIMESTAMP\b", "TEXT", cleaned, flags=re.IGNORECASE)

    # BOOLEAN -> INTEGER (SQLite uses 0/1)
    cleaned = re.sub(r"\bBOOLEAN\b", "INTEGER", cleaned, flags=re.IGNORECASE)

    # TRUE/FALSE -> 1/0
    cleaned = re.sub(r"\bTRUE\b", "1", cleaned)
    cleaned = re.sub(r"\bFALSE\b", "0", cleaned)

    return cleaned


def build() -> None:
    raw_ddl = DDL_PATH.read_text()
    sqlite_ddl = pg_to_sqlite(raw_ddl)

    # Remove existing DB so we start fresh
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.executescript(sqlite_ddl)
    conn.close()

    print(f"Database created at {DB_PATH}")

    # Quick sanity check: list tables
    conn = sqlite3.connect(DB_PATH)
    tables = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    ).fetchall()
    conn.close()

    print(f"Tables ({len(tables)}):")
    for (name,) in tables:
        print(f"  - {name}")


if __name__ == "__main__":
    build()
