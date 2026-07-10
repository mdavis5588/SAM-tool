import io
import json
import os
import smtplib
import ssl
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from functools import wraps

import psycopg2
import psycopg2.extras
import requests
from flask import (Flask, Response, render_template, request, redirect,
                   url_for, session, flash, jsonify)
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "change-me-in-production")

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
DB_CONFIG = {
    "host":     os.environ.get("DB_HOST", "localhost"),
    "port":     int(os.environ.get("DB_PORT", 5432)),
    "dbname":   os.environ.get("DB_NAME", "samdb"),
    "user":     os.environ.get("DB_USER", "sam_admin"),
    "password": os.environ.get("DB_PASSWORD", ""),
}
DEFAULT_CLIENT_SCHEMA = os.environ.get("SAM_CLIENT_SCHEMA", "client_acme")
DISPATCH_KEY = os.environ.get("DISPATCH_KEY", "")

ADMIN_USER     = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "changeme")


def get_db():
    return psycopg2.connect(**DB_CONFIG)


def query(sql, params=None, fetchall=True):
    with get_db() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params or ())
            return cur.fetchall() if fetchall else cur.fetchone()


def execute(sql, params=None):
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
        conn.commit()


def get_schema():
    """Active client schema for this session."""
    return session.get("client_schema", DEFAULT_CLIENT_SCHEMA)


def get_clients():
    """All active clients — used by the navbar switcher."""
    try:
        return query(
            "SELECT client_id, client_code, client_name, schema_name "
            "FROM sam_admin.clients WHERE is_active ORDER BY client_name"
        )
    except Exception:
        return []


# ---------------------------------------------------------------------------
# CSI <-> licence line compatibility
#
# A server's licence position line (product_family + product_detail) needs a
# CSI whose entitlement lines actually cover that same product/edition — a
# Standard Edition 2 CSI must never be usable to cover an Enterprise Edition
# requirement, and vice versa. Entitlement line product names are free text
# (e.g. "Oracle Database Enterprise Edition"), so edition rows are matched by
# edition class and everything else (options like "Partitioning") is matched
# by substring containment.
# ---------------------------------------------------------------------------
def _edition_class(text):
    if not text:
        return None
    t = text.lower()
    if "enterprise" in t:
        return "enterprise"
    if "standard edition 2" in t or "se2" in t:
        return "standard2"
    if "standard" in t:
        return "standard"
    return None


def _is_compatible_product(family, product_detail, line_family, line_product_name):
    if family != line_family:
        return False
    detail_class = _edition_class(product_detail)
    line_class = _edition_class(line_product_name)
    if detail_class or line_class:
        return detail_class is not None and detail_class == line_class
    if not product_detail:
        return True
    return product_detail.lower() in (line_product_name or "").lower()


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return f(*args, **kwargs)
    return decorated


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if (request.form.get("username") == ADMIN_USER and
                request.form.get("password") == ADMIN_PASSWORD):
            session["logged_in"] = True
            return redirect(request.args.get("next") or url_for("servers"))
        flash("Invalid username or password.", "danger")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------------------------------------------------------------------------
# Multi-client switcher
# ---------------------------------------------------------------------------
@app.route("/switch-client", methods=["POST"])
@login_required
def switch_client():
    schema = request.form.get("schema", "")
    if schema == "__all__":
        session["client_schema"] = "__all__"
        flash("Viewing all clients.", "success")
        return redirect(request.referrer or url_for("servers"))
    row = query(
        "SELECT schema_name, client_name FROM sam_admin.clients "
        "WHERE schema_name = %s AND is_active",
        (schema,), fetchall=False
    )
    if row:
        session["client_schema"] = schema
        flash(f"Switched to {row['client_name']}.", "success")
    else:
        flash("Unknown client schema.", "danger")
    return redirect(request.referrer or url_for("servers"))


# ---------------------------------------------------------------------------
# Client management
# ---------------------------------------------------------------------------
@app.route("/clients", methods=["GET", "POST"])
@login_required
def clients():
    if request.method == "POST":
        action = request.form.get("action")

        if action == "provision":
            code    = request.form.get("client_code", "").strip().lower()
            name    = request.form.get("client_name", "").strip()
            contact = request.form.get("contact_email", "").strip() or None
            if not code or not name:
                flash("Client code and name are required.", "danger")
            else:
                try:
                    result = query(
                        "SELECT sam_admin.provision_client(%s, %s, %s) AS msg",
                        (code, name, contact), fetchall=False
                    )
                    flash(result["msg"], "success")
                except Exception as e:
                    flash(f"Error provisioning client: {e}", "danger")

        elif action == "deactivate":
            client_id = request.form.get("client_id")
            execute(
                "UPDATE sam_admin.clients SET is_active = FALSE WHERE client_id = %s",
                (client_id,)
            )
            flash("Client deactivated.", "warning")

        elif action == "reactivate":
            client_id = request.form.get("client_id")
            execute(
                "UPDATE sam_admin.clients SET is_active = TRUE WHERE client_id = %s",
                (client_id,)
            )
            flash("Client reactivated.", "success")

        return redirect(url_for("clients"))

    all_clients = query("""
        SELECT c.client_id, c.client_code, c.client_name, c.schema_name,
               c.contact_email, c.is_active, c.created_at::DATE AS created_at,
               (SELECT COUNT(*) FROM pg_tables
                WHERE schemaname = c.schema_name)           AS table_count,
               (SELECT COUNT(*) FROM sam_admin.discovery_runs dr
                WHERE dr.client_id = c.client_id)           AS discovery_runs,
               (SELECT MAX(started_at)::DATE
                FROM sam_admin.discovery_runs dr
                WHERE dr.client_id = c.client_id)           AS last_discovery
        FROM sam_admin.clients c
        ORDER BY c.is_active DESC, c.client_name
    """)
    return render_template("clients.html", clients=all_clients)


