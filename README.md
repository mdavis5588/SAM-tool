# Oracle SAM Tool

Software Asset Management for Oracle databases — automated discovery via Ansible, storage in PostgreSQL, visualisation in Power BI.

## Architecture

```
Oracle Servers  →  Ansible Discovery  →  PostgreSQL  →  Power BI
                   (playbooks/)           (database/)    (powerbi/)
```

## Quick start

### 1. PostgreSQL — initialise the database

```bash
createdb oracle_sam
psql oracle_sam < database/schema/01_schema.sql
```

### 2. Ansible — configure inventory and run discovery

```bash
# Edit inventory with your Oracle server hostnames
vim ansible/inventory/hosts.yml

# Set database credentials
export SAM_DB_HOST=localhost
export SAM_DB_PASSWORD=yourpassword

# Install Ansible collections
ansible-galaxy collection install -r ansible/requirements.yml

# Run discovery (dry-run with --check first)
ansible-playbook ansible/playbooks/discover_oracle.yml \
  -i ansible/inventory/hosts.yml \
  --check

# Full discovery run
ansible-playbook ansible/playbooks/discover_oracle.yml \
  -i ansible/inventory/hosts.yml
```

### 3. Load licence entitlements (manual)

```sql
INSERT INTO sam.license_entitlements
  (csi_number, product_name, license_metric, quantity, purchase_date, support_expiry)
VALUES
  ('12345678', 'Oracle Database Enterprise Edition', 'processor', 100, '2022-01-01', '2026-01-01'),
  ('12345679', 'Oracle Database Standard Edition 2', 'processor', 20,  '2023-06-01', '2025-06-01');
```

Or import from CSV using `\copy` in psql.

### 4. Power BI

Follow `powerbi/POWERBI_SETUP.md`. Connect to PostgreSQL with the `sam_reader` role and import the views listed there.

## Licence calculation rules implemented

| Edition | Calculation | Notes |
|---------|-------------|-------|
| Enterprise Edition | Physical cores × Core Factor | Core Factor from Oracle's published table |
| Standard Edition 2 | MIN(cpu_sockets, 2) | Maximum 2 processor licences per server |
| Standard Edition | cpu_sockets | One licence per occupied socket |

The `sam.core_factor_table` contains Oracle's published factors. Key values:
- Intel Xeon / AMD EPYC / AMD Opteron: **0.5**
- Oracle SPARC T-series: **0.25**
- Oracle SPARC M-series: **0.5**
- IBM POWER: **1.0**

Always verify against the current Oracle Processor Core Factor Table PDF on oracle.com.

## Scheduling discovery

Add a cron entry on your Ansible control node:

```cron
# Run Oracle SAM discovery every day at 02:00
0 2 * * * cd /opt/oracle-sam && ansible-playbook ansible/playbooks/discover_oracle.yml \
  -i ansible/inventory/hosts.yml >> /var/log/oracle-sam/discovery.log 2>&1
```

## Project structure

```
oracle-sam/
├── ansible/
│   ├── inventory/
│   │   └── hosts.yml          # Your Oracle server inventory
│   ├── playbooks/
│   │   └── discover_oracle.yml # Main discovery playbook
│   └── requirements.yml        # Ansible Galaxy collections
├── database/
│   └── schema/
│       └── 01_schema.sql       # Full PostgreSQL schema + views + functions
├── powerbi/
│   └── POWERBI_SETUP.md        # Power BI connection and DAX guide
└── README.md
```

## Extending to other products

The schema is designed to extend. Future tables to add:
- `oracle_java_servers` — Java SE discovery
- `oracle_middleware` — WebLogic, SOA Suite
- `vmware_vsphere` — vSphere inventory for VSPP licence tracking
- `ms_sql_servers` — SQL Server SAM alongside Oracle
