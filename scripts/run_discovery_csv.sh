#!/usr/bin/env bash
# run_discovery_csv.sh — Run Oracle CSV discovery for every database on this server.
#
# Reads /etc/oratab and runs oracle_discovery_csv.sql against each active entry
# (lines where the third field is Y/y and the ORACLE_HOME exists).
# A single explicit connect string can be passed to run against one database only.
#
# Usage:
#   ./scripts/run_discovery_csv.sh                           # iterate /etc/oratab (default, OS auth)
#   ./scripts/run_discovery_csv.sh "/@CDB1 as sysdba"       # single CDB via TNS alias
#   ./scripts/run_discovery_csv.sh "/@PDB1"                  # single PDB direct (limited discovery)
#   ./scripts/run_discovery_csv.sh sam_discovery/pw@CDB1    # named account
#
# Connection context:
#   CDB$ROOT (oratab entries / "as sysdba"): full discovery — all PDBs captured.
#   PDB direct connection: server, instances, and feature/product usage for that
#   PDB only; pdb_feature_usage reflects the connected PDB. For full multi-PDB
#   coverage always connect to CDB$ROOT.
#
# CSV files are written in the current directory with the pattern:
#   <hostname>_<db>_<timestamp>_server.csv
#   <hostname>_<db>_<timestamp>_instances.csv   etc.
#
# Upload all generated CSVs to SAM via:
#   Servers > Upload Discovery > Oracle DB — CSV

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY_SQL="${SCRIPT_DIR}/oracle_discovery_csv.sql"
ORATAB="${ORATAB:-/etc/oratab}"

# ---------------------------------------------------------------------------
# Collect CPU info from the OS (done once; reused for every DB)
# ---------------------------------------------------------------------------
CPU_MODEL="unknown"
CPU_ARCH="x86_64"

if command -v lscpu &>/dev/null; then
    _model=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
    _arch=$(lscpu  2>/dev/null | awk -F': +' '/^Architecture/{print $2; exit}')
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
    [[ -n "$_arch"  ]] && CPU_ARCH="$_arch"
elif [[ -f /proc/cpuinfo ]]; then
    _model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
elif command -v sysctl &>/dev/null; then
    _model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
          || sysctl -n hw.model 2>/dev/null \
          || true)
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
    _arch=$(uname -m 2>/dev/null || true)
    [[ -n "$_arch" ]] && CPU_ARCH="$_arch"
fi

# Sanitize for SQL*Plus DEFINE: @ triggers "run script", & triggers substitution,
# ' breaks quoting. Strip/replace all three.
CPU_MODEL=$(echo "$CPU_MODEL" | sed "s/@/ /g; s/&/ /g; s/'//g; s/  */ /g" | sed 's/[[:space:]]*$//')
CPU_ARCH=$(echo  "$CPU_ARCH"  | sed "s/@/ /g; s/&/ /g; s/'//g")

echo "CPU model : ${CPU_MODEL}"
echo "CPU arch  : ${CPU_ARCH}"
echo ""

# ---------------------------------------------------------------------------
# run_sqlplus <connect_string>
#   Runs oracle_discovery_csv.sql via SQL*Plus for one database.
# ---------------------------------------------------------------------------
run_sqlplus() {
    local connect="$1"
    echo "Connecting: ${connect}"
    sqlplus -S "${connect}" <<EOF
DEFINE sam_cpu_model = '${CPU_MODEL}'
DEFINE sam_cpu_arch  = '${CPU_ARCH}'
@${DISCOVERY_SQL}
EOF
}

# ---------------------------------------------------------------------------
# Single explicit connect string — skip oratab iteration
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
    run_sqlplus "$1"
    echo ""
    echo "CSV files written to current directory."
    exit 0
fi

# ---------------------------------------------------------------------------
# Iterate /etc/oratab
# Each non-comment line: SID:ORACLE_HOME:auto-start-flag
# Run discovery for entries flagged Y/y (managed by dbstart/dbshut).
# ---------------------------------------------------------------------------
if [[ ! -f "$ORATAB" ]]; then
    echo "ERROR: $ORATAB not found and no connect string supplied." >&2
    echo "Usage: $0 [connect_string]" >&2
    exit 1
fi

discovered=0
failed=0

while IFS=: read -r sid oracle_home flag _rest; do
    # Skip blank lines, comments, and the ASM placeholder (+ASM)
    [[ -z "$sid" || "$sid" =~ ^[[:space:]]*# || "$sid" == \+* ]] && continue

    # Trim whitespace
    sid=$(echo "$sid" | tr -d '[:space:]')
    oracle_home=$(echo "$oracle_home" | tr -d '[:space:]')
    flag=$(echo "$flag" | tr -d '[:space:]')

    # Only proceed for Y/y entries (auto-start databases).
    # Change to: [[ "$flag" =~ ^[YyNn]$ ]] to also include non-auto-start DBs.
    [[ "$flag" =~ ^[Yy]$ ]] || continue

    # Verify the ORACLE_HOME exists
    if [[ ! -d "$oracle_home" ]]; then
        echo "WARN: ORACLE_HOME $oracle_home for $sid does not exist — skipping." >&2
        continue
    fi

    export ORACLE_SID="$sid"
    export ORACLE_HOME="$oracle_home"
    export PATH="${oracle_home}/bin:${PATH}"
    export LD_LIBRARY_PATH="${oracle_home}/lib:${LD_LIBRARY_PATH:-}"

    echo "=== Database: ${sid} (${oracle_home}) ==="
    if run_sqlplus "/ as sysdba"; then
        (( discovered++ )) || true
    else
        echo "ERROR: discovery failed for ${sid}" >&2
        (( failed++ )) || true
    fi
    echo ""

done < "$ORATAB"

if [[ $discovered -eq 0 && $failed -eq 0 ]]; then
    echo "No active (Y/y) database entries found in ${ORATAB}."
    echo "To run against all entries, edit the flag filter in this script."
fi

echo "Done — ${discovered} database(s) discovered, ${failed} failed."
echo ""
echo "Upload all *_server.csv, *_instances.csv etc. to SAM via:"
echo "  Servers > Upload Discovery > Oracle DB — CSV"
[[ $failed -eq 0 ]]
