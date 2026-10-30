-- ===========================================================================
-- Sample data — Operating System licensing
-- ===========================================================================
-- Run AFTER sample_data.sql, sample_data_globex.sql and sample_data_weblogic.sql,
-- and after migration 47 (the OS tables) and 48 (the rule patterns).
--
--   psql $DSN -f database/sample_data_os.sql
--
-- Safe to re-run: every insert is keyed on hostname and skips what is already
-- there, so it will not duplicate rows.
--
-- Part 1 gives every EXISTING server an OS record, derived from the columns
-- those rows already carry. os_family / os_distribution / os_version are
-- already on servers, and the socket and core counts are taken from
-- oracle_processors where one exists, so gbx-analytics-01 comes out as Oracle
-- Linux 8.8 on its real 2 x 16 hardware rather than something invented that
-- contradicts the Oracle data.
--
-- Part 2 adds hosts that run NO Oracle at all — SUSE boxes, a VMware cluster
-- with Linux guests, and one unrecognised distribution. These are the cases
-- the OS layer exists for and that the Oracle sample data cannot show: a host
-- with no oracle_processors row still has to be counted, and a host whose
-- distribution matches no rule has to be visibly unknown rather than silently
-- free.
--
-- Part 3 adds subscription contracts, lines and assignments, so the licence
-- summary shows a real position — some covered, some short — instead of every
-- row reading "unassigned".
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- PART 1 — OS records for the servers that already exist
-- ---------------------------------------------------------------------------
-- Vendor is derived from the distribution string the server row already holds.
-- Sockets and cores come from oracle_processors when present; a host with no
-- processor row falls back to a modest 2 x 8, which is also what OS discovery
-- would report for a mid-size VM.
--
-- Guests: any server whose processor row says vmware is treated as a virtual
-- guest, which is what it is. Part 2 then gives those guests a hypervisor to
-- hang off, so the Virtual Datacenter case has something to cover.

DO $OSSEED$
DECLARE
  v_schema TEXT;
BEGIN
  FOREACH v_schema IN ARRAY ARRAY['client_acme', 'client_globex']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'os_installations') THEN
      RAISE NOTICE '% : no os_installations table — run migration 47 first; skipping',
        v_schema;
      CONTINUE;
    END IF;

    EXECUTE format($sql$
      INSERT INTO %1$I.os_installations
        (server_id, vendor, distribution, os_version, kernel_version, architecture,
         cpu_sockets, cores_per_socket, vcpu_count, total_ram_mb,
         is_virtual_guest, hypervisor_type,
         subscription_state, support_level, vendor_system_id, last_discovery_run)
      SELECT
        s.server_id,
        CASE
          WHEN s.os_distribution ILIKE '%%Red Hat%%'     THEN 'redhat'
          WHEN s.os_distribution ILIKE '%%Oracle Linux%%' THEN 'oracle_linux'
          WHEN s.os_distribution ILIKE '%%SUSE%%'
            OR s.os_distribution ILIKE '%%SLES%%'         THEN 'suse'
          ELSE 'other'
        END,
        s.os_distribution,
        s.os_version,
        -- A plausible kernel for the major version, so the column is not empty.
        CASE
          WHEN s.os_version LIKE '9%%' THEN '5.14.0-427.el9.x86_64'
          WHEN s.os_version LIKE '8%%' THEN '4.18.0-513.el8.x86_64'
          WHEN s.os_version LIKE '7%%' THEN '3.10.0-1160.el7.x86_64'
          ELSE '3.10.0-1160.el6.x86_64'
        END,
        'x86_64',
        COALESCE(p.cpu_sockets, 2),
        COALESCE(p.cores_per_socket, 8),
        p.vcpu_count,
        s.total_ram_mb,
        COALESCE(p.is_vmware, FALSE),
        CASE WHEN p.is_vmware THEN 'vmware' ELSE NULL END,
        -- Production and DR are registered; lower environments are a mix, which
        -- is what an unmanaged estate actually looks like.
        CASE
          WHEN s.environment::TEXT IN ('production', 'dr') THEN 'subscribed'
          WHEN s.environment::TEXT = 'development'          THEN 'unsubscribed'
          ELSE 'subscribed'
        END,
        CASE
          WHEN s.environment::TEXT IN ('production', 'dr') THEN 'premium'
          ELSE 'standard'
        END,
        -- Stand-in for an RHSM UUID / SCC registration.
        'SYS-' || UPPER(SUBSTR(MD5(s.hostname), 1, 12)),
        'sample-os-seed'
      FROM   %1$I.servers s
      LEFT   JOIN LATERAL (
        SELECT op.cpu_sockets, op.cores_per_socket, op.vcpu_count, op.is_vmware
        FROM   %1$I.oracle_processors op
        WHERE  op.server_id = s.server_id
        ORDER  BY op.recorded_at DESC
        LIMIT  1
      ) p ON TRUE
      WHERE  s.is_active
        AND  NOT EXISTS (SELECT 1 FROM %1$I.os_installations oi
                         WHERE oi.server_id = s.server_id)
    $sql$, v_schema);

    RAISE NOTICE '% : OS records created for existing servers', v_schema;
  END LOOP;
