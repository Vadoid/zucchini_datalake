"""Sync Control Panel — FastAPI backend for the AlloyDB -> Datastream -> BQ Iceberg POC.

Runs on Cloud Run (service account `datalake-ui`). Reaches AlloyDB over the
serverless VPC connector (private IP) and drives the pipeline via GCP APIs:

  * Datastream  — read/edit the stream's `include_objects` (per-table sync on/off,
                  and switching on brand-new tables).
  * Scheduler   — burst now (run_job) / auto-burst on-off (resume/pause_job).
  * BigQuery    — per-table Iceberg row counts + replication lag.
  * AlloyDB     — list public tables, row counts, ALTER PUBLICATION.

A table feeds BQ Iceberg iff it is BOTH in publication `datalake_pub` AND in the
stream's `include_objects`. "Turn on" therefore = ADD to publication + ADD to the
stream object list (Datastream auto-creates `alloydb_iceberg.public_<t>` and
backfills). "Turn off" = remove from the stream object list (existing rows stay).
"""
import json
import os
import re
import urllib.request

import psycopg2
import google.auth.transport.requests
import google.oauth2.id_token
from psycopg2 import sql as pgsql
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from google.cloud import bigquery, datastream_v1, scheduler_v1
from google.protobuf import field_mask_pb2

# --- config (mirrors terraform/function.tf env) ----------------------------
PROJECT = os.environ["PROJECT"]
REGION = os.environ["REGION"]
STREAM_ID = os.environ.get("STREAM_ID", "alloydb-to-iceberg")
SCHEDULER_JOB = os.environ.get("SCHEDULER_JOB", "datalake-stream-tick")
BQ_DATASET = os.environ.get("BQ_DATASET", "alloydb_iceberg")
PUBLICATION = os.environ.get("PUBLICATION", "datalake_pub")
FUNCTION_URI = os.environ["FUNCTION_URI"]

DB_HOST = os.environ["ALLOYDB_HOST"]
DB_NAME = os.environ.get("ALLOYDB_DB", "tpcds")
DB_USER = os.environ.get("ALLOYDB_USER", "postgres")
DB_PASSWORD = os.environ["ALLOYDB_PASSWORD"]

HERE = os.path.dirname(__file__)

ds = datastream_v1.DatastreamClient()
sched = scheduler_v1.CloudSchedulerClient()
bq = bigquery.Client(project=PROJECT)

STREAM_NAME = ds.stream_path(PROJECT, REGION, STREAM_ID)
JOB_NAME = sched.job_path(PROJECT, REGION, SCHEDULER_JOB)

app = FastAPI(title="Sync Control Panel")


# --- AlloyDB ---------------------------------------------------------------
def db():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD,
        port=5432, connect_timeout=10,
    )


def alloydb_tables():
    """Public base tables with live row counts and publication membership."""
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema='public' AND table_type='BASE TABLE' "
            "ORDER BY table_name"
        )
        names = [r[0] for r in cur.fetchall()]

        cur.execute(
            "SELECT tablename FROM pg_publication_tables WHERE pubname=%s",
            (PUBLICATION,),
        )
        published = {r[0] for r in cur.fetchall()}

        # Primary-key columns per table, to count current-state rows in BQ
        # (the append-only log holds a row per change + per re-backfill).
        cur.execute(
            "SELECT tc.table_name, kcu.column_name "
            "FROM information_schema.table_constraints tc "
            "JOIN information_schema.key_column_usage kcu "
            "  ON tc.constraint_name=kcu.constraint_name "
            " AND tc.table_schema=kcu.table_schema "
            "WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema='public' "
            "ORDER BY tc.table_name, kcu.ordinal_position"
        )
        pks = {}
        for tbl, col in cur.fetchall():
            pks.setdefault(tbl, []).append(col)

        counts = {}
        for t in names:
            cur.execute(pgsql.SQL("SELECT count(*) FROM public.{}").format(pgsql.Identifier(t)))
            counts[t] = cur.fetchone()[0]
    return names, published, counts, pks


def publication_add(table):
    # Idempotent: a table already in the publication raises DuplicateObject (42710).
    conn = db()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                pgsql.SQL("ALTER PUBLICATION {} ADD TABLE public.{}").format(
                    pgsql.Identifier(PUBLICATION), pgsql.Identifier(table)
                )
            )
    except psycopg2.errors.DuplicateObject:
        pass
    finally:
        conn.close()


# --- Datastream include_objects -------------------------------------------
def _included_set(stream):
    inc = stream.source_config.postgresql_source_config.include_objects
    out = set()
    for schema in inc.postgresql_schemas:
        for tbl in schema.postgresql_tables:
            out.add(tbl.table)
    return out


