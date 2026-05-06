# Oracle SAM v2 — Power BI Setup Guide

## Connection strategy

| Model | Who uses it | Role |
|-------|-------------|------|
| Per-client report | Each client sees only their data | `sam_reader_<client>` |
| Admin roll-up report | SAM team — full cross-client view | `sam_reader` |

Both connect to the same `oracle_sam` PostgreSQL database.

---

## Model A — Per-client report

### Connection

```
Server:   <pg-host>:5432
Database: oracle_sam
Schema:   client_acme        (change per client)
Role:     sam_reader_acme
Mode:     DirectQuery
```

Create a client-scoped reader role in PostgreSQL:

```sql
CREATE ROLE sam_reader_acme WITH LOGIN PASSWORD 'changeme';
GRANT USAGE  ON SCHEMA client_acme, shared TO sam_reader_acme;
GRANT SELECT ON ALL TABLES IN SCHEMA client_acme TO sam_reader_acme;
GRANT SELECT ON ALL TABLES IN SCHEMA shared      TO sam_reader_acme;
REVOKE USAGE ON SCHEMA sam_admin FROM sam_reader_acme;
```

### Objects to import — client schema (`client_acme`)

| Object | Type | Description |
|--------|------|-------------|
| `oracle_servers` | Table | Server inventory |
| `oracle_processors` | Table | CPU snapshots |
| `oracle_instances` | Table | Oracle DB instances |
| `oracle_options` | Table | Installed DB options |
| `wls_domains` | Table | WebLogic domains |
| `wls_managed_servers` | Table | WLS managed servers |
| `wls_installed_products` | Table | WLS installed products |
| `license_position` | View | Compliance — required vs owned |
| `license_metric_comparison` | View | Processor vs NUP what-if |
| `server_csi_coverage` | View | Per-server CSI assignment and coverage gaps |
| `changelog_summary` | View | Licence-relevant changes detected between runs |
| `discovery_changelog` | Table | Full change history with acknowledgement state |

### Objects to import — shared schema

| Object | Type | Description |
|--------|------|-------------|
| `csi_contracts` | Table | Contract headers — one per CSI |
| `license_entitlement_lines` | Table | Product lines with quantity and pricing |
| `csi_client_map` | Table | Which clients are assigned to each CSI |
| `csi_contract_summary` | View | Contract totals rolled up from lines |
| `entitlement_line_detail` | View | Per-line pricing detail with cost calculations |
| `entitlements_by_client` | View | Lines filtered and pro-rated for this client |
| `unassigned_licences` | View | CSIs needing admin action |
| `entitlement_utilisation` | View | Alias of csi_contract_summary — for dashboards |
| `core_factor_table` | Table | Oracle processor core factors |

### Relationships in Power BI

**Client schema:**
```
oracle_processors.server_id      → oracle_servers.server_id
oracle_instances.server_id       → oracle_servers.server_id
oracle_options.instance_id       → oracle_instances.instance_id
wls_domains.server_id            → oracle_servers.server_id
wls_managed_servers.domain_id    → wls_domains.domain_id
wls_managed_servers.server_id    → oracle_servers.server_id
wls_installed_products.domain_id → wls_domains.domain_id
```

**Shared schema (entitlement hierarchy):**
```
license_entitlement_lines.csi_id → csi_contracts.csi_id
csi_client_map.csi_id            → csi_contracts.csi_id
```

---

## Model B — Admin roll-up report

### Connection

```
Server:   <pg-host>:5432
Database: oracle_sam
Role:     sam_reader
Mode:     DirectQuery
```

### Additional objects — sam_admin schema

| Object | Type | Description |
|--------|------|-------------|
| `clients` | Table | Client registry |
| `discovery_runs` | Table | Cross-client audit log |

### Additional shared objects

| Object | Description |
|--------|-------------|
| `cross_client_summary` | One row per server across all clients |

