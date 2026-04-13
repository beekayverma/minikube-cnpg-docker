# Session 4 - Secret Rotation

Author: beekay.verma@gmail.com

---

## What This Session Covers

Passwords should not live forever. In production, credentials rotate on a schedule (30/60/90
days) or immediately after a suspected leak. This session covers how to rotate the Postgres
user password with zero Postgres downtime, and explains a critical limitation of env-var-based
secret injection that forces an app pod restart.

---

## The Rotation Problem

Two things must always be in sync:

- The Kubernetes Secret - what the app reads for its password
- The Postgres user password - what the database checks on login

If they drift, authentication fails. The rotation order determines whether connections drop.

---

## Correct Rotation Order

```
WRONG:  update K8s secret first
        --> pooler reconnects with new password
        --> Postgres still has old password
        --> SASL auth failure, connections drop

CORRECT:
  Step 1 - Update Postgres password to new value
  Step 2 - Update K8s secret to match
  Step 3 - Restart poolers (flush cached connections)
  Step 4 - Restart app pods (env vars baked at start, must reload)
  Step 5 - Verify
```

During the window between step 1 and step 3, the pooler still has cached connections using the
old password. Those connections keep working. New connections from the pooler use the new secret
after the restart. This overlap avoids a hard cutover.

---

## Step 1 - Generate a New Password

Use the existing script to generate a new random password:

```bash
scripts/generate-secret.sh
```

This writes a new `manifests/cluster/secret.yaml` with a 32-character random password. The
password is saved to the file only - it never appears in the terminal or shell history.

---

## Step 2 - Update Postgres Password First

Read the new password from the file and apply it directly in Postgres via peer auth:

```bash
NEW_PASS=$(grep 'password:' manifests/cluster/secret.yaml | awk '{print $2}')
PRIMARY=$(kubectl -n cnpg-test get cluster pg-test -o jsonpath='{.status.currentPrimary}')
kubectl -n cnpg-test exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c "ALTER USER testuser PASSWORD '$NEW_PASS';"
```

Expected output: `ALTER ROLE`

**Why peer auth, not TCP:**

Connecting via `kubectl exec` into the pod uses Unix socket peer authentication - no password
sent over the network. The `postgres` superuser can change any user's password this way without
exposing credentials on the wire.

**Does `ALTER ROLE` log the password?**

It depends on `log_statement`:

| Setting | What gets logged |
|---|---|
| `none` | Nothing - no statement logging at all |
| `ddl` | Statement is logged but password is **redacted** as `********` by Postgres |
| `mod` | Same redaction as `ddl` |
| `all` | Full statement including plaintext password - never use in production |

CNPG defaults to `log_statement = none`. Verify your cluster:

```bash
kubectl -n cnpg-test exec -i $PRIMARY -c postgres -- psql -U postgres -c "SHOW log_statement;"
```

**Shell history risk:**

If you type a password directly in a command like `ALTER USER testuser PASSWORD 'mypassword'` in
an interactive shell, it lands in `.bash_history`. Reading the new password from `$NEW_PASS`
(which came from a file, not keyboard input) avoids this entirely.

---

## Step 3 - Apply the New K8s Secret

```bash
kubectl apply -f manifests/cluster/secret.yaml
```

Expected output: `secret/pg-test-credentials configured`

---

## Step 4 - Restart the Poolers

PgBouncer caches server connections. After updating the secret, restart both pooler deployments
to force them to pick up the new credentials:

```bash
kubectl -n cnpg-test rollout restart deployment/pg-test-pooler-rw deployment/pg-test-pooler-ro
```

Wait for the rollout to complete:

```bash
kubectl -n cnpg-test rollout status deployment/pg-test-pooler-rw deployment/pg-test-pooler-ro
```

Expected output:

```
deployment "pg-test-pooler-rw" successfully rolled out
deployment "pg-test-pooler-ro" successfully rolled out
```

---

## Step 5 - Restart App Pods

**Critical limitation of env-var-based secret injection:**

When a pod starts, Kubernetes injects secret values as environment variables. Those values are
baked into the process at startup. If the underlying Secret is updated later, the running pod
does not see the change - the old value stays in memory until the pod restarts.

This means any pod using `secretKeyRef` must be restarted after secret rotation:

```bash
kubectl -n cnpg-test delete pod test-app
kubectl -n cnpg-test apply -f manifests/cluster/test-app.yaml
```

Without this restart, the pod still holds the old `PGPASSWORD` in its environment. Connections
through the pooler will fail with `SASL authentication failed` because the app sends the old
password to PgBouncer, which forwards it to Postgres, which now only accepts the new password.

**This is not a CNPG limitation - it is how Kubernetes env var injection works.**

Compare with volume-mounted secrets: when a secret is updated, kubelet automatically refreshes
the mounted file inside the pod within ~60 seconds. No restart required. This is covered in
Session 5.

---

## Step 6 - Verify

Wait for the app pod to be ready:

```bash
kubectl -n cnpg-test wait --for=condition=Ready pod/test-app --timeout=60s
```

Then verify the connection works with the new credentials:

```bash
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-rw -U testuser -d testdb \
  -c "SELECT 'rotation successful' AS status, now() AS at;"
```

Expected:

```
       status        |              at
---------------------+-------------------------------
 rotation successful | 2026-04-13 11:21:22.208768+00
(1 row)
```

---

## Rotation Checklist

```
[ ] Generate new password - scripts/generate-secret.sh
[ ] Update Postgres password first - ALTER USER via peer auth
[ ] Confirm log_statement = none (password not logged)
[ ] Apply new K8s secret - kubectl apply
[ ] Restart poolers - kubectl rollout restart
[ ] Restart app pods - delete and recreate (env var limitation)
[ ] Verify connection works end to end
```

---

## Limitations of This Approach

- **App pods must restart** - any pod using `secretKeyRef` must be restarted to pick up the new
  password. This is not zero-downtime for the app - it is zero-downtime for Postgres only.
- **Manual process** - in production, use a secrets manager (Vault, AWS Secrets Manager) with
  an automated rotation job that handles all steps in sequence.
- **No rollback** - once Postgres has the new password, the old one is gone. If the new secret
  has a typo, you are locked out. Always verify the new password before discarding the old one.

---

## Useful Commands

```bash
# Generate new password
scripts/generate-secret.sh

# Check current primary
kubectl -n cnpg-test get cluster pg-test -o jsonpath='{.status.currentPrimary}'

# Check log_statement setting
kubectl -n cnpg-test exec -i <primary-pod> -c postgres -- psql -U postgres -c "SHOW log_statement;"

# Restart poolers after rotation
kubectl -n cnpg-test rollout restart deployment/pg-test-pooler-rw deployment/pg-test-pooler-ro

# Check rollout status
kubectl -n cnpg-test rollout status deployment/pg-test-pooler-rw deployment/pg-test-pooler-ro

# Verify connection after rotation
kubectl -n cnpg-test exec -it test-app -- psql -h pg-test-pooler-rw -U testuser -d testdb \
  -c "SELECT 'rotation successful' AS status, now() AS at;"
```
