import os
import socket

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)

# Bump this (and commit + push) to demo the CI/CD pipeline and the rolling deployment.
APP_VERSION = os.environ.get("APP_VERSION", "v1.0")


def get_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "appdb"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode="require",
        connect_timeout=5,
    )


def record_visit():
    """Insert a visit row and return (total_visits, error)."""
    try:
        conn = get_conn()
        with conn, conn.cursor() as cur:
            cur.execute(
                "CREATE TABLE IF NOT EXISTS visits ("
                "id SERIAL PRIMARY KEY, host TEXT, ts TIMESTAMPTZ DEFAULT now())"
            )
            cur.execute("INSERT INTO visits (host) VALUES (%s)", (socket.gethostname(),))
            cur.execute("SELECT count(*) FROM visits")
            total = cur.fetchone()[0]
        conn.close()
        return total, None
    except Exception as exc:  # surface DB problems on the page instead of 500
        return None, str(exc)


@app.route("/")
def index():
    total, err = record_visit()
    db_html = (
        f"<p class='ok'>Connected to RDS PostgreSQL. Total visits: <b>{total}</b></p>"
        if err is None
        else f"<p class='bad'>Database error: {err}</p>"
    )
    print(f"GET / served by {socket.gethostname()} version={APP_VERSION} db_error={err}", flush=True)
    return f"""<!doctype html>
<html><head><title>ECS Fargate CI/CD Demo</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:640px;margin:4rem auto;padding:0 1rem}}
.ok{{color:#0a7d32}} .bad{{color:#b00020}}
code{{background:#eee;padding:2px 6px;border-radius:4px}}
.version{{display:inline-block;background:#1a73e8;color:#fff;padding:2px 10px;border-radius:12px;font-size:0.9em}}
</style></head><body>
<h1>Hello from ECS Fargate <span class="version">{APP_VERSION}</span></h1>
<p>Served by container: <code>{socket.gethostname()}</code></p>
{db_html}
<p>Refresh to see the load balancer rotate between tasks. Push a new APP_VERSION to see a rolling deployment.</p>
</body></html>"""


@app.route("/health")
def health():
    # Used by the ALB target group; intentionally independent of the DB.
    return jsonify(status="ok")


@app.route("/version")
def version():
    return jsonify(version=APP_VERSION, host=socket.gethostname())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