END
$OSSEED$;


-- ---------------------------------------------------------------------------
-- PART 2 — hosts that run no Oracle
-- ---------------------------------------------------------------------------
-- These have no oracle_instances and no oracle_processors row. They exist only
-- in the OS layer, and are the reason the server table was renamed from
-- oracle_servers: a RHEL or SUSE box with nothing Oracle on it is still a host
-- this tool has to account for.

-- Acme: two SUSE application servers, a VMware cluster host, two RHEL guests
-- on it, and one appliance running something unrecognised.
INSERT INTO client_acme.servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
SELECT v.hostname, v.fqdn, v.ip::INET, v.fam, v.dist, v.ver,
       v.env::client_acme.environment_type, v.crit, v.ram, v.dc, TRUE, NOW()
FROM (VALUES
  ('sap-app-01',   'sap-app-01.acme.internal',   '10.0.7.11', 'Linux',
   'SUSE Linux Enterprise Server', '15 SP5', 'production',  'HIGH',   262144, 'LON-DC1'),
  ('sap-app-02',   'sap-app-02.acme.internal',   '10.0.7.12', 'Linux',
   'SUSE Linux Enterprise Server', '15 SP5', 'production',  'HIGH',   262144, 'LON-DC1'),
  ('esx-lon-01',   'esx-lon-01.acme.internal',   '10.0.8.11', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'production',  'HIGH',   524288, 'LON-DC1'),
  ('app-web-01',   'app-web-01.acme.internal',   '10.0.8.21', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'production',  'MEDIUM',  16384, 'LON-DC1'),
  ('app-web-02',   'app-web-02.acme.internal',   '10.0.8.22', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'production',  'MEDIUM',  16384, 'LON-DC1'),
  ('build-ci-01',  'build-ci-01.acme.internal',  '10.0.9.11', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'development', 'LOW',     32768, 'LON-DC1'),
  ('appliance-01', 'appliance-01.acme.internal', '10.0.9.21', 'Linux',
   'Debian GNU/Linux',             '12',     'production',  'LOW',      8192, 'LON-DC1')
) AS v(hostname, fqdn, ip, fam, dist, ver, env, crit, ram, dc)
WHERE NOT EXISTS (
  SELECT 1 FROM client_acme.servers s WHERE s.hostname = v.hostname
);

-- Globex: a SUSE pair and a VMware host with one guest.
INSERT INTO client_globex.servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
SELECT v.hostname, v.fqdn, v.ip::INET, v.fam, v.dist, v.ver,
       v.env::client_globex.environment_type, v.crit, v.ram, v.dc, TRUE, NOW()
FROM (VALUES
  ('gbx-sap-01',   'gbx-sap-01.globex.internal',   '10.1.7.11', 'Linux',
   'SUSE Linux Enterprise Server', '15 SP5', 'production', 'HIGH',   131072, 'NYC-DC1'),
  ('gbx-esx-01',   'gbx-esx-01.globex.internal',   '10.1.8.11', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'production', 'HIGH',   393216, 'NYC-DC1'),
  ('gbx-web-01',   'gbx-web-01.globex.internal',   '10.1.8.21', 'Linux',
   'Red Hat Enterprise Linux',     '9.4',    'production', 'MEDIUM',  16384, 'NYC-DC1')
) AS v(hostname, fqdn, ip, fam, dist, ver, env, crit, ram, dc)
WHERE NOT EXISTS (
  SELECT 1 FROM client_globex.servers s WHERE s.hostname = v.hostname
);

-- OS records for the non-Oracle hosts, with the socket counts that drive the
-- count: the SUSE boxes are 4-socket, so they need more than one
-- physical_server subscription; esx-lon-01 is a 2-socket hypervisor.
DO $OSSEED2$
DECLARE
  v_schema TEXT;
