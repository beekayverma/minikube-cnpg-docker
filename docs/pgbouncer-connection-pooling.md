# Session 3 - PgBouncer Connection Pooling

Author: beekay.verma@gmail.com

---

## What This Session Covers

Each Postgres connection is a real OS process consuming ~5-10MB RAM. Without pooling, 100 app
connections mean 100 Postgres processes running simultaneously. PgBouncer sits between the app
and Postgres, maintaining a small pool of real database connections and multiplexing many app
connections through them.

```
Without pooling:
100 app connections --> 100 Postgres processes --> ~500MB RAM

With PgBouncer:
100 app connections --> PgBouncer --> 10 Postgres processes --> ~50MB RAM
```

CNPG ships a `Pooler` custom resource that deploys PgBouncer pre-wired to your cluster.

---

## Connection Pooling Modes

PgBouncer has three pooling modes. Choosing the wrong one breaks your app silently.

| Mode | How it works | Breaks |
|---|---|---|
| `session` | Server connection held for the entire client session | Nothing - safest mode, least savings |
| `transaction` | Server connection returned to pool after COMMIT or ROLLBACK | `SET` outside a transaction, `LISTEN/NOTIFY`, named prepared statements |
| `statement` | Server connection returned after every statement | Any multi-statement transaction |

**Use `transaction` mode** for standard OLTP apps. It gives real connection savings while being
compatible with normal SQL patterns. Most frameworks (Django, Rails, SQLAlchemy) work fine with
transaction mode.

---

## Production Setup - Two Poolers

A production setup has two separate poolers:

- `pg-test-pooler-rw` - routes to the primary (reads and writes)
- `pg-test-pooler-ro` - routes to replicas (reads only)

Apps split their traffic:
- `INSERT`, `UPDATE`, `DELETE`, `BEGIN` with writes - connect to `pg-test-pooler-rw`
- `SELECT` queries, reporting, analytics - connect to `pg-test-pooler-ro`

This offloads read traffic from the primary and keeps it available for writes.

---

## Manifests

### manifests/pooler/pooler-rw.yaml

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pg-test-pooler-rw
  namespace: cnpg-test
spec:
  cluster:
    name: pg-test
  instances: 2
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "200"
      default_pool_size: "10"
      server_idle_timeout: "600"
      client_idle_timeout: "0"
      server_connect_timeout: "15"
      server_login_retry: "15"
```

Field breakdown:

| Field | Meaning |
|---|---|
| `kind: Pooler` | CNPG custom resource. The operator creates a Deployment, Service, and wires auth automatically. |
| `instances: 2` | Two PgBouncer pods. If one crashes, the other keeps serving connections. Minimum for production HA. |
| `type: rw` | Targets the primary (read-write) service. Use `ro` for replicas. |
| `poolMode: transaction` | Server connection returned to pool after each COMMIT or ROLLBACK. |
| `max_client_conn: 200` | Total client connections PgBouncer accepts across all pools. This is the app-facing limit. |
| `default_pool_size: 10` | Real Postgres connections kept open per user+database pair. 2 pods x 10 = 20 real connections to Postgres. |
| `server_idle_timeout: 600` | Close a server connection idle for 600 seconds. Prevents stale connections accumulating. |
| `client_idle_timeout: 0` | Never close idle client connections (0 = disabled). Set to 300 in production if you want to clean up ghost clients. |
| `server_connect_timeout: 15` | Fail fast if Postgres does not accept a connection within 15 seconds. Prevents pooler hanging on a dead primary. |
| `server_login_retry: 15` | Wait 15 seconds before retrying a failed login. Prevents hammering a recovering node. |

### manifests/pooler/pdb-pooler.yaml

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pg-test-pooler-rw-pdb
  namespace: cnpg-test
spec:
  minAvailable: 1
  selector:
    matchLabels:
      cnpg.io/poolerName: pg-test-pooler-rw
```

Field breakdown:

| Field | Meaning |
|---|---|
| `kind: PodDisruptionBudget` | Kubernetes policy limiting how many pods can be down simultaneously during voluntary disruptions (node drain, rolling update). Does not protect against hardware failures. |
| `minAvailable: 1` | At least 1 pooler pod must remain running. Kubernetes blocks drain until this is satisfied. |
| `cnpg.io/poolerName` | Label CNPG puts on every pod belonging to a Pooler. Links the PDB to the right pods. |

---

## Connection Math

Our cluster has `max_connections: 50`. Plan the pool sizes to stay within that limit.

```
rw pooler: 2 pods x 10 pool size = 20 connections to primary
Remaining on primary: ~30 for system, replication, direct access

ro pooler: 2 pods x 10 pool size = 20 connections to each replica
Each replica has max_connections: 50 - well within limits
```

Always plan: `(pooler instances) x (default_pool_size) + system headroom < max_connections`

---

## Deploy

```bash
kubectl apply -f manifests/pooler/pooler-rw.yaml
kubectl apply -f manifests/pooler/pooler-ro.yaml
kubectl apply -f manifests/pooler/pdb-pooler.yaml
```

Wait for all 4 pods to be Running:

```bash
kubectl -n cnpg-test get pods | grep pooler
```

Expected:

```
pg-test-pooler-ro-xxx   1/1     Running
pg-test-pooler-ro-xxx   1/1     Running
pg-test-pooler-rw-xxx   1/1     Running
pg-test-pooler-rw-xxx   1/1     Running
```

---

## Verify

Check the services CNPG created:

```bash
kubectl -n cnpg-test get svc | grep pooler
```

Expected - two ClusterIP services on port 5432:

```
pg-test-pooler-ro   ClusterIP   10.x.x.x   <none>   5432/TCP
pg-test-pooler-rw   ClusterIP   10.x.x.x   <none>   5432/TCP
```

Check PDBs are protecting both poolers:

```bash
kubectl -n cnpg-test get pdb
```

Note the `pg-test-primary` PDB created automatically by CNPG with `ALLOWED DISRUPTIONS: 0` -
the primary pod cannot be drained unless CNPG first promotes a replica.

Test rw pooler routes to primary:

```bash
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-rw -U testuser -d testdb \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

Expected: `pg_is_in_recovery = f` (primary)

Test ro pooler routes to a replica:

```bash
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-ro -U testuser -d testdb \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

Expected: `pg_is_in_recovery = t` (replica)

---

## Traffic Split Pattern

Update your application to use the pooler services:

```
writes  -->  pg-test-pooler-rw:5432
reads   -->  pg-test-pooler-ro:5432
```

Never connect directly to `pg-test-rw` or `pg-test-ro` from application code in production.
Direct connections bypass pooling and add unnecessary load.

---

## CNPG Auto-Created PDBs

CNPG automatically creates two PDBs for the cluster itself:

| PDB | Allowed Disruptions | Purpose |
|---|---|---|
| `pg-test` | 1 | Allows draining one replica pod at a time |
| `pg-test-primary` | 0 | Blocks draining the primary entirely - CNPG must promote first |

The `pg-test-primary` PDB with 0 allowed disruptions is a safety net. Without it, a node drain
could evict the primary mid-transaction. CNPG handles the promotion automatically when needed,
then the PDB releases.

---

## Useful Commands

```bash
# Check pooler pods
kubectl -n cnpg-test get pods | grep pooler

# Check pooler services
kubectl -n cnpg-test get svc | grep pooler

# Check all PDBs
kubectl -n cnpg-test get pdb

# Test rw pooler
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-rw -U testuser -d testdb \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"

# Test ro pooler
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-ro -U testuser -d testdb \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```
