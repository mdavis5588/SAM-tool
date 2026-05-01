# Oracle SAM — Power BI Setup Guide

## 1. PostgreSQL connection (DirectQuery recommended)

Use the **PostgreSQL connector** built into Power BI Desktop.

| Setting | Value |
|---------|-------|
| Server | `<your-pg-host>:5432` |
| Database | `oracle_sam` |
| Data Connectivity mode | **DirectQuery** (keeps data fresh) |
| Username | `sam_reader` (read-only role — see SQL below) |

Create the read-only role in PostgreSQL first:

```sql
CREATE ROLE sam_reader WITH LOGIN PASSWORD 'changeme';
GRANT USAGE ON SCHEMA sam TO sam_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA sam TO sam_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA sam TO sam_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA sam GRANT SELECT ON TABLES TO sam_reader;
```

## 2. Tables and views to import

Import these objects from the `sam` schema:

| Object | Type | Purpose |
|--------|------|---------|
| `oracle_servers` | Table | Master server list |
| `oracle_processors` | Table | CPU snapshot history |
| `oracle_instances` | Table | Database instance list |
| `oracle_options` | Table | Installed options / packs |
| `license_entitlements` | Table | What you own |
| `core_factor_table` | Table | Oracle Core Factor reference |
| `license_position` | View | Main compliance view |
| `server_summary` | View | Pre-aggregated server card data |
| `discovery_runs` | Table | Audit trail |

## 3. Power BI Data Model — relationships

After import set these relationships (all Many-to-One):

```
oracle_processors.server_id  →  oracle_servers.server_id
oracle_instances.server_id   →  oracle_servers.server_id
oracle_options.instance_id   →  oracle_instances.instance_id
```

`license_position` and `server_summary` are flat views — no joins needed.

## 4. DAX Measures

Paste these into a dedicated **_Measures** table.

### Licence position

```dax
Total Licences Required =
SUMX(
    license_position,
    license_position[licences_required]
)

Total Licences Owned =
SUMX(
    license_entitlements,
    IF(license_entitlements[status] = "active", license_entitlements[quantity], 0)
)

Licence Surplus / Deficit =
[Total Licences Owned] - [Total Licences Required]

Compliance Status =
IF(
    [Licence Surplus / Deficit] >= 0,
    "Compliant",
    "Under-licensed"
)

% Utilisation =
DIVIDE([Total Licences Required], [Total Licences Owned], 0)
```

### Server metrics

```dax
Active Server Count =
CALCULATE(
    COUNTROWS(oracle_servers),
    oracle_servers[is_active] = TRUE()
)

EE Server Count =
CALCULATE(
    DISTINCTCOUNT(oracle_instances[server_id]),
    SEARCH("Enterprise", oracle_instances[edition], 1, 0) > 0
)

SE2 Server Count =
CALCULATE(
    DISTINCTCOUNT(oracle_instances[server_id]),
    SEARCH("Standard Edition 2", oracle_instances[edition], 1, 0) > 0
)

VMware Server Count =
CALCULATE(
    COUNTROWS(oracle_servers),
    oracle_processors[is_vmware] = TRUE()
)

Avg Cores per Server =
AVERAGEX(
    SUMMARIZE(oracle_processors, oracle_processors[server_id], "cores", MAX(oracle_processors[total_physical_cores])),
    [cores]
)
```

### Discovery freshness

```dax
Days Since Last Discovery =
DATEDIFF(
    MAX(oracle_servers[last_seen]),
    TODAY(),
    DAY
)

Stale Servers (>30 days) =
CALCULATE(
    COUNTROWS(oracle_servers),
    DATEDIFF(oracle_servers[last_seen], TODAY(), DAY) > 30
)
```

## 5. Recommended report pages

### Page 1 — Executive licence position
- **KPI cards**: Total Required, Total Owned, Surplus/Deficit, Compliance Status
- **Bar chart**: Licences required by environment (Production / Non-Prod / Dev)
- **Donut chart**: Split by edition (EE vs SE2)
- **Gauge**: % utilisation of licence pool

### Page 2 — Server inventory
- **Matrix / table**: `server_summary` with columns:
  hostname, environment, edition, sockets, cores, core_factor, licences_required, virt_type
- **Slicer**: environment, edition, virt_type, is_active
- **Map visual** (if you add datacenter location columns later)

### Page 3 — Compliance gap detail
- **Table**: `license_position` — one row per server/edition combination
- **Conditional formatting**: Red if `licences_required > 0` and no matching entitlement
- **Bar chart**: Top 10 servers by licence requirement

### Page 4 — Entitlement register
- **Table**: `license_entitlements` — all columns
- **Timeline**: support_expiry / ula_expiry coming up in next 12 months
- **Card**: Total owned by metric type (Processor / NUP / ULA)

### Page 5 — Discovery health
- **Line chart**: hosts_succeeded / hosts_failed per run over time
- **Table**: discovery_runs last 30 runs
- **Card**: Days since last successful full discovery
- **Stale server list**: servers not seen in > 30 days

## 6. Row-level security (optional)

If different teams should only see their environments:

```dax
-- RLS rule on oracle_servers table
[environment] = LOOKUPVALUE(
    user_environments[environment],
    user_environments[email], USERPRINCIPALNAME()
)
```

Create a `user_environments` table mapping Azure AD emails to allowed environments.

## 7. Scheduled refresh

For DirectQuery no scheduled refresh is needed — every visual queries the database live.
If you switch to Import mode, set a refresh schedule in the Power BI Service:
- Recommended: every 6–12 hours (matching your Ansible cron schedule)
- Use an on-premises data gateway if your PostgreSQL server is not internet-accessible
