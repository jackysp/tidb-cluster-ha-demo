#!/bin/bash

# Recover clusters in case of failure

# Cluster IPs, SQL ports and version
TIDB_VERSION="v8.5.1"
CLUSTER_B_IP="10.148.0.5"; CLUSTER_B_SQL_PORT=4001
CLUSTER_C_IP="10.148.0.5"; CLUSTER_C_SQL_PORT=4002
CLUSTER_D_IP="10.148.0.5"; CLUSTER_D_SQL_PORT=4003

# Step 1: compare latest primary_ts of each cluster and mark most recent as new primary
NEW_PRIMARY_CLUSTER=""
NEW_PRIMARY_TS=0
for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  # map SQL port per cluster
  if [ "$CLUSTER_IP" = "$CLUSTER_B_IP" ]; then SQL_PORT=$CLUSTER_B_SQL_PORT
  elif [ "$CLUSTER_IP" = "$CLUSTER_C_IP" ]; then SQL_PORT=$CLUSTER_C_SQL_PORT
  else SQL_PORT=$CLUSTER_D_SQL_PORT; fi
  # fetch max primary_ts and secondary_ts
  read PRIMARY_TS SECONDARY_TS <<< $(mysql -h $CLUSTER_IP -P $SQL_PORT -u root -N -e \
    "SELECT IFNULL(MAX(CAST(primary_ts AS UNSIGNED)),0), IFNULL(MAX(CAST(secondary_ts AS UNSIGNED)),0) FROM tidb_cdc.syncpoint_v1")
  # store per-cluster timestamps
  if [ "$CLUSTER_IP" = "$CLUSTER_B_IP" ]; then
    PRIMARY_TS_B=$PRIMARY_TS; SECONDARY_TS_B=$SECONDARY_TS
  elif [ "$CLUSTER_IP" = "$CLUSTER_C_IP" ]; then
    PRIMARY_TS_C=$PRIMARY_TS; SECONDARY_TS_C=$SECONDARY_TS
  else
    PRIMARY_TS_D=$PRIMARY_TS; SECONDARY_TS_D=$SECONDARY_TS
  fi
  # update new primary if this cluster has a higher primary_ts
  if [ $PRIMARY_TS -gt $NEW_PRIMARY_TS ]; then
    NEW_PRIMARY_TS=$PRIMARY_TS
    NEW_PRIMARY_CLUSTER_IP=$CLUSTER_IP
    NEW_PRIMARY_CLUSTER_PORT=$SQL_PORT
  fi
done

echo "New primary cluster: $NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT with primary_ts $NEW_PRIMARY_TS"

# Step 2: flashback other clusters to their latest secondary_ts
for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  if [ "$CLUSTER_IP" != "$NEW_PRIMARY_CLUSTER" ]; then
    # determine TiDB SQL port and secondary TSO
    if [ "$CLUSTER_IP" = "$CLUSTER_B_IP" ]; then
      TIDB_PORT=4001; TSO=$SECONDARY_TS_B
    elif [ "$CLUSTER_IP" = "$CLUSTER_C_IP" ]; then
      TIDB_PORT=4002; TSO=$SECONDARY_TS_C
    else
      TIDB_PORT=4003; TSO=$SECONDARY_TS_D
    fi
    echo "Flashing back cluster at $CLUSTER_IP:$TIDB_PORT to TSO $TSO"
    mysql -h $CLUSTER_IP -P $TIDB_PORT -u root -e "FLASHBACK CLUSTER TO TSO $TSO;"
  fi
done

# Step 3 & 4: for each downstream cluster, compute start TS and create changefeed
echo "Recreating changefeeds from new primary $NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT"
for CLUSTER_IP in $CLUSTER_B_IP $CLUSTER_C_IP $CLUSTER_D_IP; do
  if [ "$CLUSTER_IP" != "$NEW_PRIMARY_CLUSTER_IP" ]; then
    # map ports and cluster name
    if [ "$CLUSTER_IP" = "$CLUSTER_B_IP" ]; then
      SQL_PORT=$CLUSTER_B_SQL_PORT; CDC_PORT=4001; CLUSTER_NAME=cluster_B; TARGET_PRIMARY=$PRIMARY_TS_B
    elif [ "$CLUSTER_IP" = "$CLUSTER_C_IP" ]; then
      SQL_PORT=$CLUSTER_C_SQL_PORT; CDC_PORT=4002; CLUSTER_NAME=cluster_C; TARGET_PRIMARY=$PRIMARY_TS_C
    else
      SQL_PORT=$CLUSTER_D_SQL_PORT; CDC_PORT=4003; CLUSTER_NAME=cluster_D; TARGET_PRIMARY=$PRIMARY_TS_D
    fi
    # compute start TSO from primary history where primary_ts <= target_primary
    START_TS=$(mysql -h $NEW_PRIMARY_CLUSTER_IP -P $NEW_PRIMARY_CLUSTER_PORT -u root -N -e \
      "SELECT IFNULL(MAX(CAST(secondary_ts AS UNSIGNED)),0) FROM tidb_cdc.syncpoint_v1 WHERE CAST(primary_ts AS UNSIGNED) <= $TARGET_PRIMARY")
    echo "  To $CLUSTER_NAME, primary_ts=$TARGET_PRIMARY -> start-ts=$START_TS"
    tiup ctl:$TIDB_VERSION cdc changefeed create \
      --sink-uri="mysql://root@${CLUSTER_IP}:$CDC_PORT/" \
      --start-ts=$START_TS \
      --config=./cdc_config.toml
  fi
done
