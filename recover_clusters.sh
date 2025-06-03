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

# Step 1: apply redo logs from GCS for each changefeed
echo "Applying redo logs from GCS for each changefeed"
CDC_STORAGE_PATHS=(
  "file:///tidb-data/cluster_A/redo/cf-A-to-B"
  "file:///tidb-data/cluster_A/redo/cf-A-to-C"
  "file:///tidb-data/cluster_A/redo/cf-A-to-D"
)
for i in "${!CLUSTERS[@]}"; do
  CLUSTER_IP=${CLUSTER_IPS[i]}
  SQL_PORT=${CLUSTER_PORTS[i]}
  STORAGE=${CDC_STORAGE_PATHS[i]}
  echo "  Applying redo from $STORAGE to $CLUSTER_IP:$SQL_PORT"
  tiup cdc:$TIDB_VERSION redo apply \
    --storage "$STORAGE" \
    --tmp-dir "/tmp/redo" \
    --sink-uri "mysql://root@${CLUSTER_IP}:${SQL_PORT}"
done

# Step 2: determine new primary based on redo meta
echo "Checking resolved ts for each redo storage"
declare -a RESOLVED_TS_LIST
NEW_PRIMARY_TS=0
NEW_PRIMARY_CLUSTER_INDEX=0
for i in "${!CLUSTERS[@]}"; do
  STORAGE=${CDC_STORAGE_PATHS[i]}
  echo "  Fetching meta for $STORAGE"
  META_OUTPUT=$(tiup cdc:$TIDB_VERSION redo meta --storage "$STORAGE" 2>/dev/null)
  RESOLVED_TS=$(echo "$META_OUTPUT" | grep -Eo 'resolved-ts:[[:space:]]*[0-9]+' | awk -F: '{print $2}' | tr -d ' ')
  RESOLVED_TS_LIST[i]=$RESOLVED_TS
  echo "    Resolved-ts for ${CLUSTERS[i]}: $RESOLVED_TS"
  if [[ "$RESOLVED_TS" -gt "$NEW_PRIMARY_TS" ]]; then
    NEW_PRIMARY_TS=$RESOLVED_TS
    NEW_PRIMARY_CLUSTER_INDEX=$i
  fi
done
NEW_PRIMARY_CLUSTER=${CLUSTERS[$NEW_PRIMARY_CLUSTER_INDEX]}
NEW_PRIMARY_CLUSTER_IP=${CLUSTER_IPS[$NEW_PRIMARY_CLUSTER_INDEX]}
NEW_PRIMARY_CLUSTER_PORT=${CLUSTER_PORTS[$NEW_PRIMARY_CLUSTER_INDEX]}
NEW_PRIMARY_CLUSTER_CDC_PORT=${CLUSTER_CDC_PORTS[$NEW_PRIMARY_CLUSTER_INDEX]}
echo "New primary cluster: $NEW_PRIMARY_CLUSTER ($NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT) with resolved-ts $NEW_PRIMARY_TS"

## Step 3 & 4: for each downstream cluster, compute start TS and create changefeed
echo "Recreating changefeeds from new primary $NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_PORT"
# prepare redo directory for new primary logs
sudo mkdir -p /tidb-data/${NEW_PRIMARY_CLUSTER}/redo
sudo chmod a+rwx /tidb-data/${NEW_PRIMARY_CLUSTER}/redo

for i in "${!CLUSTERS[@]}"; do
  if [ $i -eq $NEW_PRIMARY_CLUSTER_INDEX ]; then continue; fi
  CLUSTER_NAME=${CLUSTERS[i]}
  CLUSTER_IP=${CLUSTER_IPS[i]}
  SQL_PORT=${CLUSTER_PORTS[i]}
  TARGET_PRIMARY=${RESOLVED_TS_LIST[i]}
  START_TS=$(mysql -h $NEW_PRIMARY_CLUSTER_IP -P $NEW_PRIMARY_CLUSTER_PORT -u root -N -e \
    "SELECT IFNULL(MAX(CAST(secondary_ts AS UNSIGNED)),0) FROM tidb_cdc.syncpoint_v1 WHERE CAST(primary_ts AS UNSIGNED) <= $TARGET_PRIMARY AND changefeed='cf-A-to-${CLUSTER_NAME#cluster_}'")

  # define feed ID and config file
  FEED_ID="cf-${NEW_PRIMARY_CLUSTER/cluster_/}-to-${CLUSTER_NAME/cluster_/}"
  CFG_FILE="cdc-${FEED_ID}.toml"
  echo "  Setting up changefeed $FEED_ID"

  # create config file for this changefeed
  cat > "$CFG_FILE" <<EOF
# CDC config for $FEED_ID
enable-sync-point = true
sync-point-interval = "30s"

[consistent]
level = "eventual"
storage = "file:///tidb-data/${NEW_PRIMARY_CLUSTER}/redo/${FEED_ID}"
EOF

  # prepare redo dir for this feed
  sudo mkdir -p /tidb-data/${NEW_PRIMARY_CLUSTER}/redo/${FEED_ID}
  sudo chmod a+rwx /tidb-data/${NEW_PRIMARY_CLUSTER}/redo/${FEED_ID}

  # create the changefeed
  tiup ctl:$TIDB_VERSION cdc --server="$NEW_PRIMARY_CLUSTER_IP:$NEW_PRIMARY_CLUSTER_CDC_PORT" changefeed create \
    --changefeed-id="$FEED_ID" \
    --sink-uri="mysql://root@${CLUSTER_IP}:$SQL_PORT/" \
    --start-ts=$START_TS \
    --config="$CFG_FILE"
done