BEGIN
  FOREACH v_schema IN ARRAY ARRAY['client_acme', 'client_globex']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'os_installations') THEN
      CONTINUE;
    END IF;

    EXECUTE format($sql$
      INSERT INTO %1$I.os_installations
        (server_id, vendor, distribution, os_version, kernel_version, architecture,
         cpu_sockets, cores_per_socket, vcpu_count, total_ram_mb,
         is_virtual_guest, hypervisor_type, hypervisor_hostname,
         subscription_state, support_level, vendor_system_id,
         is_exempt, exempt_reason, notes, last_discovery_run)
      SELECT s.server_id, v.vendor, v.dist, v.ver, v.kernel, 'x86_64',
             v.sockets, v.cores, v.vcpu, s.total_ram_mb,
             v.guest, v.hv_type, v.hv_host,
             v.state, v.level,
             'SYS-' || UPPER(SUBSTR(MD5(s.hostname), 1, 12)),
             v.exempt, v.exempt_why, v.notes, 'sample-os-seed'
      FROM   %1$I.servers s
      JOIN (VALUES
        -- Acme
        ('sap-app-01',   'suse',         'SUSE Linux Enterprise Server', '15 SP5',
         '5.14.21-150500.55', 4, 16, NULL::INTEGER, FALSE, NULL, NULL,
         'subscribed',   'priority', FALSE, NULL,
         'SAP HANA application tier. No Oracle on this host.'),
        ('sap-app-02',   'suse',         'SUSE Linux Enterprise Server', '15 SP5',
         '5.14.21-150500.55', 4, 16, NULL,          FALSE, NULL, NULL,
         'unsubscribed', 'priority', FALSE, NULL,
         'Registered in SCC but the subscription lapsed — deliberately shown as a gap.'),
        ('esx-lon-01',   'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 2, 24, NULL,      FALSE, NULL, NULL,
         'subscribed',   'premium',  FALSE, NULL,
         'Virtualisation host. Carries the Virtual Datacenter subscription that '
         'covers its guests.'),
        ('app-web-01',   'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 1,  4, 4,         TRUE,  'vmware', 'esx-lon-01',
         'subscribed',   'standard', FALSE, NULL,
         'Guest on esx-lon-01 — covered by the host subscription.'),
        ('app-web-02',   'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 1,  4, 4,         TRUE,  'vmware', 'esx-lon-01',
         'subscribed',   'standard', FALSE, NULL,
         'Guest on esx-lon-01 — covered by the host subscription.'),
        ('build-ci-01',  'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 2,  8, NULL,      FALSE, NULL, NULL,
         'unsubscribed', 'self_support', TRUE,
         'No-cost Red Hat Developer subscription',
         'CI build farm. Exempt, so it requires nothing, but the reason is on record.'),
        ('appliance-01', 'other',        'Debian GNU/Linux',             '12',
         '6.1.0-18-amd64',        2,  8, NULL,      FALSE, NULL, NULL,
         'unknown',      NULL,       FALSE, NULL,
         'Vendor appliance. No counting rule matches, so the requirement is '
         'unknown rather than zero.'),
        -- Globex
        ('gbx-sap-01',   'suse',         'SUSE Linux Enterprise Server', '15 SP5',
         '5.14.21-150500.55', 2, 16, NULL,          FALSE, NULL, NULL,
         'subscribed',   'priority', FALSE, NULL,
         'SAP application tier. No Oracle on this host.'),
        ('gbx-esx-01',   'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 2, 20, NULL,      FALSE, NULL, NULL,
         'subscribed',   'premium',  FALSE, NULL,
         'Virtualisation host — deliberately left WITHOUT a Virtual Datacenter '
         'subscription, so its guest is counted on its own.'),
        ('gbx-web-01',   'redhat',       'Red Hat Enterprise Linux',     '9.4',
         '5.14.0-427.el9.x86_64', 1,  4, 4,         TRUE,  'vmware', 'gbx-esx-01',
         'subscribed',   'standard', FALSE, NULL,
         'Guest on an uncovered host — needs its own per-guest subscription.')
      ) AS v(hostname, vendor, dist, ver, kernel, sockets, cores, vcpu,
             guest, hv_type, hv_host, state, level, exempt, exempt_why, notes)
        ON v.hostname = s.hostname
      WHERE NOT EXISTS (SELECT 1 FROM %1$I.os_installations oi
                        WHERE oi.server_id = s.server_id)
    $sql$, v_schema);

    -- Resolve the hypervisor hostname to a server_id. Done as a second step
    -- because the host and its guests are inserted in the same statement, so
    -- the host's server_id is not available while the guest row is written.
    EXECUTE format($sql$
      UPDATE %1$I.os_installations oi
      SET    hypervisor_server_id = h.server_id
      FROM   %1$I.servers h
      WHERE  h.hostname = oi.hypervisor_hostname
        AND  oi.hypervisor_server_id IS NULL
        AND  oi.hypervisor_hostname IS NOT NULL
    $sql$, v_schema);
  END LOOP;
