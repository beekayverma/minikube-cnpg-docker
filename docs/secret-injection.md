# Secret Injection - How to Connect to Postgres Without Leaking Credentials

A hands-on guide for beginners on the right way to handle database credentials
in Kubernetes. You will learn why common approaches leak secrets and how
Kubernetes secret injection solves the problem properly.

- Author: beekay.verma@gmail.com
- Requires: a running CNPG cluster (see README.md to set one up)

---

## The Problem - How Secrets Get Leaked

Before learning the right way, it helps to understand the wrong ways and why
they are dangerous.

**Wrong way 1 - hardcoded in the manifest:**

```yaml
env:
- name: PGPASSWORD
  value: "mysecretpassword"   # anyone with git access sees this
```

This gets committed to git. It lives in git history forever even after you
delete it. If the repo is ever made public, the password is exposed.

**Wrong way 2 - PGPASSWORD in the shell:**

```bash
PGPASSWORD=mysecretpassword psql -h localhost -U myuser -d mydb
```

This exposes the password in:
- Your shell history (`~/.bash_history`)
- `ps aux` output - any user on the machine can run this and see it
- Environment variables inherited by child processes

**Wrong way 3 - ALTER USER with plaintext:**

```sql
ALTER USER myuser WITH PASSWORD 'mysecretpassword';
```

Depending on your `log_min_duration_statement` setting, this can appear in
Postgres logs in plaintext. Anyone with log access sees the password.

---

## The Right Way - Kubernetes Secret Injection

Kubernetes has a built-in resource called a `Secret` for storing sensitive
values. Instead of putting the password in your manifest or shell, you store
it in a Secret and tell Kubernetes to inject it into your pod at start time.

```
K8s Secret (your-credentials)
        |
        | Kubernetes injects at pod start
        v
   Your App Pod (env vars populated silently)
        |
        | app reads env vars - never sees the raw value as a string you typed
        v
   Postgres (TLS encrypted connection)
```

The password is never in your manifest. The manifest is safe to commit to git.

---

## Step 1 - Store Credentials in a Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-test-credentials
  namespace: cnpg-test
type: kubernetes.io/basic-auth
stringData:
  username: testuser
  password: testpassword123
```

Apply it:

```bash
kubectl apply -f manifests/cluster/secret.yaml
```

> In production, never commit `secret.yaml`. Add it to `.gitignore` and
> generate it with a script (see `scripts/generate-secret.sh`) or pull
> values from a secrets manager like Vault or AWS Secrets Manager.

---

## Step 2 - Inject the Secret into Your Pod

Instead of hardcoding credentials, use `secretKeyRef` to tell Kubernetes
which secret and which key to read at pod start:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-app
  namespace: cnpg-test
spec:
  containers:
  - name: app
    image: postgres:17
    command: ["sleep", "infinity"]
    env:
    - name: PGHOST
      value: "pg-test-rw"           # always routes to current primary
    - name: PGDATABASE
      value: "testdb"
    - name: PGUSER
      valueFrom:
        secretKeyRef:
          name: pg-test-credentials  # name of the Secret
          key: username              # key inside the Secret
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: pg-test-credentials
          key: password
    - name: PGSSLMODE
      value: "require"               # enforce TLS - never skip this
```

Notice the manifest contains **no password**. It only references where the
password lives. This file is completely safe to commit to git.

Apply it:

```bash
kubectl apply -f manifests/cluster/test-app.yaml
```

Wait for the pod to be ready:

```bash
kubectl -n cnpg-test get pod test-app -w
```

---

## Step 3 - Connect Without Typing a Password

Exec into the pod:

```bash
kubectl -n cnpg-test exec -it test-app -- psql
```

Notice:
- No `-U username`
- No `-d database`
- No password prompt

psql automatically reads `PGHOST`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE`
from the environment variables that Kubernetes injected from the secret.

You land directly at:

```
testdb=>
```

The connection is also TLS encrypted - CNPG enforces this by default:

```
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384 ...)
```

---

## Why This is Better

| Approach | In git? | In shell history? | In ps aux? | In logs? |
|----------|---------|------------------|------------|---------|
| Hardcoded in manifest | Yes - dangerous | No | No | No |
| PGPASSWORD in shell | No | Yes - dangerous | Yes - dangerous | No |
| ALTER USER plaintext | No | No | No | Possibly - dangerous |
| Secret injection | No | No | No | No |

Secret injection keeps the password out of every dangerous location.

---

## What Happens at the Kubernetes Level

When you apply the pod manifest, Kubernetes:

1. Reads the `secretKeyRef` fields
2. Looks up `pg-test-credentials` in the `cnpg-test` namespace
3. Decodes the base64 values for `username` and `password`
4. Injects them as environment variables into the container at start time
5. The values exist only in the container's memory - not on disk, not in any log

You can verify the injected values from inside the pod:

```bash
kubectl -n cnpg-test exec -it test-app -- env | grep PG
```

You will see all the PG* variables populated - including PGPASSWORD. This is
why you should restrict who has `kubectl exec` access in production. Anyone
who can exec into a pod can read its environment variables.

---

## The Next Level - File Mounting Instead of Env Vars

For even tighter security, secrets can be mounted as files instead of env vars.
Files are harder to accidentally expose than environment variables:

```yaml
volumeMounts:
- name: db-credentials
  mountPath: "/etc/secrets"
  readOnly: true
volumes:
- name: db-credentials
  secret:
    secretName: pg-test-credentials
```

The app then reads `/etc/secrets/username` and `/etc/secrets/password` as files.
This is the pattern used by most production-grade applications.

---

## Production Recommendations

| What | Why |
|------|-----|
| Use a secrets manager (Vault, AWS Secrets Manager) | K8s Secrets are base64, not encrypted at rest by default |
| Enable K8s Secret encryption at rest | Protects secrets stored in etcd |
| Restrict `kubectl exec` with RBAC | Prevents env var extraction from running pods |
| Use short-lived credentials | Rotate passwords frequently, automate rotation |
| Never use PGPASSWORD in CI/CD scripts | Use secret injection or `.pgpass` with restricted permissions |
| Use PgBouncer pooler | Abstracts credentials further, adds connection pooling |

---

## Teardown

```bash
kubectl -n cnpg-test delete pod test-app
```
