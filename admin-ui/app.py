import os
import json
import psycopg2
import psycopg2.extras
from functools import wraps
from datetime import date
from flask import (Flask, render_template, request, redirect,
                   url_for, session, flash, jsonify)

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
CLIENT_SCHEMA = os.environ.get("SAM_CLIENT_SCHEMA", "client_acme")

# Admin credentials (set via env vars)
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
# Servers list
# ---------------------------------------------------------------------------
@app.route("/")
@app.route("/servers")
@login_required
def servers():
    rows = query(f"""
        SELECT
            s.server_id,
            s.hostname,
            s.environment::TEXT,
            s.datacenter,
            s.ip_address::TEXT,
            s.is_active,
            s.last_seen::DATE AS last_seen,
            COALESCE(s.licence_metric_override, 'processor_perpetual') AS licence_metric,
            s.licence_metric_override IS NOT NULL                        AS metric_overridden,
            COUNT(DISTINCT m.csi_id)                                     AS csi_count
        FROM {CLIENT_SCHEMA}.oracle_servers s
        LEFT JOIN {CLIENT_SCHEMA}.server_csi_map m ON m.server_id = s.server_id
        WHERE s.is_active = TRUE
        GROUP BY s.server_id, s.hostname, s.environment, s.datacenter,
                 s.ip_address, s.is_active, s.last_seen, s.licence_metric_override
        ORDER BY s.hostname
    """)
    return render_template("servers.html", servers=rows, schema=CLIENT_SCHEMA)


# ---------------------------------------------------------------------------
# Edit server
# ---------------------------------------------------------------------------
@app.route("/servers/<int:server_id>", methods=["GET", "POST"])
@login_required
def edit_server(server_id):
    if request.method == "POST":
        action = request.form.get("action")

        if action == "set_metric":
            metric = request.form.get("metric")
            if metric == "processor_perpetual":
                # Clear override — default
                execute(
                    f"UPDATE {CLIENT_SCHEMA}.oracle_servers "
                    f"SET licence_metric_override = NULL WHERE server_id = %s",
                    (server_id,)
                )
            else:
                execute(
                    f"UPDATE {CLIENT_SCHEMA}.oracle_servers "
                    f"SET licence_metric_override = %s WHERE server_id = %s",
                    (metric, server_id)
                )
            flash("Licence metric updated.", "success")

        elif action == "assign_csi":
            csi_id     = request.form.get("csi_id")
            family     = request.form.get("product_family")
            consumed   = request.form.get("licences_consumed") or None
            notes      = request.form.get("notes") or None
            assigned_by = ADMIN_USER
            execute(f"""
                INSERT INTO {CLIENT_SCHEMA}.server_csi_map
                  (server_id, csi_id, product_family, licences_consumed, notes, assigned_by)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (server_id, csi_id, COALESCE(line_id,-1), product_family)
                  DO UPDATE SET
                    licences_consumed = EXCLUDED.licences_consumed,
                    notes             = EXCLUDED.notes,
                    updated_at        = NOW()
            """, (server_id, csi_id, family, consumed, notes, assigned_by))
            flash("CSI assignment saved.", "success")

        elif action == "remove_csi":
            map_id = request.form.get("map_id")
            execute(
                f"DELETE FROM {CLIENT_SCHEMA}.server_csi_map WHERE map_id = %s",
                (map_id,)
            )
            flash("CSI assignment removed.", "success")

        return redirect(url_for("edit_server", server_id=server_id))

    # GET
    server = query(
        f"""SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
                   s.ip_address::TEXT, s.last_seen::DATE,
                   COALESCE(s.licence_metric_override, 'processor_perpetual') AS licence_metric,
                   s.licence_metric_override IS NOT NULL AS metric_overridden
            FROM {CLIENT_SCHEMA}.oracle_servers s
            WHERE s.server_id = %s""",
        (server_id,), fetchall=False
    )
    if not server:
        flash("Server not found.", "danger")
        return redirect(url_for("servers"))

    instances = query(
        f"SELECT oracle_sid, edition, db_version FROM {CLIENT_SCHEMA}.oracle_instances "
        f"WHERE server_id = %s AND is_active ORDER BY oracle_sid",
        (server_id,)
    )

    assignments = query(f"""
        SELECT m.map_id, m.csi_id, m.product_family, m.licences_consumed,
               m.notes, m.assigned_by, m.effective_date,
               cs.csi_number, cs.contract_name, cs.support_expiry,
               cs.status AS contract_status
        FROM {CLIENT_SCHEMA}.server_csi_map m
        JOIN shared.csi_contracts cs ON cs.csi_id = m.csi_id
        WHERE m.server_id = %s
        ORDER BY cs.csi_number, m.product_family
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
        f"SELECT * FROM {CLIENT_SCHEMA}.license_position WHERE server_id = %s",
        (server_id,)
    )

    return render_template("edit_server.html",
                           server=server,
                           instances=instances,
                           assignments=assignments,
                           available_csis=available_csis,
                           licence_position=licence_position)


# ---------------------------------------------------------------------------
# CSI contracts browser
# ---------------------------------------------------------------------------
@app.route("/contracts")
@login_required
def contracts():
    rows = query("""
        SELECT cs.csi_id, cs.csi_number, cs.contract_name, cs.vendor_reference,
               cs.purchase_date, cs.support_expiry, cs.is_ula, cs.ula_expiry,
               cs.sharing_policy, cs.status,
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
                 cs.sharing_policy, cs.status, oc.client_code
        ORDER BY cs.csi_number
    """)
    return render_template("contracts.html", contracts=rows)


@app.route("/contracts/<int:csi_id>")
@login_required
def contract_detail(csi_id):
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
    assigned_servers = query(f"""
        SELECT s.hostname, s.environment::TEXT, m.product_family,
               m.licences_consumed, m.notes, m.effective_date, m.map_id
        FROM {CLIENT_SCHEMA}.server_csi_map m
        JOIN {CLIENT_SCHEMA}.oracle_servers s ON s.server_id = m.server_id
        WHERE m.csi_id = %s
        ORDER BY s.hostname
    """, (csi_id,))

    return render_template("contract_detail.html",
                           contract=contract,
                           lines=lines,
                           assigned_servers=assigned_servers)


# ---------------------------------------------------------------------------
# Compliance alerts dashboard
# ---------------------------------------------------------------------------
@app.route("/alerts")
@login_required
def alerts():
    rows = query("SELECT * FROM shared.compliance_alerts ORDER BY severity, days_until NULLS LAST")
    return render_template("alerts.html", alerts=rows)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.context_processor
def inject_today():
    today = date.today()
    return {"today": today.isoformat(), "today_date": today}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
