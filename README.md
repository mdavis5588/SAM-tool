# Oracle SAM Tool v2 — Multi-Client with WebLogic

Software Asset Management for Oracle Database and Oracle WebLogic Server.
Supports multiple clients in a single PostgreSQL database using per-client schemas,
with a shared entitlement and core factor table accessible across all clients.

## What's new in v2

- WebLogic Server discovery via WLST (offline mode — no running server required)
- Per-client PostgreSQL schemas — full data isolation between clients
- Shared CSI entitlement register — one CSI can be split across multiple clients
- `sam_admin.provision_client()` — adds a new client in one SQL call
- `sam_admin.migrate_all_clients()` — rolls schema updates out to every client at once
- WebLogic licence calculation in `license_position` view (alongside Oracle DB)

## Schema layout

```
oracle_sam database
├── sam_admin schema        Client registry, discovery audit log
├── shared schema           CSI entitlements, core factor table, cross-client views
├── client_acme schema      Acme Corp — Oracle DB + WebLogic data
├── client_globex schema    Globex Corp — Oracle DB + WebLogic data
└── client_<code> schema    One per client, created by provision_client()
```

Each client schema contains identical tables:
`oracle_servers`, `oracle_processors`, `oracle_instances`, `oracle_options`,
`wls_domains`, `wls_managed_servers`, `wls_installed_products`, `license_position` (view)

## Quick start

### 1. Initialise the database

```bash
createdb oracle_sam
psql oracle_sam -f database/01_admin_schema.sql
psql oracle_sam -f database/02_shared_schema.sql
psql oracle_sam -f database/03_client_template_functions.sql
psql oracle_sam -f database/00_init.sql
```

`00_init.sql` creates roles, provisions example clients, and seeds sample entitlements.
Edit it before running to use your real client names and CSI data.

### 2. Add a new client

```sql
SELECT sam_admin.provision_client('newclient', 'New Client Ltd', 'admin@newclient.com');

-- Then grant database roles
GRANT USAGE ON SCHEMA client_newclient TO sam_loader, sam_reader;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA client_newclient TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA client_newclient TO sam_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA client_newclient TO sam_loader;

-- Assign their CSI entitlements
INSERT INTO shared.csi_client_map (csi_id, client_id, allocated_quantity)
SELECT <csi_id>, c.client_id, <quantity>
FROM   sam_admin.clients c WHERE c.client_code = 'newclient';

-- Rebuild cross-client view
SELECT shared.refresh_cross_client_summary();
```

### 3. Run Oracle DB discovery

```bash
export SAM_DB_HOST=localhost SAM_DB_PASSWORD=yourpassword

# Discover a specific client's Oracle servers
ansible-playbook ansible/playbooks/discover_oracle.yml \
  -i ansible/inventory/hosts.yml \
  --limit client_acme_oracle
```

### 4. Run WebLogic discovery

```bash
ansible-playbook ansible/playbooks/discover_weblogic.yml \
  -i ansible/inventory/hosts.yml \
  --limit client_acme_weblogic
```

### 5. View licence position for a client

```sql
-- Oracle DB and WebLogic combined
SELECT product_family, product_detail, hostname, licences_required,
       total_licensed, licence_surplus_deficit, compliance_status
FROM   client_acme.license_position
ORDER  BY product_family, hostname;

-- Cross-client admin summary
SELECT client_code, hostname, oracle_instance_count, wls_domain_count
FROM   shared.cross_client_summary
ORDER  BY client_code, hostname;
```

### 6. Schedule discovery (cron)

```cron
# Oracle DB — all clients, nightly at 02:00
0 2 * * * ansible-playbook /opt/oracle-sam/ansible/playbooks/discover_oracle.yml \
  -i /opt/oracle-sam/ansible/inventory/hosts.yml >> /var/log/sam/oracle.log 2>&1

# WebLogic — all clients, nightly at 03:00
0 3 * * * ansible-playbook /opt/oracle-sam/ansible/playbooks/discover_weblogic.yml \
  -i /opt/oracle-sam/ansible/inventory/hosts.yml >> /var/log/sam/weblogic.log 2>&1
```

## Manual discovery (no Ansible)

