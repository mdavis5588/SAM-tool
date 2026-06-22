#!/usr/bin/env bash
# run_and_load.sh — Run SQL*Plus discovery on this server and load results into SAM DB.
#
# Usage:
#   ./scripts/run_and_load.sh [sql_plus_connect_string]
#
# Examples:
#   ./scripts/run_and_load.sh                         # uses OS auth (/ as sysdba)
#   ./scripts/run_and_load.sh sys/secret@orcl         # explicit credentials
#
# Required environment variables (can also be passed as CLI flags to load_discovery.py):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, SAM_CLIENT_SCHEMA

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONNECT="${1:-/ as sysdba}"
DISCOVERY_SQL="${SCRIPT_DIR}/oracle_discovery.sql"
LOADER="${SCRIPT_DIR}/load_discovery.py"

# Run discovery
echo "Running Oracle discovery as: ${CONNECT}"
sqlplus -S "${CONNECT}" "@${DISCOVERY_SQL}"

# Find the most recently written discovery JSON in current dir
LATEST_JSON=$(ls -t oracle_discovery_*.json 2>/dev/null | head -1)
if [[ -z "$LATEST_JSON" ]]; then
  echo "ERROR: No oracle_discovery_*.json file found after SQL*Plus run." >&2
  exit 1
fi

echo "Loading: ${LATEST_JSON}"
python3 "${LOADER}" "${LATEST_JSON}"
