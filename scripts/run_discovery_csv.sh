#!/usr/bin/env bash
# run_discovery_csv.sh — Run Oracle CSV discovery on this server.
#
# Collects CPU model and architecture from the OS before calling SQL*Plus so
# they are available to oracle_discovery_csv.sql without needing Ansible.
#
# Usage:
#   ./scripts/run_discovery_csv.sh [connect_string]
#
# Examples:
#   ./scripts/run_discovery_csv.sh                       # OS auth: / as sysdba
#   ./scripts/run_discovery_csv.sh sys/secret@orcl       # explicit credentials
#   ./scripts/run_discovery_csv.sh "/@mydb as sysdba"
#
# CSV files are written in the current directory with the pattern:
#   <hostname>_<db>_<timestamp>_server.csv
#   <hostname>_<db>_<timestamp>_instances.csv   etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONNECT="${1:-/ as sysdba}"
DISCOVERY_SQL="${SCRIPT_DIR}/oracle_discovery_csv.sql"

# ---------------------------------------------------------------------------
# Collect CPU info from the OS
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

echo "CPU model   : ${CPU_MODEL}"
echo "CPU arch    : ${CPU_ARCH}"
echo "Connecting  : ${CONNECT}"
echo ""

# ---------------------------------------------------------------------------
# Run SQL*Plus, pre-defining the OS-gathered values
# ---------------------------------------------------------------------------
sqlplus -S "${CONNECT}" <<EOF
DEFINE sam_cpu_model = '${CPU_MODEL}'
DEFINE sam_cpu_arch  = '${CPU_ARCH}'
@${DISCOVERY_SQL}
EOF

echo ""
echo "CSV files written to current directory."
echo "Upload all *_server.csv, *_instances.csv etc. to SAM via:"
echo "  Servers > Upload Discovery > Oracle DB — CSV"