Add `sam_admin.clients[client_code]` as a slicer — it filters
`cross_client_summary` and all other views that contain a `client_code` column.

---

## DAX Measures

Paste all measures into a dedicated `_Measures` table.

### Licence position — Oracle Database

```dax
DB Licences Required =
SUMX(
    FILTER(license_position, license_position[product_family] = "oracle_database"),
    license_position[licences_required]
)

DB Licences Owned =
SUMX(
    FILTER(entitlements_by_client,
           entitlements_by_client[product_family] = "oracle_database"),
    entitlements_by_client[client_quantity]
)

DB Surplus / Deficit = [DB Licences Owned] - [DB Licences Required]

DB Compliance = IF([DB Surplus / Deficit] >= 0, "Compliant", "Under-licensed")

DB % Utilisation = DIVIDE([DB Licences Required], [DB Licences Owned], 0)
```

### Licence position — WebLogic

```dax
WLS Licences Required =
SUMX(
    FILTER(license_position, license_position[product_family] = "oracle_weblogic"),
    license_position[licences_required]
)

WLS Licences Owned =
SUMX(
    FILTER(entitlements_by_client,
           entitlements_by_client[product_family] = "oracle_weblogic"),
    entitlements_by_client[client_quantity]
)

WLS Surplus / Deficit = [WLS Licences Owned] - [WLS Licences Required]

WLS Domain Count        = DISTINCTCOUNT(wls_domains[domain_id])
WLS Managed Server Count = DISTINCTCOUNT(wls_managed_servers[managed_server_id])
```

### Cost and pricing (entitlement_line_detail / csi_contract_summary)

```dax
-- Total licence purchase cost across all active CSI lines
Total Licence Cost =
SUMX(
    FILTER(entitlement_line_detail, entitlement_line_detail[contract_status] = "active"),
    COALESCE(entitlement_line_detail[total_price], 0)
)

-- Total annual support cost across all active lines
Total Annual Support Cost =
SUMX(
    FILTER(entitlement_line_detail, entitlement_line_detail[contract_status] = "active"),
    COALESCE(entitlement_line_detail[annual_support_cost], 0)
)

-- Total cost of ownership: licence fees + support
Total Cost of Ownership = [Total Licence Cost] + [Total Annual Support Cost]

-- Average cost per licence seat (weighted across all lines)
Avg Cost per Licence =
DIVIDE(
    [Total Licence Cost],
    SUMX(
        FILTER(entitlement_line_detail, entitlement_line_detail[contract_status] = "active"),
        entitlement_line_detail[quantity]
    ),
    0
)

-- Cost per licence including annual support
Avg Cost per Licence incl Support =
DIVIDE(
    [Total Cost of Ownership],
    SUMX(
        FILTER(entitlement_line_detail, entitlement_line_detail[contract_status] = "active"),
        entitlement_line_detail[quantity]
    ),
    0
)

-- Cost breakdown by product family
DB Licence Cost =
SUMX(
    FILTER(entitlement_line_detail,
           entitlement_line_detail[product_family] = "oracle_database"
        && entitlement_line_detail[contract_status] = "active"),
    COALESCE(entitlement_line_detail[total_price], 0)
)

WLS Licence Cost =
SUMX(
    FILTER(entitlement_line_detail,
           entitlement_line_detail[product_family] = "oracle_weblogic"
        && entitlement_line_detail[contract_status] = "active"),
    COALESCE(entitlement_line_detail[total_price], 0)
)

-- Total contract value (licence + support) for selected CSI
Selected CSI Total Value =
SELECTEDVALUE(csi_contract_summary[total_contract_value])

-- Cost per licence for selected line (drill-through use)
Selected Line Cost per Seat =
SELECTEDVALUE(entitlement_line_detail[unit_price])

Selected Line Cost per Seat incl Support =
SELECTEDVALUE(entitlement_line_detail[cost_per_licence_incl_support])
```

### Licence metric comparison (what-if)

