-- Migration 06: RBAC user management
-- Creates sam_admin.app_users and sam_admin.app_roles tables for
-- application-level access control with AD integration readiness.

-- Role enum
DO $$ BEGIN
  CREATE TYPE sam_admin.app_role AS ENUM (
    'superadmin',   -- full access
    'contracting',  -- add/manage contracts, view everything
    'dba',          -- view everything, manage licence assignments on servers
    'client'        -- view-only, scoped to one client
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Auth method enum
DO $$ BEGIN
  CREATE TYPE sam_admin.auth_method AS ENUM ('local', 'active_directory');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS sam_admin.app_users (
  user_id         SERIAL PRIMARY KEY,
  username        TEXT NOT NULL UNIQUE,
  display_name    TEXT,
  email           TEXT,
  password_hash   TEXT,                       -- NULL when auth_method = 'active_directory'
  role            sam_admin.app_role NOT NULL DEFAULT 'client',
  client_id       INTEGER REFERENCES sam_admin.clients(client_id) ON DELETE SET NULL,
                  -- NULL = accessible to all clients (superadmin/contracting/dba)
                  -- set for client-scoped users
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  auth_method     sam_admin.auth_method NOT NULL DEFAULT 'local',
  ad_username     TEXT,                       -- UPN or sAMAccountName for AD lookup
  ad_groups       TEXT[],                     -- cached AD group membership
  force_password_change BOOLEAN NOT NULL DEFAULT FALSE,
  last_login      TIMESTAMPTZ,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_app_users_username   ON sam_admin.app_users (username);
CREATE INDEX IF NOT EXISTS idx_app_users_ad_username ON sam_admin.app_users (ad_username)
  WHERE ad_username IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_app_users_client      ON sam_admin.app_users (client_id)
  WHERE client_id IS NOT NULL;

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION sam_admin.touch_app_user()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;

-- Drop old name variants safely (table may not exist on a first failed run)
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'sam_admin' AND table_name = 'app_users'
  ) THEN
    DROP TRIGGER IF EXISTS trg_app_usr_updated  ON sam_admin.app_users;
    DROP TRIGGER IF EXISTS trg_app_user_updated ON sam_admin.app_users;
  END IF;
END $$;
CREATE TRIGGER trg_app_user_updated
  BEFORE UPDATE ON sam_admin.app_users
  FOR EACH ROW EXECUTE FUNCTION sam_admin.touch_app_user();

-- Seed the bootstrap superadmin from env vars (username = 'admin' by default).
-- Password is stored as a bcrypt hash; the Python side handles hashing.
-- This row is intentionally left with password_hash = NULL here — the
-- application will upsert it on first start with the env-var credentials hashed.
INSERT INTO sam_admin.app_users (username, display_name, role, auth_method, created_by)
VALUES ('admin', 'Administrator', 'superadmin', 'local', 'migration-06')
ON CONFLICT (username) DO NOTHING;
