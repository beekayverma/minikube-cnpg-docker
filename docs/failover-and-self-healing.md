# Failover and Self-Healing in CNPG

A hands-on guide for beginners. You will delete a pod, watch the cluster recover itself,
and understand exactly what happened at each step.

- Author: beekay.verma@gmail.com
- Requires: a running 3-instance CNPG cluster (see README.md to set one up)

---

## What You Will See

In under 15 seconds you will watch:

- A primary pod get deleted
- CNPG detect the failure and promote a replica to primary
- A new pod spin up and rejoin the cluster as a replica
- The cluster return to 3/3 healthy - with no manual intervention

---

## Before You Start

Make sure your cluster is healthy. Run:

```bash
kubectl -n cnpg-test get cluster pg-test
```

Expected output:

```
NAME      AGE   INSTANCES   READY   STATUS                     PRIMARY
pg-test   ...   3           3       Cluster in healthy state   pg-test-1
```

Note which pod is listed as `PRIMARY` - you will compare this after the failover.

Also check all 3 pods are running:

```bash
kubectl -n cnpg-test get pods
```

Expected output:

```
NAME        READY   STATUS    RESTARTS   AGE
pg-test-1   1/1     Running   0          ...
pg-test-2   1/1     Running   0          ...
pg-test-3   1/1     Running   0          ...
```

---

## Step 1 - Open Two Terminals

This works best with two terminal windows side by side.

**Terminal 1 - the watcher:**

```bash
kubectl -n cnpg-test get pods -w
```

Leave this running. It will stream pod status changes live as they happen.

**Terminal 2 - the one you run commands in.**

---

## Step 2 - Delete the Primary Pod

In Terminal 2, run:

```bash
kubectl -n cnpg-test delete pod pg-test-1
```

Now watch Terminal 1.

---

## What You Will See in Terminal 1

```
NAME        READY   STATUS            RESTARTS   AGE
pg-test-1   0/1     PodInitializing   0          2s
pg-test-2   1/1     Running           0          24m
pg-test-3   1/1     Running           0          24m
pg-test-1   0/1     Running           0          3s
pg-test-1   1/1     Running           0          11s
```

Breaking this down second by second:

| Time | What happened |
|------|--------------|
| t=0s | You deleted pg-test-1 |
| t=2s | CNPG detected the failure and scheduled a new pg-test-1 pod |
| t=3s | New pod container started - not yet ready |
| t=11s | Pod passed health checks and rejoined the cluster |

Notice that **pg-test-2 and pg-test-3 never changed status**. They stayed `1/1 Running`
the entire time. An application connected via `pg-test-rw` service would have experienced
a brief blip during promotion but the cluster never went fully down.

---

## Step 3 - Check Who is Primary Now

Once Terminal 1 shows all 3 pods at `1/1 Running`, hit `Ctrl+C` to stop watching.

In Terminal 2, run:

```bash
kubectl -n cnpg-test get cluster pg-test
```

You will see that `PRIMARY` is now `pg-test-2` or `pg-test-3` - not `pg-test-1`.

Example output:

```
NAME      AGE   INSTANCES   READY   STATUS                     PRIMARY
pg-test   ...   3           3       Cluster in healthy state   pg-test-2
```

The rebuilt `pg-test-1` rejoined as a **replica**, streaming WAL from the new primary
to catch up on any writes it missed.

---

## What CNPG Did Automatically

Here is the full sequence the CNPG operator ran without you doing anything:

```
1. pg-test-1 (primary) deleted
2. CNPG operator detected the pod was gone
3. CNPG ran a leader election between pg-test-2 and pg-test-3
4. Winner (e.g. pg-test-2) was promoted to primary
5. pg-test-rw service now routes to pg-test-2 automatically
6. CNPG scheduled a new pg-test-1 pod to restore the cluster to 3 instances
7. New pg-test-1 started streaming WAL from pg-test-2 to catch up
8. Once synced, new pg-test-1 registered as a replica
9. Cluster back to 3/3 healthy
```

---

## Key Concepts Explained

**WAL - Write-Ahead Log**

Every write to Postgres is recorded in the WAL before it is applied to the data files.
Replicas stay in sync by continuously streaming and replaying this log from the primary.
When a new replica comes up, it first does a base backup, then streams WAL to catch up
to the current position.

**pg-test-rw Service**

This service always points to the current primary pod. CNPG updates it automatically
during failover. Your application only needs one connection string - it never needs to
know which pod is primary.

```
Before failover:  pg-test-rw  -->  pg-test-1
After failover:   pg-test-rw  -->  pg-test-2
```

Your app sees the same service address throughout.

**Why the new pod is a replica, not primary**

CNPG already has a healthy primary (pg-test-2 or pg-test-3). The new pod's job is to
restore redundancy, not take over leadership. Having two pods compete for primary would
risk split-brain - a dangerous condition where two nodes both think they are the writer.

---

## Try It Again

You can repeat this as many times as you like. Try deleting a replica instead of the primary:

```bash
kubectl -n cnpg-test delete pod pg-test-3
```

This time there is no leader election - the primary stays in place. CNPG just replaces
the missing replica.

Try deleting two pods at once:

```bash
kubectl -n cnpg-test delete pod pg-test-2 pg-test-3
```

Watch how CNPG handles losing both replicas simultaneously and rebuilds the cluster.

---

## Teardown

When you are done experimenting, remove everything:

```bash
# Remove cluster and operator but keep minikube VM
kubectl -n cnpg-test delete cluster pg-test
kubectl delete -f manifests/cluster/namespace.yaml
kubectl delete -f manifests/operator/cnpg-1.24.0.yaml

# Or delete the minikube VM entirely
minikube delete -p cnpg-local
```
