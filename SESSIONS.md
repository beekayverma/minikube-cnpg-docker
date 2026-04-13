# Workshop Sessions - CNPG Security on Kubernetes

Author: beekay.verma@gmail.com

A hands-on workshop series for engineers who want to understand how to run CloudNativePG
securely on Kubernetes. Every session is live-tested on a local minikube cluster. No slides
without proof - every concept is demonstrated with real commands and real output.

---

## Prerequisites

Before starting, make sure you have:

- minikube
- kubectl
- docker

```bash
minikube version && kubectl version --client && docker --version
```

Then follow the setup in [README.md](README.md) to bring up the cluster.

---

## Sessions

### [Session 1 - Cluster, Replication, Failover, RBAC](docs/failover-and-self-healing.md)

Deploy a 3-instance CNPG cluster. Watch WAL streaming replication in action. Delete the
primary pod and see CNPG promote a replica in under 15 seconds. Lock down access with
least-privilege RBAC roles and prove they work.

Key concepts: CNPG operator, Cluster CR, WAL streaming, automatic failover, Role,
ServiceAccount, RoleBinding.

---

### [Session 2 - Secret Encryption at Rest](docs/secret-encryption-at-rest.md)

Read a Kubernetes Secret directly from etcd in plaintext - no decryption needed. Then enable
EncryptionConfiguration with aescbc on the kube-apiserver. Rotate all existing secrets.
Read the same secret from etcd again and see only ciphertext.

Key concepts: etcd, base64 vs encryption, EncryptionConfiguration, aescbc provider,
kube-apiserver static pod, key rotation.

---

### [Session 3 - PgBouncer Connection Pooling](docs/pgbouncer-connection-pooling.md)

Deploy two production-grade PgBouncer poolers - one for reads, one for writes - each with 2
pods for HA and a PodDisruptionBudget. Prove the rw pooler routes to the primary and the ro
pooler routes to a replica using pg_is_in_recovery(). Understand why CNPG auto-creates a PDB
with 0 allowed disruptions on the primary.

Key concepts: connection pooling, transaction mode, Pooler CR, PodDisruptionBudget,
rw/ro traffic split, pg_is_in_recovery.

---

### [Session 4 - Secret Rotation](docs/secret-rotation.md)

Rotate the Postgres user password with zero database downtime. Learn the correct rotation
order - Postgres first, then Kubernetes secret, then pooler restart. Discover the critical
limitation of env-var-based secret injection: the app pod must restart to pick up the new
password. Understand log_statement levels and why ALTER ROLE does not leak passwords by default.

Key concepts: rotation order, ALTER ROLE, log_statement, peer authentication, env var
baking, pooler connection flushing.

---

### [Session 5 - File Mounting Instead of Env Vars](docs/file-mounting-vs-env-vars.md)

Fix the env var limitation from Session 4. Mount the secret as files inside the pod. Watch
the password change inside a running pod - no restart - using kubectl watch. Understand the
kubelet double-symlink atomic swap that makes this safe. Connect to Postgres immediately
after rotation with zero restarts.

Key concepts: volume mounts, tmpfs, kubelet sync interval, atomic file swap, defaultMode,
readOnly volumes.

---

### Session 6 - External Secret Store with Vault (coming soon)

Why Kubernetes-native secrets are still not enough. Run HashiCorp Vault locally as a Docker
container. Store credentials in Vault. Use the External Secrets Operator to sync them into
Kubernetes Secrets automatically. Trigger rotation from Vault with no manual steps.

Key concepts: Vault dev server, External Secrets Operator, dynamic secrets, KV engine,
envelope encryption.

---

### Session 7 - Security Hardening (coming soon)

Lock down the pod itself. Run as non-root. Read-only root filesystem. Drop Linux capabilities.
Restrict pod-to-pod traffic with NetworkPolicy. Enforce standards across the namespace with
Pod Security Admission.

Key concepts: securityContext, runAsNonRoot, readOnlyRootFilesystem, NetworkPolicy,
Pod Security Admission, Linux capabilities.

---

## The Security Stack

Each session adds a layer. All layers together form a production-grade security posture:

```
Session 1 - RBAC              who can access what inside Kubernetes
Session 2 - etcd encryption   protect secrets if storage is compromised
Session 3 - PgBouncer         protect Postgres from connection exhaustion
Session 4 - Secret rotation   limit blast radius of a leaked credential
Session 5 - File mounting     credentials auto-rotate without pod restarts
Session 6 - Vault             secrets managed outside Kubernetes entirely
Session 7 - Pod hardening     restrict what the pod itself can do
```

No single layer is enough. Security is the combination of all of them.

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