When Ansible cannot reach a server — firewall restrictions, isolated networks, or ad-hoc
one-off collection — you can run discovery directly on the Oracle DB server using SQL*Plus
and then load the output file from any machine that can reach the SAM PostgreSQL database.

### 1. Run the discovery script on the Oracle server

```bash
# Copy the script to the Oracle server (any method — scp, USB, shared drive)
scp scripts/oracle_discovery.sql oracle-server:/tmp/

# Run with OS authentication (common for DBAs already logged in as oracle)
sqlplus / as sysdba @/tmp/oracle_discovery.sql

# Or with explicit credentials / TNS alias
sqlplus sys/yourpassword@ORCL as sysdba @/tmp/oracle_discovery.sql
```

The script queries `v$instance`, `v$database`, `v$osstat`, `gv$instance`, `v$pdbs`,
`v$option`, and `dba_users`.  It writes a single JSON file:

```
oracle_discovery_<hostname>_<YYYYMMDD_HH24MISS>.json
```

### 2. Transfer the JSON file to the SAM host

```bash
scp oracle-server:/tmp/oracle_discovery_myserver_20250101_120000.json .
```

### 3. Load into PostgreSQL

```bash
# Install dependency if needed
pip install psycopg2-binary

# Set connection variables
export DB_HOST=localhost DB_NAME=samdb DB_USER=sam_admin DB_PASSWORD=yourpassword
export SAM_CLIENT_SCHEMA=client_acme

# Load
python3 scripts/load_discovery.py oracle_discovery_myserver_20250101_120000.json
```

**Optional flags:**

| Flag | Description |
|---|---|
| `--client SCHEMA` | Override `SAM_CLIENT_SCHEMA` env var |
| `--host / --port / --dbname / --user / --password` | Override any DB connection env var |
| `--dry-run` | Parse and validate JSON without writing to the database |
| `--verbose` | Print each SQL call as it executes |

### 4. Combined one-liner (if Python is available on the Oracle server)

If the Oracle server can also reach the SAM PostgreSQL database directly, the wrapper
script runs both steps in sequence:

```bash
# Copy both scripts to the Oracle server
scp scripts/oracle_discovery.sql scripts/load_discovery.py scripts/run_and_load.sh oracle-server:/tmp/

ssh oracle-server
cd /tmp
export DB_HOST=sam-db.internal DB_NAME=samdb DB_USER=sam_admin DB_PASSWORD=yourpassword
export SAM_CLIENT_SCHEMA=client_acme
./run_and_load.sh "/ as sysdba"
```

### What gets loaded

The loader calls three operations in a single transaction:

| Step | Function | Data |
|---|---|---|
| 1 | `upsert_oracle_discovery` | Server, CPU/processor, Oracle instances |
| 2 | `upsert_oracle_extended_discovery` | RAC nodes, PDBs, NUP user counts |
| 3 | Direct upsert | `v$option` flags (partitioning, RAC, etc.) |

Afterwards the `license_position` view recalculates automatically on next query.

## Licence calculation rules

### Oracle Database

| Edition | Calculation |
|---------|-------------|
| Enterprise Edition | `physical_cores × core_factor` |
| Standard Edition 2 | `MIN(cpu_sockets, 2)` |
| Standard Edition | `cpu_sockets` |

### Oracle WebLogic

| Edition | Calculation |
|---------|-------------|
| WebLogic Server / Suite | `physical_cores × core_factor` |
| Oracle SOA Suite | `physical_cores × core_factor` (separate licence) |
| Oracle Coherence | `physical_cores × core_factor` (separate licence) |
| Oracle Service Bus | `physical_cores × core_factor` (separate licence) |

Core factors are maintained centrally in `shared.core_factor_table`.
Intel Xeon / AMD EPYC = 0.5. IBM POWER = 1.0. SPARC T-series = 0.25.

## CSI allocation examples

```sql
-- Scenario A: Group ULA shared across two clients
-- Total: 100 EE processor licences — Acme gets 60, Globex gets 40
INSERT INTO shared.csi_client_map (csi_id, client_id, allocated_quantity)
VALUES (1, 1, 60), (1, 2, 40);

-- Scenario B: Client-exclusive CSI (full quantity available to one client)
-- No allocated_quantity means the full entitlement quantity is available
INSERT INTO shared.csi_client_map (csi_id, client_id)
VALUES (2, 1);

-- Scenario C: ULA covers all current clients
INSERT INTO shared.csi_client_map (csi_id, client_id)
SELECT 3, client_id FROM sam_admin.clients WHERE is_active = TRUE;
```