# ---------------------------------------------------------------------------
# Servers list
# ---------------------------------------------------------------------------
@app.route("/")
@app.route("/servers")
@login_required
def servers():
    schema = get_schema()

    if schema == "__all__":
        active_clients = query(
            "SELECT schema_name, client_name, client_code FROM sam_admin.clients "
            "WHERE is_active ORDER BY client_name"
        )
        rows = []
        for c in active_clients:
            s = c["schema_name"]
            try:
                client_rows = query(f"""
                    WITH lp AS (
                        SELECT server_id,
                            JSONB_AGG(JSONB_BUILD_OBJECT(
                                'product_family',    product_family,
                                'product_detail',    product_detail,
                                'licences_required', licences_required,
                                'total_licensed',    total_licensed,
                                'compliance_status', compliance_status
                            ) ORDER BY product_family) AS licence_rows,
                            SUM(licences_required)                        AS total_licences_required,
                            BOOL_OR(compliance_status = 'under_licensed') AS any_under_licensed,
                            STRING_AGG(product_family||': '||licences_required::TEXT,
                                       ' | ' ORDER BY product_family)     AS licence_summary
                        FROM {s}.license_position GROUP BY server_id
                    ),
                    cpu_issues AS (
                        SELECT server_id, factor_unknown
                        FROM   {s}.cpu_validation_report WHERE factor_unknown
                    )
                    SELECT
                        s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
                        s.ip_address::TEXT, s.last_seen::DATE AS last_seen,
                        COALESCE(s.licence_metric_override,'processor_perpetual') AS licence_metric,
                        s.licence_metric_override IS NOT NULL AS metric_overridden,
                        COUNT(DISTINCT m.csi_id) AS csi_count,
                        lp.licence_rows,
                        COALESCE(lp.total_licences_required,0) AS total_licences_required,
                        COALESCE(lp.any_under_licensed,FALSE)  AS any_under_licensed,
                        lp.licence_summary,
                        COALESCE(cpu_issues.factor_unknown,FALSE) AS cpu_unvalidated
                    FROM {s}.oracle_servers s
                    LEFT JOIN {s}.server_csi_map m ON m.server_id = s.server_id
                    LEFT JOIN lp                   ON lp.server_id = s.server_id
                    LEFT JOIN cpu_issues           ON cpu_issues.server_id = s.server_id
                    WHERE s.is_active
                    GROUP BY s.server_id, s.hostname, s.environment, s.datacenter,
                             s.ip_address, s.last_seen, s.licence_metric_override,
                             lp.licence_rows, lp.total_licences_required,
                             lp.any_under_licensed, lp.licence_summary, cpu_issues.factor_unknown
                    ORDER BY s.hostname
                """)
                for r in client_rows:
                    r = dict(r)
                    r["_client_name"] = c["client_name"]
                    r["_client_code"] = c["client_code"]
                    r["_schema"]      = s
                    rows.append(r)
            except Exception:
                pass
        se2_count = 0
        return render_template("servers.html", servers=rows, schema="__all__",
                               se2_count=se2_count)

    rows = query(f"""
        WITH lp AS (
            SELECT
                server_id,
                JSONB_AGG(
                    JSONB_BUILD_OBJECT(
                        'product_family',    product_family,
                        'product_detail',    product_detail,
                        'licences_required', licences_required,
                        'total_licensed',    total_licensed,
                        'compliance_status', compliance_status
                    ) ORDER BY product_family
                ) AS licence_rows,
                SUM(licences_required)                        AS total_licences_required,
                BOOL_OR(compliance_status = 'under_licensed') AS any_under_licensed,
                STRING_AGG(
                    product_family || ': ' || licences_required::TEXT,
                    ' | ' ORDER BY product_family
                )                                             AS licence_summary
            FROM {schema}.license_position
            GROUP BY server_id
        ),
        cpu_issues AS (
            SELECT server_id, factor_unknown
            FROM   {schema}.cpu_validation_report
            WHERE  factor_unknown = TRUE
        )
        SELECT
            s.server_id,
            s.hostname,
            s.environment::TEXT,
            s.datacenter,
            s.ip_address::TEXT,
            s.last_seen::DATE                                  AS last_seen,
            COALESCE(s.licence_metric_override, 'processor_perpetual') AS licence_metric,
            s.licence_metric_override IS NOT NULL              AS metric_overridden,
            COUNT(DISTINCT m.csi_id)                           AS csi_count,
            lp.licence_rows,
            COALESCE(lp.total_licences_required, 0)            AS total_licences_required,
            COALESCE(lp.any_under_licensed, FALSE)             AS any_under_licensed,
            lp.licence_summary,
            COALESCE(cpu_issues.factor_unknown, FALSE)         AS cpu_unvalidated
        FROM {schema}.oracle_servers s
        LEFT JOIN {schema}.server_csi_map m    ON m.server_id = s.server_id
        LEFT JOIN lp                           ON lp.server_id = s.server_id
        LEFT JOIN cpu_issues                   ON cpu_issues.server_id = s.server_id
        WHERE s.is_active = TRUE
        GROUP BY s.server_id, s.hostname, s.environment, s.datacenter,
                 s.ip_address, s.last_seen, s.licence_metric_override,
                 lp.licence_rows, lp.total_licences_required,
                 lp.any_under_licensed, lp.licence_summary, cpu_issues.factor_unknown
        ORDER BY s.hostname
    """)

    # Tag each row with the client name/code for the Owner column
    client_info = query(
        "SELECT client_name, client_code FROM sam_admin.clients WHERE schema_name = %s",
        (schema,), fetchall=False
    ) or {}
    rows = [dict(r,
                 _client_name=client_info.get("client_name", schema),
                 _client_code=client_info.get("client_code", schema))
            for r in rows]

    # SE2 violations for badge count in header
    try:
        se2_count = len(query(f"SELECT 1 FROM {schema}.se2_violations"))
    except Exception:
        se2_count = 0

    return render_template("servers.html", servers=rows, schema=schema,
                           se2_count=se2_count)


