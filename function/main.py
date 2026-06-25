"""Mini-batch streamer: inserts a handful of store_sales rows into AlloyDB.

Invoked by Cloud Scheduler (every minute). Each call appends a random small
batch of fact rows referencing existing dimension keys, so Datastream picks
them up as INSERT change events into the alloydb_iceberg dataset.
"""
import os
import random

import functions_framework
import psycopg2

HOST = os.environ["ALLOYDB_HOST"]
DB = os.environ.get("ALLOYDB_DB", "tpcds")
USER = os.environ.get("ALLOYDB_USER", "postgres")
PASSWORD = os.environ["ALLOYDB_PASSWORD"]
BATCH_MIN = int(os.environ.get("BATCH_MIN", "20"))
BATCH_MAX = int(os.environ.get("BATCH_MAX", "60"))


def _connect():
    return psycopg2.connect(
        host=HOST, dbname=DB, user=USER, password=PASSWORD, port=5432, connect_timeout=10
    )


@functions_framework.http
def stream_batch(request):
    n = random.randint(BATCH_MIN, BATCH_MAX)
    conn = _connect()
    try:
        with conn, conn.cursor() as cur:
            # Pull existing dimension key ranges so foreign keys stay valid.
            cur.execute("SELECT min(c_customer_sk), max(c_customer_sk) FROM customer")
            cust_lo, cust_hi = cur.fetchone()
            cur.execute("SELECT min(i_item_sk), max(i_item_sk) FROM item")
            item_lo, item_hi = cur.fetchone()
            cur.execute("SELECT min(d_date_sk), max(d_date_sk) FROM date_dim")
            date_lo, date_hi = cur.fetchone()
            cur.execute("SELECT min(s_store_sk), max(s_store_sk) FROM store")
            store_lo, store_hi = cur.fetchone()
            cur.execute("SELECT COALESCE(max(ss_ticket_number), 0) FROM store_sales")
            ticket = cur.fetchone()[0]

            rows = []
            for i in range(n):
                ticket += 1
                qty = random.randint(1, 10)
                price = round(random.uniform(1.0, 250.0), 2)
                rows.append((
                    ticket,
                    random.randint(item_lo, item_hi),
                    random.randint(cust_lo, cust_hi),
                    random.randint(date_lo, date_hi),
                    random.randint(store_lo, store_hi),
                    qty,
                    price,
                    round(qty * price, 2),
                ))

            cur.executemany(
                """
                INSERT INTO store_sales
                  (ss_ticket_number, ss_item_sk, ss_customer_sk, ss_sold_date_sk,
                   ss_store_sk, ss_quantity, ss_sales_price, ss_net_paid)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                rows,
            )
        return (f"inserted {n} store_sales rows (up to ticket {ticket})", 200)
    finally:
        conn.close()
