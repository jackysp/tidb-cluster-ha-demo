#!/bin/bash

# Recover clusters in case of failure

# Cluster IPs
CLUSTER_B_IP="10.148.0.6"
CLUSTER_C_IP="10.148.0.9"
CLUSTER_D_IP="10.148.0.12"

# Check the syncpoint table in clusters B, C, and D
LATEST_CLUSTER=""
LATEST_TIMESTAMP=0

for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  TIMESTAMP=$(mysql -h $CLUSTER_IP -u root -e "SELECT MAX(ts) FROM tidb_cdc.syncpoint")
  if [ $TIMESTAMP -gt $LATEST_TIMESTAMP ]; then
    LATEST_TIMESTAMP=$TIMESTAMP
    LATEST_CLUSTER=$CLUSTER_IP
  fi
done

echo "Cluster with the latest data: $LATEST_CLUSTER"

# Recover clusters B, C, and D to their latest consistent snapshot using PiTR
for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  tiup br restore full --pd $CLUSTER_IP:2379 --storage "local:///br_data/cluster_${CLUSTER_IP##*.}"
done

# Recreate the changefeed from the recovered cluster to the other clusters
for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  if [ $CLUSTER_IP != $LATEST_CLUSTER ]; then
    tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@${CLUSTER_IP}:4000/" --config=./cdc_config.yaml
  fi
done
