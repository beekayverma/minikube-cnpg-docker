# Session 5 - File Mounting Instead of Env Vars

Author: beekay.verma@gmail.com

---

## What This Session Covers

Kubernetes Secrets can be injected into pods two ways - as environment variables or as mounted
files. Most tutorials use env vars because they are simpler. This session shows why file mounting
is the better pattern for production, and proves it live with a secret rotation that updates
inside a running pod with zero restarts.

---

## The Problem With Env Var Injection

When a pod starts, Kubernetes injects secret values as environment variables. Those values are
baked into the process at startup. If the underlying Secret is updated later, the running pod
does not see the change.

You saw this live in Session 4:

```
Secret rotated in Kubernetes
        |
        v
Running pod: PGPASSWORD still has the OLD value
        |
        v
SASL authentication failed
        |
        v
Must delete and recreate the pod to pick up the new secret
```

This means secret rotation = pod restart. In a real app with multiple replicas, this is a
rolling restart across every pod that uses the secret.

---

## How File Mounting Fixes It

When a secret is mounted as a volume, kubelet manages the files inside the pod. When the secret
is updated in Kubernetes, kubelet automatically refreshes the mounted files within ~60 seconds.
No pod restart needed.

```
Secret rotated in Kubernetes
        |
        v
kubelet detects the change (~60s sync interval)
        |
        v
Atomically updates the mounted files inside the running pod
        |
        v
App reads new credentials from file on next connection
        |
        v
No restart. No downtime.
```

---

## The Atomic Swap - How kubelet Updates Files Safely

When you inspect the mounted directory you see this structure:

```
/etc/db-creds/
  password  ->  ..data/password                    (symlink)
  username  ->  ..data/username                    (symlink)
  ..data    ->  ..2026_04_13_11_38_27.2398713515   (symlink to timestamped dir)
  ..2026_04_13_11_38_27.2398713515/
    password   (actual file)
    username   (actual file)
```

This is not accidental. kubelet uses a double-symlink pattern for atomic updates:

1. Creates a new timestamped directory with the new secret values
2. Atomically swaps `..data` to point to the new directory
3. Deletes the old timestamped directory

The swap is atomic at the filesystem level. The app either reads old or new credentials - never
a half-written file mid-rotation. This is safe even if the app reads the file at the exact
moment of rotation.

---

## Pod Spec - Before and After

### Before - env var injection (Session 4 style)

```yaml
spec:
  containers:
  - name: app
    env:
    - name: PGUSER
      valueFrom:
        secretKeyRef:
          name: pg-test-credentials
          key: username
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: pg-test-credentials
          key: password
```

Problem: `PGPASSWORD` is baked at pod start. Secret rotation requires pod restart.

### After - file mounting (this session)

```yaml
spec:
  containers:
  - name: app
    image: postgres:17
    command: ["sleep", "infinity"]
    env:
    - name: PGHOST
      value: "pg-test-pooler-rw"
    - name: PGDATABASE
      value: "testdb"
    - name: PGSSLMODE
      value: "require"
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
    volumeMounts:
    - name: db-creds
      mountPath: /etc/db-creds
      readOnly: true
  volumes:
  - name: db-creds
    secret:
      secretName: pg-test-credentials
      defaultMode: 0600
```

Field breakdown:

| Field | Meaning |
|---|---|
| `volumeMounts.mountPath` | Where the secret files appear inside the container. |
| `readOnly: true` | The container cannot modify the credentials directory. |
| `volumes.secret.secretName` | Which Kubernetes Secret to mount. |
| `defaultMode: 0600` | Files are readable only by the pod's process. Not world-readable. |
| `resources` | CPU and memory limits prevent the pod from consuming unbounded resources (noisy neighbor protection). |

---

## Connecting With File-Mounted Credentials

The app reads credentials from files at connection time, not from env vars baked at startup:

```bash
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb \
   -c "SELECT current_user, now();"'
```

`$(cat /etc/db-creds/password)` reads the current value from the file at the moment the command
runs. If the file has been updated by kubelet since the pod started, the new password is used
automatically.

---

## Live Demo - Secret Rotation Without Pod Restart

This is the key demo. Run it in front of your audience.

**Terminal 1 - watch the file inside the running pod:**

```bash
kubectl -n cnpg-test exec -it test-app -- watch -n5 'cat /etc/db-creds/password'
```

Leave this running. The current password is displayed, refreshing every 5 seconds.

**Terminal 2 - rotate the secret:**

```bash
# Generate new password
scripts/generate-secret.sh

# Update Postgres first
NEW_PASS=$(grep 'password:' manifests/cluster/secret.yaml | awk '{print $2}')
PRIMARY=$(kubectl -n cnpg-test get cluster pg-test -o jsonpath='{.status.currentPrimary}')
kubectl -n cnpg-test exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c "ALTER USER testuser PASSWORD '$NEW_PASS';"

# Apply new K8s secret
kubectl apply -f manifests/cluster/secret.yaml
```

**Watch Terminal 1.** Within ~60 seconds the password changes on screen. Same pod. No restart.

**Terminal 2 - verify connection with new credentials:**

```bash
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb \
   -c "SELECT current_user, now();"'
```

Expected: `testuser` returned with current timestamp. Connected with the new password, zero
pod restarts.

---

## Comparison - Env Vars vs File Mounting

| | Env var injection | File mounting |
|---|---|---|
| Secret value baked at | Pod start | Never - read from file at use time |
| Picks up secret rotation | Never (requires pod restart) | Within ~60 seconds automatically |
| Pod restart on rotation | Required | Not required |
| Visible in `kubectl describe pod` | Yes - env vars are visible | No - only the volume mount is shown |
| File permissions | N/A | Controlled by `defaultMode` |
| Atomic update on rotation | N/A | Yes - kubelet double-symlink swap |

---

## Security Considerations

The mounted files are plaintext inside the pod. This is intentional - the app needs to read
them to connect. What protects them:

| Layer | Protection |
|---|---|
| etcd | Encrypted with aescbc (Session 2) - ciphertext only |
| Network | tmpfs mount - files never written to node disk |
| File permissions | `defaultMode: 0600` - pod process only |
| Pod access | RBAC controls who can `kubectl exec` (Session 1) |

In production, add:
- `securityContext.runAsNonRoot: true` - do not run pod as root
- `securityContext.readOnlyRootFilesystem: true` - immutable container filesystem
- NetworkPolicy - restrict which pods can reach the database

These are covered in Session 7 - Security Hardening.

---

## Useful Commands

```bash
# Inspect the mounted secret directory
kubectl -n cnpg-test exec -it test-app -- ls -la /etc/db-creds/

# Read credentials from files
kubectl -n cnpg-test exec -it test-app -- cat /etc/db-creds/username
kubectl -n cnpg-test exec -it test-app -- cat /etc/db-creds/password

# Connect using file-mounted credentials
kubectl -n cnpg-test exec -it test-app -- bash -c \
  'PGPASSWORD=$(cat /etc/db-creds/password) psql \
   -U $(cat /etc/db-creds/username) \
   -h pg-test-pooler-rw testdb -c "SELECT current_user, now();"'

# Watch the file update live during rotation (run before rotating)
kubectl -n cnpg-test exec -it test-app -- watch -n5 'cat /etc/db-creds/password'
```
