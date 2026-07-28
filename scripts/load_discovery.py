#!/usr/bin/env python3
"""
load_discovery.py — Load oracle_discovery_*.json output into the SAM PostgreSQL database.

Usage:
    python3 load_discovery.py <discovery_file.json> [options]

Options:
    --client SCHEMA     Target client schema (default: $SAM_CLIENT_SCHEMA or client_acme)
    --host HOST         PostgreSQL host (default: $DB_HOST or localhost)
    --port PORT         PostgreSQL port (default: $DB_PORT or 5432)
    --dbname NAME       Database name (default: $DB_NAME or samdb)
    --user USER         Database user (default: $DB_USER or sam_admin)
    --password PASS     Database password (default: $DB_PASSWORD)
    --dry-run           Parse and validate JSON but do not write to DB
    --verbose           Print SQL being executed

The JSON file is produced by scripts/oracle_discovery.sql run via SQL*Plus.
"""

import argparse
import json
import os
import sys

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    sys.exit("psycopg2 is required: pip install psycopg2-binary")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Load SAM discovery JSON into PostgreSQL")
    p.add_argument("discovery_file", help="JSON file produced by oracle_discovery.sql")
    p.add_argument("--client",   default=os.environ.get("SAM_CLIENT_SCHEMA", "client_acme"))
    p.add_argument("--host",     default=os.environ.get("DB_HOST",     "localhost"))
    p.add_argument("--port",     type=int, default=int(os.environ.get("DB_PORT", 5432)))
    p.add_argument("--dbname",   default=os.environ.get("DB_NAME",     "samdb"))
    p.add_argument("--user",     default=os.environ.get("DB_USER",     "sam_admin"))
    p.add_argument("--password", default=os.environ.get("DB_PASSWORD", ""))
    p.add_argument("--dry-run",  action="store_true", help="Parse only; do not write to DB")
    p.add_argument("--verbose",  action="store_true", help="Print SQL calls")
    return p.parse_args()


# ---------------------------------------------------------------------------
# JSON loading / validation
# ---------------------------------------------------------------------------

def load_json(path: str) -> dict:
    """Read the discovery file, stripping any SQL*Plus banner lines before the JSON."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        content = fh.read()

    # SQL*Plus may prepend blank lines or a "Connected to …" banner — find the first '{'
    start = content.find("{")
    if start == -1:
        sys.exit(f"No JSON object found in {path}")
    # Similarly, find the last '}' in case there is trailing output
    end = content.rfind("}")
    if end == -1:
        sys.exit("JSON object is not terminated — file may be truncated")

    try:
        return json.loads(content[start : end + 1])
    except json.JSONDecodeError as exc:
        sys.exit(f"JSON parse error: {exc}")


def validate(doc: dict) -> None:
    required = {"_meta", "base", "extended", "options"}  # db_parameters is optional
    missing = required - doc.keys()
    if missing:
        sys.exit(f"Discovery file is missing top-level keys: {missing}")
    if "error" in doc:
        sys.exit(f"Discovery script reported an error: {doc['error']}")
    base = doc["base"]
    if not base.get("hostname"):
        sys.exit("'hostname' is missing from the base payload")
    if not base.get("instances"):
        print("WARNING: No Oracle instances found in discovery output.", file=sys.stderr)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def connect(args):
    return psycopg2.connect(
        host=args.host, port=args.port, dbname=args.dbname,
        user=args.user, password=args.password,
    )


def call_upsert(cur, schema: str, func: str, payload: dict, verbose: bool) -> None:
    sql = f"SELECT {schema}.{func}(%s::jsonb)"
    if verbose:
        print(f"  → {schema}.{func}({json.dumps(payload)[:120]}…)")
    cur.execute(sql, (json.dumps(payload),))


# ---------------------------------------------------------------------------
# Options upsert (oracle_options table)
# ---------------------------------------------------------------------------

OPTION_UPSERT_SQL = """
INSERT INTO {schema}.oracle_options
    (server_id, option_name, is_active, discovery_run_id)
