# Oracle SAM v2 — Power BI Multi-Client Setup Guide

## Connection strategy

Because data is separated by PostgreSQL schema (one per client), there are
two reporting models to choose from:

| Model | Who uses it | How |
|-------|------------|-----|
| Per-client report | Each client sees only their data | Connect to their schema directly |
| Admin roll-up report | SAM team, full cross-client view | Connect to `shared` + `sam_admin` schemas |

Both use the same PostgreSQL database (`oracle_sam`). Access is controlled by
which PostgreSQL role the Power BI connection uses.

---

## Model A — Per-client report

### Connection setup

```
Server:   <pg-host>:5432
Database: oracle_sam
Schema:   client_acme   (or client_globex, etc.)
Role:     sam_reader_acme  (see role creation below)
Mode:     DirectQuery
```

Create a client-scoped reader role:

```sql
-- Per-client reader (cannot see other schemas)
CREATE ROLE sam_reader_acme WITH LOGIN PASSWORD 'changeme';
GRANT USAGE ON SCHEMA client_acme, shared TO sam_reader_acme;
GRANT SELECT ON ALL TABLES IN SCHEMA client_acme TO sam_reader_acme;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO sam_reader_acme;
REVOKE USAGE ON SCHEMA sam_admin FROM sam_reader_acme;
```

### Tables to import (client_acme schema)

| Object | Type |
|--------|------|
| `oracle_servers` | Table |
| `oracle_processors` | Table |
| `oracle_instances` | Table |
| `oracle_options` | Table |
| `wls_domains` | Table |
| `wls_managed_servers` | Table |
| `wls_installed_products` | Table |
| `license_position` | View — calculated compliance |

### Tables to import (shared schema)

| Object | Type |
|--------|------|
| `entitlements_by_client` | View — filtered to this client's CSIs |
| `core_factor_table` | Table — reference |
| `entitlement_utilisation` | View — expiry tracking |

### Relationships in Power BI

```
oracle_processors.server_id     → oracle_servers.server_id
oracle_instances.server_id      → oracle_servers.server_id
oracle_options.instance_id      → oracle_instances.instance_id
wls_domains.server_id           → oracle_servers.server_id
wls_managed_servers.domain_id   → wls_domains.domain_id
wls_managed_servers.server_id   → oracle_servers.server_id
wls_installed_products.domain_id → wls_domains.domain_id
```

---

## Model B — Admin roll-up report

### Connection setup

```
Server:   <pg-host>:5432
Database: oracle_sam
Role:     sam_reader  (has SELECT on all schemas)
Mode:     DirectQuery
```

### Additional tables (sam_admin schema)

| Object | Type |
|--------|------|
| `clients` | Table — client registry |
| `discovery_runs` | Table — audit log across all clients |

### Additional shared views

| Object | Purpose |
|--------|---------|
| `cross_client_summary` | One row per server across all clients |
| `entitlement_utilisation` | All CSIs, allocation vs available |

### Slicer: client_code

Add `sam_admin.clients[client_code]` as a slicer. Because `cross_client_summary`
already contains `client_code`, all visuals filter correctly.

---

## DAX Measures

Paste into a dedicated `_Measures` table. These work for both model A and B.

### Oracle Database

```dax
DB Licences Required =
SUMX(
    FILTER(license_position, license_position[product_family] = "oracle_database"),
    license_position[licences_required]
)

DB Licences Owned =
SUMX(
    FILTER(entitlements_by_client, entitlements_by_client[product_family] = "oracle_database"),
    entitlements_by_client[client_quantity]
)

DB Surplus / Deficit = [DB Licences Owned] - [DB Licences Required]

DB Compliance =
IF([DB Surplus / Deficit] >= 0, "Compliant", "Under-licensed")

DB % Utilisation =
DIVIDE([DB Licences Required], [DB Licences Owned], 0)
```

### WebLogic

```dax
WLS Licences Required =
SUMX(
    FILTER(license_position, license_position[product_family] = "oracle_weblogic"),
    license_position[licences_required]
)

WLS Licences Owned =
SUMX(
    FILTER(entitlements_by_client, entitlements_by_client[product_family] = "oracle_weblogic"),
    entitlements_by_client[client_quantity]
)

WLS Surplus / Deficit = [WLS Licences Owned] - [WLS Licences Required]

WLS Domain Count =
DISTINCTCOUNT(wls_domains[domain_id])

WLS Managed Server Count =
DISTINCTCOUNT(wls_managed_servers[managed_server_id])
```

### Entitlement health

```dax
CSIs Expiring in 90 Days =
CALCULATE(
    COUNTROWS(entitlement_utilisation),
    entitlement_utilisation[support_status] = "expiring_soon"
)

ULAs Expiring in 180 Days =
CALCULATE(
    COUNTROWS(entitlement_utilisation),
    entitlement_utilisation[ula_status] = "ula_expiring"
)

Total Active CSIs =
CALCULATE(
    COUNTROWS(shared_license_entitlements),
    shared_license_entitlements[status] = "active"
)
```

### Discovery health

```dax
Days Since Discovery =
DATEDIFF(MAX(oracle_servers[last_seen]), TODAY(), DAY)

Stale Servers =
CALCULATE(
    COUNTROWS(oracle_servers),
    DATEDIFF(oracle_servers[last_seen], TODAY(), DAY) > 30,
    oracle_servers[is_active] = TRUE()
)
```

---

## Recommended report pages

### Page 1 — Licence position summary
- KPI cards: DB required/owned/surplus, WLS required/owned/surplus
- Stacked bar: Required vs owned by product family
- Donut: Servers by edition (EE vs SE2 vs WLS)
- Slicer: environment, client (admin report only)

### Page 2 — Oracle Database detail
- Matrix: server, environment, edition, sockets, cores, core_factor, licences_required
- Bar chart: top 10 servers by DB licence requirement
- Map: if datacenter column populated — heat map by location

### Page 3 — WebLogic detail
- Matrix: server, domain, wls_edition, managed_server_count, licences_required
- Bar chart: installed products (SOA, OSB, Coherence, etc.) counts
- Table: wls_managed_servers with cluster grouping

### Page 4 — Entitlement register
- Table: all active CSIs with product, quantity, support_expiry, ula_expiry
- Timeline: upcoming support renewals (next 12 months)
- Conditional formatting: red = expired, amber = expiring in 90 days

### Page 5 — Discovery health
- Line chart: successful vs failed discovery runs over time
- Table: last 20 discovery_runs
- Card: stale server count
- Card: days since last full discovery

### Page 6 — Client comparison (admin report only)
- Matrix: client_code × product_family with licences_required and surplus/deficit
- Bar chart: server count by client and environment
- Treemap: total cores discovered by client

---

## Row-level security for multi-tenant report

If you want a single Power BI report shared across all clients where each
client only sees their own data:

```dax
-- RLS rule on oracle_servers (and all tables joined to it)
-- Assumes Azure AD user email maps to client_code in a mapping table

[hostname] IN
CALCULATETABLE(
    VALUES(oracle_servers[hostname]),
    RELATED(client_lookup[client_code]) = LOOKUPVALUE(
        client_lookup[client_code],
        client_lookup[user_email], USERPRINCIPALNAME()
    )
)
```

Simpler approach: publish separate reports per client, each connecting with
their own `sam_reader_<client>` credential. Less RLS complexity, cleaner
Power BI workspace management.
