#!/usr/bin/env bash
# =============================================================================
# run_wls_discovery.sh
# Manual WebLogic discovery script — produces a JSON file that can be
# uploaded to the SAM tool via Servers > Upload Discovery > WebLogic JSON.
#
# Usage:
#   ./run_wls_discovery.sh [output_file]
#
# Output defaults to ./wls_discovery_<hostname>_<timestamp>.json
#
# Requirements:
#   - Run as a user that can read the Oracle inventory and domain config.xml
#   - wlst.sh must be on PATH or discoverable under the Oracle MW home.
#   - lscpu must be available (standard on all Linux distros).
#
# No running WebLogic server is required — WLST runs in offline mode.
# =============================================================================

set -euo pipefail

HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname)
FQDN_VAL=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
RUN_ID="${TIMESTAMP}-${HOSTNAME_VAL}"
OUTPUT_FILE="${1:-wls_discovery_${HOSTNAME_VAL}_${TIMESTAMP}.json}"

# ---------------------------------------------------------------------------
# CPU topology  (same logic as run_discovery.sh)
# ---------------------------------------------------------------------------
CPU_SOCKETS=1
CPU_CORES_PER_SOCKET=1
CPU_THREADS_PER_CORE=1
CPU_MODEL="unknown"
CPU_ARCH="x86_64"
TOTAL_RAM_MB=0

if command -v lscpu >/dev/null 2>&1; then
    _model=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
    _arch=$(lscpu  2>/dev/null | awk -F': +' '/^Architecture/{print $2; exit}')
    _sockets=$(lscpu 2>/dev/null | awk -F': +' '/^Socket\(s\)/{print $2; exit}')
    _cores=$(lscpu   2>/dev/null | awk -F': +' '/^Core\(s\) per socket/{print $2; exit}')
    _threads=$(lscpu 2>/dev/null | awk -F': +' '/^Thread\(s\) per core/{print $2; exit}')
    [[ -n "$_model"   ]] && CPU_MODEL="$_model"
    [[ -n "$_arch"    ]] && CPU_ARCH="$_arch"
    [[ -n "$_sockets" ]] && CPU_SOCKETS="$_sockets"
    [[ -n "$_cores"   ]] && CPU_CORES_PER_SOCKET="$_cores"
    [[ -n "$_threads" ]] && CPU_THREADS_PER_CORE="$_threads"
elif [[ -f /proc/cpuinfo ]]; then
    _model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
elif command -v sysctl >/dev/null 2>&1; then
    _model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
          || sysctl -n hw.model 2>/dev/null \
          || true)
    _arch=$(uname -m 2>/dev/null || true)
    [[ -n "$_model" ]] && CPU_MODEL="$_model"
    [[ -n "$_arch"  ]] && CPU_ARCH="$_arch"
fi

# Sanitize for JSON: strip characters that break string values
CPU_MODEL=$(echo "$CPU_MODEL" | sed "s/\"/'/g; s/\\\\/\\\\\\\\/g; s/  */ /g" | sed 's/[[:space:]]*$//')
CPU_ARCH=$(echo  "$CPU_ARCH"  | sed "s/\"/'/g")

if [ -r /proc/meminfo ]; then
    TOTAL_RAM_MB=$(awk '/^MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
fi

# Virtualisation
VIRT_TYPE="physical"
IS_VMWARE="false"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "physical")
    [ "$VIRT_TYPE" = "none" ] && VIRT_TYPE="physical"
fi
if command -v vmware-toolsd >/dev/null 2>&1 || [ "${VIRT_TYPE}" = "vmware" ]; then
    IS_VMWARE="true"
fi

# OS info
OS_FAMILY="Linux"
OS_DISTRIBUTION="Unknown"
OS_VERSION="Unknown"
if [ -r /etc/os-release ]; then
    OS_DISTRIBUTION=$(. /etc/os-release 2>/dev/null; echo "${NAME:-Unknown}")
    OS_VERSION=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-Unknown}")
