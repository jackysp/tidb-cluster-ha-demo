#!/bin/bash
set -e

# Deploy TiDB clusters using TiUP

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

# Enable CDC syncpoint for each changefeed
tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@${CLUSTER_B_IP}:4001/" --config=./cdc_config.toml
tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@${CLUSTER_C_IP}:4002/" --config=./cdc_config.toml
tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@${CLUSTER_D_IP}:4003/" --config=./cdc_config.toml

# Enable PiTR for all clusters using BR tools
tiup br backup full --pd ${CLUSTER_A_IP}:2379 --storage "local:///br_data/cluster_A"
tiup br backup full --pd ${CLUSTER_B_IP}:2381 --storage "local:///br_data/cluster_B"
tiup br backup full --pd ${CLUSTER_C_IP}:2383 --storage "local:///br_data/cluster_C"
tiup br backup full --pd ${CLUSTER_D_IP}:2385 --storage "local:///br_data/cluster_D"
