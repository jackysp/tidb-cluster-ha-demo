# TiDB Cluster HA Demo

This repository demonstrates a high availability (HA) setup for TiDB clusters. In this demo, we have four clusters: A, B, C, and D. Cluster A is the primary cluster, and there are three changefeeds syncing data from A to B, A to C, and A to D. We enable CDC syncpoint for each changefeed and also enable PiTR for these four clusters.

## Cluster IP Map

- A: 10.148.0.5
- B: 10.148.0.6
- C: 10.148.0.9
- D: 10.148.0.12

## TiDB Version

The TiDB version used in this demo is v8.5.1.

## Setting Up TiDB Clusters Using TiUP

1. Install TiUP by following the instructions on the [TiUP website](https://tiup.io/).
2. Deploy the four TiDB clusters (A, B, C, and D) on the specified IP addresses using the `scripts/deploy_clusters.sh` script.

## Enabling CDC Syncpoint for Each Changefeed

1. Ensure that the TiCDC component is installed and running on each cluster.
2. Enable CDC syncpoint for each changefeed from A to B, A to C, and A to D by following the instructions in the `scripts/deploy_clusters.sh` script.

## Enabling PiTR for All Clusters Using BR Tools

1. Ensure that the BR (Backup & Restore) tools are installed on each cluster.
2. Enable PiTR for all four clusters by following the instructions in the `scripts/deploy_clusters.sh` script.

## Recovering Clusters and Recreating Changefeeds in Case of Failure

1. In case of failure of cluster A, check the syncpoint table in clusters B, C, and D to determine which one has the latest data from A.
2. Use PiTR to recover clusters B, C, and D to their latest consistent snapshot.
3. Recreate the changefeed from the recovered cluster to the other clusters by following the instructions in the `scripts/recover_clusters.sh` script.