def stream_status():
    stream = ds.get_stream(name=STREAM_NAME)
    state = datastream_v1.Stream.State(stream.state).name
    return _included_set(stream), state


def set_synced(table, on, valid_tables):
    if table not in valid_tables:
        raise HTTPException(404, f"unknown table {table!r}")

    stream = ds.get_stream(name=STREAM_NAME)
    wanted = set(_included_set(stream))  # currently-included `public` tables
    if on:
        publication_add(table)  # must be published before Datastream can read it
        wanted.add(table)
    else:
        wanted.discard(table)

    # Rebuild include_objects from typed proto-plus messages (the repeated fields
    # are list-like: assign, not .add()). Single `public` schema for this POC.
    stream.source_config.postgresql_source_config.include_objects = (
        datastream_v1.PostgresqlRdbms(
            postgresql_schemas=[
                datastream_v1.PostgresqlSchema(
                    schema="public",
                    postgresql_tables=[
                        datastream_v1.PostgresqlTable(table=t) for t in sorted(wanted)
                    ],
                )
            ]
        )
    )

    ds.update_stream(
        stream=stream,
        update_mask=field_mask_pb2.FieldMask(
            paths=["source_config.postgresql_source_config.include_objects"]
        ),
    ).result()


# --- BigQuery stats --------------------------------------------------------
def bq_stats(table, pk_cols):
    """(current_rows, append_log_rows, lag_seconds); (None, None, None) if the table is absent.

    The Iceberg table is an append-only log (a row per CDC change AND per
    re-backfill). current_rows = distinct primary key (matches AlloyDB);
    append_log_rows = raw COUNT(*). Lag = age of the newest replicated row
    (source_timestamp is INT64 epoch-millis). No PK -> current falls back to raw.
    """
    fq = f"`{PROJECT}.{BQ_DATASET}.public_{table}`"
    if pk_cols:
        key = "TO_JSON_STRING(STRUCT(" + ", ".join(f"`{c}`" for c in pk_cols) + "))"
        n_expr = f"COUNT(DISTINCT {key})"
    else:
        n_expr = "COUNT(*)"
    q = (
        f"SELECT {n_expr} AS n, COUNT(*) AS raw, "
        f"TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), "
        f"TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)), SECOND) AS lag "
        f"FROM {fq}"
    )
    try:
        row = next(iter(bq.query(q).result()))
        return row["n"], row["raw"], row["lag"]
    except Exception:
        return None, None, None


def web_source_counts():
    """Row counts for the statically-loaded BigQuery Iceberg side of the join."""
    q = (
        f"SELECT (SELECT COUNT(*) FROM `{PROJECT}.bigquery_iceberg.web_sales`)   AS web_sales, "
        f"       (SELECT COUNT(*) FROM `{PROJECT}.bigquery_iceberg.web_returns`) AS web_returns"
    )
    try:
        row = next(iter(bq.query(q).result()))
        return {"web_sales": row["web_sales"], "web_returns": row["web_returns"]}
    except Exception:
        return {"web_sales": None, "web_returns": None}


# --- Scheduler -------------------------------------------------------------
def scheduler_state():
    job = sched.get_job(name=JOB_NAME)
    return scheduler_v1.Job.State(job.state).name


# --- Stream health ---------------------------------------------------------
def stream_objects_health():
    """table -> {backfill_state, error} from Datastream stream objects (best-effort)."""
    out = {}
    try:
        for obj in ds.list_stream_objects(parent=STREAM_NAME):
            tbl = obj.source_object.postgresql_identifier.table
            if not tbl:
                continue
            bf = obj.backfill_job
            state = datastream_v1.BackfillJob.State(bf.state).name if (bf and bf.state) else None
            errs = list(getattr(bf, "errors", []) or []) + list(getattr(obj, "errors", []) or [])
            out[tbl] = {"backfill_state": state, "error": (errs[0].message if errs else None)}
    except Exception:
        pass
    return out


