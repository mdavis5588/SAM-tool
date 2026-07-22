# Helios — Multi-Client Oracle SAM with WebLogic

Software Asset Management for Oracle Database and Oracle WebLogic Server.
Supports multiple clients in a single PostgreSQL database using per-client schemas,
with a shared entitlement and core factor table accessible across all clients.

---

## Table of contents

1. [Schema layout](#schema-layout)
2. [Quick start — fresh install](#quick-start--fresh-install)
3. [Adding a new client](#adding-a-new-client)
4. [Oracle Database discovery](#oracle-database-discovery)
5. [WebLogic discovery](#weblogic-discovery)
6. [Manual server registration](#manual-server-registration)
7. [Logging discovery runs](#logging-discovery-runs)
8. [Licence calculation rules](#licence-calculation-rules)
9. [Admin UI](#admin-ui)
10. [User roles & access control](#user-roles--access-control)
11. [Database migrations](#database-migrations)
12. [File layout](#file-layout)

---

## Schema layout

```
oracle_sam database
├── sam_admin schema        Client registry, user accounts, audit log, discovery runs
├── shared schema           CSI entitlements, core factor table, licensed options
├── client_acme schema      Acme Corp — Oracle DB + WebLogic data
├── client_globex schema    Globex Corp — Oracle DB + WebLogic data
└── client_<code> schema    One per client, created by provision_client()
```

Each client schema contains identical tables and views:

| Object | Description |
|---|---|
| `oracle_servers` | Server inventory (hostname, IP, environment, etc.) |
| `oracle_processors` | CPU details — model, sockets, cores per socket |
| `oracle_instances` | Oracle DB instances (SID, edition, version) |
| `oracle_options` | Active `v$option` flags (Partitioning, RAC, Diagnostics Pack, etc.) |
| `wls_domains` | WebLogic domains (name, edition, version) |
| `wls_managed_servers` | Managed server nodes within each domain |
| `wls_installed_products` | Products installed in each domain |
| `server_csi_map` | Licence assignments: server ↔ CSI contract line |
| `license_position` (view) | Calculated licence requirement vs. entitlement per server |
| `server_csi_coverage` (view) | Detailed CSI coverage breakdown per server |
| `cpu_validation_report` (view) | Servers with unrecognised CPU models |
| `se2_violations` (view) | Servers breaching SE2 2-socket / 2-node RAC limits |

---

## Quick start — fresh install

### 1. Initialise the database

```bash
createdb oracle_sam
psql oracle_sam -f database/00_full_schema.sql
psql oracle_sam -f database/02_shared_schema.sql
psql oracle_sam -f database/03_client_template_functions.sql
psql oracle_sam -f database/00_init.sql
```

| File | What it creates |
|---|---|
| `00_full_schema.sql` | All `sam_admin` tables, enums, RBAC, audit log, snapshots, FinOps, discovery, VMware — everything in one file |
| `02_shared_schema.sql` | `shared` schema — CSI contracts, entitlement lines, core factor table |
| `03_client_template_functions.sql` | Per-client view and function installers called by `provision_client()` |
| `00_init.sql` | Roles, example clients, seed data — edit before running to use your real client names and CSI data |

> **Upgrading an existing database?** See [Database migrations](#database-migrations) below.

### 2. Verify

```sql
-- Check clients exist
SELECT client_code, client_name, schema_name FROM sam_admin.clients;

-- Check sample licence position
SELECT hostname, product_family, licences_required, compliance_status
FROM   client_acme.license_position
ORDER  BY hostname;
```

---

## Adding a new client

```sql
-- Creates the schema, all tables, views, and triggers in one call
SELECT sam_admin.provision_client('newclient', 'New Client Ltd', 'admin@newclient.com');

-- Grant database roles
GRANT USAGE ON SCHEMA client_newclient TO sam_loader, sam_reader;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA client_newclient TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA client_newclient TO sam_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA client_newclient TO sam_loader;

-- Assign their CSI entitlements
INSERT INTO shared.csi_client_map (csi_id, client_id, allocated_quantity)
SELECT <csi_id>, c.client_id, <quantity>
FROM   sam_admin.clients c WHERE c.client_code = 'newclient';
```

After provisioning, the new client will appear in the Admin UI client switcher immediately.

---

## Oracle Database discovery

### Ansible (recommended)

```bash
export SAM_DB_HOST=localhost SAM_DB_PASSWORD=yourpassword

# Discover all Oracle servers for a specific client
ansible-playbook ansible/playbooks/discover_oracle.yml \
  -i ansible/inventory/hosts.yml \
  --limit client_acme_oracle
```

### Manual (no Ansible — air-gapped or firewalled servers)

**Step 1 — Run the discovery script on the Oracle server**

```bash
scp scripts/oracle_discovery.sql oracle-server:/tmp/

# OS authentication
sqlplus / as sysdba @/tmp/oracle_discovery.sql

# Or explicit credentials
sqlplus sys/yourpassword@ORCL as sysdba @/tmp/oracle_discovery.sql
```

The script queries `v$instance`, `v$database`, `v$osstat`, `gv$instance`, `v$pdbs`,
`v$option`, and `dba_users`. It writes:

```
oracle_discovery_<hostname>_<YYYYMMDD_HH24MISS>.json
```

**Step 2 — Transfer and load**

```bash
scp oracle-server:/tmp/oracle_discovery_myserver_20250101_120000.json .

export DB_HOST=localhost DB_NAME=samdb DB_USER=sam_admin DB_PASSWORD=yourpassword
export SAM_CLIENT_SCHEMA=client_acme

python3 scripts/load_discovery.py oracle_discovery_myserver_20250101_120000.json
```

| Flag | Description |
|---|---|
| `--client SCHEMA` | Override `SAM_CLIENT_SCHEMA` env var |
| `--dry-run` | Validate JSON without writing to the database |
| `--verbose` | Print each SQL call as it executes |

### Schedule nightly discovery (cron)

```cron
# Oracle DB — nightly at 02:00
0 2 * * * ansible-playbook /opt/oracle-sam/ansible/playbooks/discover_oracle.yml \
  -i /opt/oracle-sam/ansible/inventory/hosts.yml >> /var/log/sam/oracle.log 2>&1
```

---

## WebLogic discovery

```bash
ansible-playbook ansible/playbooks/discover_weblogic.yml \
  -i ansible/inventory/hosts.yml \
  --limit client_acme_weblogic
```

WLST offline mode is used — no running AdminServer required.

```cron
# WebLogic — nightly at 03:00
0 3 * * * ansible-playbook /opt/oracle-sam/ansible/playbooks/discover_weblogic.yml \
  -i /opt/oracle-sam/ansible/inventory/hosts.yml >> /var/log/sam/weblogic.log 2>&1
```

---

## Manual server registration

When a server cannot be discovered automatically (firewall restrictions, new build not
yet in inventory, etc.), it can be registered through the Admin UI:

**Sidebar → Register Server**

Fields available at registration time:

| Section | Fields |
|---|---|
| **Client** | Which client this server belongs to |
| **Server type** | Oracle Database or WebLogic |
| **Identity** | Hostname *(required)*, FQDN, IP address, environment, datacenter |
| **Database details** *(DB only)* | Oracle SID, DB version, edition |
| **Licensed options** *(DB only)* | Checkboxes for all Oracle licensed options (Diagnostics Pack, Tuning Pack, Partitioning, RAC, Active Data Guard, etc.) — only Enterprise Edition options generate a licence requirement |
| **WebLogic details** *(WLS only)* | Domain name, WLS version, edition |
| **CPU model & core factor** | Common CPU presets (Intel Xeon, AMD EPYC, IBM POWER, HP-UX/Itanium, SPARC T/M, ARM) with automatic core factor; override available if needed |
| **Hardware** | Total RAM (MB), physical cores, CPU sockets, cores per socket |
| **OS** | OS family, distribution, version |
| **Notes** | Free text |

After registration the server appears immediately on the Servers tab and all licence
calculations include it.

### Server deduplication

The `sam_admin.register_server()` function resolves identity using four-priority matching
to avoid creating duplicate records when the same server is discovered by multiple sources
(Ansible, PSQL cron, manual registration):

1. Exact hostname match
2. Short-name match (hostname without domain)
3. FQDN match
4. IP address match

If a conflict is detected (same server discovered with different attributes), it is
flagged in **Administration → Discovery Conflicts** for manual resolution.

---

## Logging discovery runs

Every discovery sweep — whether Ansible, PSQL cron, or manual registration — should
call `sam_admin.log_discovery_run()` at the end to record the sweep in the discovery
run history. This populates the **Discovery History** page in the Admin UI.

### Function signature

```sql
SELECT sam_admin.log_discovery_run(
    p_schema          => 'client_acme',   -- client schema name (required)
    p_source          => 'ansible',       -- 'ansible' | 'psql' | 'manual'
    p_servers_seen    => 12,              -- total servers visited in this sweep
    p_servers_new     => 2,              -- new server records created
    p_servers_updated => 9,              -- existing records updated
    p_servers_conflict=> 1,              -- records flagged as conflicts
    p_run_host        => 'ansible-ctl',  -- hostname that ran the sweep (optional)
    p_notes           => NULL,           -- free text (optional)
    p_status          => 'completed'     -- 'running' | 'completed' | 'failed'
);
```

All parameters except `p_schema` and `p_source` are optional and default to 0 / NULL.

### Ansible playbook integration

Add a task at the end of each playbook that calls this function with the sweep totals:

```yaml
- name: Log discovery run to SAM
  community.postgresql.postgresql_query:
    db: "{{ sam_db_name }}"
    login_host: "{{ sam_db_host }}"
    login_user: "{{ sam_db_user }}"
    login_password: "{{ sam_db_password }}"
    query: >
      SELECT sam_admin.log_discovery_run(
        p_schema           => %s,
        p_source           => 'ansible',
        p_servers_seen     => %s,
        p_servers_new      => %s,
        p_servers_updated  => %s,
        p_servers_conflict => %s,
        p_run_host         => %s,
        p_status           => 'completed'
      )
    positional_args:
      - "{{ sam_client_schema }}"
      - "{{ servers_seen | default(0) }}"
      - "{{ servers_new | default(0) }}"
      - "{{ servers_updated | default(0) }}"
      - "{{ servers_conflict | default(0) }}"
      - "{{ inventory_hostname }}"
```

### PSQL cron integration

```bash
#!/bin/bash
# oracle_discovery_cron.sh — run at end of your discovery script

psql "$SAM_DSN" <<SQL
SELECT sam_admin.log_discovery_run(
    p_schema          => '$SAM_CLIENT_SCHEMA',
    p_source          => 'psql',
    p_servers_seen    => $SERVERS_SEEN,
    p_servers_new     => $SERVERS_NEW,
    p_servers_updated => $SERVERS_UPDATED,
    p_run_host        => '$(hostname)',
    p_status          => 'completed'
);
SQL
```

---

## Licence calculation rules

### Oracle Database — Processor Perpetual (default)

| Edition | Calculation |
|---|---|
| Enterprise Edition | `physical_cores × core_factor` |
| Standard Edition 2 | `MIN(cpu_sockets, 2)` — max 2 sockets per server |
| Standard Edition | `cpu_sockets` |

**SE2 limits:** SE2 is limited to 2 populated sockets per server and 2 nodes per RAC
cluster. Violations are surfaced on the **Compliance → SE2 Violations** page and
in the LMS export.

### Oracle Database — Named User Plus (NUP)

Set `licence_metric_override = 'named_user_plus'` on a server to switch it to NUP metric.

| Edition | Minimum floor | Licences required |
|---|---|---|
| Enterprise Edition | `physical_cores × core_factor × 25` | `GREATEST(nup_minimum, active_users)` |
| Standard Edition 2 | `cpu_sockets × 10` | `GREATEST(nup_minimum, active_users)` |

### Oracle WebLogic

| Edition | Calculation |
|---|---|
| WebLogic Server / Suite | `physical_cores × core_factor` |
| Oracle Coherence | `physical_cores × core_factor` |

### Core factor table

Core factors are maintained in `shared.core_factor_table`. Standard values:

| Processor family | Factor |
|---|---|
| Intel Xeon / Core / AMD EPYC / AMD Opteron / ARM | 0.50 |
| Oracle SPARC T-series | 0.25 |
| Oracle SPARC M-series / IBM POWER / HP-UX Itanium | 1.00 |
| Unknown (unrecognised model) | 1.00 |

To add a custom CPU model:

```sql
INSERT INTO shared.core_factor_table (processor_pattern, core_factor, notes)
VALUES ('My Custom CPU%', 0.5, 'From Oracle processor core factor table PDF');
```

The pattern column uses `ILIKE` matching — `%` wildcards are supported.

### Oracle licensed options

Options (Diagnostics Pack, Tuning Pack, Partitioning, RAC, Active Data Guard, etc.) are
stored in `oracle_options` per instance and only generate a licence requirement when the
instance edition is **Enterprise Edition**. Each active option adds a separate line to
`license_position` with its own processor-perpetual licence requirement.

---

## Admin UI

A web interface for managing licence assignments, reviewing compliance, and exporting
audit data. Runs as a Docker container.

### Setup

```bash
cd admin-ui
cp .env.example .env
```

| Variable | Description |
|---|---|
| `DB_HOST` | PostgreSQL hostname or IP |
| `DB_PORT` | PostgreSQL port (default `5432`) |
| `DB_NAME` | Database name |
| `DB_USER` | Database user |
| `DB_PASSWORD` | Database password |
| `SAM_CLIENT_SCHEMA` | Default client schema (e.g. `client_acme`) |
| `ADMIN_USER` | Bootstrap admin username |
| `ADMIN_PASSWORD` | Bootstrap admin password (stored as bcrypt hash) |
| `FLASK_SECRET` | Random string for session cookie signing — change this |
| `DISPATCH_KEY` | Secret key for the `/api/dispatch-alerts` cron endpoint |

```bash
docker compose up -d
# UI available at http://your-server:5000
```

Without Docker:

```bash
cd admin-ui
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python app.py
```

### Sidebar sections

The sidebar is divided into named sections. Some sections are role-gated:

| Section | Who sees it | Contents |
|---|---|---|
| *(top)* | All | Executive Summary |
| **Inventory** | All | Servers |
| **Licensing** | All | Contracts, Licence Summary, FinOps (cost / server costs / optimisation) |
| **Billing** | superadmin, contracting | Billing Reports flyout (Annual Client Totals + Monthly Shared Pool Overview) |
| **Compliance** | All | Compliance, Audit Readiness, VMware |
| **Visibility** | All | Version Lifecycle, Licence History |
| **Administration** | superadmin | Clients, Register Server, Users & Access, Audit & Snapshots, Discovery History/Conflicts |

### Client switcher

The top-right client switcher scopes most pages to a single client. Key behaviours:

- **FinOps → Cost Summary** (via the FinOps sidebar link) — jumps directly to the selected client's Licence Cost Detail page. Falls back to the all-clients overview when "All Clients" is selected.
- **Billing Reports → Annual Client Totals** — always shows the full all-clients list regardless of switcher state, so you can click through to any client.
- **Server Costs** — filters to the selected client's servers only.
- **ULA Coverage tab** — hidden automatically when the selected client has no ULA contracts.

### Pages

| Page | Description |
|---|---|
| **Dashboard** | KPI summary — compliance score, licence gaps, contract value, per-client RAG status |
| **Servers** | All active servers — licence requirements, CSI assignment status, compliance badge; remove servers from inventory |
| **Edit Server** | Switch metric (Processor / NUP); assign/remove CSI contracts; view change history; reactivate removed servers |
| **Register Server** | Manually add a server with CPU model, core factor, OS, hardware, DB/WLS details, and licensed options |
| **WebLogic Servers** | WebLogic domain inventory with licence position |
| **Contracts** | CSI contracts, entitlement lines, server consumption |
| **Renewal Calendar** | Timeline of upcoming support and ULA expiry dates |
| **FinOps → Cost Summary** | Per-client licence cost breakdown — client-locked annual support vs. shared pool, product-by-product utilisation |
| **FinOps → Server Costs** | Per-server licence cost breakdown scoped to the selected client |
| **FinOps → Cost Optimisation** | Recommendations for reducing licence spend — unused lines, low-utilisation contracts, ULA candidates |
| **FinOps → ULA Coverage** | ULA contracts — assigned servers, product licence requirements, expiry status *(hidden when client has no ULAs)* |
| **Billing Reports → Annual Client Totals** | All-clients cost overview — annual support + shared pool FY cost per client; click any client to drill into their detail *(superadmin / contracting only)* |
| **Billing Reports → Monthly Shared Pool Overview** | Shared pool usage per client and CSI for the current month; scannable month-by-month history table (click a row to expand per-client/CSI detail); take and re-take monthly snapshots *(superadmin / contracting only)* |
| **Licence Summary** | Aggregate licence position across all contracts |
| **Compliance** | Audit-ready compliance findings |
| **Audit Readiness** | Five-section audit report: licence gaps, unassigned servers, contract risks, empty contracts, ULA scope violations |
| **VMware** | vSphere clusters with Oracle workloads and required physical core counts |
| **Visibility → Lifecycle** | Oracle DB and WebLogic version distribution with lifecycle status |
| **Visibility → Licence History** | Trend charts from monthly snapshots — required vs. assigned over time |
| **Discovery History** | Log of all discovery sweeps — source, timing, server counts, conflicts |
| **Discovery Conflicts** | Servers flagged during deduplication for manual resolution |
| **Alerts** | Live compliance alerts — expiring contracts, SE2 violations, unrecognised CPUs |
| **LMS Export** | Download a 10-sheet Excel audit workbook |
| **Settings** | Configure email, Slack, and Teams alert channels |
| **Administration → Users & Access** | Create/manage users, assign roles and client scope *(superadmin only)* |
| **Administration → Audit & Snapshots** | Take/view licence snapshots and shared pool snapshots; browse user activity audit trail *(superadmin only)* |

The UI supports **English and French** — toggle in the top navigation bar.

### LMS audit export

**LMS Export** in the navbar generates an `.xlsx` workbook:

| Sheet | Contents |
|---|---|
| Server Inventory | All active Oracle servers — hostname, environment, OS, RAM |
| Processor Details | CPU model, socket count, core count, core factor |
| Oracle Instances | SID, edition, version per instance |
| Options | Active `v$option` flags |
| Licence Position | Requirements vs. entitlements, surplus/deficit |
| CSI Contracts | Contract headers, quantities, costs, expiry dates |
| SE2 Violations | Servers breaching SE2 limits |
| CPU Validation | Servers with unrecognised CPU models |
| VMware Exposure | vSphere clusters with Oracle workloads |

Rows highlighted red = compliance failures. Rows highlighted amber = manual review required.

### Alert channels

The **Settings** page lets you add Slack, Microsoft Teams, or email channels for
compliance alert notifications.

Trigger alert dispatch from cron:

```cron
0 7 * * * curl -s "http://your-server:5000/api/dispatch-alerts?key=YOUR_DISPATCH_KEY" \
  >> /var/log/sam/alerts.log 2>&1
```

---

## User roles & access control

| Role | Who | Permissions |
|---|---|---|
| **superadmin** | Platform administrators | Full access: all clients, all data, user management, settings |
| **contracting** | Procurement / contract managers | Add/edit CSI contracts; read-only everything else |
| **dba** | DBAs | Add/remove licence assignments; read-only everything else |
| **client** | Client-specific users | Read-only access to their assigned client only |

### Bootstrap admin

The application creates or updates a superadmin account on first start, seeded from
`ADMIN_USER` / `ADMIN_PASSWORD` in `.env`. The password is stored as a bcrypt hash.
This account cannot be deleted through the UI.

### Active Directory

Set `auth_method = 'active_directory'` and `ad_username` on a user record. Replace the
`_check_password()` call in `login()` in `admin-ui/app.py` with your LDAP bind logic
when `user["auth_method"] == "active_directory"`.

---

## Database migrations

Run migration scripts in order when upgrading an **existing** database. All scripts are
safe to re-run.

> **New installs:** Use `database/00_full_schema.sql` — it includes everything below in
> one file. You do **not** need to run any migration scripts on a fresh database.

```bash
psql oracle_sam -f database/migrations/01_java_licence_exemptions.sql
psql oracle_sam -f database/migrations/02_vmware_se2_cpu_alerts.sql
psql oracle_sam -f database/migrations/03_merge_tuning_pack_names.sql
psql oracle_sam -f database/migrations/04_ula_covered_products.sql
psql oracle_sam -f database/05_migration_per_line_csi.sql
psql oracle_sam -f database/migrations/05_nup_license_position.sql
psql oracle_sam -f database/migrations/06_rbac_users.sql
psql oracle_sam -f database/migrations/07_audit_logging.sql
psql oracle_sam -f database/migrations/08_assignment_queue.sql
psql oracle_sam -f database/migrations/09_server_dedup.sql
psql oracle_sam -f database/migrations/10_discovery_runs.sql
psql oracle_sam -f database/01_admin_schema.sql                # refresh install_client_tables()
psql oracle_sam -f database/03_client_template_functions.sql   # refresh view installer functions
psql oracle_sam -f database/migrations/11_refresh_client_functions.sql
psql oracle_sam -f database/migrations/12_finops_pool_snapshots.sql
psql oracle_sam -f database/migrations/add_client_pool_snapshots.sql
psql oracle_sam -f database/migrations/13_stale_server_investigations.sql
psql oracle_sam -f database/migrations/14_decommissioned_servers.sql
psql oracle_sam -f database/migrations/15_contract_br_p2p.sql
```

| Script | What it adds |
|---|---|
| `01_java_licence_exemptions.sql` | Exemption columns on `java_installations` |
| `02_vmware_se2_cpu_alerts.sql` | VMware cluster tables, SE2 violation tracking, alert channels |
| `03_merge_tuning_pack_names.sql` | Data fix: merges duplicate Tuning Pack product lines |
| `04_ula_covered_products.sql` | `shared.ula_covered_products` — ULA scope tracking |
| `05_migration_per_line_csi.sql` | `product_detail` and `line_id` on `server_csi_map`; per-line CSI assignment |
| `05_nup_license_position.sql` | NUP columns in `license_position` view |
| `06_rbac_users.sql` | `sam_admin.app_users` table, role and auth method enums |
| `07_audit_logging.sql` | `sam_admin.audit_log`, `sam_admin.licence_snapshots` |
| `08_assignment_queue.sql` | `sam_admin.assignment_requests` — approval workflow for licence assignments |
| `09_server_dedup.sql` | `sam_admin.register_server()` — 4-priority deduplication; `sam_admin.list_conflicts()` |
| `10_discovery_runs.sql` | `sam_admin.discovery_runs` table; `sam_admin.log_discovery_run()` function |
| `11_refresh_client_functions.sql` | Rebuilds all views in every client schema after `03_client_template_functions.sql` is updated |
| `12_finops_pool_snapshots.sql` | `sam_admin.finops_pool_snapshots` and `finops_pool_snapshot_lines` — FinOps monthly cost history |
| `add_client_pool_snapshots.sql` | `sam_admin.client_pool_snapshots` and `client_pool_snapshot_lines` — per-client monthly shared pool snapshots for Audit & Snapshots |
| `13_stale_server_investigations.sql` | `sam_admin.stale_server_investigations` — tracks assignment and resolution of servers missing for 14+ days |
| `14_decommissioned_servers.sql` | `sam_admin.decommissioned_servers` — permanent archive of decommissioned servers and their licence snapshots |
| `15_contract_br_p2p.sql` | `br_number` and `p2p_number` columns on `shared.csi_contracts` |

---

## File layout

```
SAM-tool/
├── ansible/
│   ├── inventory/hosts.yml
│   └── playbooks/
│       ├── discover_oracle.yml
│       └── discover_weblogic.yml
├── database/
│   ├── 00_full_schema.sql                   ★ FRESH INSTALL — all sam_admin tables + migrations consolidated
│   ├── 00_init.sql                          Roles, sample clients, seed data
│   ├── 01_admin_schema.sql                  Client registry, provision_client() (legacy — use 00_full_schema.sql)
│   ├── 02_shared_schema.sql                 CSI entitlements, core factor table
│   ├── 03_client_template_functions.sql     Per-client views, upsert functions, triggers
│   ├── 05_migration_per_line_csi.sql        Per-line CSI migration
│   ├── sample_data.sql                      Sample data — client_acme (processor)
│   ├── sample_data_globex.sql               Sample data — client_globex
│   ├── sample_data_nup.sql                  Sample NUP data — client_acme
│   ├── sample_data_weblogic.sql             Sample WebLogic data
│   └── migrations/                          Run in order only when UPGRADING an existing DB
│       ├── 01_java_licence_exemptions.sql
│       ├── 02_vmware_se2_cpu_alerts.sql
│       ├── 03_merge_tuning_pack_names.sql
│       ├── 04_ula_covered_products.sql
│       ├── 05_nup_license_position.sql
│       ├── 06_rbac_users.sql
│       ├── 07_audit_logging.sql
│       ├── 08_assignment_queue.sql
│       ├── 09_server_dedup.sql
│       ├── 10_discovery_runs.sql
│       ├── 11_refresh_client_functions.sql
│       ├── 12_finops_pool_snapshots.sql
│       ├── add_client_pool_snapshots.sql
│       ├── 13_stale_server_investigations.sql
│       ├── 14_decommissioned_servers.sql
│       └── 15_contract_br_p2p.sql
├── admin-ui/
│   ├── app.py
│   ├── requirements.txt
│   ├── templates/
│   └── translations/                        en.json / fr.json
├── PowerBI/POWERBI_SETUP.md
└── README.md
```
