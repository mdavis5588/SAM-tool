#!/usr/bin/env bash
# run_discovery.sh — Run Oracle discovery on this server and (optionally) load into SAM.
#
# Collects CPU model and architecture from the OS before calling SQL*Plus so
# they are available to oracle_discovery.sql without needing Ansible.
#
# Usage:
#   ./scripts/run_discovery.sh [connect_string]
#
# Examples:
#   ./scripts/run_discovery.sh                              # sam_discovery user, prompted for password
#   ./scripts/run_discovery.sh sam_discovery/secret@orcl   # sam_discovery with password in-line
#   ./scripts/run_discovery.sh "/ as sysdba"               # OS auth (fallback / legacy)
#
# Prerequisites:
#   Run scripts/create_sam_discovery_user.sql as SYSDBA once per target database
#   to create the least-privileged sam_discovery account before using this script.
#
# The script writes oracle_discovery_<host>_<db>_<ts>.json in the current
# directory.  Set SAM_LOAD=1 to also load it into the SAM database via
# load_discovery.py (requires DB_HOST, DB_PORT, DB_NAME, DB_USER,
# DB_PASSWORD, SAM_CLIENT_SCHEMA environment variables).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default to sam_discovery — prompt for password if not supplied in connect string
if [[ $# -eq 0 ]]; then
    read -r -s -p "Password for sam_discovery: " _pw
    echo ""
    CONNECT="sam_discovery/${_pw}"
    unset _pw
else
    CONNECT="${1}"
fi
DISCOVERY_SQL="${SCRIPT_DIR}/oracle_discovery.sql"
LOADER="${SCRIPT_DIR}/load_discovery.py"

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
    # macOS / FreeBSD / Solaris
    _model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
          || sysctl -n hw.model 2>/dev/null \
          || true)
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
    _arch=$(uname -m 2>/dev/null || true)
    [[ -n "$_arch" ]] && CPU_ARCH="$_arch"
fi

# Sanitize for SQL*Plus DEFINE: strip characters that SQL*Plus misinterprets.
# @ is treated as "run script", & triggers substitution, ' breaks quoting.
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

# ---------------------------------------------------------------------------
# Optionally load the resulting JSON into SAM
# ---------------------------------------------------------------------------
if [[ "${SAM_LOAD:-0}" == "1" ]]; then
    LATEST_JSON=$(ls -t oracle_discovery_*.json 2>/dev/null | head -1 || true)
    if [[ -z "$LATEST_JSON" ]]; then
        echo "ERROR: No oracle_discovery_*.json found — load skipped." >&2
        exit 1
    fi
    echo "Loading: ${LATEST_JSON}"
    python3 "${LOADER}" "${LATEST_JSON}"
fi