# ---------------------------------------------------------------------------
# Edit server
# ---------------------------------------------------------------------------
@app.route("/servers/<int:server_id>", methods=["GET", "POST"])
@login_required
def edit_server(server_id):
    schema = get_schema()

    # When viewing all clients, resolve the actual schema for this server
    if schema == "__all__":
        active_clients = query(
            "SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name"
        )
        for c in active_clients:
            s = c["schema_name"]
            row = query(
                f"SELECT 1 FROM {s}.oracle_servers WHERE server_id = %s",
                (server_id,), fetchall=False
            )
            if row:
                schema = s
                break
        if schema == "__all__":
            flash("Server not found.", "danger")
            return redirect(url_for("servers"))

    if request.method == "POST":
        action = request.form.get("action")

        if action == "set_metric":
            metric = request.form.get("metric")
            if metric == "processor_perpetual":
                execute(
                    f"UPDATE {schema}.oracle_servers "
                    f"SET licence_metric_override = NULL WHERE server_id = %s",
                    (server_id,)
                )
            else:
                execute(
                    f"UPDATE {schema}.oracle_servers "
                    f"SET licence_metric_override = %s WHERE server_id = %s",
                    (metric, server_id)
                )
            flash("Licence metric updated.", "success")

        elif action == "assign_csi":
            csi_id         = request.form.get("csi_id")
            family         = request.form.get("product_family")
            product_detail = request.form.get("product_detail") or None
            consumed_raw   = request.form.get("licences_consumed") or None
            notes          = request.form.get("notes") or None

            # Re-derive the server's actual requirement for this line server-side —
            # never trust the hidden form fields as authorization for the write.
            line_row = query(
                f"SELECT licences_required FROM {schema}.license_position "
                f"WHERE server_id = %s AND product_family = %s "
                f"AND product_detail IS NOT DISTINCT FROM %s",
                (server_id, family, product_detail), fetchall=False
            )
            if not line_row:
                flash("That licence line no longer exists for this server.", "danger")
                return redirect(url_for("edit_server", server_id=server_id))

            entitlement_lines = query(
                "SELECT product_name, product_family::TEXT AS product_family "
                "FROM shared.license_entitlement_lines WHERE csi_id = %s AND is_active",
                (csi_id,)
            )
            if not any(_is_compatible_product(family, product_detail,
                                               l["product_family"], l["product_name"])
                       for l in entitlement_lines):
                flash("That CSI contract doesn't cover this product/edition — "
                      "pick a contract that matches.", "danger")
                return redirect(url_for("edit_server", server_id=server_id))

            # Enforce client_locked CSIs — cannot be assigned to a different client's server
            csi_policy = query(
                """SELECT cs.sharing_policy, c.client_code AS owning_client
                   FROM shared.csi_contracts cs
                   LEFT JOIN sam_admin.clients c ON c.client_id = cs.owning_client_id
                   WHERE cs.csi_id = %s""",
                (csi_id,), fetchall=False
            )
            if csi_policy and csi_policy["sharing_policy"] == "client_locked":
                server_client = query(
                    "SELECT client_code FROM sam_admin.clients WHERE schema_name = %s",
                    (schema,), fetchall=False
                )
                server_code = server_client["client_code"] if server_client else None
                if csi_policy["owning_client"] != server_code:
                    flash(
                        f"CSI is locked to {csi_policy['owning_client']} and cannot be "
                        f"assigned to a {server_code} server.",
                        "danger"
                    )
                    return redirect(url_for("edit_server", server_id=server_id))

            consumed = None
            if consumed_raw:
                try:
                    consumed = Decimal(consumed_raw)
                except InvalidOperation:
                    flash("Licences consumed must be a number.", "danger")
                    return redirect(url_for("edit_server", server_id=server_id))

                required = line_row["licences_required"]
                if required is not None:
                    other_consumed = query(
                        f"SELECT COALESCE(SUM(licences_consumed), 0) AS total "
                        f"FROM {schema}.server_csi_map "
                        f"WHERE server_id = %s AND product_family = %s "
                        f"AND product_detail IS NOT DISTINCT FROM %s AND csi_id != %s",
                        (server_id, family, product_detail, csi_id), fetchall=False
                    )["total"]
                    if other_consumed + consumed > required:
                        remaining = required - other_consumed
                        flash(
                            f"This line only needs {required} licence(s) — "
                            f"{other_consumed} already assigned from other contracts, "
                            f"leaving {remaining} available. Reduce the quantity.",
                            "danger"
                        )
                        return redirect(url_for("edit_server", server_id=server_id))

            # Check CSI capacity — total licences in the CSI vs already consumed
            # across ALL client schemas (excluding the current assignment being replaced)
            if consumed is not None:
                csi_capacity = query(
                    "SELECT COALESCE(SUM(quantity), 0) AS total_qty "
                    "FROM shared.license_entitlement_lines "
                    "WHERE csi_id = %s AND is_active",
                    (csi_id,), fetchall=False
                )["total_qty"]

                if csi_capacity > 0:
                    all_schemas = [
                        r["schema_name"] for r in query(
                            "SELECT schema_name FROM sam_admin.clients WHERE is_active"
                        )
                    ]
                    # Sum consumed for this CSI across all schemas, excluding the row
                    # we are about to replace (same server+csi+family+detail)
                    already_consumed = 0
                    for s in all_schemas:
                        try:
                            row = query(
                                f"SELECT COALESCE(SUM(licences_consumed), 0) AS total "
                                f"FROM {s}.server_csi_map "
                                f"WHERE csi_id = %s "
                                f"AND NOT (server_id = %s AND product_family = %s "
                                f"         AND product_detail IS NOT DISTINCT FROM %s)",
                                (csi_id, server_id, family, product_detail),
                                fetchall=False
                            )
                            already_consumed += row["total"] or 0
                        except Exception:
                            pass

                    if already_consumed + consumed > csi_capacity:
                        remaining = max(csi_capacity - already_consumed, 0)
                        flash(
                            f"This CSI only has {csi_capacity} licences in total — "
                            f"{already_consumed} are already assigned to other servers, "
                            f"leaving {remaining} available. You entered {consumed}.",
                            "danger"
                        )
                        return redirect(url_for("edit_server", server_id=server_id))

            # Remove any existing assignment for this server+csi+family+detail first
            execute(f"""
                DELETE FROM {schema}.server_csi_map
                WHERE server_id = %s AND csi_id = %s AND product_family = %s
                  AND (product_detail IS NOT DISTINCT FROM %s)
            """, (server_id, csi_id, family, product_detail))
            execute(f"""
                INSERT INTO {schema}.server_csi_map
                  (server_id, csi_id, product_family, product_detail,
                   licences_consumed, notes, assigned_by)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (server_id, csi_id, family, product_detail, consumed, notes, ADMIN_USER))
            flash("CSI assignment saved.", "success")

        elif action == "remove_csi":
            map_id = request.form.get("map_id")
            execute(f"DELETE FROM {schema}.server_csi_map WHERE map_id = %s", (map_id,))
            flash("CSI assignment removed.", "success")

        elif action == "save_contacts":
            client_row = query(
                "SELECT client_id FROM sam_admin.clients WHERE schema_name = %s",
                (schema,), fetchall=False
            )
            if client_row:
                client_id = client_row["client_id"]
                execute(
                    "DELETE FROM shared.client_contacts WHERE client_id = %s",
                    (client_id,)
                )
                for i in range(1, 4):
                    name  = (request.form.get(f"contact_name_{i}") or "").strip()
                    email = (request.form.get(f"contact_email_{i}") or "").strip()
                    phone = (request.form.get(f"contact_phone_{i}") or "").strip()
                    if name or email or phone:
                        execute(
                            """INSERT INTO shared.client_contacts
                               (client_id, full_name, email, phone, sort_order)
                               VALUES (%s, %s, %s, %s, %s)""",
                            (client_id, name, email, phone, i)
                        )
                flash("Client contacts saved.", "success")

        elif action == "set_java_exempt":
            java_id = request.form.get("java_id")
            exempt  = request.form.get("exempt") == "1"
            reason  = request.form.get("exempt_reason") or None
            notes   = request.form.get("exempt_notes") or None
            if exempt:
                execute(
                    f"UPDATE {schema}.java_installations "
                    f"SET licence_exempt = TRUE, exempt_reason = %s, "
                    f"    exempt_notes = %s, exempt_set_by = %s, exempt_set_at = NOW() "
                    f"WHERE java_id = %s",
                    (reason, notes, ADMIN_USER, java_id)
                )
                flash("Java installation marked as exempt from licensing.", "success")
            else:
                execute(
                    f"UPDATE {schema}.java_installations "
                    f"SET licence_exempt = FALSE, exempt_reason = NULL, "
                    f"    exempt_notes = NULL, exempt_set_by = NULL, exempt_set_at = NULL "
                    f"WHERE java_id = %s",
                    (java_id,)
                )
                flash("Java licence exemption cleared.", "success")

        return redirect(url_for("edit_server", server_id=server_id))

    # GET
    server = query(
        f"""SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
                   s.ip_address::TEXT, s.last_seen::DATE,
                   COALESCE(s.licence_metric_override, 'processor_perpetual') AS licence_metric,
                   s.licence_metric_override IS NOT NULL AS metric_overridden
            FROM {schema}.oracle_servers s WHERE s.server_id = %s""",
        (server_id,), fetchall=False
    )
    if not server:
        flash("Server not found.", "danger")
        return redirect(url_for("servers"))

    instances = query(
        f"SELECT oracle_sid, edition, db_version FROM {schema}.oracle_instances "
        f"WHERE server_id = %s AND is_active ORDER BY oracle_sid",
        (server_id,)
    )

    assignments = query(f"""
        SELECT m.map_id, m.csi_id, m.product_family, m.product_detail,
               m.licences_consumed, m.notes, m.assigned_by, m.effective_date,
               cs.csi_number, cs.contract_name, cs.support_expiry,
               cs.status AS contract_status
        FROM {schema}.server_csi_map m
        JOIN shared.csi_contracts cs ON cs.csi_id = m.csi_id
        WHERE m.server_id = %s
        ORDER BY m.product_family, m.product_detail, cs.csi_number
    """, (server_id,))

    # Fetch the client code for this server so we can filter out locked CSIs
    server_client_row = query(
        "SELECT client_code FROM sam_admin.clients WHERE schema_name = %s",
        (schema,), fetchall=False
    )
    server_client_code = server_client_row["client_code"] if server_client_row else None

    entitlement_lines = query("""
        SELECT l.csi_id, l.product_name, l.product_family::TEXT AS product_family,
               l.quantity, cs.csi_number, cs.contract_name, cs.support_expiry,
               cs.sharing_policy, c.client_code AS owning_client
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        LEFT JOIN sam_admin.clients c ON c.client_id = cs.owning_client_id
        WHERE cs.status = 'active'
          AND (cs.sharing_policy != 'client_locked' OR c.client_code = %s)
        ORDER BY cs.csi_number
    """, (server_client_code,))

    licence_position = query(
        f"SELECT * FROM {schema}.license_position WHERE server_id = %s", (server_id,)
    )

    def _licence_sort_key(row):
        d = (row.get("product_detail") or "").lower()
        if "enterprise" in d or "standard" in d:
            return (0, d)
        if "diagnostic" in d:
            return (1, d)
        if "tuning" in d:
            return (2, d)
        return (3, d)

    licence_position = sorted(licence_position, key=_licence_sort_key)

    # Per-line: which active CSIs actually cover this product/edition, and how
    # much licence headroom is left once existing assignments are subtracted.
    consumed_by_line = {}
    for a in assignments:
        if a["licences_consumed"] is not None:
            key = (a["product_family"], a["product_detail"])
            consumed_by_line[key] = consumed_by_line.get(key, 0) + a["licences_consumed"]

    # Quantity per (csi_id, product_name) from entitlement lines
    line_qty = {}
    for l in entitlement_lines:
        line_qty[(l["csi_id"], l["product_name"])] = l.get("quantity") or 0

    # Consumed per (csi_id, product_detail) across ALL active client schemas
    active_schemas = [
        r["schema_name"] for r in query(
            "SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name"
        )
    ]
    consumed_by_csi_detail = {}   # (csi_id, product_detail) -> total consumed
    if active_schemas:
        union_sql = " UNION ALL ".join(
            f"SELECT csi_id, product_family::TEXT, COALESCE(product_detail,'') AS product_detail, "
            f"COALESCE(SUM(licences_consumed), 0) AS consumed "
            f"FROM {s}.server_csi_map GROUP BY csi_id, product_family, product_detail"
            for s in active_schemas
        )
        for r in query(
            f"SELECT csi_id, product_family, product_detail, SUM(consumed) AS total "
            f"FROM ({union_sql}) t GROUP BY csi_id, product_family, product_detail"
        ):
            key = (r["csi_id"], r["product_detail"])
            consumed_by_csi_detail[key] = consumed_by_csi_detail.get(key, 0) + r["total"]

    # Index consumed entries by csi_id for fast lookup
    consumed_entries_by_csi = {}
    for (csi_id, detail), amt in consumed_by_csi_detail.items():
        consumed_entries_by_csi.setdefault(csi_id, []).append((detail, amt))

    # DEBUG — remove after diagnosis
    print("DEBUG licence_position rows:")
    for row in licence_position:
        print(f"  LP row: family={row['product_family']!r} detail={row['product_detail']!r}")
    print("DEBUG entitlement_lines:")
    for l in entitlement_lines:
        print(f"  EL line: csi_id={l['csi_id']} family={l['product_family']!r} name={l['product_name']!r} qty={l.get('quantity')}")

    compatible_csis_by_line = {}
    for row in licence_position:
        key = f"{row['product_family']}|{row['product_detail'] or ''}"
        matches = {}
        for l in entitlement_lines:
            if _is_compatible_product(row["product_family"], row["product_detail"],
                                       l["product_family"], l["product_name"]):
                if l["csi_id"] not in matches:
                    qty = line_qty.get((l["csi_id"], l["product_name"]), 0)
                    # Sum consumed entries for this CSI that match this product type
                    consumed = sum(
                        amt for det, amt in consumed_entries_by_csi.get(l["csi_id"], [])
                        if _is_compatible_product(
                            l["product_family"], det or None,
                            l["product_family"], l["product_name"])
                    )
                    matches[l["csi_id"]] = dict(l,
                        csi_total_qty=qty,
                        csi_consumed=consumed,
                        csi_available=max(qty - consumed, 0)
                    )
        compatible_csis_by_line[key] = list(matches.values())

        already = consumed_by_line.get((row["product_family"], row["product_detail"]), 0)
        row["already_consumed"] = already
        row["remaining_capacity"] = (
            row["licences_required"] - already if row["licences_required"] is not None else None
        )

    java_installations = query(
        f"""SELECT java_id, java_home, java_vendor, java_version,
                   java_major_version, java_edition, is_oracle_jdk,
                   requires_licence, licence_metric,
                   licence_exempt, exempt_reason, exempt_notes,
                   exempt_set_by, exempt_set_at::DATE AS exempt_set_at
            FROM {schema}.java_installations
            WHERE server_id = %s
            ORDER BY java_major_version DESC, java_home""",
        (server_id,)
    )

    # SE2 violations for this server
    try:
        se2_violations = query(
            f"SELECT * FROM {schema}.se2_violations WHERE server_id = %s", (server_id,)
        )
    except Exception:
        se2_violations = []

    # CPU validation
    try:
        cpu_validation = query(
            f"SELECT * FROM {schema}.cpu_validation_report WHERE server_id = %s",
            (server_id,), fetchall=False
        )
    except Exception:
        cpu_validation = None

    # Client contacts
    client_row = query(
        "SELECT client_id FROM sam_admin.clients WHERE schema_name = %s",
        (schema,), fetchall=False
    )
    client_contacts = []
    if client_row:
        try:
            client_contacts = query(
                "SELECT full_name, email, phone FROM shared.client_contacts "
                "WHERE client_id = %s ORDER BY sort_order",
                (client_row["client_id"],)
            )
        except Exception:
            client_contacts = []

    return render_template("edit_server.html",
                           server=server,
                           instances=instances,
                           assignments=assignments,
                           compatible_csis_by_line=compatible_csis_by_line,
                           licence_position=licence_position,
                           java_installations=java_installations,
                           se2_violations=se2_violations,
                           cpu_validation=cpu_validation,
                           client_contacts=client_contacts)


# ---------------------------------------------------------------------------
# Server change history
# ---------------------------------------------------------------------------
@app.route("/servers/<int:server_id>/history")
@login_required
def server_history(server_id):
    schema = get_schema()
    server = query(
        f"SELECT server_id, hostname FROM {schema}.oracle_servers WHERE server_id = %s",
        (server_id,), fetchall=False
    )
    if not server:
        flash("Server not found.", "danger")
        return redirect(url_for("servers"))

    history = query(f"""
        SELECT change_id, change_category, object_name, object_type,
               severity, old_value, new_value, change_description,
               detected_at::TIMESTAMPTZ, acknowledged, acknowledged_by,
               acknowledged_at::DATE
        FROM {schema}.discovery_changelog
        WHERE server_id = %s
        ORDER BY detected_at DESC
        LIMIT 500
    """, (server_id,))

    return render_template("history.html", server=server, history=history)


@app.route("/servers/<int:server_id>/history/<int:change_id>/acknowledge",
           methods=["POST"])
@login_required
def acknowledge_change(server_id, change_id):
    schema = get_schema()
    execute(
        f"UPDATE {schema}.discovery_changelog "
        f"SET acknowledged = TRUE, acknowledged_by = %s, acknowledged_at = NOW() "
        f"WHERE change_id = %s",
        (ADMIN_USER, change_id)
    )
    flash("Change acknowledged.", "success")
    return redirect(url_for("server_history", server_id=server_id))


# ---------------------------------------------------------------------------
# CSI contracts browser
# ---------------------------------------------------------------------------
@app.route("/licence-summary")
@login_required
def licence_summary():
    # Per-client totals from client_locked CSIs
    client_rows = query("""
        SELECT c.client_code, c.client_name,
               l.product_name, l.product_family::TEXT AS product_family,
               COALESCE(SUM(l.quantity), 0) AS total_qty
        FROM sam_admin.clients c
        JOIN shared.csi_contracts cs ON cs.owning_client_id = c.client_id
            AND cs.status = 'active'
            AND cs.sharing_policy = 'client_locked'
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        GROUP BY c.client_code, c.client_name, l.product_name, l.product_family
        ORDER BY c.client_code, l.product_family, l.product_name
    """)

    # Shared/pooled CSI totals (sharing_policy != 'client_locked')
    shared_rows = query("""
        SELECT l.product_name, l.product_family::TEXT AS product_family,
               COALESCE(SUM(l.quantity), 0) AS total_qty
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        WHERE cs.status = 'active'
          AND cs.sharing_policy != 'client_locked'
        GROUP BY l.product_name, l.product_family
        ORDER BY l.product_family, l.product_name
    """)

    def _line_sort(name):
        n = (name or "").lower()
        if "enterprise" in n or "standard" in n:
            return (0, n)
        if "diagnostic" in n:
            return (1, n)
        if "tuning" in n:
            return (2, n)
        return (3, n)

    # Group client rows by client
    clients_map = {}
    for r in client_rows:
        key = r["client_code"]
        if key not in clients_map:
            clients_map[key] = {"client_code": r["client_code"],
                                "client_name": r["client_name"],
                                "lines": []}
        clients_map[key]["lines"].append(r)
    for v in clients_map.values():
        v["lines"].sort(key=lambda r: _line_sort(r["product_name"]))

    shared_lines = sorted(shared_rows, key=lambda r: _line_sort(r["product_name"]))

    return render_template("licence_summary.html",
                           clients=list(clients_map.values()),
                           shared_lines=shared_lines)


def _build_licence_detail(entitlement_rows):
    """Return list of dicts with total_qty, assigned_qty, unassigned_qty, servers per product."""
    active_schemas = [
        r["schema_name"] for r in query(
            "SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name"
        )
    ]

    # Per-server assignments: (csi_id, product_detail) -> [{hostname, licences_consumed}]
    server_assignments = {}   # (csi_id, product_detail) -> list of {hostname, consumed}
    if active_schemas:
        union_sql = " UNION ALL ".join(
            f"SELECT m.csi_id, COALESCE(m.product_detail,'') AS product_detail, "
            f"s.hostname, COALESCE(m.licences_consumed, 0) AS consumed "
            f"FROM {s}.server_csi_map m "
            f"JOIN {s}.oracle_servers s ON s.server_id = m.server_id"
            for s in active_schemas
        )
        for r in query(f"SELECT csi_id, product_detail, hostname, SUM(consumed) AS consumed "
                       f"FROM ({union_sql}) t GROUP BY csi_id, product_detail, hostname "
                       f"ORDER BY hostname"):
            key = (r["csi_id"], r["product_detail"])
            server_assignments.setdefault(key, []).append(
                {"hostname": r["hostname"], "consumed": int(r["consumed"])}
            )

    # Aggregated consumed by csi_id for totals
    consumed_entries_by_csi = {}
    for (csi_id, detail), entries in server_assignments.items():
        total = sum(e["consumed"] for e in entries)
        consumed_entries_by_csi.setdefault(csi_id, []).append((detail, total))

    def _line_sort(name):
        n = (name or "").lower()
        if "enterprise" in n or "standard" in n:
            return (0, n)
        if "diagnostic" in n:
            return (1, n)
        if "tuning" in n:
            return (2, n)
        return (3, n)

    # Roll up by product_name across all CSIs in the set
    product_totals = {}   # product_name -> {total, assigned, servers, family}
    for r in entitlement_rows:
        pname = r["product_name"]
        if pname not in product_totals:
            product_totals[pname] = {"product_name": pname,
                                     "product_family": r["product_family"],
                                     "total_qty": 0, "assigned_qty": 0,
                                     "servers": {}}   # hostname -> consumed
        product_totals[pname]["total_qty"] += int(r["quantity"] or 0)

        # Match server assignments for this CSI line
        for (csi_id, detail), entries in server_assignments.items():
            if csi_id != r["csi_id"]:
                continue
            if _is_compatible_product(r["product_family"], detail or None,
                                      r["product_family"], r["product_name"]):
                for e in entries:
                    h = e["hostname"]
                    product_totals[pname]["servers"][h] = (
                        product_totals[pname]["servers"].get(h, 0) + e["consumed"]
                    )

        consumed = sum(
            amt for det, amt in consumed_entries_by_csi.get(r["csi_id"], [])
            if _is_compatible_product(r["product_family"], det or None,
                                      r["product_family"], r["product_name"])
        )
        product_totals[pname]["assigned_qty"] += consumed

    lines = sorted(product_totals.values(), key=lambda x: _line_sort(x["product_name"]))
    for ln in lines:
        ln["unassigned_qty"] = max(ln["total_qty"] - ln["assigned_qty"], 0)
        # Convert servers dict to sorted list
        ln["servers"] = sorted(
            [{"hostname": h, "consumed": c} for h, c in ln["servers"].items()],
            key=lambda x: x["hostname"]
        )
    return lines


@app.route("/licence-summary/client/<client_code>")
@login_required
def licence_summary_client(client_code):
    client = query(
        "SELECT client_id, client_code, client_name FROM sam_admin.clients WHERE client_code = %s",
        (client_code,), fetchall=False
    )
    if not client:
        flash("Client not found.", "danger")
        return redirect(url_for("licence_summary"))

    entitlement_rows = query("""
        SELECT l.csi_id, l.product_name, l.product_family::TEXT AS product_family,
               COALESCE(l.quantity, 0) AS quantity
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        WHERE cs.status = 'active'
          AND cs.sharing_policy = 'client_locked'
          AND cs.owning_client_id = %s
    """, (client["client_id"],))

    lines = _build_licence_detail(entitlement_rows)
    return render_template("licence_summary_detail.html",
                           title=f"{client['client_name'] or client_code} — Locked Licences",
                           subtitle="Client-locked CSIs only",
                           lines=lines,
                           back_url=url_for("licence_summary"))


@app.route("/licence-summary/shared")
@login_required
def licence_summary_shared():
    entitlement_rows = query("""
        SELECT l.csi_id, l.product_name, l.product_family::TEXT AS product_family,
               COALESCE(l.quantity, 0) AS quantity
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        WHERE cs.status = 'active'
          AND cs.sharing_policy != 'client_locked'
    """)

    lines = _build_licence_detail(entitlement_rows)
    return render_template("licence_summary_detail.html",
                           title="Shared Pool — Licences",
                           subtitle="Pooled / shared CSIs",
                           lines=lines,
                           back_url=url_for("licence_summary"))


import math as _math

_FINOPS_PALETTE = ["#2a78d6","#1baf7a","#eda100","#008300",
                   "#4a3aa7","#e34948","#e87ba4","#eb6834"]

def _finops_line_sort(name):
    n = (name or "").lower()
    if "enterprise" in n or "standard" in n:
        return (0, n)
    if "diagnostic" in n:
        return (1, n)
    if "tuning" in n:
        return (2, n)
    return (3, n)

def _pie_slices(items, cx=100, cy=100, r=80, gap_deg=1.5):
    total = sum(i["value"] for i in items)
    if total == 0:
        return []
    slices, angle = [], 0.0
    for i, item in enumerate(items):
        sweep = item["value"] / total * 360
        a0 = _math.radians(angle + gap_deg / 2)
        a1 = _math.radians(angle + sweep - gap_deg / 2)
        x1, y1 = cx + r * _math.cos(a0), cy + r * _math.sin(a0)
        x2, y2 = cx + r * _math.cos(a1), cy + r * _math.sin(a1)
        slices.append({
            "path": (f"M {cx} {cy} L {x1:.2f} {y1:.2f} "
                     f"A {r} {r} 0 {1 if sweep >= 180 else 0} 1 {x2:.2f} {y2:.2f} Z"),
            "colour": _FINOPS_PALETTE[i % len(_FINOPS_PALETTE)],
            "label": item["label"],
            "value": item["value"],
            "pct": round(item["value"] / total * 100, 1),
        })
        angle += sweep
    return slices

def _build_client_finops(client_id):
    rows = query("""
        SELECT l.product_name,
               l.product_family::TEXT AS product_family,
               COALESCE(SUM(l.quantity), 0)            AS qty,
               COALESCE(SUM(l.total_price), 0)         AS licence_cost,
               COALESCE(SUM(l.annual_support_cost), 0) AS support_cost
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l
             ON l.csi_id = cs.csi_id AND l.is_active
        WHERE cs.status = 'active'
          AND cs.owning_client_id = %s
        GROUP BY l.product_name, l.product_family
    """, (client_id,))
    if not rows:
        return None
    lines = sorted(rows, key=lambda r: _finops_line_sort(r["product_name"]))
    for i, ln in enumerate(lines):
        ln["colour"] = _FINOPS_PALETTE[i % len(_FINOPS_PALETTE)]
    total_licence = sum(float(r["licence_cost"] or 0) for r in lines)
    total_support = sum(float(r["support_cost"] or 0) for r in lines)
    pie_items = [{"label": r["product_name"], "value": float(r["licence_cost"] or 0)}
                 for r in lines if float(r["licence_cost"] or 0) > 0]
    return {
        "lines": lines,
        "total_licence": total_licence,
        "total_support": total_support,
        "total_tco": total_licence + total_support,
        "pie_slices": _pie_slices(pie_items),
    }


@app.route("/finops")
@login_required
def finops():
    clients_list = query(
        "SELECT client_id, client_code, client_name FROM sam_admin.clients "
        "WHERE is_active ORDER BY client_name, client_code"
    )
    summary = []
    for c in clients_list:
        data = _build_client_finops(c["client_id"])
        if data:
            summary.append({
                "client_code": c["client_code"],
                "client_name": c["client_name"] or c["client_code"],
                "total_licence": data["total_licence"],
                "total_support": data["total_support"],
                "total_tco": data["total_tco"],
                "product_count": len(data["lines"]),
            })
    return render_template("finops_summary.html", summary=summary)


@app.route("/finops/<client_code>")
@login_required
def finops_client(client_code):
    client = query(
        "SELECT client_id, client_code, client_name FROM sam_admin.clients "
        "WHERE client_code = %s", (client_code,), fetchall=False
    )
    if not client:
        flash("Client not found.", "danger")
        return redirect(url_for("finops"))
    data = _build_client_finops(client["client_id"])
    if not data:
        flash("No cost data found for this client.", "warning")
        return redirect(url_for("finops"))
    data["client_code"] = client["client_code"]
    data["client_name"] = client["client_name"] or client["client_code"]
    return render_template("finops.html", client=data)


@app.route("/contracts")
@login_required
def contracts():
    # One row per CSI header
    csi_rows = query("""
        SELECT cs.csi_id, cs.csi_number, cs.contract_name,
               cs.support_expiry, cs.sharing_policy, cs.status, cs.currency,
               oc.client_code AS owning_client
        FROM shared.csi_contracts cs
        LEFT JOIN sam_admin.clients oc ON oc.client_id = cs.owning_client_id
        ORDER BY cs.csi_number
    """)

    # All active entitlement lines
    line_rows = query("""
        SELECT l.line_id, l.csi_id, l.product_name,
               l.product_family::TEXT AS product_family,
               l.license_metric::TEXT AS license_metric,
               l.quantity, l.unit_price, l.total_price
        FROM shared.license_entitlement_lines l
        WHERE l.is_active
        ORDER BY l.csi_id, l.line_number
    """)

    # Sum licences_consumed per (csi_id, product_detail) across all active schemas
    active_schemas = [
        r["schema_name"] for r in query(
            "SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name"
        )
    ]
    consumed_entries_by_csi = {}   # csi_id -> [(product_family, product_detail, amount)]
    if active_schemas:
        union_sql = " UNION ALL ".join(
            f"SELECT csi_id, product_family::TEXT, COALESCE(product_detail,'') AS product_detail, "
            f"COALESCE(SUM(licences_consumed), 0) AS consumed "
            f"FROM {s}.server_csi_map GROUP BY csi_id, product_family, product_detail"
            for s in active_schemas
        )
        for r in query(
            f"SELECT csi_id, product_family, product_detail, SUM(consumed) AS total "
            f"FROM ({union_sql}) t GROUP BY csi_id, product_family, product_detail"
        ):
            consumed_entries_by_csi.setdefault(r["csi_id"], []).append(
                (r["product_family"], r["product_detail"], r["total"])
            )

    # Group lines under each CSI, attaching consumed/available per line
    # Match each line to assignments using product compatibility logic
    lines_by_csi = {}
    for l in line_rows:
        consumed = sum(
            amt for fam, det, amt in consumed_entries_by_csi.get(l["csi_id"], [])
            if _is_compatible_product(l["product_family"], det or None,
                                      l["product_family"], l["product_name"])
        )
        qty = l["quantity"] or 0
        line = dict(l,
                    consumed=consumed,
                    available=max(qty - consumed, 0))
        lines_by_csi.setdefault(l["csi_id"], []).append(line)

    contracts = [dict(r, lines=lines_by_csi.get(r["csi_id"], [])) for r in csi_rows]

    # Values for filter dropdowns
    all_clients = query(
        "SELECT client_code, client_name FROM sam_admin.clients WHERE is_active ORDER BY client_name"
    )
    sharing_policies = sorted({r["sharing_policy"] for r in csi_rows})

    return render_template("contracts.html", contracts=contracts,
                           all_clients=all_clients,
                           sharing_policies=sharing_policies)


@app.route("/contracts/<int:csi_id>")
@login_required
def contract_detail(csi_id):
    schema = get_schema()
    contract = query(
        "SELECT * FROM shared.csi_contract_summary WHERE csi_id = %s",
        (csi_id,), fetchall=False
    )
    if not contract:
        flash("Contract not found.", "danger")
        return redirect(url_for("contracts"))

    lines = query(
        "SELECT * FROM shared.license_entitlement_lines WHERE csi_id = %s ORDER BY line_number",
        (csi_id,)
    )
    # Gather assigned servers across all active client schemas
    all_schemas = query(
        "SELECT schema_name, client_name FROM sam_admin.clients WHERE is_active ORDER BY client_name"
    )
    assigned_servers = []
    for c in all_schemas:
        s = c["schema_name"]
        try:
            rows = query(f"""
                SELECT s.server_id, s.hostname, s.environment::TEXT,
                       m.product_family, m.product_detail,
                       m.licences_consumed, m.notes, m.effective_date, m.map_id,
                       %s AS client_name, %s AS schema_name
                FROM {s}.server_csi_map m
                JOIN {s}.oracle_servers s ON s.server_id = m.server_id
                WHERE m.csi_id = %s
                ORDER BY s.hostname
            """, (c["client_name"], s, csi_id))
            assigned_servers.extend(rows)
        except Exception:
            pass

    # Sum consumed per product_family across all schemas
    consumed_by_line = {}
    for row in assigned_servers:
        key = row["product_family"]
        consumed_by_line[key] = consumed_by_line.get(key, 0) + (row["licences_consumed"] or 0)

    return render_template("contract_detail.html",
                           contract=contract, lines=lines,
                           assigned_servers=assigned_servers,
                           consumed_by_line=consumed_by_line)


# ---------------------------------------------------------------------------
# Compliance alerts
# ---------------------------------------------------------------------------
@app.route("/alerts")
@login_required
def alerts():
    rows = query(
        "SELECT * FROM shared.compliance_alerts ORDER BY severity, days_until NULLS LAST"
    )
    return render_template("alerts.html", alerts=rows)


# ---------------------------------------------------------------------------
# VMware cluster view
# ---------------------------------------------------------------------------
@app.route("/vmware")
@login_required
def vmware():
    clusters = query("""
        SELECT vle.*, c.client_name
        FROM   sam_admin.vmware_licence_exposure vle
        LEFT   JOIN sam_admin.clients c ON c.client_code = vle.client_code
        ORDER  BY vle.has_oracle_workloads DESC, vle.total_physical_cores DESC
    """)
    return render_template("vmware.html", clusters=clusters)


# ---------------------------------------------------------------------------
# LMS Audit Export (Excel workbook)
# ---------------------------------------------------------------------------
@app.route("/export/lms")
@login_required
def export_lms():
    schema = get_schema()
    wb = Workbook()

    header_font  = Font(bold=True, color="FFFFFF")
    header_fill  = PatternFill("solid", fgColor="203864")
    warn_fill    = PatternFill("solid", fgColor="FFE599")
    danger_fill  = PatternFill("solid", fgColor="F4CCCC")

    def add_sheet(title, columns, rows):
        ws = wb.create_sheet(title)
        ws.append(columns)
        for cell in ws[1]:
            cell.font  = header_font
            cell.fill  = header_fill
            cell.alignment = Alignment(horizontal="center")
        for row in rows:
            ws.append([row.get(c.lower().replace(" ", "_").replace("/", "_")) for c in columns])
        for col in ws.columns:
            ws.column_dimensions[col[0].column_letter].width = max(
                len(str(col[0].value or "")),
                max((len(str(c.value or "")) for c in col[1:]), default=0)
            ) + 4
        return ws

    # Sheet 1: Summary
    ws_sum = wb.active
    ws_sum.title = "Summary"
    ws_sum["A1"] = "Oracle SAM — LMS Audit Export"
    ws_sum["A1"].font = Font(bold=True, size=14)
    ws_sum["A2"] = f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    ws_sum["A3"] = f"Client schema: {schema}"
    ws_sum["A5"] = "Sheet"
    ws_sum["B5"] = "Contents"
    ws_sum["A5"].font = Font(bold=True)
    ws_sum["B5"].font = Font(bold=True)
    for i, (s, d) in enumerate([
        ("Server Inventory", "All active Oracle servers with hardware details"),
        ("Processor Details", "CPU socket / core / factor data per server"),
        ("Oracle Instances", "Oracle DB instances with edition and version"),
        ("Options", "v$option flags per instance"),
        ("Licence Position", "Calculated licence requirements per product"),
        ("CSI Contracts", "All CSI contract headers and entitlement totals"),
        ("SE2 Violations", "Servers violating SE2 socket or RAC node limits"),
        ("CPU Validation", "Servers with unrecognised CPU models"),
        ("VMware Exposure", "vSphere clusters with Oracle VM workloads"),
    ], start=6):
        ws_sum[f"A{i}"] = s
        ws_sum[f"B{i}"] = d

    # Sheet 2: Server Inventory
    servers_data = query(f"""
        SELECT s.hostname, s.environment::TEXT AS environment, s.datacenter,
               s.ip_address::TEXT AS ip_address, s.os_family, s.os_distribution,
               s.os_version, s.total_ram_mb, s.last_seen::DATE AS last_seen,
               COALESCE(s.licence_metric_override, 'processor_perpetual') AS licence_metric
        FROM {schema}.oracle_servers s WHERE s.is_active ORDER BY s.hostname
    """)
    ws2 = wb.create_sheet("Server Inventory")
    cols2 = ["Hostname", "Environment", "Datacenter", "IP Address", "OS Family",
             "OS Distribution", "OS Version", "RAM (MB)", "Last Seen", "Licence Metric"]
    ws2.append(cols2)
    for cell in ws2[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in servers_data:
        ws2.append([r.get("hostname"), r.get("environment"), r.get("datacenter"),
                    r.get("ip_address"), r.get("os_family"), r.get("os_distribution"),
                    r.get("os_version"), r.get("total_ram_mb"),
                    str(r.get("last_seen", "")), r.get("licence_metric")])

    # Sheet 3: Processor Details
    proc_data = query(f"""
        SELECT s.hostname, p.cpu_model, p.cpu_architecture,
               p.cpu_sockets, p.cores_per_socket,
               p.cpu_sockets * p.cores_per_socket AS total_physical_cores,
               p.threads_per_core, p.virt_type::TEXT AS virt_type,
               p.is_vmware, p.vcpu_count,
               shared.cpu_core_factor_lookup(p.cpu_model) AS oracle_core_factor,
               p.recorded_at::DATE AS snapshot_date
        FROM {schema}.oracle_servers s
        JOIN LATERAL (
          SELECT * FROM {schema}.oracle_processors
          WHERE server_id = s.server_id ORDER BY recorded_at DESC LIMIT 1
        ) p ON TRUE
        WHERE s.is_active ORDER BY s.hostname
    """)
    ws3 = wb.create_sheet("Processor Details")
    cols3 = ["Hostname", "CPU Model", "Architecture", "Sockets", "Cores/Socket",
             "Total Physical Cores", "Threads/Core", "Virt Type", "Is VMware",
             "vCPU Count", "Oracle Core Factor", "Snapshot Date"]
    ws3.append(cols3)
    for cell in ws3[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in proc_data:
        row = [r.get("hostname"), r.get("cpu_model"), r.get("cpu_architecture"),
               r.get("cpu_sockets"), r.get("cores_per_socket"),
               r.get("total_physical_cores"), r.get("threads_per_core"),
               r.get("virt_type"), r.get("is_vmware"), r.get("vcpu_count"),
               r.get("oracle_core_factor"), str(r.get("snapshot_date", ""))]
        ws3.append(row)
        if r.get("oracle_core_factor") is None:
            for cell in ws3[ws3.max_row]:
                cell.fill = warn_fill

    # Sheet 4: Oracle Instances
    inst_data = query(f"""
        SELECT s.hostname, i.oracle_sid, i.db_name, i.edition,
               i.db_version, i.platform_name, i.last_seen::DATE AS last_seen
        FROM {schema}.oracle_instances i
        JOIN {schema}.oracle_servers s ON s.server_id = i.server_id
        WHERE i.is_active ORDER BY s.hostname, i.oracle_sid
    """)
    ws4 = wb.create_sheet("Oracle Instances")
    cols4 = ["Hostname", "Oracle SID", "DB Name", "Edition", "Version",
             "Platform", "Last Seen"]
    ws4.append(cols4)
    for cell in ws4[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in inst_data:
        ws4.append([r.get("hostname"), r.get("oracle_sid"), r.get("db_name"),
                    r.get("edition"), r.get("db_version"), r.get("platform_name"),
                    str(r.get("last_seen", ""))])

    # Sheet 5: Options
    try:
        opt_data = query(f"""
            SELECT s.hostname, i.oracle_sid, o.option_name, o.is_active::TEXT AS installed
            FROM {schema}.oracle_options o
            JOIN {schema}.oracle_instances i ON i.instance_id = o.instance_id
            JOIN {schema}.oracle_servers   s ON s.server_id   = i.server_id
            WHERE o.is_active = TRUE
            ORDER BY s.hostname, i.oracle_sid, o.option_name
        """)
    except Exception:
        opt_data = []
    ws5 = wb.create_sheet("Options")
    cols5 = ["Hostname", "Oracle SID", "Option Name", "Installed"]
    ws5.append(cols5)
    for cell in ws5[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in opt_data:
        ws5.append([r.get("hostname"), r.get("oracle_sid"),
                    r.get("option_name"), r.get("installed")])

    # Sheet 6: Licence Position
    lp_data = query(f"""
        SELECT s.hostname, lp.product_family, lp.product_detail,
               lp.licences_required, lp.total_licensed,
               lp.licence_surplus_deficit, lp.compliance_status
        FROM {schema}.license_position lp
        JOIN {schema}.oracle_servers s ON s.server_id = lp.server_id
        ORDER BY s.hostname, lp.product_family
    """)
    ws6 = wb.create_sheet("Licence Position")
    cols6 = ["Hostname", "Product Family", "Product Detail", "Licences Required",
             "Total Licensed", "Surplus/Deficit", "Compliance Status"]
    ws6.append(cols6)
    for cell in ws6[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in lp_data:
        row = [r.get("hostname"), r.get("product_family"), r.get("product_detail"),
               r.get("licences_required"), r.get("total_licensed"),
               r.get("licence_surplus_deficit"), r.get("compliance_status")]
        ws6.append(row)
        if r.get("compliance_status") == "under_licensed":
            for cell in ws6[ws6.max_row]:
                cell.fill = danger_fill

    # Sheet 7: CSI Contracts
    csi_data = query("""
        SELECT cs.csi_number, cs.contract_name, cs.purchase_date,
               cs.support_start, cs.support_expiry, cs.is_ula, cs.ula_expiry,
               cs.status, cs.sharing_policy,
               oc.client_code AS owning_client,
               COUNT(DISTINCT l.line_id) AS line_count,
               SUM(l.quantity) AS total_licences,
               SUM(l.total_price) AS total_licence_cost,
               STRING_AGG(DISTINCT l.product_name, ' | ' ORDER BY l.product_name) AS products
        FROM shared.csi_contracts cs
        LEFT JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id AND l.is_active
        LEFT JOIN sam_admin.clients oc ON oc.client_id = cs.owning_client_id
        GROUP BY cs.csi_id, cs.csi_number, cs.contract_name, cs.purchase_date,
                 cs.support_start, cs.support_expiry, cs.is_ula, cs.ula_expiry,
                 cs.status, cs.sharing_policy, oc.client_code
        ORDER BY cs.csi_number
    """)
    ws7 = wb.create_sheet("CSI Contracts")
    cols7 = ["CSI Number", "Contract Name", "Purchase Date", "Support Start",
             "Support Expiry", "Is ULA", "ULA Expiry", "Status", "Sharing Policy",
             "Owning Client", "Line Count", "Total Licences", "Total Cost", "Products"]
    ws7.append(cols7)
    for cell in ws7[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in csi_data:
        ws7.append([r.get("csi_number"), r.get("contract_name"),
                    str(r.get("purchase_date", "")), str(r.get("support_start", "")),
                    str(r.get("support_expiry", "")), r.get("is_ula"),
                    str(r.get("ula_expiry", "")), r.get("status"), r.get("sharing_policy"),
                    r.get("owning_client"), r.get("line_count"),
                    r.get("total_licences"), r.get("total_licence_cost"), r.get("products")])

    # Sheet 8: SE2 Violations
    try:
        se2_data = query(f"SELECT * FROM {schema}.se2_violations ORDER BY hostname")
    except Exception:
        se2_data = []
    ws8 = wb.create_sheet("SE2 Violations")
    cols8 = ["Hostname", "Oracle SID", "Edition", "CPU Sockets",
             "RAC Node Count", "Socket Violation", "RAC Violation", "Summary"]
    ws8.append(cols8)
    for cell in ws8[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in se2_data:
        row = [r.get("hostname"), r.get("oracle_sid"), r.get("edition"),
               r.get("cpu_sockets"), r.get("rac_node_count"),
               r.get("socket_violation"), r.get("rac_violation"),
               r.get("violation_summary")]
        ws8.append(row)
        for cell in ws8[ws8.max_row]:
            cell.fill = danger_fill

    # Sheet 9: CPU Validation
    try:
        cpu_data = query(f"SELECT * FROM {schema}.cpu_validation_report ORDER BY factor_unknown DESC, hostname")
    except Exception:
        cpu_data = []
    ws9 = wb.create_sheet("CPU Validation")
    cols9 = ["Hostname", "CPU Model", "Sockets", "Cores/Socket",
             "Total Cores", "Validated Factor", "Factor Unknown", "Status", "Last Snapshot"]
    ws9.append(cols9)
    for cell in ws9[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in cpu_data:
        row = [r.get("hostname"), r.get("cpu_model"), r.get("cpu_sockets"),
               r.get("cores_per_socket"), r.get("total_physical_cores"),
               r.get("validated_factor"), r.get("factor_unknown"),
               r.get("validation_status"), str(r.get("last_processor_snapshot", ""))]
        ws9.append(row)
        if r.get("factor_unknown"):
            for cell in ws9[ws9.max_row]:
                cell.fill = warn_fill

    # Sheet 10: VMware Exposure
    vmw_data = query("""
        SELECT cluster_name, vcenter_host, datacenter, client_code,
               host_count, total_sockets, total_physical_cores,
               oracle_db_vm_count, oracle_wls_vm_count, oracle_java_vm_count,
               has_oracle_workloads, last_seen
        FROM sam_admin.vmware_licence_exposure
        ORDER BY has_oracle_workloads DESC, total_physical_cores DESC
    """)
    ws10 = wb.create_sheet("VMware Exposure")
    cols10 = ["Cluster Name", "vCenter Host", "Datacenter", "Client",
              "Host Count", "Total Sockets", "Total Physical Cores",
              "Oracle DB VMs", "WLS VMs", "Java VMs", "Has Oracle Workloads", "Last Seen"]
    ws10.append(cols10)
    for cell in ws10[1]:
        cell.font = header_font; cell.fill = header_fill
    for r in vmw_data:
        row = [r.get("cluster_name"), r.get("vcenter_host"), r.get("datacenter"),
               r.get("client_code"), r.get("host_count"), r.get("total_sockets"),
               r.get("total_physical_cores"), r.get("oracle_db_vm_count"),
               r.get("oracle_wls_vm_count"), r.get("oracle_java_vm_count"),
               r.get("has_oracle_workloads"), str(r.get("last_seen", ""))]
        ws10.append(row)
        if r.get("has_oracle_workloads"):
            for cell in ws10[ws10.max_row]:
                cell.fill = warn_fill

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    filename = f"oracle_lms_export_{schema}_{date.today().isoformat()}.xlsx"
    return Response(
        buf.getvalue(),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename={filename}"}
    )


# ---------------------------------------------------------------------------
# Settings — alert channels
# ---------------------------------------------------------------------------
@app.route("/settings", methods=["GET", "POST"])
@login_required
def settings():
    if request.method == "POST":
        action = request.form.get("action")

        if action == "add_channel":
            ctype = request.form.get("channel_type")
            cname = request.form.get("channel_name", "").strip()
            min_sev = request.form.get("min_severity", "MEDIUM")
            if ctype == "email":
                cfg = {
                    "smtp_host":     request.form.get("smtp_host", ""),
                    "smtp_port":     int(request.form.get("smtp_port", 587)),
                    "smtp_user":     request.form.get("smtp_user", ""),
                    "smtp_password": request.form.get("smtp_password", ""),
                    "from_addr":     request.form.get("from_addr", ""),
                    "to_addrs":      [a.strip() for a in
                                      request.form.get("to_addrs", "").split(",") if a.strip()],
                }
            else:
                cfg = {"webhook_url": request.form.get("webhook_url", "")}
            execute(
                "INSERT INTO sam_admin.alert_channels "
                "(channel_type, channel_name, config, min_severity) VALUES (%s, %s, %s, %s)",
                (ctype, cname, json.dumps(cfg), min_sev)
            )
            flash(f"Alert channel '{cname}' added.", "success")

        elif action == "toggle":
            cid = request.form.get("channel_id")
            execute(
                "UPDATE sam_admin.alert_channels SET enabled = NOT enabled WHERE channel_id = %s",
                (cid,)
            )
            flash("Channel updated.", "success")

        elif action == "delete":
            cid = request.form.get("channel_id")
            execute("DELETE FROM sam_admin.alert_channels WHERE channel_id = %s", (cid,))
            flash("Channel deleted.", "success")

        return redirect(url_for("settings"))

    channels = query(
        "SELECT * FROM sam_admin.alert_channels ORDER BY channel_type, channel_name"
    )
    return render_template("settings.html", channels=channels)


@app.route("/settings/test/<int:channel_id>", methods=["POST"])
@login_required
def test_channel(channel_id):
    row = query(
        "SELECT * FROM sam_admin.alert_channels WHERE channel_id = %s",
        (channel_id,), fetchall=False
    )
    if not row:
        flash("Channel not found.", "danger")
        return redirect(url_for("settings"))

    test_alert = {
        "alert_type": "TEST",
        "severity": "LOW",
        "object_name": "SAM Alert System",
        "description": "This is a test alert from Oracle SAM.",
        "action_needed": "No action required — this is a connectivity test.",
    }
    ok, err = _send_to_channel(row, [test_alert])
    if ok:
        flash(f"Test alert sent successfully to '{row['channel_name']}'.", "success")
    else:
        flash(f"Test failed: {err}", "danger")
    return redirect(url_for("settings"))


# ---------------------------------------------------------------------------
# Alert dispatch (call from cron)
# ---------------------------------------------------------------------------
@app.route("/api/dispatch-alerts")
def dispatch_alerts():
    """Send pending compliance alerts to all enabled channels.
    Protect with DISPATCH_KEY env var:
      curl 'http://localhost:5000/api/dispatch-alerts?key=YOUR_KEY'
    """
    if DISPATCH_KEY and request.args.get("key", "") != DISPATCH_KEY:
        return jsonify({"error": "unauthorized"}), 401

    alerts_data = query(
        "SELECT * FROM shared.compliance_alerts ORDER BY severity, days_until NULLS LAST"
    )
    if not alerts_data:
        return jsonify({"status": "ok", "sent": 0, "message": "No alerts to dispatch"})

    channels = query(
        "SELECT * FROM sam_admin.alert_channels WHERE enabled ORDER BY channel_id"
    )
    results = []
    for ch in channels:
        # Filter by min_severity
        sev_order = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}
        min_sev = sev_order.get(ch.get("min_severity", "MEDIUM"), 2)
        filtered = [a for a in alerts_data
                    if sev_order.get(a.get("severity", "LOW"), 1) >= min_sev]
        if not filtered:
            continue
        ok, err = _send_to_channel(ch, filtered)
        execute(
            "UPDATE sam_admin.alert_channels SET last_sent_at = NOW() WHERE channel_id = %s",
            (ch["channel_id"],)
        )
        results.append({"channel": ch["channel_name"], "ok": ok, "error": err,
                        "alert_count": len(filtered)})

    return jsonify({"status": "ok", "channels": results})


def _send_to_channel(channel, alerts):
    """Send a list of alerts to a channel. Returns (success, error_message)."""
    ctype = channel["channel_type"]
    cfg   = channel["config"] if isinstance(channel["config"], dict) else json.loads(channel["config"])

    try:
        if ctype == "slack":
            _send_slack(cfg["webhook_url"], channel["channel_name"], alerts)
        elif ctype == "teams":
            _send_teams(cfg["webhook_url"], channel["channel_name"], alerts)
        elif ctype == "email":
            _send_email(cfg, channel["channel_name"], alerts)
        return True, None
    except Exception as exc:
        return False, str(exc)


def _send_slack(webhook_url, channel_name, alerts):
    high   = [a for a in alerts if a.get("severity") == "HIGH"]
    medium = [a for a in alerts if a.get("severity") == "MEDIUM"]
    blocks = [{"type": "header", "text": {"type": "plain_text",
               "text": f"Oracle SAM Compliance Alerts ({len(alerts)} total)"}}]
    for a in alerts[:20]:
        emoji = ":red_circle:" if a.get("severity") == "HIGH" else ":large_yellow_circle:"
        blocks.append({"type": "section", "text": {"type": "mrkdwn",
            "text": f"{emoji} *{a.get('alert_type')}* — {a.get('object_name')}\n"
                    f"{a.get('description')}\n_Action: {a.get('action_needed')}_"}})
    if len(alerts) > 20:
        blocks.append({"type": "section", "text": {"type": "mrkdwn",
            "text": f"… and {len(alerts) - 20} more alerts. Log in to Oracle SAM to review all."}})
    resp = requests.post(webhook_url, json={"blocks": blocks}, timeout=10)
    resp.raise_for_status()


def _send_teams(webhook_url, channel_name, alerts):
    facts = [{"name": f"{a.get('severity')} — {a.get('alert_type')}",
              "value": f"{a.get('object_name')}: {a.get('description')}"}
             for a in alerts[:25]]
    payload = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "FF0000" if any(a.get("severity") == "HIGH" for a in alerts) else "FFA500",
        "summary": f"Oracle SAM: {len(alerts)} compliance alert(s)",
        "sections": [{"activityTitle": f"Oracle SAM — {len(alerts)} Compliance Alert(s)",
                      "facts": facts}]
    }
    resp = requests.post(webhook_url, json=payload, timeout=10)
    resp.raise_for_status()


def _send_email(cfg, channel_name, alerts):
    body_lines = [f"Oracle SAM Compliance Alerts — {len(alerts)} item(s)\n",
                  "=" * 60]
    for a in alerts:
        body_lines += [
            f"\n[{a.get('severity')}] {a.get('alert_type')}",
            f"  Object  : {a.get('object_name')}",
            f"  Client  : {a.get('client_code', 'N/A')}",
            f"  Detail  : {a.get('description')}",
            f"  Action  : {a.get('action_needed')}",
        ]
    body = "\n".join(body_lines)

    msg = MIMEMultipart()
    msg["From"]    = cfg.get("from_addr", "sam@example.com")
    msg["To"]      = ", ".join(cfg.get("to_addrs", []))
    msg["Subject"] = f"Oracle SAM: {len(alerts)} compliance alert(s)"
    msg.attach(MIMEText(body, "plain"))

    ctx = ssl.create_default_context()
    with smtplib.SMTP(cfg["smtp_host"], int(cfg.get("smtp_port", 587))) as smtp:
        smtp.starttls(context=ctx)
        if cfg.get("smtp_user"):
            smtp.login(cfg["smtp_user"], cfg.get("smtp_password", ""))
        smtp.sendmail(cfg["from_addr"], cfg["to_addrs"], msg.as_string())


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# Context processor — inject shared variables into every template
# ---------------------------------------------------------------------------
@app.context_processor
def inject_globals():
    today = date.today()
    return {
        "today":         today.isoformat(),
        "today_date":    today,
        "active_schema": get_schema() if session.get("logged_in") else DEFAULT_CLIENT_SCHEMA,
        "all_clients":   get_clients() if session.get("logged_in") else [],
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