END
$OSSEED2$;


-- ---------------------------------------------------------------------------
-- PART 3 — contracts, lines and assignments
-- ---------------------------------------------------------------------------
-- Deliberately not complete coverage. The point of a licence summary is to show
-- a position, so Red Hat is roughly covered, Oracle Linux is short, and the
-- lapsed SUSE host has no assignment at all.

INSERT INTO shared.os_contracts
  (vendor, agreement_number, contract_name, purchase_date, support_start,
   support_expiry, auto_renew, currency, sharing_policy, po_number, notes)
SELECT v.vendor::shared.os_vendor, v.agreement, v.name,
       v.purchased::DATE, v.starts::DATE, v.expires::DATE,
       v.renew, 'USD', v.policy::shared.os_sharing_policy, v.po, v.notes
FROM (VALUES
  ('redhat', 'RH-4471902', 'Red Hat Enterprise Linux — Server, Premium',
   '2025-11-15', '2026-01-01', '2027-12-31', TRUE,  'shareable', 'PO-2026-0144',
   'Socket-pair subscriptions for the physical estate.'),
  ('redhat', 'RH-4471903', 'Red Hat Virtual Datacenter — Premium',
   '2025-11-15', '2026-01-01', '2027-12-31', TRUE,  'shareable', 'PO-2026-0144',
   'Covers unlimited RHEL guests on the hosts it is assigned to.'),
  ('oracle_linux', '28471055', 'Oracle Linux Premier Support',
   '2025-09-01', '2025-10-01', '2026-09-30', FALSE, 'shareable', 'PO-2025-0981',
   'Deliberately both under-bought AND out of support in this sample: the '
   'quantity is below what the estate needs, and the expiry has passed, so the '
   'hosts assigned to it report coverage_status = contract_expired rather '
   'than assigned. Shift support_expiry forward if you want a clean position.'),
  ('suse', 'SUSE-8820114', 'SUSE Linux Enterprise Server — Priority',
   '2026-01-20', '2026-02-01', '2027-01-31', TRUE,  'shareable', 'PO-2026-0210',
   'Covers the SAP application tier.')
) AS v(vendor, agreement, name, purchased, starts, expires, renew, policy, po, notes)
WHERE NOT EXISTS (
  SELECT 1 FROM shared.os_contracts c
  WHERE c.vendor = v.vendor::shared.os_vendor AND c.agreement_number = v.agreement
);

INSERT INTO shared.os_entitlement_lines
  (os_contract_id, line_number, sku, product_name, license_metric,
   support_level, quantity, unit_price, annual_cost, term_start, term_end, notes)
SELECT c.os_contract_id, v.line, v.sku, v.product,
       v.metric::shared.os_license_metric, v.level::shared.os_support_level,
       v.qty, v.price, v.annual, c.support_start, c.support_expiry, v.notes
FROM (VALUES
  ('RH-4471902', 1, 'RH00003',  'Red Hat Enterprise Linux Server, Premium (1-2 sockets)',
   'socket_pair',        'premium',  20, 1299.00, 25980.00,
   'One per pair of populated sockets.'),
  ('RH-4471903', 1, 'RH00284',  'Red Hat Enterprise Linux Virtual Datacenter, Premium',
   'virtual_datacenter', 'premium',   4, 2499.00,  9996.00,
   'One per hypervisor host; guests on that host need nothing.'),
  ('28471055',   1, 'B88301',   'Oracle Linux Premier Limited (1-2 sockets)',
   'physical_server',    'premier',   8, 1399.00, 11192.00,
   'Fewer than the estate needs — the gap is intentional.'),
  ('SUSE-8820114', 1, '874-0057', 'SUSE Linux Enterprise Server, 1-2 Sockets, Priority',
   'physical_server',    'priority',  2,  799.00,  1598.00,
   'Covers one 4-socket host as two subscriptions.')
) AS v(agreement, line, sku, product, metric, level, qty, price, annual, notes)
JOIN shared.os_contracts c ON c.agreement_number = v.agreement
WHERE NOT EXISTS (
  SELECT 1 FROM shared.os_entitlement_lines l
  WHERE l.os_contract_id = c.os_contract_id AND l.line_number = v.line
);

