# Session 6 - External Secret Store with Vault

Author: beekay.verma@gmail.com

---

## What This Session Covers

Kubernetes-native Secrets have a fundamental limitation: they live inside the cluster. Any
operator with `kubectl get secret` access can read them. They are also managed manually - you
update the YAML and apply it. This session replaces that manual process with a real secret
store: HashiCorp Vault, running as a local Docker container.

The External Secrets Operator (ESO) bridges Vault and Kubernetes. It watches Vault, pulls
secret values on a schedule, and keeps Kubernetes Secrets in sync automatically. Combined with
Session 5's file mounting, a single Vault write rotates credentials end to end with no pod
restarts and no manual kubectl commands.

---

## Why Kubernetes-Native Secrets Are Not Enough

| Concern | Kubernetes Secrets | Vault |
|---|---|---|
| Access control | RBAC - anyone with get/list can read | Fine-grained policies per path |
| Audit log | No secret-read audit trail | Every read/write logged with identity |
| Rotation | Manual kubectl apply | Automated, policy-driven |
| Dynamic secrets | Not supported | Supported (generate and revoke on demand) |
| Secret lives inside cluster | Yes - etcd (encrypted in Session 2) | No - external, separate blast radius |

In Session 2 we encrypted etcd. That protects secrets if storage is compromised. Vault goes
further: the secrets never live in etcd at all. ESO pulls them into Kubernetes transiently, and
they stay in sync from the authoritative source.

---

## Architecture

```
HashiCorp Vault (Docker container)
  secret/cnpg/pg-test
    username: testuser
    password: <current value>
        |
        | ESO polls every 30s
        v
External Secrets Operator (in-cluster)
  ClusterSecretStore -> points to Vault
  ExternalSecret     -> maps Vault path to K8s Secret
        |
        | creates/updates
        v
Kubernetes Secret: pg-test-credentials
        |
        | kubelet syncs files every ~60s
        v
test-app pod: /etc/db-creds/password (auto-updated, no restart)
```

Rotation flow:

```
1. Update password in Postgres (ALTER USER)
2. Write new password to Vault (vault kv put)
   -> ESO detects change within 30s
   -> K8s Secret updated automatically
   -> kubelet updates mounted file within ~60s
   -> App uses new credentials on next connection
```

Zero manual kubectl commands after step 2. Zero pod restarts.

---

## Prerequisites

- Sessions 1-5 complete (cluster running, file-mounted credentials)
- Docker available on the host
- Helm installed

---

## Step 1 - Start Vault Dev Server

Vault dev mode starts unsealed with a single root token. It runs in memory - data is lost on
container restart. For this workshop that is fine - we are demonstrating the pattern, not
running production Vault.

```bash
docker run -d \
  --name vault \
  --cap-add=IPC_LOCK \
  -p 192.168.49.1:8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  hashicorp/vault:latest
```

| Flag | Meaning |
|---|---|
| `--cap-add=IPC_LOCK` | Allows Vault to lock memory and prevent secrets from being swapped to disk |
| `-p 192.168.49.1:8200:8200` | Binds to the minikube bridge IP so the cluster can reach Vault |
| `VAULT_DEV_ROOT_TOKEN_ID=root` | Sets the root token to `root` for easy dev access |
| `VAULT_DEV_LISTEN_ADDRESS` | Listens on all interfaces inside the container |

Check it started:

```bash
docker logs vault 2>&1 | tail -10
```

Expected: `Root Token: root`, `Development mode should NOT be used in production`

Verify reachable from inside minikube:

```bash
minikube -p cnpg-local ssh -- "curl -s http://192.168.49.1:8200/v1/sys/health"
```

Expected: `"initialized":true,"sealed":false`

---

## Step 2 - Write Credentials to Vault

Read the current credentials from the K8s secret and write them to Vault KV v2:

```bash
CURRENT_USER=$(kubectl -n cnpg-test get secret pg-test-credentials -o jsonpath='{.data.username}' | base64 -d)
CURRENT_PASS=$(kubectl -n cnpg-test get secret pg-test-credentials -o jsonpath='{.data.password}' | base64 -d)

docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
  vault kv put -mount=secret cnpg/pg-test \
  username="$CURRENT_USER" \
  password="$CURRENT_PASS"
```

Expected output includes `version: 1`.

Verify:

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
  vault kv get -mount=secret cnpg/pg-test
```

The KV path `secret/cnpg/pg-test` is the source of truth from this point forward.

---

## Step 3 - Install External Secrets Operator

ESO is installed via Helm:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --wait
```

Verify all three pods are running:

```bash
kubectl -n external-secrets get pods
```

Expected: `external-secrets`, `external-secrets-cert-controller`, `external-secrets-webhook` all `1/1 Running`.

---

## Step 4 - Create Vault Token Secret

ESO needs a Kubernetes Secret containing the Vault token so it can authenticate:

```bash
kubectl create secret generic vault-token \
  -n cnpg-test \
  --from-literal=token=root
```

In production, use a Vault policy-scoped token with read-only access to the specific secret
path - not the root token.

---

## Step 5 - Create the ClusterSecretStore

`ClusterSecretStore` is a cluster-wide resource that defines how ESO connects to a secret
backend. It is cluster-scoped (not namespaced) so any namespace can reference it.

`manifests/vault/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://192.168.49.1:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: cnpg-test
          key: token
```

| Field | Meaning |
|---|---|
| `server` | Vault address reachable from inside the cluster |
| `path` | The KV engine mount point (`secret/` in dev mode) |
| `version: v2` | KV v2 supports versioning and soft-delete |
| `tokenSecretRef` | References the K8s Secret containing the Vault token |