```dax
Total EE Processor Required =
SUMX(
    FILTER(license_metric_comparison,
           license_metric_comparison[product_family] = "oracle_database"),
    license_metric_comparison[processor_licences_ee]
)

Total SE2 Processor Required =
SUMX(
    FILTER(license_metric_comparison,
           license_metric_comparison[product_family] = "oracle_database"),
    license_metric_comparison[processor_licences_se2]
)

Total NUP Minimum EE =
SUMX(
    FILTER(license_metric_comparison,
           license_metric_comparison[product_family] = "oracle_database"),
    license_metric_comparison[nup_minimum_ee]
)

NUP Break-even User Count =
SUMX(
    FILTER(license_metric_comparison,
           license_metric_comparison[product_family] = "oracle_database"),
    license_metric_comparison[nup_break_even_user_count]
)

Selected Server EE Processor Licences =
SELECTEDVALUE(license_metric_comparison[processor_licences_ee])

Selected Server NUP Minimum =
SELECTEDVALUE(license_metric_comparison[nup_minimum_ee])
```

### CSI entitlement health and sharing policy

```dax
Total Active CSIs =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[status] = "active")

CSIs Expiring in 90 Days =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[support_status] = "expiring_soon")

ULAs Expiring in 180 Days =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[ula_status] = "ula_expiring")

CSIs Needing Policy =
CALCULATE(COUNTROWS(unassigned_licences),
          unassigned_licences[allocation_status] = "NEEDS POLICY")

CSIs Needing Assignment =
CALCULATE(COUNTROWS(unassigned_licences),
          unassigned_licences[allocation_status] = "NEEDS ASSIGNMENT")

Action Required CSI Count = [CSIs Needing Policy] + [CSIs Needing Assignment]

Shareable CSI Count =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[sharing_policy] = "shareable")

Client Locked CSI Count =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[sharing_policy] = "client_locked")

Unassigned Policy CSI Count =
CALCULATE(COUNTROWS(csi_contract_summary),
          csi_contract_summary[sharing_policy] = "unassigned")
```

### Server CSI coverage (`server_csi_coverage` view)

```dax
Servers with No CSI Assigned =
CALCULATE(
    DISTINCTCOUNT(server_csi_coverage[server_id]),
    server_csi_coverage[coverage_status] = "NO CSI ASSIGNED"
)

Servers Fully Covered =
CALCULATE(
    DISTINCTCOUNT(server_csi_coverage[server_id]),
    server_csi_coverage[coverage_status] = "COVERED"
)

Servers Under-Assigned =
CALCULATE(
    DISTINCTCOUNT(server_csi_coverage[server_id]),
    server_csi_coverage[coverage_status] = "UNDER-ASSIGNED"
)

-- Total licence gap across all unmapped / under-assigned servers
Total Coverage Gap =
SUMX(server_csi_coverage, server_csi_coverage[coverage_gap])

-- % of servers that have at least one explicit CSI assignment
CSI Coverage % =
DIVIDE(
    CALCULATE(DISTINCTCOUNT(server_csi_coverage[server_id]),
              server_csi_coverage[assigned_csi_count] > 0),
    DISTINCTCOUNT(server_csi_coverage[server_id]),
    0
)

-- Total licence cost assigned to servers (from CSI line prices)
Total Assigned Licence Cost =
SUMX(server_csi_coverage, COALESCE(server_csi_coverage[assigned_licence_cost], 0))

Total Assigned Support Cost =
SUMX(server_csi_coverage, COALESCE(server_csi_coverage[assigned_support_cost], 0))
```

### Discovery health

```dax
Days Since Discovery =
DATEDIFF(MAX(oracle_servers[last_seen]), TODAY(), DAY)

Stale Servers =
CALCULATE(COUNTROWS(oracle_servers),
          DATEDIFF(oracle_servers[last_seen], TODAY(), DAY) > 30,
          oracle_servers[is_active] = TRUE())
```

---

## Recommended report pages

