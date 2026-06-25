-- Datastream CDC prerequisites on AlloyDB (postgres logical replication).
-- Run as the postgres superuser against the `tpcds` database.
-- psql "host=<ip> dbname=tpcds user=postgres" -f 03_alloydb_cdc_setup.sql
--
-- Requires database flag alloydb.logical_decoding = on (set by Terraform).

-- 1) Dedicated replication user that Datastream authenticates as.
--    Replace the password to match var.alloydb_password.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'datastream_user') THEN
    CREATE ROLE datastream_user WITH LOGIN REPLICATION PASSWORD 'change-me-strong-password';
  END IF;
END$$;

GRANT USAGE ON SCHEMA public TO datastream_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO datastream_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO datastream_user;

-- 2) Publication covering the replicated tables.
DROP PUBLICATION IF EXISTS datalake_pub;
CREATE PUBLICATION datalake_pub
  FOR TABLE store_sales, customer, item, date_dim, store;

-- 3) Logical replication slot consumed by the stream.
SELECT pg_create_logical_replication_slot('datalake_slot', 'pgoutput')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name = 'datalake_slot'
);

-- Note: publication + slot names must match terraform/datastream.tf
-- (postgresql_source_config.publication / replication_slot).
