# RBAC - Role-Based Access Control for CNPG

A hands-on guide for beginners on locking down who can do what in your
Kubernetes cluster. You will create two identities with different permission
levels and prove the restrictions work using live impersonation tests.

- Author: beekay.verma@gmail.com
- Requires: a running CNPG cluster (see README.md to set one up)

---

## The Problem - Default Access is Wide Open

By default, minikube gives your user cluster-admin. Run this to see:

```bash
kubectl -n cnpg-test auth can-i --list
```

The first line will show:

```
*.*    []    []    [*]
```

That means all resources, all namespaces, all verbs. Anyone with kubectl
access can read secrets, exec into pods, delete workloads - everything.
In production this would be catastrophic.

---

## What is RBAC?

RBAC - Role-Based Access Control - is how Kubernetes controls who can do
what to which resources. It has three building blocks:

```
Role          - defines a set of permissions (what actions on what resources)
ServiceAccount - an identity (who)
RoleBinding   - connects the two (this identity gets these permissions)
```

The key principle is **least privilege** - every identity should have only
the minimum permissions it needs to do its job, and nothing more.

---

## What We Will Build

Two identities with different access levels:

```
developer-sa  - can view pods and logs
              - cannot read secrets
              - cannot delete pods
              - cannot exec into pods

app-sa        - can read only pg-test-credentials secret
              - cannot read any other secret
              - cannot see pods
              - cannot do anything else
```

---

## Step 1 - Create ServiceAccounts

```bash
mkdir -p manifests/rbac
```

```bash
cat > manifests/rbac/service-accounts.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: developer-sa
  namespace: cnpg-test
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: cnpg-test
EOF
```

```bash
kubectl apply -f manifests/rbac/service-accounts.yaml
```

---

## Step 2 - Create Roles

```bash
cat > manifests/rbac/roles.yaml << 'EOF'
# developer-role - can view pods and logs, nothing else
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-role
  namespace: cnpg-test
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get", "list"]
---
# app-role - can only read the one secret it needs
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-role
  namespace: cnpg-test
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["pg-test-credentials"]
EOF
```

```bash
kubectl apply -f manifests/rbac/roles.yaml
```

**Key points:**

- `developer-role` lists pods and logs but secrets are not listed at all - omitting a resource means no access
- `app-role` uses `resourceNames` to restrict access to one specific secret - even if someone compromises the app it can only ever read this one secret
- `verbs: ["get"]` means read-only - no list, no watch, no delete

---

## Step 3 - Create RoleBindings

```bash
cat > manifests/rbac/rolebindings.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-binding
  namespace: cnpg-test
subjects:
- kind: ServiceAccount
  name: developer-sa
  namespace: cnpg-test
roleRef:
  kind: Role
  name: developer-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-binding
  namespace: cnpg-test
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: cnpg-test
roleRef:
  kind: Role
  name: app-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

```bash
kubectl apply -f manifests/rbac/rolebindings.yaml
```

---

## Step 4 - Verify the Restrictions Work

Kubernetes lets you impersonate a ServiceAccount with `--as` to test its
permissions without actually switching users.

**Test developer-sa:**

```bash
kubectl -n cnpg-test auth can-i get pods --as=system:serviceaccount:cnpg-test:developer-sa
kubectl -n cnpg-test auth can-i get secrets --as=system:serviceaccount:cnpg-test:developer-sa
kubectl -n cnpg-test auth can-i delete pods --as=system:serviceaccount:cnpg-test:developer-sa
```

Expected output:
```
yes
no
no
```

**Test app-sa:**

```bash
kubectl -n cnpg-test auth can-i get secrets/pg-test-credentials --as=system:serviceaccount:cnpg-test:app-sa
kubectl -n cnpg-test auth can-i get secrets/some-other-secret --as=system:serviceaccount:cnpg-test:app-sa
kubectl -n cnpg-test auth can-i get pods --as=system:serviceaccount:cnpg-test:app-sa
```

Expected output:
```
yes
no
no
```

**Full results summary:**

| ServiceAccount | Action | Result |
|---------------|--------|--------|
| developer-sa | get pods | yes |
| developer-sa | get secrets | no |
| developer-sa | delete pods | no |
| developer-sa | exec into pods | no |
| app-sa | get pg-test-credentials | yes |
| app-sa | get any other secret | no |
| app-sa | get pods | no |

---

## How This Applies in Production

In production you would assign ServiceAccounts to actual application pods
so they inherit the restricted permissions automatically:

```yaml
spec:
  serviceAccountName: app-sa   # pod runs with app-sa identity
  containers:
  - name: app
    ...
```

The pod can then only read `pg-test-credentials` and nothing else in the
cluster - even if an attacker gains code execution inside the container.

---

## What RBAC Does Not Protect Against

RBAC controls the Kubernetes API - it does not protect against:

- Someone who can `kubectl exec` into a pod reading env vars directly
- A compromised node where an attacker reads secrets from memory
- Insider threats with legitimate kubectl access

This is why RBAC is one layer in a defence-in-depth strategy, not the
only layer. Combine it with:

- Secret encryption at rest (Session 2)
- File mounting instead of env vars (Session 5)
- Network policies to restrict pod-to-pod traffic
- Audit logging to detect unusual access patterns

---

## Teardown

```bash
kubectl delete -f manifests/rbac/
```