### Page 1 — Licence position summary
- **KPI row**: DB Required / DB Owned / DB Surplus · WLS Required / WLS Owned / WLS Surplus
- **Compliance status cards**: DB Compliance · WLS Compliance (green/red)
- **Stacked bar**: Required vs Owned by product family
- **Donut**: Active servers by edition (EE / SE2 / WLS)
- **Slicer**: environment · client (admin report only)

### Page 2 — Oracle Database detail
Source: `license_position` + `oracle_servers` + `oracle_processors`

- **Matrix**: hostname, environment, edition, cpu_sockets, total_physical_cores, core_factor, licences_required, compliance_status
- **Bar chart**: top 10 servers by licences_required
- **Slicer**: environment, edition, virt_type

### Page 3 — WebLogic detail
Source: `license_position` + `wls_domains` + `wls_managed_servers` + `wls_installed_products`

- **Matrix**: hostname, domain, wls_edition, managed_server_count, licences_required
- **Bar chart**: installed product counts (SOA, OSB, Coherence, OAM, etc.)
- **Table**: `wls_managed_servers` with cluster grouping

### Page 4 — Licence metric comparison (what-if)
Source: `license_metric_comparison`

- **Clustered bar**: per server — EE Processor / SE2 Processor / NUP Minimum side by side
- **Matrix**: hostname, edition, cpu_sockets, cores, core_factor, processor_licences_ee, processor_licences_se2, nup_minimum_ee, nup_minimum_se2, current_metric, current_metric_licences
  - Conditional formatting: green on the lowest column per row
- **KPI card**: NUP Break-even User Count fleet-wide
- **Slicer**: product_family, environment, virt_type
- **Drill-through**: click any server → full processor and instance detail

> NUP minimums are Oracle's floor per server. Actual NUP count must also
> cover every named user who can access the database, whichever is higher.

### Page 5 — CSI contract register
Source: `csi_contract_summary`

- **KPI row**: Total Active CSIs · Total Licence Cost · Total Annual Support · Total CoO
- **Main table**:

  | Column | Notes |
  |--------|-------|
  | `csi_number` | |
  | `contract_name` | |
  | `sharing_policy` | Badge: blue = shareable · orange = client_locked · grey = unassigned |
  | `owning_client` | |
  | `assigned_clients` | Comma-separated list |
  | `line_count` | Number of product lines in this CSI |
  | `product_summary` | Pipe-separated product names |
  | `total_licences` | Sum of all line quantities |
  | `total_licence_cost` | Sum of all line total_price |
  | `total_annual_support` | |
  | `total_contract_value` | Licence + support |
  | `support_expiry` | Conditional: red = expired · amber = <90 days |
  | `allocation_status` | Conditional: red = NEEDS POLICY/ASSIGNMENT · green = ASSIGNED |

- **Slicer**: sharing_policy · status · product_families · allocation_status
- **Timeline**: support_expiry and ula_expiry for next 18 months

### Page 6 — CSI line item pricing
Source: `entitlement_line_detail`

- **KPI row**: Total Licence Cost · Total Annual Support · Avg Cost per Licence · Avg Cost per Licence incl Support
- **Stacked bar**: Licence cost by product_family
- **Main table**:

  | Column | Notes |
  |--------|-------|
  | `csi_number` | |
  | `contract_name` | |
  | `owning_client` | |
  | `line_number` | |
  | `product_name` | |
  | `product_family` | |
  | `license_metric` | |
  | `quantity` | Licences purchased |
  | `unit_price` | Price per licence seat |
  | `total_price` | quantity × unit_price |
  | `annual_support_cost` | |
  | `total_line_cost` | Licence + support |
  | `cost_per_licence_incl_support` | Useful for benchmarking vs renewals |

- **Slicer**: product_family · contract_name · owning_client
- **Drill-through from Page 5**: clicking a CSI row goes here, pre-filtered to that contract

### Page 7 — Unassigned / action-required licences
Source: `unassigned_licences`

