#!/usr/bin/env bash
# STAGE 1 — provision AlloyDB (+ network + proxy), create schema + CDC + seed, CHECK.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools

say "STAGE 1: AlloyDB cluster, network, Datastream proxy VM"
tf_apply \
  google_alloydb_instance.primary \
  google_compute_instance.ds_proxy \
  google_compute_router_nat.nat \
  google_compute_firewall.allow_internal \
  google_compute_firewall.allow_iap_ssh \
  google_vpc_access_connector.connector

load_cfg
ok "AlloyDB IP: $(tfout alloydb_ip)   proxy: $PROXY"

say "waiting 30s for proxy VM startup script (socat) to settle"
sleep 30

start_tunnel

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
