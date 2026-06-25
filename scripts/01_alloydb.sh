#!/usr/bin/env bash
# STAGE 1 — provision AlloyDB (+ network + PSC attachment), schema + CDC + seed, CHECK.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools

say "STAGE 1: AlloyDB cluster + network + Datastream network attachment"
tf_apply \
  google_alloydb_instance.primary \
  google_compute_network_attachment.datastream \
  google_vpc_access_connector.connector

load_cfg
alloydb_host
ok "AlloyDB private IP: $(tfout alloydb_ip)   public IP: $ALLOYDB_PUB"

wait_for_db

say "create database tpcds (if absent)"
psqlt postgres -tAc "SELECT 1 FROM pg_database WHERE datname='tpcds'" | grep -q 1 \
  || psqlt postgres -c "CREATE DATABASE tpcds;"
ok "tpcds present"

say "apply schema"
psqlt tpcds -f "$SQL_DIR/01_alloydb_schema.sql"

say "apply CDC setup (publication + slot + replication user)"
# inject the real password into the CDC role DDL
tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
load_password
sed "s/change-me-strong-password/${ALLOYDB_PASSWORD}/g" "$SQL_DIR/03_alloydb_cdc_setup.sql" > "$tmp"
psqlt tpcds -f "$tmp"

say "seed dimensions + initial facts"
psqlt tpcds -f "$SQL_DIR/02_alloydb_seed.sql"

echo
say "CHECK — row counts in AlloyDB"
psqlt tpcds -c "
SELECT 'date_dim' t, count(*) n FROM date_dim
UNION ALL SELECT 'customer', count(*) FROM customer
UNION ALL SELECT 'item', count(*) FROM item
UNION ALL SELECT 'store', count(*) FROM store
UNION ALL SELECT 'store_sales', count(*) FROM store_sales
ORDER BY t;"

say "CHECK — replication slot + publication exist"
psqlt tpcds -c "SELECT slot_name, plugin, active FROM pg_replication_slots;"
psqlt tpcds -c "SELECT pubname FROM pg_publication;"

ok "STAGE 1 done. AlloyDB provisioned, seeded, CDC armed."