fi

# IP address
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo "=== WebLogic SAM Discovery ==="
echo "Host:      $FQDN_VAL"
echo "CPU:       $CPU_MODEL"
echo "Sockets:   $CPU_SOCKETS  Cores/socket: $CPU_CORES_PER_SOCKET  Threads/core: $CPU_THREADS_PER_CORE"
echo "Virt:      $VIRT_TYPE  VMware: $IS_VMWARE"
echo ""

# ---------------------------------------------------------------------------
# Locate Oracle inventory to find middleware homes
# ---------------------------------------------------------------------------
INVENTORY_LOC=""
for f in /etc/oraInst.loc /var/opt/oracle/oraInst.loc; do
    if [ -r "$f" ]; then
        INVENTORY_LOC=$(grep "inventory_loc=" "$f" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        break
    fi
done
: "${INVENTORY_LOC:=/home/oracle/oraInventory}"

MW_HOMES=""
INVENTORY_XML="${INVENTORY_LOC}/ContentsXML/inventory.xml"
if [ -r "$INVENTORY_XML" ]; then
    MW_HOMES=$(grep -oE 'LOC="[^"]*"' "$INVENTORY_XML" 2>/dev/null \
               | grep -iE 'middleware|weblogic|fmw' \
               | sed 's/LOC="//;s/"//')
fi

# Also check common paths if inventory not found
if [ -z "$MW_HOMES" ]; then
    for d in /u01/app/oracle/middleware /oracle/middleware /opt/oracle/middleware /home/oracle/Oracle/Middleware; do
        [ -d "$d" ] && MW_HOMES="$MW_HOMES $d"
    done
fi

echo "Oracle Middleware homes found:"
echo "${MW_HOMES:-  (none detected)}"
echo ""

# ---------------------------------------------------------------------------
# Write WLST offline discovery script to a temp file
# ---------------------------------------------------------------------------
WLST_SCRIPT=$(mktemp /tmp/sam_wls_discovery_XXXXXX.py)
trap 'rm -f "$WLST_SCRIPT"' EXIT

cat > "$WLST_SCRIPT" << 'WLST_EOF'
import sys, os, json

domain_home = sys.argv[1] if len(sys.argv) > 1 else '.'

try:
    readDomain(domain_home)
except Exception as e:
    print(json.dumps({'error': str(e), 'domain_home': domain_home}))
    exit(0)

result = {
    'domain_name':        cmo.getName(),
    'domain_home':        domain_home,
    'wls_version':        None,
    'wls_edition':        None,
    'admin_server_host':  None,
    'admin_server_port':  None,
    'managed_servers':    [],
    'clusters':           [],
    'installed_products': []
}

try:
    cd('/Servers/AdminServer')
    result['admin_server_host'] = cmo.getListenAddress() or ''
    result['admin_server_port'] = cmo.getListenPort()
except: pass

try:
    servers = ls('/Servers', returnType='a')
    for srv in servers:
        try:
            cd('/Servers/' + srv)
            ms = {
                'name':        srv,
                'listen_port': cmo.getListenPort(),
                'ssl_port':    None,
                'machine':     cmo.getMachine().getName() if cmo.getMachine() else None,
                'cluster':     cmo.getCluster().getName() if cmo.getCluster() else None,
                'state':       'UNKNOWN'
            }
            try:
                cd('/Servers/' + srv + '/SSL/' + srv)
                ms['ssl_port'] = cmo.getListenPort()
            except: pass
            result['managed_servers'].append(ms)
        except: pass
except: pass

try:
    clusters = ls('/Clusters', returnType='a')
    for cl in clusters:
        result['clusters'].append({'name': cl})
except: pass

try:
    registry_path = os.path.join(domain_home, '..', '..', 'registry.xml')
    if os.path.exists(registry_path):
        import xml.etree.ElementTree as ET
        tree = ET.parse(registry_path)
        for comp in tree.findall('.//component'):
            name = comp.get('name', '')
            ver  = comp.get('version', '')
            if 'WebLogic' in name:
                result['wls_version'] = ver
                result['wls_edition'] = name
            elif name:
                result['installed_products'].append({'name': name, 'version': ver, 'home': ''})
except: pass

closeDomain()
print(json.dumps(result))
WLST_EOF

# ---------------------------------------------------------------------------
# Discover domains under each middleware home
# ---------------------------------------------------------------------------
DOMAINS_JSON="[]"

for MW_HOME in $MW_HOMES; do
    [ -d "$MW_HOME" ] || continue

    # Find wlst.sh
    WLST_BIN=$(find "$MW_HOME" -name 'wlst.sh' 2>/dev/null | head -1)
    if [ -z "$WLST_BIN" ]; then
        echo "  wlst.sh not found under $MW_HOME, skipping"
        continue
    fi

    DOMAINS_DIR="${MW_HOME}/user_projects/domains"
    [ -d "$DOMAINS_DIR" ] || continue

    for DOMAIN_HOME in "$DOMAINS_DIR"/*/; do
        [ -d "$DOMAIN_HOME" ] || continue
        DOMAIN_NAME=$(basename "$DOMAIN_HOME")
        echo "  Scanning domain: $DOMAIN_NAME ($DOMAIN_HOME)"

        DOMAIN_JSON=$("$WLST_BIN" "$WLST_SCRIPT" "$DOMAIN_HOME" 2>/dev/null || echo '{"error":"wlst failed","domain_home":"'"$DOMAIN_HOME"'"}')

        # Skip error entries
        if echo "$DOMAIN_JSON" | grep -q '"error"'; then
            echo "    Warning: WLST returned error for $DOMAIN_NAME"
            continue
        fi

        DOMAINS_JSON=$(echo "$DOMAINS_JSON" | python3 -c "
import sys, json
domains = json.load(sys.stdin)
new = json.loads(sys.stdin.read() if False else '''$DOMAIN_JSON''')
domains.append(new)
print(json.dumps(domains))
" 2>/dev/null || echo "$DOMAINS_JSON")
    done
done

# ---------------------------------------------------------------------------
# Assemble final JSON payload
# ---------------------------------------------------------------------------
python3 - << PYEOF
import json, datetime

payload = {
    "run_id":             "$RUN_ID",
    "hostname":           "$HOSTNAME_VAL",
    "fqdn":               "$FQDN_VAL",
    "ip_address":         "$IP_ADDRESS",
    "os_family":          "$OS_FAMILY",
    "os_distribution":    "$OS_DISTRIBUTION",
    "os_version":         "$OS_VERSION",
    "environment":        "unknown",
    "criticality":        "unknown",
    "datacenter":         "",
    "cpu_sockets":        int("$CPU_SOCKETS"),
    "cpu_cores_per_socket": int("$CPU_CORES_PER_SOCKET"),
    "cpu_threads_per_core": int("$CPU_THREADS_PER_CORE"),
    "total_physical_cores": int("$CPU_SOCKETS") * int("$CPU_CORES_PER_SOCKET"),
    "cpu_model":          "$CPU_MODEL",
    "cpu_architecture":   "$CPU_ARCH",
    "virt_type":          "$VIRT_TYPE",
    "is_vmware":          ${IS_VMWARE},
    "total_ram_mb":       int("$TOTAL_RAM_MB") if "$TOTAL_RAM_MB" else 0,
    "discovered_at":      datetime.datetime.utcnow().isoformat() + "Z",
    "domains":            $DOMAINS_JSON
}

with open("$OUTPUT_FILE", "w") as f:
    json.dump(payload, f, indent=2)

print("Domains discovered:", len(payload["domains"]))
total_ms = sum(len(d.get("managed_servers", [])) for d in payload["domains"])
print("Managed servers:  ", total_ms)
print("")
print("Output written to: $OUTPUT_FILE")
PYEOF