## Admin UI (Flask)

A web interface for non-technical users to manage licence metric overrides and
CSI contract assignments per server. Runs as a Docker container.

### Prerequisites

- Docker and Docker Compose installed on the host
- PostgreSQL reachable from the Docker host

### 1. Configure environment variables

```bash
cd admin-ui
cp .env.example .env
```

Edit `.env` and set the following:

| Variable | Description |
|---|---|
| `DB_HOST` | PostgreSQL hostname or IP |
| `DB_PORT` | PostgreSQL port (default `5432`) |
| `DB_NAME` | Database name (e.g. `samdb`) |
| `DB_USER` | Database user (e.g. `sam_admin`) |
| `DB_PASSWORD` | Database password |
| `SAM_CLIENT_SCHEMA` | Client schema to manage (e.g. `client_acme`) |
| `ADMIN_USER` | Login username for the web UI |
| `ADMIN_PASSWORD` | Login password for the web UI |
| `FLASK_SECRET` | Random string used to sign session cookies — change this |

### 2. Build and start

```bash
cd admin-ui
docker compose up -d
```

The UI will be available at **http://your-server:5000**.

To stop it:

```bash
docker compose down
```

### 3. What you can do in the UI

- **Servers** — see every discovered server with its calculated licence requirement
  (processor count and type), CSI assignment status, and compliance badge
- **Edit a server** — switch between Processor Perpetual (default) and Named User Plus;
  assign or remove CSI contracts with optional licence quantity override;
  view change history and acknowledge entries
- **Contracts** — browse all CSI contracts, view entitlement lines and which servers
  are consuming them
- **Alerts** — live compliance alerts: expiring contracts, ULA deadlines,
  unacknowledged HIGH severity changes, SE2 violations, unrecognised CPUs, and VMware exposure
- **VMware** — vSphere cluster inventory showing Oracle VM workloads and the full
  physical core count that Oracle requires to be licensed across each cluster
- **LMS Export** — download a 10-sheet Excel workbook covering the full audit pack
  (see below)
- **Settings** — configure email, Slack, or Teams alert channels

### 4. LMS Audit Export

The **LMS Export** button in the top navigation bar generates an Excel workbook
(`.xlsx`) covering everything an Oracle audit typically requires.

#### Download from a browser

1. Log in to the Admin UI.
2. Click **LMS Export** in the navbar (top-right).
3. The file downloads immediately as
   `oracle_lms_export_<client_schema>_<date>.xlsx`.

#### Download from the command line

```bash
# Basic — saves the file in the current directory
curl -c cookies.txt -b cookies.txt \
     -X POST http://your-server:5000/login \
     -d "username=admin&password=yourpassword" \
     -L -o /dev/null

curl -c cookies.txt -b cookies.txt \
     http://your-server:5000/export/lms \
     -o oracle_lms_export.xlsx
```

#### What the workbook contains

| Sheet | Contents |
|---|---|
| **Server Inventory** | All active Oracle servers — hostname, environment, OS, RAM |
| **Processor Details** | CPU model, socket count, core count, Oracle core factor |
| **Oracle Instances** | SID, edition, version, platform per instance |
| **Options** | Active `v$option` flags (Partitioning, RAC, Diagnostics Pack, etc.) |
| **Licence Position** | Calculated licence requirements vs. entitlements, surplus/deficit |
| **CSI Contracts** | Contract headers, quantities, costs, and expiry dates |
| **SE2 Violations** | Servers breaching the SE2 2-socket or 2-node RAC limits |
| **CPU Validation** | Servers with CPU models not matched in the Oracle core factor table |
| **VMware Exposure** | vSphere clusters with Oracle workloads and full physical core counts |

Rows highlighted **red** indicate compliance failures (under-licensed, SE2 violations,
Oracle VM clusters). Rows highlighted **amber** indicate items requiring manual review
(unrecognised CPU models, VMware clusters with Oracle workloads).

