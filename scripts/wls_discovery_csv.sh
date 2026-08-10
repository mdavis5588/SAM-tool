#!/usr/bin/env bash
# =============================================================================
# wls_discovery_csv.sh
# Manual WebLogic discovery — produces CSV files that can be uploaded to
# the SAM tool via Servers > Upload Discovery > WebLogic CSV.
#
# Usage:
#   ./wls_discovery_csv.sh [output_dir]
#
# Output directory defaults to ./wls_discovery_<hostname>_<timestamp>/
#
# Files produced:
#   <hostname>_wls_server.csv           - server/CPU info
#   <hostname>_wls_domains.csv          - WLS domain metadata
#   <hostname>_wls_managed_servers.csv  - managed servers per domain
#   <hostname>_wls_products.csv         - installed middleware products
#
# Requirements:
#   - Run as a user that can read the Oracle inventory and domain config.xml
#   - Python 3 with xml.etree.ElementTree (standard library — always present)
#   - lscpu available (standard on all Linux distros)
#   - No running WebLogic server required — parses config.xml directly
# =============================================================================

set -euo pipefail

HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname)
FQDN_VAL=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
RUN_ID="${TIMESTAMP}-${HOSTNAME_VAL}"
OUTPUT_DIR="${1:-wls_discovery_${HOSTNAME_VAL}_${TIMESTAMP}}"
mkdir -p "$OUTPUT_DIR"

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

# Sanitize for CSV: strip characters that break quoted fields
CPU_MODEL=$(echo "$CPU_MODEL" | sed 's/"/""/g; s/  */ /g' | sed 's/[[:space:]]*$//')
CPU_ARCH=$(echo  "$CPU_ARCH"  | sed 's/"/""/g')

if [ -r /proc/meminfo ]; then
    TOTAL_RAM_MB=$(awk '/^MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
fi

VIRT_TYPE="physical"
IS_VMWARE="false"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "physical")
    [ "$VIRT_TYPE" = "none" ] && VIRT_TYPE="physical"
fi
if command -v vmware-toolsd >/dev/null 2>&1 || [ "${VIRT_TYPE}" = "vmware" ]; then
    IS_VMWARE="true"
fi

OS_FAMILY="Linux"
OS_DISTRIBUTION="Unknown"
OS_VERSION="Unknown"
if [ -r /etc/os-release ]; then
    OS_DISTRIBUTION=$(. /etc/os-release 2>/dev/null; echo "${NAME:-Unknown}")
    OS_VERSION=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-Unknown}")
fi

IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
TOTAL_PHYSICAL_CORES=$(( CPU_SOCKETS * CPU_CORES_PER_SOCKET ))
VCPU_COUNT=$(( TOTAL_PHYSICAL_CORES * CPU_THREADS_PER_CORE ))

echo "=== WebLogic SAM Discovery (CSV mode) ==="
echo "Host:      $FQDN_VAL"
echo "CPU:       $CPU_MODEL"
echo "Sockets:   $CPU_SOCKETS  Cores/socket: $CPU_CORES_PER_SOCKET  Threads/core: $CPU_THREADS_PER_CORE"
echo ""

# ---------------------------------------------------------------------------
# Write server CSV
# ---------------------------------------------------------------------------
SERVER_CSV="${OUTPUT_DIR}/${HOSTNAME_VAL}_wls_server.csv"
cat > "$SERVER_CSV" << SERVEREOF
hostname,fqdn,ip_address,os_family,os_distribution,os_version,cpu_sockets,cores_per_socket,threads_per_core,total_physical_cores,vcpu_count,cpu_model,cpu_architecture,virt_type,is_vmware,total_ram_mb,run_id,discovered_at
${HOSTNAME_VAL},${FQDN_VAL},${IP_ADDRESS},${OS_FAMILY},${OS_DISTRIBUTION},${OS_VERSION},${CPU_SOCKETS},${CPU_CORES_PER_SOCKET},${CPU_THREADS_PER_CORE},${TOTAL_PHYSICAL_CORES},${VCPU_COUNT},"${CPU_MODEL}",${CPU_ARCH},${VIRT_TYPE},${IS_VMWARE},${TOTAL_RAM_MB},${RUN_ID},$(date -u +%Y-%m-%dT%H:%M:%SZ)
SERVEREOF
echo "Written: $SERVER_CSV"

# ---------------------------------------------------------------------------
# Locate Oracle inventory
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

if [ -z "$MW_HOMES" ]; then
    for d in /u01/app/oracle/middleware /oracle/middleware /opt/oracle/middleware /home/oracle/Oracle/Middleware; do
        [ -d "$d" ] && MW_HOMES="$MW_HOMES $d"
    done
fi

# ---------------------------------------------------------------------------
# Parse each domain using Python (reads config.xml and registry.xml directly)
# ---------------------------------------------------------------------------
DOMAINS_CSV="${OUTPUT_DIR}/${HOSTNAME_VAL}_wls_domains.csv"
MS_CSV="${OUTPUT_DIR}/${HOSTNAME_VAL}_wls_managed_servers.csv"
PRODUCTS_CSV="${OUTPUT_DIR}/${HOSTNAME_VAL}_wls_products.csv"

