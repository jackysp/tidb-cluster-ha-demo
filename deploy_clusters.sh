#!/bin/bash
set -e

# Deploy TiDB clusters using TiUP

# Destroy existing clusters if they exist
tiup cluster destroy cluster_A -y || true
tiup cluster destroy cluster_B -y || true
tiup cluster destroy cluster_C -y || true
tiup cluster destroy cluster_D -y || true

# Cluster IPs
CLUSTER_A_IP="10.148.0.5"
CLUSTER_B_IP="10.148.0.5"
CLUSTER_C_IP="10.148.0.5"
CLUSTER_D_IP="10.148.0.5"

# TiDB version
TIDB_VERSION="v8.5.1"

# Deploy cluster A
tiup cluster deploy cluster_A $TIDB_VERSION ./topology/cluster_A.yaml -y
tiup cluster start cluster_A

# Deploy cluster B
tiup cluster deploy cluster_B $TIDB_VERSION ./topology/cluster_B.yaml -y
tiup cluster start cluster_B

# Deploy cluster C
tiup cluster deploy cluster_C $TIDB_VERSION ./topology/cluster_C.yaml -y
tiup cluster start cluster_C

# Deploy cluster D
tiup cluster deploy cluster_D $TIDB_VERSION ./topology/cluster_D.yaml -y
tiup cluster start cluster_D

sudo mkdir -p /tidb-data/cluster_A/redo
sudo chmod a+rwx /tidb-data/cluster_A/redo

# Enable CDC changefeeds with eventual consistency (GCS storage)
tiup ctl:$TIDB_VERSION cdc changefeed create --server="${CLUSTER_A_IP}:8300" \
  --sink-uri="mysql://root@${CLUSTER_B_IP}:4001/" \
  --config=./cdc-cf-A-to-B.toml \
  --changefeed-id="cf-A-to-B"

tiup ctl:$TIDB_VERSION cdc changefeed create --server="${CLUSTER_A_IP}:8300" \
  --sink-uri="mysql://root@${CLUSTER_C_IP}:4002/" \
  --config=./cdc-cf-A-to-C.toml \
  --changefeed-id="cf-A-to-C"

tiup ctl:$TIDB_VERSION cdc changefeed create --server="${CLUSTER_A_IP}:8300" \
  --sink-uri="mysql://root@${CLUSTER_D_IP}:4003/" \
  --config=./cdc-cf-A-to-D.toml \
  --changefeed-id="cf-A-to-D"

# Enable PiTR for all clusters using BR tools
#tiup br backup full --pd ${CLUSTER_A_IP}:2379 --storage "local:///br_data/cluster_A"
#tiup br backup full --pd ${CLUSTER_B_IP}:2381 --storage "local:///br_data/cluster_B"
#tiup br backup full --pd ${CLUSTER_C_IP}:2383 --storage "local:///br_data/cluster_C"
#tiup br backup full --pd ${CLUSTER_D_IP}:2385 --storage "local:///br_data/cluster_D"

# Start TiDB log backup for PiTR
#tiup br log start --task-name=pitr_A --pd ${CLUSTER_A_IP}:2379 --storage "local:///br_data/cluster_A_log"
#tiup br log start --task-name=pitr_B --pd ${CLUSTER_B_IP}:2381 --storage "local:///br_data/cluster_B_log"
#tiup br log start --task-name=pitr_C --pd ${CLUSTER_C_IP}:2383 --storage "local:///br_data/cluster_C_log"
#tiup br log start --task-name=pitr_D --pd ${CLUSTER_D_IP}:2385 --storage "local:///br_data/cluster_D_log"

# Connect to cluster A: create database/table and insert data
mysql -h ${CLUSTER_A_IP} -P4000 -u root <<EOF
USE TEST;
CREATE TABLE IF NOT EXISTS users (
  id INT PRIMARY KEY,
  name VARCHAR(50)
);
INSERT INTO users (id, name) VALUES (1, 'Alice'), (2, 'Bob');
EOF
