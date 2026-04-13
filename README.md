# minikube-cnpg-docker

A hands-on security workshop for CloudNativePG on Kubernetes.

- Author: beekay.verma@gmail.com
- Postgres version: 17.0
- CNPG operator version: 1.24.0
- Kubernetes version: v1.30.0

Every concept is demonstrated live on a local minikube cluster. No theory without proof.

---

## What This Repo Is

A 7-session workshop series covering how to deploy and secure a production-grade
CloudNativePG Postgres cluster on Kubernetes. Built for engineers who want to understand
not just how to run CNPG, but how to secure it end to end.

See [SESSIONS.md](SESSIONS.md) for the full workshop index.

---

## What Gets Deployed

A 3-instance CloudNativePG Postgres cluster on a local minikube cluster:

```
cnpg-test namespace
- pg-test-1  (primary  - reads + writes)
- pg-test-2  (replica  - streaming replication from primary)
- pg-test-3  (replica  - streaming replication from primary)

PgBouncer poolers
- pg-test-pooler-rw  (2 pods - routes to primary)
- pg-test-pooler-ro  (2 pods - routes to replicas)
```

CNPG manages replication automatically. If the primary pod dies, a replica is promoted
without manual intervention.

---

## Prerequisites

| Tool | Purpose |
| --- | --- |
| minikube | Runs a local Kubernetes cluster inside Docker |
| kubectl | CLI to interact with Kubernetes |
| docker | Container runtime used by minikube |

Check all three are available:

```bash
minikube version && kubectl version --client && docker --version
```

---

## Quick Start

### Step 1 - Start Minikube

```bash
minikube start \
  --profile=cnpg-local \
  --driver=docker \
  --cpus=4 \
  --memory=6144 \
  --disk-size=20g \
  --kubernetes-version=v1.30.0
```

| Flag | Meaning |
| --- | --- |
| `--profile=cnpg-local` | Names this cluster to avoid conflicts with other minikube profiles |
| `--driver=docker` | Uses Docker to run the Kubernetes node instead of a VM |
| `--cpus=4` | Allocates 4 CPU cores |
| `--memory=6144` | Allocates 6GB RAM |
| `--disk-size=20g` | 20GB disk for storage |
| `--kubernetes-version=v1.30.0` | Pins a specific Kubernetes version for reproducibility |

Verify the node is ready:

```bash
kubectl get nodes
```

### Step 2 - Install the CNPG Operator

```bash
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
```

Wait for the operator to be ready:

```bash
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

### Step 3 - Create the Namespace

```bash
kubectl apply -f manifests/cluster/namespace.yaml
```

### Step 4 - Generate Credentials

```bash
scripts/generate-secret.sh
kubectl apply -f manifests/cluster/secret.yaml
```

### Step 5 - Deploy the Cluster

```bash
kubectl apply -f manifests/cluster/cluster.yaml
```

Watch pods come up:

```bash
kubectl -n cnpg-test get pods -w
```

Wait until all 3 show `1/1 Running`.

### Step 6 - Verify

```bash
kubectl -n cnpg-test get cluster pg-test
```

Expected:

```
NAME      AGE   INSTANCES   READY   STATUS                     PRIMARY
pg-test   ...   3           3       Cluster in healthy state   pg-test-1
```

---

## Repo Structure

```
manifests/
  cluster/       - namespace, secret template, CNPG cluster, test-app pod
  operator/      - CNPG operator install reference
  pooler/        - PgBouncer pooler manifests and PodDisruptionBudgets
  rbac/          - Role, ServiceAccount, RoleBinding manifests
scripts/
  generate-secret.sh   - generate a fresh random credentials secret
  wait-for.sh          - poll until pods matching a label selector are Ready
docs/
  failover-and-self-healing.md
  secret-injection.md
  rbac.md
  secret-encryption-at-rest.md
  pgbouncer-connection-pooling.md
  secret-rotation.md
  file-mounting-vs-env-vars.md
```

---

## Workshop Sessions

| Session | Topic | Doc |
| --- | --- | --- |
| 1 | Cluster, Replication, Failover, RBAC | [doc](docs/failover-and-self-healing.md) |
| 2 | Secret Encryption at Rest | [doc](docs/secret-encryption-at-rest.md) |
| 3 | PgBouncer Connection Pooling | [doc](docs/pgbouncer-connection-pooling.md) |
| 4 | Secret Rotation | [doc](docs/secret-rotation.md) |
| 5 | File Mounting Instead of Env Vars | [doc](docs/file-mounting-vs-env-vars.md) |
| 6 | External Secret Store with Vault | coming soon |
| 7 | Security Hardening | coming soon |

---

## Useful Commands

```bash
# Check cluster health
kubectl -n cnpg-test get cluster pg-test

# Check all pods
kubectl -n cnpg-test get pods

# Check services
kubectl -n cnpg-test get svc

# Check PodDisruptionBudgets
kubectl -n cnpg-test get pdb

# Connect via rw pooler
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb'

# Tail operator logs
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=50

# Rotate credentials
scripts/generate-secret.sh
```

---

## Teardown

Remove the cluster and operator but keep minikube:

```bash
kubectl -n cnpg-test delete cluster pg-test
kubectl delete -f manifests/cluster/namespace.yaml
kubectl delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
```

Delete minikube entirely:

```bash
minikube delete -p cnpg-local
```