echo "hostname,domain_name,domain_home,wls_version,wls_edition,admin_server_host,admin_server_port,cluster_count,managed_server_count,run_id" > "$DOMAINS_CSV"
echo "hostname,domain_name,managed_server_name,listen_port,ssl_port,cluster_name,machine_name,run_id" > "$MS_CSV"
echo "hostname,domain_name,product_name,product_version,home_path,run_id" > "$PRODUCTS_CSV"

python3 - << PYEOF
import os, sys, csv
import xml.etree.ElementTree as ET

hostname   = "$HOSTNAME_VAL"
run_id     = "$RUN_ID"
mw_homes   = "$MW_HOMES".split()
output_dir = "$OUTPUT_DIR"

def csv_val(v):
    if v is None:
        return ""
    v = str(v)
    if any(c in v for c in [',', '"', '\n']):
        v = '"' + v.replace('"', '""') + '"'
    return v

domains_f  = open("$DOMAINS_CSV", "a", newline='')
ms_f       = open("$MS_CSV",      "a", newline='')
products_f = open("$PRODUCTS_CSV","a", newline='')

def write_row(f, vals):
    f.write(",".join(csv_val(v) for v in vals) + "\n")

total_domains = 0

for mw_home in mw_homes:
    if not os.path.isdir(mw_home):
        continue

    # Read products from registry.xml
    wls_version = None
    wls_edition = None
    products = []
    registry = os.path.join(mw_home, "registry.xml")
    if os.path.isfile(registry):
        try:
            tree = ET.parse(registry)
            for comp in tree.findall('.//component'):
                name = comp.get('name', '')
                ver  = comp.get('version', '')
                if 'WebLogic' in name:
                    wls_version = ver
                    wls_edition = name
                elif name:
                    products.append((name, ver, mw_home))
        except Exception as e:
            print(f"  Warning: could not parse {registry}: {e}", file=sys.stderr)

    domains_dir = os.path.join(mw_home, "user_projects", "domains")
    if not os.path.isdir(domains_dir):
        continue

    for domain_name in os.listdir(domains_dir):
        domain_home = os.path.join(domains_dir, domain_name)
        if not os.path.isdir(domain_home):
            continue

        config_xml = os.path.join(domain_home, "config", "config.xml")
        if not os.path.isfile(config_xml):
            print(f"  Skipping {domain_name}: no config/config.xml", file=sys.stderr)
            continue

        print(f"  Parsing domain: {domain_name}")

        admin_host = ""
        admin_port = ""
        managed_servers = []
        clusters = []

        try:
            tree = ET.parse(config_xml)
            ns = {'wl': 'http://xmlns.oracle.com/weblogic/domain'}
            root = tree.getroot()

            # Namespace-aware parsing — try with and without namespace
            def find_all(tag):
                results = root.findall(f'wl:{tag}', ns)
                if not results:
                    results = root.findall(tag)
                return results

            def get_text(el, tag):
                child = el.find(f'wl:{tag}', ns) or el.find(tag)
                return child.text.strip() if child is not None and child.text else None

            for srv in find_all('server'):
                name = get_text(srv, 'name') or ''
                port = get_text(srv, 'listen-port') or ''
                ssl_el = srv.find('wl:ssl', ns) or srv.find('ssl')
                ssl_port = get_text(ssl_el, 'listen-port') if ssl_el is not None else None
                machine  = get_text(srv, 'machine')
                cluster  = get_text(srv, 'cluster')

                if name.lower() in ('adminserver',):
                    admin_host = get_text(srv, 'listen-address') or ''
                    admin_port = port
                else:
                    managed_servers.append((name, port, ssl_port, cluster, machine))

            for cl in find_all('cluster'):
                clusters.append(get_text(cl, 'name') or '')

        except Exception as e:
            print(f"  Warning: could not parse config.xml for {domain_name}: {e}", file=sys.stderr)

        # Write domain row
        write_row(domains_f, [
            hostname, domain_name, domain_home,
            wls_version, wls_edition,
            admin_host, admin_port,
            len(clusters), len(managed_servers),
            run_id
        ])

        # Write managed server rows
        for (ms_name, port, ssl_port, cluster, machine) in managed_servers:
            write_row(ms_f, [hostname, domain_name, ms_name, port, ssl_port or '', cluster or '', machine or '', run_id])

        # Write product rows for this domain
        for (pname, pver, phome) in products:
            write_row(products_f, [hostname, domain_name, pname, pver, phome, run_id])

        total_domains += 1

domains_f.close()
ms_f.close()
products_f.close()

print(f"\nDomains discovered: {total_domains}")
PYEOF

echo ""
echo "Written: $DOMAINS_CSV"
echo "Written: $MS_CSV"
echo "Written: $PRODUCTS_CSV"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo "Upload all CSV files from this directory to SAM via: Servers > Upload Discovery > WebLogic CSV"