-- Let both sample clients draw on every sample contract.
INSERT INTO shared.os_contract_client_map (os_contract_id, client_id)
SELECT c.os_contract_id, cl.client_id
FROM   shared.os_contracts c
CROSS  JOIN sam_admin.clients cl
WHERE  c.agreement_number IN ('RH-4471902', 'RH-4471903', '28471055', 'SUSE-8820114')
  AND  cl.client_code IN ('acme', 'globex')
  AND  c.sharing_policy <> 'unassigned'
ON CONFLICT (os_contract_id, client_id) DO NOTHING;

-- Assignments. Chosen to produce a readable mixture rather than full coverage:
--   esx-lon-01   Virtual Datacenter — its two guests then need nothing
--   sap-app-01   SUSE — covered;  sap-app-02 left unassigned (lapsed)
--   gbx-esx-01   deliberately NOT given Virtual Datacenter, so gbx-web-01 is
--                counted as a guest in its own right
--   the Oracle Linux contract has expired, so the hosts on it show
--   contract_expired — that state is worth seeing at least once
DO $OSASSIGN$
DECLARE
  v_schema TEXT;
BEGIN
  FOREACH v_schema IN ARRAY ARRAY['client_acme', 'client_globex']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'os_subscription_map') THEN
      CONTINUE;
    END IF;

    EXECUTE format($sql$
      INSERT INTO %1$I.os_subscription_map
        (server_id, os_contract_id, os_line_id, subscriptions_consumed,
         effective_date, notes, assigned_by)
      SELECT s.server_id, c.os_contract_id, l.os_line_id, v.consumed,
             COALESCE(c.support_start, CURRENT_DATE), v.notes, 'sample-os-seed'
      FROM (VALUES
        ('esx-lon-01', 'RH-4471903', 1::NUMERIC,
         'Virtual Datacenter on the hypervisor; covers app-web-01 and app-web-02.'),
        ('db-prod-01', 'RH-4471902', 1,
         'Two sockets — one socket-pair subscription.'),
        ('db-prod-02', 'RH-4471902', 1,
         'Two sockets — one socket-pair subscription.'),
        ('db-dr-01',   'RH-4471902', 1, 'DR host.'),
        ('sap-app-01', 'SUSE-8820114', 2,
         'Four sockets — two subscriptions at the 1-2 socket band.'),
        ('db-prod-03', '28471055',   1, 'Oracle Linux, 2 sockets.'),
        ('db-prod-04', '28471055',   1, 'Oracle Linux, 2 sockets.'),
        ('gbx-prod-01','RH-4471902', 1, 'Globex production.'),
        ('gbx-prod-03','28471055',   1, 'Globex Oracle Linux.'),
        ('gbx-sap-01', 'SUSE-8820114', 1,
         'Two sockets — one subscription.')
      ) AS v(hostname, agreement, consumed, notes)
      JOIN   %1$I.servers s        ON s.hostname = v.hostname
      JOIN   shared.os_contracts c ON c.agreement_number = v.agreement
      LEFT   JOIN shared.os_entitlement_lines l
             ON l.os_contract_id = c.os_contract_id AND l.line_number = 1
      WHERE  NOT EXISTS (
               SELECT 1 FROM %1$I.os_subscription_map m
               WHERE  m.server_id      = s.server_id
                 AND  m.os_contract_id = c.os_contract_id
                 AND  COALESCE(m.os_line_id, -1) = COALESCE(l.os_line_id, -1))
    $sql$, v_schema);
  END LOOP;
END
$OSASSIGN$;


-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- Expect a mixture: assigned, covered_by_host, unassigned, exempt and one
-- no_rule (appliance-01). A requirement of NULL appears only for no_rule.
SELECT 'client_acme' AS schema, coverage_status, COUNT(*) AS hosts,
       SUM(COALESCE(subscriptions_required, 0)) AS required
FROM   client_acme.os_license_position
GROUP  BY coverage_status
UNION ALL
SELECT 'client_globex', coverage_status, COUNT(*),
       SUM(COALESCE(subscriptions_required, 0))
FROM   client_globex.os_license_position
GROUP  BY coverage_status
ORDER  BY 1, 2;