- **Banner KPI**: Action Required CSI Count — red card, should be zero
- **Table**: csi_number, contract_name, sharing_policy, owning_client_name, assigned_client_count, allocation_status, total_licences, total_contract_value, support_expiry
  - Conditional formatting: NEEDS POLICY = red · NEEDS ASSIGNMENT = amber
- **Bar**: unallocated licence quantity by product_family
- **Text cards** with SQL snippets to resolve each allocation_status:

  ```
  NEEDS POLICY:
    SELECT shared.set_csi_owner(<csi_id>, 'client_code', p_lock => TRUE);
    -- or for shareable:
    UPDATE shared.csi_contracts SET sharing_policy = 'shareable' WHERE csi_id = <csi_id>;

  NEEDS ASSIGNMENT:
    SELECT shared.assign_csi_to_client(<csi_id>, 'client_code', 'shareable', <qty>);
  ```

> This page should be empty in a well-managed estate.

### Page 8 — Entitlement expiry timeline
Source: `csi_contract_summary`

- **Gantt / timeline visual**: one bar per CSI from support_start to support_expiry
- **Table**: CSIs expiring within 12 months — csi_number, contract_name, owning_client, support_expiry, total_annual_support, total_contract_value
- **KPI**: CSIs Expiring in 90 Days · ULAs Expiring in 180 Days
- **Slicer**: owning_client · product_families

### Discovery changelog (`changelog_summary` / `discovery_changelog`)

```dax
-- Unacknowledged changes total
Unacknowledged Changes =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[acknowledged] = FALSE()
)

-- HIGH severity unacknowledged — the most important KPI
High Severity Unacknowledged =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[acknowledged] = FALSE(),
    changelog_summary[severity] = "HIGH"
)

-- Overdue HIGH changes (unacknowledged for more than 48 hours)
Overdue Changes =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[overdue] = TRUE()
)

-- New options detected this week
New Options This Week =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[change_category] = "oracle_option",
    changelog_summary[change_type] = "NEW",
    changelog_summary[detected_at] >= TODAY() - 7
)

-- New instances detected this week
New Instances This Week =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[change_category] = "oracle_instance",
    changelog_summary[change_type] = "NEW",
    changelog_summary[detected_at] >= TODAY() - 7
)

-- Core count increases (always HIGH)
Core Count Increases =
CALCULATE(
    COUNTROWS(changelog_summary),
    changelog_summary[change_category] = "processor",
    changelog_summary[field_changed] = "total_physical_cores"
)

-- Changes by category (for donut chart)
Changes by Category =
COUNTROWS(DISTINCT(changelog_summary[change_category]))
```

### Page 10 — Discovery changelog (change detection)
Source: `changelog_summary` + `discovery_changelog`

- **Alert banner** (top of page): `High Severity Unacknowledged` in red — links to the HIGH filter below. Should be zero between discovery cycles.
- **KPI row**: Unacknowledged Changes · High Severity Unacknowledged · Overdue Changes · New Options This Week · Core Count Increases
- **Main table** (unacknowledged changes, sorted HIGH first):

  | Column | Notes |
  |--------|-------|
  | `severity` | Badge: 🔴 HIGH · 🟠 MEDIUM · 🔵 INFO |
  | `detected_at` | |
  | `hostname` | |
  | `change_category` | oracle_option / oracle_instance / processor / wls_domain / wls_product |
  | `change_type` | NEW / CHANGED / REMOVED |
  | `object_name` | e.g. `PROD01 → Oracle Diagnostic Pack` |
  | `field_changed` | Which field changed (for CHANGED rows) |
  | `old_value` | |
  | `new_value` | |
  | `licence_impact` | Plain-English description of the licence implication |
  | `overdue` | Flag if HIGH and >48h unacknowledged |
  | `discovery_run_id` | Which Ansible run detected this |

  Conditional formatting:
  - Row background red: severity = HIGH and acknowledged = FALSE
  - Row background amber: severity = MEDIUM and acknowledged = FALSE
  - Row background green: acknowledged = TRUE

