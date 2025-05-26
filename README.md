# TiDB Cluster HA Demo

This repository demonstrates a high availability (HA) setup for TiDB clusters. In this demo, we have four clusters: A, B, C, and D. Cluster A is the primary cluster, and there are three changefeeds syncing data from A to B, A to C, and A to D. We enable CDC syncpoint for each changefeed and also enable PiTR for these four clusters.

## Cluster IP Map

- A: 10.148.0.5
- B: 10.148.0.5
- C: 10.148.0.5
- D: 10.148.0.5

## Host and Port Map (single host: 10.148.0.5)

All clusters share the same host but use distinct ports:

- Cluster A: PD 2379, TiDB 4000, TiKV 20160
- Cluster B: PD 2381, TiDB 4001, TiKV 20161
- Cluster C: PD 2383, TiDB 4002, TiKV 20162
- Cluster D: PD 2385, TiDB 4003, TiKV 20163

## TiDB Version

The TiDB version used in this demo is v8.5.1.

## Setting Up TiDB Clusters Using TiUP

1. Install TiUP by following the instructions on the [TiUP website](https://tiup.io/).
2. Deploy the four TiDB clusters (A, B, C, and D) on the host 10.148.0.5 using the `./deploy_clusters.sh` script.

## Enabling CDC Syncpoint for Each Changefeed

1. Ensure that the TiCDC component is installed and running on each cluster.
2. Enable CDC syncpoint for each changefeed by running:

   ```bash
   # Changefeed A->B
   tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@10.148.0.5:4001/" --config=./cdc_config.toml
   # Changefeed A->C
   tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@10.148.0.5:4002/" --config=./cdc_config.toml
   # Changefeed A->D
   tiup ctl:v8.5.1 cdc changefeed create --sink-uri="mysql://root@10.148.0.5:4003/" --config=./cdc_config.toml
   ```

## Recovering Clusters and Recreating Changefeeds in Case of Failure

1. In case of failure of cluster A, check the syncpoint table in clusters B, C, and D to determine which one has the latest data from A.
2. Use Flashback to revert clusters B, C, and D to their latest consistent snapshot.

> **Note:** FLASHBACK only reverts DML changes to the specified TSO. It cannot undo DDLs executed after that point. Ensure you wait for a fresh CDC syncpoint covering any DDLs before recovery.

3. Recreate the changefeed from the recovered cluster to the other clusters by following the instructions in the `scripts/recover_clusters.sh` script.

## Enabling Stale Reads on Secondary Clusters (Minimal Changes)

To perform a stale (historical) read on a secondary cluster (B, C, or D) with minimal changes:

1. Apply that TSO and enable external-Timestamp read:
   ```sql
   -- On the secondary cluster
   SET GLOBAL tidb_enable_external_ts_read = ON;
   ```
1. Run your SELECT queries: they now return data as of the latest syncpoint.
1. When finished, disable stale reads and return to normal mode:
   ```sql
   SET GLOBAL tidb_enable_external_ts_read = OFF;
   ```
