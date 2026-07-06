import io
import json
import os
import smtplib
import ssl
from datetime import date, datetime
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
            consumed       = request.form.get("licences_consumed") or None
            notes          = request.form.get("notes") or None
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

    available_csis = query("""
        SELECT cs.csi_id, cs.csi_number, cs.contract_name, cs.support_expiry,
               cs.status,
               STRING_AGG(DISTINCT l.product_family::TEXT, ', ') AS families
        FROM shared.csi_contracts cs
        JOIN shared.license_entitlement_lines l ON l.csi_id = cs.csi_id
        WHERE cs.status = 'active'
        GROUP BY cs.csi_id, cs.csi_number, cs.contract_name,
                 cs.support_expiry, cs.status
        ORDER BY cs.csi_number
    """)

    licence_position = query(
        f"SELECT * FROM {schema}.license_position WHERE server_id = %s", (server_id,)
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

    return render_template("edit_server.html",
                           server=server,
                           instances=instances,
                           assignments=assignments,
                           available_csis=available_csis,
                           licence_position=licence_position,
                           java_installations=java_installations,
                           se2_violations=se2_violations,
                           cpu_validation=cpu_validation)


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
@app.route("/contracts")
@login_required
def contracts():
    rows = query("""
        SELECT cs.csi_id, cs.csi_number, cs.contract_name, cs.vendor_reference,
               cs.purchase_date, cs.support_expiry, cs.is_ula, cs.ula_expiry,
               cs.sharing_policy, cs.status, cs.currency,
               oc.client_code AS owning_client,
               COUNT(DISTINCT l.line_id)  AS line_count,
               SUM(l.quantity)            AS total_qty,
               SUM(l.total_price)         AS total_value,
               STRING_AGG(DISTINCT l.product_name, ' | ' ORDER BY l.product_name) AS products
        FROM shared.csi_contracts cs
        LEFT JOIN shared.license_entitlement_lines l  ON l.csi_id = cs.csi_id AND l.is_active
        LEFT JOIN sam_admin.clients                oc ON oc.client_id = cs.owning_client_id
        GROUP BY cs.csi_id, cs.csi_number, cs.contract_name, cs.vendor_reference,
                 cs.purchase_date, cs.support_expiry, cs.is_ula, cs.ula_expiry,
                 cs.sharing_policy, cs.status, cs.currency, oc.client_code
        ORDER BY cs.csi_number
    """)

    # Sum licences_consumed per CSI across all active client schemas
    active_schemas = [
        r["schema_name"] for r in query(
            "SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name"
        )
    ]
    consumed_by_csi = {}
    if active_schemas:
        union_sql = " UNION ALL ".join(
            f"SELECT csi_id, COALESCE(SUM(licences_consumed), 0) AS consumed "
            f"FROM {s}.server_csi_map GROUP BY csi_id"
            for s in active_schemas
        )
        consumed_rows = query(
            f"SELECT csi_id, SUM(consumed) AS total FROM ({union_sql}) t GROUP BY csi_id"
        )
        consumed_by_csi = {r["csi_id"]: r["total"] for r in consumed_rows}

    # Attach consumed/available to each contract row
    rows = [
        dict(r,
             total_consumed=consumed_by_csi.get(r["csi_id"], 0),
             total_available=max(
                 (r["total_qty"] or 0) - consumed_by_csi.get(r["csi_id"], 0), 0
             ))
        for r in rows
    ]
    return render_template("contracts.html", contracts=rows)


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