- **Acknowledged history table** (secondary, collapsed by default): same columns, filtered to acknowledged = TRUE, last 90 days
- **Bar chart**: change count per discovery run — shows when activity spikes
- **Donut chart**: unacknowledged changes by change_category
- **Slicer**: severity · change_category · hostname · acknowledged · date range

> **Workflow**: When a HIGH change appears, the SAM analyst should review
> the `licence_impact` text, update `server_csi_map` or the entitlement
> register as needed, then mark the change acknowledged. Use this SQL:
>
> ```sql
> UPDATE client_acme.discovery_changelog
> SET    acknowledged    = TRUE,
>        acknowledged_by = 'your.name',
>        acknowledged_at = NOW(),
>        notes           = 'Diagnostic Pack confirmed in use — added to CSI 11111111 line 2'
> WHERE  change_id = <id>;
> ```

### Page 11 — Server CSI coverage (audit prep)
Source: `server_csi_coverage`

- **KPI row**: Servers with No CSI Assigned (red if > 0) · Servers Under-Assigned · Servers Fully Covered · CSI Coverage % · Total Coverage Gap
- **Main table**:

  | Column | Notes |
  |--------|-------|
  | `hostname` | |
  | `environment` | |
  | `product_family` | oracle_database / oracle_weblogic |
  | `product_detail` | Edition |
  | `cpu_sockets` | |
  | `total_physical_cores` | |
  | `core_factor` | |
  | `licences_required` | Calculated from topology |
  | `assigned_csi_count` | How many CSIs cover this server+product |
  | `assigned_csis` | Newline-separated CSI number + contract name |
  | `total_licences_assigned` | Sum from all assigned CSIs |
  | `coverage_gap` | Shortfall licences — 0 = fully covered |
  | `coverage_status` | Key column — see conditional formatting below |
  | `assigned_licence_cost` | Cost from assigned CSI lines |

  Conditional formatting on `coverage_status`:
  - 🔴 Red: `NO CSI ASSIGNED`
  - 🟠 Amber: `UNDER-ASSIGNED`
  - 🟡 Yellow: `ASSIGNED — QUANTITY UNCONFIRMED`
  - 🟢 Green: `COVERED`

- **Donut chart**: Server count by coverage_status
- **Bar chart**: coverage_gap by hostname (shows which servers have the largest shortfall)
- **Slicer**: product_family · environment · coverage_status · datacenter
- **Drill-through**: click a server → Page 2 (DB detail) or Page 3 (WLS detail)

> This page is the primary output for an Oracle LMS audit. Every row with
> `coverage_status = NO CSI ASSIGNED` is a server you cannot demonstrate
> licence coverage for. Aim for all rows to show `COVERED`.

### Page 12 — Discovery health
- **Line chart**: hosts_succeeded vs hosts_failed per discovery run over time
- **Table**: last 20 discovery_runs — run_id, product, started_at, hosts_targeted, hosts_succeeded, hosts_failed
- **KPI cards**: Stale Servers · Days Since Discovery

### Page 13 — Client comparison (admin report only)
Source: `cross_client_summary` + `csi_contract_summary`

- **Matrix**: client_code × product_family — licences_required and surplus/deficit
- **Bar**: server count per client per environment
- **Bar**: total_contract_value per owning_client
- **Treemap**: total cores discovered by client

---

## Row-level security (multi-tenant single report)

```dax
-- RLS filter on oracle_servers
[hostname] IN
CALCULATETABLE(
    VALUES(oracle_servers[hostname]),
    RELATED(client_lookup[client_code]) = LOOKUPVALUE(
        client_lookup[client_code],
        client_lookup[user_email], USERPRINCIPALNAME()
    )
)
```

Simpler alternative: publish one report per client, each using a
`sam_reader_<client>` credential. No RLS complexity, natural workspace separation.
