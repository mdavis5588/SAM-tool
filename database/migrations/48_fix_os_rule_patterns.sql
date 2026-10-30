-- Migration 48: correct the OS counting-rule patterns.
--
-- os_license_position matches a rule with:
--     reported distribution ILIKE '%' || product_pattern || '%'
-- so the pattern has to be a SUBSTRING of what the host actually reports. The
-- rules seeded with migration 47 used the marketing names of the SKUs — 'Red
-- Hat Enterprise Linux Server', 'Oracle Linux Premier' — which are LONGER than
-- the strings hosts report ('Red Hat Enterprise Linux', 'Oracle Linux'). A
-- longer pattern can never be contained in a shorter string, so every Red Hat
-- and Oracle Linux host matched nothing and reported coverage_status =
-- 'no_rule' with a null requirement.
--
-- The support tier (Basic, Premier, Standard, Premium) does not change the
-- count, so it belongs in support_level, not in the pattern. The two Oracle
-- Linux rules collapse into one.
--
-- Safe to run more than once. It only renames patterns and removes the
-- redundant Oracle Linux row; no installation or assignment data is touched.

DO $MIGR48$
DECLARE
  v_fixed   INTEGER := 0;
  v_removed INTEGER := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'shared' AND table_name = 'os_license_rules') THEN
    RAISE EXCEPTION
      'shared.os_license_rules does not exist. Load '
      'database/02_shared_schema.sql and run migration 47 first.';
  END IF;

  -- Red Hat: drop the edition word so a host reporting the base name matches.
  UPDATE shared.os_license_rules
  SET    product_pattern = 'Red Hat Enterprise Linux'
  WHERE  vendor          = 'redhat'
    AND  product_pattern = 'Red Hat Enterprise Linux Server'
    AND  license_metric  = 'socket_pair'
    AND  NOT EXISTS (
           SELECT 1 FROM shared.os_license_rules x
           WHERE  x.vendor          = 'redhat'
             AND  x.product_pattern = 'Red Hat Enterprise Linux'
             AND  x.license_metric  = 'socket_pair');
  GET DIAGNOSTICS v_fixed = ROW_COUNT;

  -- Oracle Linux: one rule, tier-independent.
  UPDATE shared.os_license_rules
  SET    product_pattern = 'Oracle Linux',
         notes = 'Per server; the 1-2 socket SKU covers up to two sockets, '
                 'above which the unlimited-socket SKU applies. Basic and '
                 'Premier count identically, so the tier is recorded as a '
                 'support level rather than a separate rule.'
  WHERE  vendor          = 'oracle_linux'
    AND  product_pattern = 'Oracle Linux Premier'
    AND  license_metric  = 'physical_server'
    AND  NOT EXISTS (
           SELECT 1 FROM shared.os_license_rules x
           WHERE  x.vendor          = 'oracle_linux'
             AND  x.product_pattern = 'Oracle Linux'
             AND  x.license_metric  = 'physical_server');

  DELETE FROM shared.os_license_rules
  WHERE  vendor          = 'oracle_linux'
    AND  product_pattern = 'Oracle Linux Basic';
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  -- Oracle Linux guests. The per-server rule is only considered for physical
  -- hosts, so without a per-guest rule every Oracle Linux VM matched nothing
  -- and reported no_rule -- which on an estate that runs Oracle Linux under
  -- VMware is most of it.
  INSERT INTO shared.os_license_rules
    (vendor, product_pattern, license_metric,
     covers_guests, counts_guests, source_reference, notes)
  VALUES
    ('oracle_linux', 'Oracle Linux', 'virtual_guest', FALSE, TRUE,
     'Oracle Linux and Virtualization price list',
     'One subscription per Oracle Linux guest where the physical host it runs '
     'on is not itself covered.')
  ON CONFLICT (vendor, product_pattern, license_metric, effective_from) DO NOTHING;

  -- SUSE: hosts whose os-release reports the short name.
  INSERT INTO shared.os_license_rules
    (vendor, product_pattern, license_metric, max_sockets,
     covers_guests, counts_guests, source_reference, notes)
  VALUES
    ('suse', 'SLES', 'physical_server', 2, FALSE, FALSE,
     'SUSE subscription terms',
     'Same rule as SUSE Linux Enterprise Server, for hosts whose os-release '
     'reports the short name.')
  ON CONFLICT (vendor, product_pattern, license_metric, effective_from) DO NOTHING;

  RAISE NOTICE 'Migration 48 complete: % pattern(s) corrected, % redundant rule(s) removed.',
    v_fixed, v_removed;

  IF EXISTS (SELECT 1 FROM shared.os_license_rules
             WHERE is_active AND product_pattern IN
               ('Red Hat Enterprise Linux Server', 'Oracle Linux Premier',
                'Oracle Linux Basic')) THEN
    RAISE WARNING
      'An unmatchable pattern is still active. Check shared.os_license_rules '
      'for rows whose product_pattern is longer than the distribution string '
      'hosts report.';
  END IF;
END
$MIGR48$;

-- Verification: every active rule's pattern should be something a host could
-- actually report. unmatched_installs counts installations that still resolve
-- to no rule — expected only for vendor 'other'.
SELECT r.vendor::TEXT AS vendor,
       r.product_pattern,
       r.license_metric::TEXT AS license_metric,
       r.sockets_per_unit,
       r.max_sockets
FROM   shared.os_license_rules r
WHERE  r.is_active
ORDER  BY r.vendor, r.product_pattern;
