-- TPC-DS subset (minimal star schema) for the AlloyDB `tpcds` database.
-- Run against AlloyDB:  psql "host=<ip> dbname=tpcds user=postgres" -f 01_alloydb_schema.sql
-- Create the database first if needed:  CREATE DATABASE tpcds;

-- ---- dimensions ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS date_dim (
  d_date_sk   integer PRIMARY KEY,
  d_date      date    NOT NULL,
  d_year      integer NOT NULL,
  d_moy       integer NOT NULL,   -- month of year
  d_dom       integer NOT NULL    -- day of month
);

CREATE TABLE IF NOT EXISTS customer (
  c_customer_sk integer PRIMARY KEY,
  c_first_name  text,
  c_last_name   text,
  c_birth_year  integer,
  c_email       text
);

CREATE TABLE IF NOT EXISTS item (
  i_item_sk       integer PRIMARY KEY,
  i_item_id       text,
  i_category      text,
  i_brand         text,
  i_current_price numeric(7,2)
);

CREATE TABLE IF NOT EXISTS store (
  s_store_sk   integer PRIMARY KEY,
  s_store_name text,
  s_state      text
);

-- ---- fact (streamed into by the Cloud Function) --------------------------
CREATE TABLE IF NOT EXISTS store_sales (
  ss_sale_sk       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ss_ticket_number bigint  NOT NULL,
  ss_item_sk       integer NOT NULL REFERENCES item(i_item_sk),
  ss_customer_sk   integer REFERENCES customer(c_customer_sk),
  ss_sold_date_sk  integer REFERENCES date_dim(d_date_sk),
  ss_store_sk      integer REFERENCES store(s_store_sk),
  ss_quantity      integer,
  ss_sales_price   numeric(7,2),
  ss_net_paid      numeric(7,2)
);

CREATE INDEX IF NOT EXISTS ix_ss_item ON store_sales(ss_item_sk);
CREATE INDEX IF NOT EXISTS ix_ss_date ON store_sales(ss_sold_date_sk);
