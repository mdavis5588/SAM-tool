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
    end = content.rfind("}")
    if end == -1:
        sys.exit("JSON object is not terminated — file may be truncated")

    try:
        return json.loads(content[start : end + 1])
    except json.JSONDecodeError as exc:
        sys.exit(f"JSON parse error: {exc}")


def validate(doc: dict) -> None:
    required = {"_meta", "base", "extended", "feature_usage"}
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

    version = doc.get("_meta", {}).get("script_version", "0")
    if version < "2.1":
        print(
            f"WARNING: discovery file was produced by script version {version}; "
            "expected 2.1+. Re-run oracle_discovery.sql on the target server.",
            file=sys.stderr,
        )


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
# Feature usage upsert (oracle_feature_usage table via upsert function)
# ---------------------------------------------------------------------------

def load_feature_usage(cur, schema: str, hostname: str,
                       features: list, run_id: str, verbose: bool) -> None:
    """
    Upserts DBA_FEATURE_USAGE_STATISTICS rows via the per-client function
    upsert_oracle_feature_usage, which is installed by install_extended_views().
    Each row is keyed on (instance_id, feature_name); oldest first_usage_date
    and latest last_usage_date are preserved on conflict.
    """
    if not features:
        return
    payload = {"hostname": hostname, "run_id": run_id, "features": features}
    call_upsert(cur, schema, "upsert_oracle_feature_usage", payload, verbose)


# ---------------------------------------------------------------------------
# DB parameters upsert (oracle_options table, param: prefix)
# ---------------------------------------------------------------------------

DB_PARAM_UPSERT_SQL = """
INSERT INTO {schema}.oracle_options
    (server_id, option_name, is_active, discovery_run_id)
SELECT s.server_id,
       CASE WHEN %(con_id)s <= 1
            THEN 'param:' || %(name)s
            ELSE 'param:pdb' || %(con_id)s || ':' || %(name)s
       END,
       LOWER(%(value)s) NOT IN ('none','false','0','','no'),
       %(run_id)s
FROM   {schema}.oracle_servers s
WHERE  s.hostname = %(hostname)s
ON CONFLICT (server_id, option_name) DO UPDATE SET
    is_active        = EXCLUDED.is_active,
    discovery_run_id = EXCLUDED.discovery_run_id,
    updated_at       = NOW()
"""

def load_db_parameters(cur, schema: str, hostname: str, run_id: str,
                       params: list, verbose: bool) -> None:
    """
    Store raw GV$PARAMETER values in oracle_options.
    CDB-root entries (con_id 0 or 1) → 'param:<name>'
    PDB overrides (con_id > 1)        → 'param:pdb<con_id>:<name>'
    """
    for p in params:
        con_id = p.get("con_id", 0)
        name   = p.get("name", "")
        value  = p.get("value", "")
        if verbose:
            label = f"con_id={con_id}"
            print(f"    db_parameter [{label}]: {name} = {value!r}")
        cur.execute(
            DB_PARAM_UPSERT_SQL.format(schema=schema),
            {"con_id": con_id, "name": name, "value": value,
             "run_id": run_id, "hostname": hostname},
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

    base          = doc["base"]
    extended      = doc["extended"]
    feature_usage = doc.get("feature_usage", [])
    db_params     = doc.get("db_parameters", [])
    hostname      = base["hostname"]
    run_id        = base["run_id"]

    meta = doc.get("_meta", {})
    print(f"Host   : {hostname}  (run_id={run_id})")
    print(f"DB     : {meta.get('db_unique_name', 'unknown')}")
    print(f"Script : v{meta.get('script_version', '?')}  generated {meta.get('generated', '?')}")
    print(f"Instances: {[i['sid'] for i in base.get('instances', [])]}")

    if args.dry_run:
        print("Dry run — no changes written.")
        return

    conn = connect(args)
    try:
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:

                # 1. Base Oracle discovery (server + processor + instances)
                print("\n[1/4] Calling upsert_oracle_discovery …")
                call_upsert(cur, args.client, "upsert_oracle_discovery", base, args.verbose)

                # 2. Extended discovery (RAC nodes, PDBs, NUP users)
                print("[2/4] Calling upsert_oracle_extended_discovery …")
                call_upsert(cur, args.client, "upsert_oracle_extended_discovery",
                            extended, args.verbose)

                # 3. Feature usage (DBA_FEATURE_USAGE_STATISTICS)
                print(f"[3/4] Loading {len(feature_usage)} feature usage rows …")
                if feature_usage:
                    load_feature_usage(cur, args.client, hostname,
                                       feature_usage, run_id, args.verbose)
                else:
                    print("  No feature_usage rows — skipping.")

                # 4. DB parameters (GV$PARAMETER — management pack access etc.)
                print(f"[4/4] Loading {len(db_params)} db_parameters …")
                if db_params:
                    load_db_parameters(cur, args.client, hostname,
                                       run_id, db_params, args.verbose)
                else:
                    print("  No db_parameters — skipping.")

        print("\nDone — all data committed.")

    except psycopg2.Error as exc:
        conn.rollback()
        sys.exit(f"Database error: {exc}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