### 5. Configuring alert channels (email, Slack, Teams)

The **Settings** page lets you add one or more alert channels. When the
`/api/dispatch-alerts` endpoint is called (manually or by cron), the tool
evaluates all active compliance alerts and sends them to every enabled channel.

#### 5a. Microsoft Teams (Incoming Webhook)

1. In Teams, open the channel you want to post alerts to.
2. Click **···** → **Connectors** → search for **Incoming Webhook** → **Add**.
3. Give it a name (e.g. *Oracle SAM Alerts*), optionally upload an icon, then
   click **Create**.
4. Copy the webhook URL (it looks like
   `https://your-org.webhook.office.com/webhookb2/…`).
5. In the Admin UI, go to **Settings** → **Add Channel**:
   - **Channel type**: Teams
   - **Name**: anything descriptive (e.g. *#oracle-alerts*)
   - **Webhook URL**: paste the URL from step 4
   - **Minimum severity**: LOW / MEDIUM / HIGH — alerts below this level are
     suppressed for this channel
6. Click **Add Channel**, then optionally click **Test** to send a sample message.

#### 5b. Slack (Incoming Webhook)

1. Go to **api.slack.com/apps** → **Create New App** → **From scratch**.
2. Under **Features**, choose **Incoming Webhooks** and activate them.
3. Click **Add New Webhook to Workspace**, select the target channel, and
   copy the webhook URL (`https://hooks.slack.com/services/…`).
4. In the Admin UI go to **Settings** → **Add Channel**:
   - **Channel type**: Slack
   - **Webhook URL**: paste the Slack webhook URL
5. Click **Add Channel** and optionally **Test**.

#### 5c. Email (SMTP)

| Field | Description |
|---|---|
| **SMTP host** | Your mail relay, e.g. `smtp.office365.com` or `smtp.gmail.com` |
| **SMTP port** | `587` for STARTTLS (recommended), `465` for implicit TLS, `25` for plain |
| **From address** | Sender address the relay permits, e.g. `oracle-sam@yourcompany.com` |
| **SMTP username** | Usually the same as the from address |
| **SMTP password** | Account password or app-specific password |
| **To addresses** | Comma-separated list of recipients |

The tool uses STARTTLS on port 587 / 465 and plain SMTP on port 25. If your
relay requires no authentication (e.g. an internal smarthost), leave username
and password blank.

#### 5d. Scheduled dispatch (cron)

The endpoint `/api/dispatch-alerts` triggers alert evaluation and delivery.
Set `DISPATCH_KEY` in `.env` to a random string, then call it from cron:

```cron
# Check and send compliance alerts every morning at 07:00
0 7 * * * curl -s "http://your-server:5000/api/dispatch-alerts?key=YOUR_DISPATCH_KEY" \
  >> /var/log/sam/alerts.log 2>&1
```

Leave `DISPATCH_KEY` blank in `.env` to disable authentication (not
recommended in production).

### 6. Running without Docker (development)

```bash
cd admin-ui
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

export DB_HOST=localhost DB_NAME=samdb DB_USER=sam_admin DB_PASSWORD=yourpassword
export SAM_CLIENT_SCHEMA=client_acme ADMIN_USER=admin ADMIN_PASSWORD=changeme
export FLASK_SECRET=dev-only-secret

python app.py
```

### 7. Running on a different port

Edit `docker-compose.yml` and change the left side of the port mapping:

```yaml
ports:
  - "8080:5000"   # now accessible on port 8080
```

Then restart: `docker compose up -d`

## Files

```
oracle-sam-v2/
├── ansible/
│   ├── inventory/hosts.yml             Multi-client inventory
│   └── playbooks/
│       ├── discover_oracle.yml         Oracle DB discovery
│       └── discover_weblogic.yml       WebLogic discovery (WLST)
├── database/
│   ├── admin/01_admin_schema.sql       Client registry + provisioning
│   ├── shared/02_shared_schema.sql     CSI entitlements + core factor table
│   ├── client_template/
│   │   └── 03_client_template_functions.sql  Views + upserts installed per client
│   └── migrations/00_init.sql         Full init script with roles + sample data
├── powerbi/POWERBI_SETUP.md           Power BI connection + DAX guide
└── README.md
```