# --- Function invocation (burst) -------------------------------------------
def invoke_function(count=None):
    """POST the streamer function with an OIDC token; optional row count override."""
    authreq = google.auth.transport.requests.Request()
    token = google.oauth2.id_token.fetch_id_token(authreq, FUNCTION_URI)
    payload = json.dumps({"count": int(count)} if count else {}).encode()
    req = urllib.request.Request(
        FUNCTION_URI, method="POST", data=payload,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read().decode("utf-8", "replace")[:200]


# --- API -------------------------------------------------------------------
class Toggle(BaseModel):
    on: bool


@app.get("/api/status")
def status():
    names, published, counts, pks = alloydb_tables()
    included, stream_state = stream_status()
    health = stream_objects_health()
    tables, lags, errors = [], [], []
    for t in names:
        synced = t in included
        bq_rows, bq_appendlog, lag = bq_stats(t, pks.get(t, []))  # (None,...) if BQ table absent
        h = health.get(t, {})
        if synced and lag is not None:
            lags.append(lag)
        if h.get("error"):
            errors.append({"table": t, "message": h["error"]})
        tables.append({
            "name": t,
            "synced": synced,
            "in_publication": t in published,
            "alloydb_rows": counts[t],
            "bq_rows": bq_rows,
            "bq_appendlog": bq_appendlog,
            "lag_seconds": lag,
            "backfill_state": h.get("backfill_state"),
            "error": h.get("error"),
        })
    return {
        "tables": tables,
        "stream_state": stream_state,
        "scheduler_state": scheduler_state(),
        "freshness_seconds": min(lags) if lags else None,  # newest event across tables
        "errors": errors,
        "web_sources": web_source_counts(),
    }


@app.get("/api/revenue")
def revenue():
    """The headline cross-source join: store (AlloyDB live) vs web (Iceberg static)."""
    q = (
        "SELECT i_category, channel, line_items, units, "
        "CAST(gross_revenue AS FLOAT64) AS gross_revenue, returns_units, "
        "CAST(returns_amt AS FLOAT64) AS returns_amt, CAST(net_revenue AS FLOAT64) AS net_revenue "
        f"FROM `{PROJECT}.common_layer.channel_revenue_by_category` "
        "ORDER BY i_category, channel"
    )
    try:
        rows = [dict(r) for r in bq.query(q).result()]
    except Exception as e:
        return {"rows": [], "error": str(e)}
    return {"rows": rows}


class Mutate(BaseModel):
    action: str  # "update" | "delete"


@app.post("/api/cdc/mutate")
def cdc_mutate(body: Mutate):
    """Demo full CDC: UPDATE or DELETE the newest store_sales row in AlloyDB.

    The change flows through Datastream into the append-only log (a new version
    or a DELETE marker), and the `store_sales_current` view dedups/drops it.
    """
    conn = db()
    try:
        with conn, conn.cursor() as cur:
            if body.action == "update":
                cur.execute(
                    "UPDATE store_sales SET ss_net_paid = ROUND(ss_net_paid * 1.10, 2) "
                    "WHERE ss_sale_sk = (SELECT MAX(ss_sale_sk) FROM store_sales) "
                    "RETURNING ss_sale_sk, ss_net_paid"
                )
                r = cur.fetchone()
                return {"ok": True, "action": "update", "ss_sale_sk": r[0] if r else None,
                        "detail": f"bumped ss_sale_sk {r[0]} net_paid to {r[1]}" if r else "no rows"}
            if body.action == "delete":
                cur.execute(
                    "DELETE FROM store_sales WHERE ss_sale_sk = "
                    "(SELECT MAX(ss_sale_sk) FROM store_sales) RETURNING ss_sale_sk"
                )
                r = cur.fetchone()
                return {"ok": True, "action": "delete", "ss_sale_sk": r[0] if r else None,
                        "detail": f"deleted ss_sale_sk {r[0]}" if r else "no rows"}
            raise HTTPException(400, "action must be update|delete")
    finally:
        conn.close()


@app.post("/api/tables/{name}/sync")
def sync(name: str, body: Toggle):
    names, _, _, _ = alloydb_tables()
    set_synced(name, body.on, set(names))
    return {"name": name, "synced": body.on}


class Burst(BaseModel):
    count: int | None = None   # rows per batch; None -> function's random 20-60
    batches: int = 1           # how many batches to fire


@app.post("/api/burst/once")
def burst_once(body: Burst = Burst()):
    # Invoke the streamer function directly, independent of the scheduler:
    # Scheduler's RunJob API requires the job be ENABLED, so it would fail
    # whenever auto-burst is off.
    batches = max(1, min(20, body.batches))
    total, detail = 0, ""
    for _ in range(batches):
        detail = invoke_function(body.count)
        m = re.search(r"inserted (\d+)", detail)
        if m:
            total += int(m.group(1))
    return {"ok": True, "inserted": total, "batches": batches, "detail": detail}


@app.post("/api/burst/auto")
def burst_auto(body: Toggle):
    if body.on:
        sched.resume_job(name=JOB_NAME)
    else:
        sched.pause_job(name=JOB_NAME)
    return {"auto": body.on}


@app.get("/")
def index():
    # no-store so a redeploy is never masked by a cached page.
    return FileResponse(
        os.path.join(HERE, "static", "index.html"),
        headers={"Cache-Control": "no-store"},
    )


app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")
