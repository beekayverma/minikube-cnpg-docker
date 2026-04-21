# Helm — Managing CNPG Clusters as a Package

> **What this covers:** Wrapping your CloudNativePG cluster manifests into a
> reusable Helm chart, so you can deploy the same cluster to multiple
> environments with a single command and different values.

---

## Why Helm

Without Helm you have three separate files (`namespace.yaml`, `secret.yaml`,
`cluster.yaml`) and you apply each one manually. Changing anything between
environments means editing files by hand.

With Helm, all tunables live in one `values.yaml`. Deploying to a different
environment is a one-liner:

```sh
helm install pg-staging charts/cnpg-cluster \
  --set cluster.instances=2 \
  --set credentials.password=abc123
```

Same chart. Different values. No file editing.

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Helm | v3.x |
| A running CNPG operator | (installed via `make up`) |

Check Helm is available:

```sh
helm version
```

---

## Chart layout

```
charts/
└── cnpg-cluster/
    ├── Chart.yaml          # chart metadata
    ├── values.yaml         # all tunables with defaults
    └── templates/
        ├── namespace.yaml  # Namespace
        ├── secret.yaml     # credentials Secret
        └── cluster.yaml    # CNPG Cluster CR
```

---

## Chart.yaml

```yaml
apiVersion: v2
name: cnpg-cluster
description: CloudNativePG cluster for local dev
type: application
version: 0.1.0
appVersion: "17.0"
```

---

## values.yaml

```yaml
cluster:
  name: pg-test
  namespace: cnpg-test
  instances: 3
  image: ghcr.io/cloudnative-pg/postgresql:17.0

database:
  name: testdb
  owner: testuser

storage:
  size: 5Gi
  storageClass: standard

resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "400Mi"
    cpu: "500m"

credentials:
  username: testuser
  password: ""   # always override at install time — never commit a real password
```

---

## templates/namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.cluster.namespace }}
```

---

## templates/secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.cluster.name }}-credentials
  namespace: {{ .Values.cluster.namespace }}
type: kubernetes.io/basic-auth
stringData:
  username: {{ .Values.credentials.username }}
  password: {{ .Values.credentials.password }}
```

---

## templates/cluster.yaml

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Values.cluster.name }}
  namespace: {{ .Values.cluster.namespace }}
spec:
  instances: {{ .Values.cluster.instances }}
  imageName: {{ .Values.cluster.image }}
  startDelay: 60
  stopDelay: 60

  resources:
    requests:
      memory: {{ .Values.resources.requests.memory | quote }}
      cpu: {{ .Values.resources.requests.cpu | quote }}
    limits:
      memory: {{ .Values.resources.limits.memory | quote }}
      cpu: {{ .Values.resources.limits.cpu | quote }}

  postgresql:
    parameters:
      max_connections: "50"
      shared_buffers: "128MB"

  bootstrap:
    initdb:
      database: {{ .Values.database.name }}
      owner: {{ .Values.database.owner }}
      secret:
        name: {{ .Values.cluster.name }}-credentials
      encoding: UTF8
      localeCollate: C
      localeCType: C
      dataChecksums: true

  storage:
    size: {{ .Values.storage.size }}
    storageClass: {{ .Values.storage.storageClass }}
```

---

## Common operations

### Render without applying (dry-run)

Always do this first to catch template errors before touching the cluster.

```sh
helm template my-pg charts/cnpg-cluster \
  --set credentials.password=supersecret \
  --kube-context cnpg-local
```

### Install a release

```sh
helm install pg-helm charts/cnpg-cluster \
  --kube-context cnpg-local \
  --set cluster.name=pg-helm \
  --set cluster.namespace=cnpg-helm \
  --set credentials.password=supersecret
```

### List all releases (all namespaces)

```sh
helm list --kube-context cnpg-local -A
```

### Upgrade — change instance count

```sh
helm upgrade pg-helm charts/cnpg-cluster \
  --kube-context cnpg-local \
  --set cluster.name=pg-helm \
  --set cluster.namespace=cnpg-helm \
  --set credentials.password=supersecret \
  --set cluster.instances=1
```

### View upgrade history

```sh
helm history pg-helm --kube-context cnpg-local
```

### Rollback to a previous revision

```sh
helm rollback pg-helm 1 --kube-context cnpg-local
```

### Uninstall a release

```sh
helm uninstall pg-helm --kube-context cnpg-local
```

---

## Running two clusters side by side

Because the cluster name and namespace are values, you can run multiple
independent clusters from the same chart:

```sh
# Cluster A — dev
helm install pg-dev charts/cnpg-cluster \
  --set cluster.name=pg-dev \
  --set cluster.namespace=cnpg-dev \
  --set cluster.instances=1 \
  --set credentials.password=devpass

# Cluster B — staging
helm install pg-staging charts/cnpg-cluster \
  --set cluster.name=pg-staging \
  --set cluster.namespace=cnpg-staging \
  --set cluster.instances=3 \
  --set credentials.password=stagingpass
```

---

## Services created per cluster

CNPG automatically creates three services for every cluster:

| Service | Routes to |
|---|---|
| `<name>-rw` | Current primary — read + write |
| `<name>-ro` | Replicas only — read-only |
| `<name>-r` | All instances — load balanced |

---

## What Helm does NOT manage here

- The CNPG **operator** itself. That is installed separately via
  `make operator` (raw manifest). To manage the operator with Helm,
  add the official CNPG Helm repo:

  ```sh
  helm repo add cnpg https://cloudnative-pg.github.io/charts
  helm install cnpg-operator cnpg/cloudnative-pg -n cnpg-system --create-namespace
  ```

- **Backups.** Add `spec.backup.barmanObjectStore` to `templates/cluster.yaml`
  and expose the relevant values in `values.yaml` when you need it.

- **PodMonitor / metrics.** Flip `spec.monitoring.enablePodMonitor: true`
  in the cluster template once kube-prometheus-stack is installed.
