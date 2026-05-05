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
psql oracle_sam -f database/admin/01_admin_schema.sql
psql oracle_sam -f database/shared/02_shared_schema.sql
psql oracle_sam -f database/client_template/03_client_template_functions.sql
psql oracle_sam -f database/migrations/00_init.sql
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
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id, allocated_quantity)
SELECT <entitlement_id>, c.client_id, <quantity>
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
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id, allocated_quantity)
VALUES (1, 1, 60), (1, 2, 40);

-- Scenario B: Client-exclusive CSI (full quantity available to one client)
-- No allocated_quantity means the full entitlement quantity is available
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id)
VALUES (2, 1);

-- Scenario C: ULA covers all current clients
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id)
SELECT 3, client_id FROM sam_admin.clients WHERE is_active = TRUE;
```

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
