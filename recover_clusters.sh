#!/bin/bash

set -e

# Shutdown cluster_A to avoid conflicts during recovery
tiup cluster stop cluster_A -y || true

# Recover clusters in case of failure

# Cluster IPs, SQL ports and version
TIDB_VERSION="v8.5.1"
CLUSTER_B_IP="10.148.0.5"; CLUSTER_B_SQL_PORT=4001
CLUSTER_C_IP="10.148.0.5"; CLUSTER_C_SQL_PORT=4002
CLUSTER_D_IP="10.148.0.5"; CLUSTER_D_SQL_PORT=4003
CLUSTERS=(cluster_B cluster_C cluster_D)
CLUSTER_IPS=($CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP)
CLUSTER_PORTS=($CLUSTER_B_SQL_PORT $CLUSTER_C_SQL_PORT $CLUSTER_D_SQL_PORT)
CLUSTER_CDC_PORTS=(8301 8302 8303)

# Step 1: compare latest primary_ts of each cluster and mark most recent as new primary
NEW_PRIMARY_CLUSTER=""
NEW_PRIMARY_TS=0
NEW_PRIMARY_CLUSTER_INDEX=0
declare -a PRIMARY_TS_LIST SECONDARY_TS_LIST
for i in "${!CLUSTERS[@]}"; do
  CLUSTER_IP=${CLUSTER_IPS[i]}
  SQL_PORT=${CLUSTER_PORTS[i]}
  read PRIMARY_TS SECONDARY_TS <<< $(mysql -h $CLUSTER_IP -P $SQL_PORT -u root -N -e \
    "SELECT IFNULL(MAX(CAST(primary_ts AS UNSIGNED)),0), IFNULL(MAX(CAST(secondary_ts AS UNSIGNED)),0) FROM tidb_cdc.syncpoint_v1")
  PRIMARY_TS_LIST[i]=$PRIMARY_TS
  SECONDARY_TS_LIST[i]=$SECONDARY_TS
  if [ $PRIMARY_TS -gt $NEW_PRIMARY_TS ]; then
    NEW_PRIMARY_TS=$PRIMARY_TS
    NEW_PRIMARY_CLUSTER_INDEX=$i
  fi
done
NEW_PRIMARY_CLUSTER_IP=${CLUSTER_IPS[NEW_PRIMARY_CLUSTER_INDEX]}
NEW_PRIMARY_CLUSTER_PORT=${CLUSTER_PORTS[NEW_PRIMARY_CLUSTER_INDEX]}
NEW_PRIMARY_CLUSTER_CDC_PORT=${CLUSTER_CDC_PORTS[NEW_PRIMARY_CLUSTER_INDEX]}
echo "New primary cluster: $NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT with primary_ts $NEW_PRIMARY_TS"

# Step 2: flashback other clusters to their latest secondary_ts
# Note: FLASHBACK only reverts DML changes to the specified TSO. It cannot recover DDLs.
# If any DDLs were executed after the target TSO, those changes won't be undone.
# Ensure you wait for a fresh CDC syncpoint to include DDLs before recovery.
for i in "${!CLUSTERS[@]}"; do
   CLUSTER_IP=${CLUSTER_IPS[i]}
   TIDB_PORT=${CLUSTER_PORTS[i]}
   TSO=${SECONDARY_TS_LIST[i]}
   echo "Flashing back cluster at $CLUSTER_IP:$TIDB_PORT to TSO $TSO"
   mysql -h $CLUSTER_IP -P $TIDB_PORT -u root -e "FLASHBACK CLUSTER TO TSO $TSO;"
 done

# Step 3 & 4: for each downstream cluster, compute start TS and create changefeed
echo "Recreating changefeeds from new primary $NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT"
# iterate by index
for i in "${!CLUSTERS[@]}"; do
  if [ $i -eq $NEW_PRIMARY_CLUSTER_INDEX ]; then continue; fi
  CLUSTER_NAME=${CLUSTERS[i]}
  CLUSTER_IP=${CLUSTER_IPS[i]}
  SQL_PORT=${CLUSTER_PORTS[i]}
  TARGET_PRIMARY=${PRIMARY_TS_LIST[i]}
  START_TS=$(mysql -h $NEW_PRIMARY_CLUSTER_IP -P $NEW_PRIMARY_CLUSTER_PORT -u root -N -e \
    "SELECT IFNULL(MAX(CAST(secondary_ts AS UNSIGNED)),0) FROM tidb_cdc.syncpoint_v1 WHERE CAST(primary_ts AS UNSIGNED) <= $TARGET_PRIMARY")
  echo "  To $CLUSTER_NAME, primary_ts=$TARGET_PRIMARY -> start-ts=$START_TS"
  tiup ctl:$TIDB_VERSION cdc --server="$NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_CDC_PORT" changefeed create \
    --sink-uri="mysql://root@${CLUSTER_IP}:$SQL_PORT/" \
    --start-ts=$START_TS \
    --config=./cdc_config.toml
done