VALUES
    (%s, %s, %s, %s)
ON CONFLICT (server_id, option_name) DO UPDATE SET
    is_active        = EXCLUDED.is_active,
    discovery_run_id = EXCLUDED.discovery_run_id,
    updated_at       = NOW()
"""

def load_options(cur, schema: str, server_id: int, run_id: str,
                 options: list, verbose: bool) -> None:
    for opt in options:
        if verbose:
            print(f"    option: {opt['option_name']} = {opt['is_active']}")
        cur.execute(
            OPTION_UPSERT_SQL.format(schema=schema),
            (server_id, opt["option_name"], opt["is_active"], run_id),
        )


DB_PARAM_UPSERT_SQL = """
INSERT INTO {schema}.oracle_options
    (server_id, option_name, is_active, discovery_run_id)
VALUES
    (%s, %s, %s, %s)
ON CONFLICT (server_id, option_name) DO UPDATE SET
    is_active        = EXCLUDED.is_active,
    discovery_run_id = EXCLUDED.discovery_run_id,
    updated_at       = NOW()
"""

_FALSY = {"none", "false", "0", "", "no"}

def load_db_parameters(cur, schema: str, server_id: int, run_id: str,
                       params: list, verbose: bool) -> None:
    """Store raw GV$PARAMETER values in oracle_options.

    CDB-root entries (con_id 0 or 1) → 'param:<name>'
    PDB overrides (con_id > 1)        → 'param:pdb<con_id>:<name>'
    """
    for p in params:
        con_id  = p.get("con_id", 0)
        name    = p.get("name", "")
        value   = p.get("value", "")
        is_active = value.lower() not in _FALSY
        opt_name  = f"param:{name}" if con_id <= 1 else f"param:pdb{con_id}:{name}"
        if verbose:
            print(f"    db_parameter [con_id={con_id}]: {name} = {value!r} → is_active={is_active}")
        cur.execute(
            DB_PARAM_UPSERT_SQL.format(schema=schema),
            (server_id, opt_name, is_active, run_id),
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    print(f"Loading: {args.discovery_file}")
    print(f"Target : {args.dbname} → schema {args.client}")

    doc = load_json(args.discovery_file)
    validate(doc)

    base        = doc["base"]
    extended    = doc["extended"]
    options     = doc.get("options", [])
    db_params   = doc.get("db_parameters", [])
    hostname    = base["hostname"]
    run_id      = base["run_id"]

    print(f"Host   : {hostname}  (run_id={run_id})")
    print(f"Instances: {[i['sid'] for i in base.get('instances', [])]}")

    if args.dry_run:
        print("Dry run — no changes written.")
        return

    conn = connect(args)
    try:
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:

                # 1. Base Oracle discovery (server + processor + instances)
                print("\n[1/3] Calling upsert_oracle_discovery …")
                call_upsert(cur, args.client, "upsert_oracle_discovery", base, args.verbose)

                # 2. Extended discovery (RAC nodes, PDBs, NUP users)
                print("[2/3] Calling upsert_oracle_extended_discovery …")
                call_upsert(cur, args.client, "upsert_oracle_extended_discovery",
                            extended, args.verbose)

                # 3. Oracle options + db_parameters
                if options or db_params:
                    print(f"[3/3] Loading {len(options)} option flags + {len(db_params)} db_parameters …")
                    cur.execute(
                        f"SELECT server_id FROM {args.client}.oracle_servers "
                        f"WHERE hostname = %s",
                        (hostname,),
                    )
                    row = cur.fetchone()
                    if row:
                        sid = row["server_id"]
                        if options:
                            load_options(cur, args.client, sid, run_id, options, args.verbose)
                        if db_params:
                            load_db_parameters(cur, args.client, sid, run_id, db_params, args.verbose)
                    else:
                        print("  WARNING: server not found after base upsert — skipping options")
                else:
                    print("[3/3] No options or db_parameters to load.")

        print("\nDone — all data committed.")

    except psycopg2.Error as exc:
        conn.rollback()
        sys.exit(f"Database error: {exc}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
