-- Tiny seed data for the AlloyDB TPC-DS subset.
-- psql "host=<ip> dbname=tpcds user=postgres" -f 02_alloydb_seed.sql

-- date_dim: all days of 2025 (sk = 2025NNN ordinal).
INSERT INTO date_dim (d_date_sk, d_date, d_year, d_moy, d_dom)
SELECT 20250000 + g,
       (DATE '2025-01-01' + (g - 1)),
       EXTRACT(YEAR  FROM DATE '2025-01-01' + (g - 1))::int,
       EXTRACT(MONTH FROM DATE '2025-01-01' + (g - 1))::int,
       EXTRACT(DAY   FROM DATE '2025-01-01' + (g - 1))::int
FROM generate_series(1, 365) AS g
ON CONFLICT DO NOTHING;

-- customer: 200 rows.
INSERT INTO customer (c_customer_sk, c_first_name, c_last_name, c_birth_year, c_email)
SELECT g,
       'First' || g,
       'Last'  || g,
       1950 + (g % 50),
       'cust' || g || '@example.com'
FROM generate_series(1, 200) AS g
ON CONFLICT DO NOTHING;

-- item: 100 rows across a few categories/brands.
INSERT INTO item (i_item_sk, i_item_id, i_category, i_brand, i_current_price)
SELECT g,
       'ITEM' || lpad(g::text, 5, '0'),
       (ARRAY['Electronics','Home','Sports','Books','Grocery'])[1 + (g % 5)],
       (ARRAY['Acme','Globex','Initech','Umbrella'])[1 + (g % 4)],
       round((5 + random() * 245)::numeric, 2)
FROM generate_series(1, 100) AS g
ON CONFLICT DO NOTHING;

-- store: 10 rows.
INSERT INTO store (s_store_sk, s_store_name, s_state)
SELECT g,
       'Store ' || g,
       (ARRAY['CA','NY','TX','WA','IL'])[1 + (g % 5)]
FROM generate_series(1, 10) AS g
ON CONFLICT DO NOTHING;

-- store_sales: ~2000 initial fact rows (the Cloud Function appends more later).
INSERT INTO store_sales
  (ss_ticket_number, ss_item_sk, ss_customer_sk, ss_sold_date_sk, ss_store_sk,
   ss_quantity, ss_sales_price, ss_net_paid)
SELECT g,
       1 + (random() * 99)::int,
       1 + (random() * 199)::int,
       20250000 + 1 + (random() * 364)::int,
       1 + (random() * 9)::int,
       q.qty,
       q.price,
       round((q.qty * q.price)::numeric, 2)
FROM generate_series(1, 2000) AS g
CROSS JOIN LATERAL (
  SELECT (1 + (random() * 9)::int) AS qty,
         round((1 + random() * 249)::numeric, 2) AS price
) AS q;
