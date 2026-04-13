# minikube-cnpg-docker

A step-by-step local CloudNativePG (CNPG) setup on minikube using Docker as the driver.

- Author: beekay.verma@gmail.com
- Postgres version: 17.0
- CNPG operator version: 1.24.0
- Kubernetes version: v1.30.0

---

## What This Repo Does

Deploys a 3-instance CloudNativePG Postgres cluster on a local minikube cluster.

```
cnpg-test namespace
- pg-test-1  (primary  - reads + writes)
- pg-test-2  (replica  - read only, replicating from primary)
- pg-test-3  (replica  - read only, replicating from primary)
```

The CNPG operator manages replication automatically. If the primary pod dies, it promotes a replica without manual intervention.

---

## Prerequisites

Make sure these tools are installed before starting:

| Tool | Purpose |
|------|---------|
| minikube | Runs a local Kubernetes cluster inside Docker |
| kubectl | CLI to interact with Kubernetes |
| docker | Container runtime used by minikube |

Check all three are available:

```bash
minikube version && kubectl version --client && docker --version
```

---

## Repo Structure

```
.
- manifests/
  - cluster/
    - namespace.yaml          # cnpg-test namespace
    - secret.template.yaml    # copy this to secret.yaml and fill in credentials
    - cluster.yaml            # CNPG Cluster custom resource (3 instances)
- README.md
- .gitignore
```

> `secret.yaml` is git-ignored. Never commit real credentials.

---

## Step-by-Step Setup

### Step 1 - Check for Existing Minikube Clusters

Before starting, check if any old clusters are running:

```bash
minikube profile list
```

If you see any profiles you no longer need, remove them:

```bash
minikube delete -p <profile-name>
```

---

### Step 2 - Start Minikube

```bash
minikube start \
  --profile=cnpg-local \
  --driver=docker \
  --cpus=4 \
  --memory=6144 \
  --disk-size=20g \
  --kubernetes-version=v1.30.0
```

Flag breakdown:

| Flag | Meaning |
|------|---------|
| `--profile=cnpg-local` | Names this cluster to avoid conflicts with other profiles |
| `--driver=docker` | Uses Docker to run the K8s node instead of a VM |
| `--cpus=4` | Allocates 4 CPU cores |
| `--memory=6144` | Allocates 6GB RAM |
| `--disk-size=20g` | 20GB disk for storage |
| `--kubernetes-version=v1.30.0` | Pins a specific K8s version |

Verify the node is ready:

```bash
kubectl get nodes
```

Expected output:

```
NAME         STATUS   ROLES           AGE   VERSION
cnpg-local   Ready    control-plane   ...   v1.30.0
```

---

### Step 3 - Install the CNPG Operator

The CNPG operator teaches Kubernetes how to manage Postgres clusters. It registers Custom Resource Definitions (CRDs) and runs a controller that watches for `Cluster` resources.

```bash
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
```

Why `--server-side`: The CNPG manifest is large. Server-side apply lets the K8s API server handle merging logic and avoids annotation size limits.

Wait for the operator to be fully ready:

```bash
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

Expected output:

```
deployment "cnpg-controller-manager" successfully rolled out
```

---

### Step 4 - Create the Namespace

```bash
kubectl apply -f manifests/cluster/namespace.yaml
```

This creates the `cnpg-test` namespace where all Postgres resources will live.

---

### Step 5 - Create the Credentials Secret

Copy the template and fill in your credentials:

```bash
cp manifests/cluster/secret.template.yaml manifests/cluster/secret.yaml
```

Edit `manifests/cluster/secret.yaml` and replace `YOUR_USERNAME` and `YOUR_PASSWORD` with real values, then apply:

```bash
kubectl apply -f manifests/cluster/secret.yaml
```

> The secret uses `type: kubernetes.io/basic-auth`. Kubernetes stores the values base64-encoded. This is not encryption - use a proper secrets manager in production.

---

### Step 6 - Deploy the CNPG Cluster

```bash
kubectl apply -f manifests/cluster/cluster.yaml
```

Watch the pods come up:

```bash
kubectl -n cnpg-test get pods -w
```

CNPG starts `pg-test-1` first (the primary), then brings up replicas one by one. Wait until all 3 show `1/1 Running`.

---

### Step 7 - Verify Cluster Health

```bash
kubectl -n cnpg-test get cluster pg-test
```

Expected output:

```
NAME      AGE   INSTANCES   READY   STATUS                     PRIMARY
pg-test   ...   3           3       Cluster in healthy state   pg-test-1
```

- `INSTANCES` and `READY` should both be `3`
- `STATUS` should say `Cluster in healthy state`
- `PRIMARY` shows which pod is currently the read/write node

---

## Connecting to Postgres

Connect directly into the primary pod:

```bash
kubectl -n cnpg-test exec -it pg-test-1 -c postgres -- psql -U testuser -d testdb
```

Or port-forward to connect from your local machine:

```bash
kubectl -n cnpg-test port-forward svc/pg-test-rw 5432:5432
```

Then connect with any Postgres client:

```bash
psql -h localhost -U testuser -d testdb
```

---

## Useful Commands

```bash
# Check everything in the namespace
kubectl -n cnpg-test get all

# Check services CNPG created
kubectl -n cnpg-test get svc

# Tail operator logs
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=50

# Tail primary pod logs
kubectl -n cnpg-test logs pg-test-1 -c postgres --tail=50

# Check cluster status
kubectl -n cnpg-test get cluster pg-test
```

---

## Teardown

Remove the cluster and operator but keep the minikube VM:

```bash
kubectl -n cnpg-test delete cluster pg-test
kubectl delete -f manifests/cluster/namespace.yaml
kubectl delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
```

Delete the minikube VM entirely:

```bash
minikube delete -p cnpg-local
```

---

## How Replication Works

```
pg-test-1  (primary)
    |
    - WAL stream --> pg-test-2  (replica)
    - WAL stream --> pg-test-3  (replica)
```

WAL (Write-Ahead Log) is Postgres's transaction log. Replicas continuously stream it from the primary to stay in sync. If the primary pod fails, CNPG automatically promotes one of the replicas - no manual steps required.