Apply:

```bash
kubectl apply -f manifests/vault/cluster-secret-store.yaml
```

Verify ESO can reach Vault:

```bash
kubectl get clustersecretstore vault-backend
```

Expected: `STATUS: Valid`, `READY: True`

---

## Step 6 - Delete the Manually-Managed Secret

ESO will take ownership of `pg-test-credentials`. Delete the existing one first:

```bash
kubectl -n cnpg-test delete secret pg-test-credentials
```

---

## Step 7 - Create the ExternalSecret

`ExternalSecret` maps a Vault path to a Kubernetes Secret. ESO reads from Vault and writes
the K8s Secret on the defined refresh interval.

`manifests/vault/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pg-test-credentials
  namespace: cnpg-test
spec:
  refreshInterval: 30s
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: pg-test-credentials
    creationPolicy: Owner
  data:
  - secretKey: username
    remoteRef:
      key: cnpg/pg-test
      property: username
  - secretKey: password
    remoteRef:
      key: cnpg/pg-test
      property: password
```

| Field | Meaning |
|---|---|
| `refreshInterval` | How often ESO polls Vault for changes |
| `secretStoreRef` | Which ClusterSecretStore to use |
| `target.name` | Name of the K8s Secret to create/update |
| `creationPolicy: Owner` | ESO owns the secret - deleting the ExternalSecret deletes the K8s Secret |
| `data[].secretKey` | Key name in the resulting K8s Secret |
| `data[].remoteRef.key` | Vault KV path (relative to the engine mount) |
| `data[].remoteRef.property` | Field name within the Vault secret |

Apply:

```bash
kubectl apply -f manifests/vault/external-secret.yaml
```

Check sync status:

```bash
kubectl -n cnpg-test get externalsecret pg-test-credentials
```

Expected: `STATUS: SecretSynced`, `READY: True`

Verify K8s secret was created:

```bash
kubectl -n cnpg-test get secret pg-test-credentials
```

Expected: `TYPE: Opaque`, `DATA: 2`

---

## Step 8 - Verify Connection Still Works

The test-app pod is still running with the same file mount from Session 5. ESO recreated the
K8s secret, kubelet will have refreshed the mounted files within ~60 seconds.

```bash
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb \
   -c "SELECT current_user, now();"'
```

Expected: `testuser` with current timestamp.

---

## Live Demo - Full Automated Rotation

**Terminal 1 - watch the password file:**

```bash
kubectl -n cnpg-test exec -it test-app -- watch -n5 'cat /etc/db-creds/password'
```

**Terminal 2 - rotate in Postgres and Vault:**

```bash
NEW_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#$%' | head -c 32)

PRIMARY=$(kubectl -n cnpg-test get cluster pg-test -o jsonpath='{.status.currentPrimary}')
kubectl -n cnpg-test exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c "ALTER USER testuser PASSWORD '$NEW_PASS';"

docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
  vault kv put -mount=secret cnpg/pg-test \
  username="testuser" \
  password="$NEW_PASS"
```

**Watch Terminal 1.** Within ~30s ESO syncs Vault to K8s secret. Within another ~60s kubelet
updates the mounted file. Password changes on screen. No pod restart. No kubectl apply.

**Terminal 2 - verify:**

```bash
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb \
   -c "SELECT current_user, now();"'
```

---

## Comparison - Manual Rotation vs Vault-Driven Rotation

| Step | Session 4 (manual) | Session 6 (Vault) |
|---|---|---|
| Update Postgres password | Manual ALTER USER | Manual ALTER USER |
| Update secret store | kubectl apply secret.yaml | vault kv put |
| K8s Secret updated | Manual | Automatic (ESO, ~30s) |
| Mounted file updated | Automatic (kubelet, ~60s) | Automatic (kubelet, ~60s) |
| Pod restart needed | Yes (env vars) | No (file mounting) |
| Audit trail | None | Every Vault write logged |
| Source of truth | manifests/cluster/secret.yaml | Vault KV |

---

## Security Considerations

| Layer | This Session |
|---|---|
| Vault token | Root token used for dev. Production: scoped policy token, read-only on path |
| Network | Vault on host bridge IP, not exposed to internet |
| Vault dev mode | In-memory, no TLS, no persistence. Production: use Vault in production mode with TLS |
| ESO permissions | ESO can only read - `creationPolicy: Owner` means it manages the secret lifecycle |

In production:
- Run Vault in server mode with TLS
- Use Vault AppRole or Kubernetes auth method (not a static token)
- Use Vault policies to restrict ESO to read-only on the specific path
- Enable Vault audit logging to a SIEM

---

## Useful Commands

```bash
# Check Vault is running
docker logs vault 2>&1 | tail -5

# Read from Vault
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
  vault kv get -mount=secret cnpg/pg-test

# Check ESO sync status
kubectl -n cnpg-test get externalsecret pg-test-credentials

# Check ClusterSecretStore health
kubectl get clustersecretstore vault-backend

# Force ESO to re-sync immediately (annotate to trigger refresh)
kubectl -n cnpg-test annotate externalsecret pg-test-credentials \
  force-sync=$(date +%s) --overwrite

# Check ESO operator logs
kubectl -n external-secrets logs deploy/external-secrets --tail=30
```

---

## Teardown

```bash
# Remove ESO resources
kubectl -n cnpg-test delete externalsecret pg-test-credentials
kubectl delete clustersecretstore vault-backend
kubectl -n cnpg-test delete secret vault-token

# Uninstall ESO
helm uninstall external-secrets -n external-secrets
kubectl delete namespace external-secrets

# Stop Vault
docker rm -f vault
```
