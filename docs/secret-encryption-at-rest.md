# Session 2 - Secret Encryption at Rest

Author: beekay.verma@gmail.com

---

## What This Session Covers

By default, Kubernetes Secrets are stored in etcd encoded in base64 - not encrypted. Anyone with
direct etcd access can read every secret in your cluster in plaintext. This session shows how to
enable Encryption at Rest using the `aescbc` provider so that secrets in etcd are encrypted with
a real symmetric key.

---

## The Problem - Secrets Are Readable by Default

Kubernetes Secrets store values as base64. Base64 is encoding, not encryption. Anyone who can
reach etcd directly can decode everything:

```
/registry/secrets/cnpg-test/pg-test-credentials
{"username":"testuser","password":"abc123..."}
```

This is visible without any credentials other than access to the etcd data directory or the etcd
API with the server cert.

---

## How Encryption at Rest Works

The kube-apiserver sits between all clients and etcd. It is the only component that reads and
writes to etcd directly. When configured with an `EncryptionConfiguration`, the API server:

1. Encrypts secret data before writing to etcd
2. Decrypts it transparently when reading back

etcd never sees plaintext. The encryption key lives only on the control plane node, separate from
the data it protects.

```
kubectl apply secret
       |
       v
kube-apiserver  -->  encrypt with aescbc key  -->  etcd (ciphertext)
kube-apiserver  <--  decrypt with aescbc key  <--  etcd (ciphertext)
       |
       v
kubectl get secret (plaintext to authorized callers)
```

---

## Step 1 - Generate an Encryption Key

The key must be 32 bytes, base64-encoded:

```bash
head -c 32 /dev/urandom | base64
```

Flag and concept breakdown:

| Flag / Concept | Meaning |
|---|---|
| `head -c 32` | Read exactly 32 bytes. AES-256 requires a 256-bit (32-byte) key. |
| `/dev/urandom` | Kernel entropy pool. Cryptographically safe random source on Linux. |
| `base64` | Encode the raw bytes to ASCII so they can be written into a YAML file safely. |

Save the output - you will need it in the EncryptionConfiguration. Never commit this key to git.

---

## Step 2 - Write the EncryptionConfiguration

SSH into the minikube node:

```bash
minikube ssh -p cnpg-local
```

Create the directory and config file:

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo cat > /etc/kubernetes/enc/encryption-config.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <YOUR_BASE64_KEY>
      - identity: {}
EOF
sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml
```

Field breakdown:

| Field | Meaning |
|---|---|
| `resources: [secrets]` | Only encrypt Secrets. ConfigMaps, Pods, etc. stay unencrypted. |
| `providers` | Ordered list. The first provider is used for all new writes. |
| `aescbc` | AES in CBC mode. The standard symmetric encryption provider in Kubernetes. |
| `keys[].name` | Label for this key version. Used in the `k8s:enc:aescbc:v1:key1:` prefix written to etcd. Needed for key rotation. |
| `keys[].secret` | The base64-encoded 32-byte key you generated. |
| `identity: {}` | Fallback - reads unencrypted secrets written before encryption was enabled. Keep this second so it is never used for writes. |

Why `identity: {}` must be second, not first: providers are tried in order for both reads and
writes. If `identity` is first, the API server writes secrets unencrypted. Put it second so it
can still read old secrets but never writes new ones that way.

---

## Step 3 - Modify the kube-apiserver Static Pod Manifest

The kube-apiserver in minikube runs as a static pod. The manifest lives at:
`/etc/kubernetes/manifests/kube-apiserver.yaml`

The kubelet watches this directory. Any change to the file restarts the static pod automatically.

Back up the manifest first:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak
```

Three changes are needed:

### Change 1 - Add the flag

```bash
sudo sed -i 's|    - kube-apiserver|    - kube-apiserver\n    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

Flag breakdown:

| Flag | Meaning |
|---|---|
| `--encryption-provider-config` | Tells kube-apiserver where to find the EncryptionConfiguration file. Without this flag, encryption is never activated even if the file exists. |

### Change 2 - Mount the directory into the container

```bash
sudo sed -i 's|    volumeMounts:|    volumeMounts:\n    - mountPath: /etc/kubernetes/enc\n      name: enc-config\n      readOnly: true|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

Field breakdown:

| Field | Meaning |
|---|---|
| `mountPath` | The path inside the container where the volume appears. Must match the path in `--encryption-provider-config`. |
| `name` | Links this volumeMount to the volume defined below. |
| `readOnly: true` | The API server only needs to read the config. Prevents the container from accidentally modifying the key file. |

### Change 3 - Define the volume source

```bash
sudo sed -i 's|  volumes:|  volumes:\n  - hostPath:\n      path: /etc/kubernetes/enc\n      type: DirectoryOrCreate\n    name: enc-config|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

Field breakdown:

| Field | Meaning |
|---|---|
| `hostPath` | Mount a directory from the node's filesystem directly into the pod. Used here because the encryption key must persist across pod restarts and is managed manually on the node. |
| `path: /etc/kubernetes/enc` | The directory on the minikube node containing encryption-config.yaml. |
| `type: DirectoryOrCreate` | Create the directory if it does not exist. Prevents pod failure if the directory was removed. |

---

## Step 4 - Verify the Changes Landed

```bash
grep -A2 'encryption\|enc-config' /etc/kubernetes/manifests/kube-apiserver.yaml
```

Expected output shows three matches:
- `--encryption-provider-config=...` in the command args
- `name: enc-config` + `readOnly: true` in volumeMounts
- `name: enc-config` below the hostPath in volumes

---

## Step 5 - Wait for the API Server to Restart

The kubelet restarts the static pod automatically within ~60 seconds. Verify it is healthy:

```bash
kubectl get pods -n kube-system -l component=kube-apiserver
```

Wait for `1/1 Running`. Then confirm etcd is reachable:

```bash
kubectl get --raw /healthz/etcd
```

Expected: `ok`

---

## Step 6 - Re-encrypt Existing Secrets

Encryption only applies to new writes. Secrets already in etcd are still plaintext until you
touch them. Force a rewrite of every secret:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

What this does:
- `kubectl get secrets --all-namespaces -o json` - reads every secret across all namespaces as JSON
- `kubectl replace -f -` - writes each one back, triggering a new etcd write through the now-active encryption layer

---

## Step 7 - Verify Encryption in etcd

Query etcd directly using `kubectl exec` into the etcd pod:

```bash
kubectl -n kube-system exec etcd-cnpg-local -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/minikube/certs/etcd/ca.crt \
  --cert=/var/lib/minikube/certs/etcd/server.crt \
  --key=/var/lib/minikube/certs/etcd/server.key \
  get /registry/secrets/cnpg-test/pg-test-credentials | od -c | head -5
```

Flag breakdown:

| Flag | Meaning |
|---|---|
| `--endpoints` | etcd client endpoint. Uses HTTPS because client-cert-auth is enabled. |
| `--cacert` | Certificate Authority cert to verify the etcd server's TLS certificate. |
| `--cert` | Client certificate - proves to etcd that this client is authorized. |
| `--key` | Private key for the client certificate. |
| `od -c` | Octal dump with character representation. Handles binary data safely - shows raw bytes without terminal corruption. |

Expected output:

```
0000000   /   r   e   g   i   s   t   r   y   /   s   e   c   r   e   t
0000020   s   /   c   n   p   g   -   t   e   s   t   /   p   g   -   t
0000040   e   s   t   -   c   r   e   d   e   n   t   i   a   l   s  \n
0000060   k   8   s   :   e   n   c   :   a   e   s   c   b   c   :   v
0000100   1   :   k   e   y   1   : 334  \r 223 361 004  \0   * 271   t
```

The key line is `k 8 s : e n c : a e s c b c : v 1 : k e y 1 :` - this is the encryption
envelope prefix Kubernetes writes before the ciphertext. Everything after the `:` is the
encrypted blob. No plaintext credentials visible.

---

## What the Encryption Prefix Tells You

`k8s:enc:aescbc:v1:key1:`

| Part | Meaning |
|---|---|
| `k8s:enc` | Marker that this value is encrypted by the API server |
| `aescbc` | The provider that encrypted it |
| `v1` | Provider version |
| `key1` | The key name from your EncryptionConfiguration - used during key rotation to know which key to decrypt with |

---

## Key Rotation (Reference)

When you rotate the encryption key:
1. Add the new key as the first entry in `providers` (new writes use it)
2. Keep the old key as the second entry (needed to decrypt existing secrets)
3. Restart the API server
4. Re-run `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` to re-encrypt everything with the new key
5. Remove the old key entry once all secrets are re-encrypted

---

## Limitations

- The key itself lives on the control plane node. If an attacker gets the node AND the etcd data, they have both. For stronger guarantees, use an external KMS provider (HashiCorp Vault, AWS KMS, GCP KMS).
- This only encrypts Secrets. Other sensitive resources (like ConfigMaps containing credentials) are not covered unless you add them to the `resources` list.
- Encryption at rest does not protect against a compromised kube-apiserver - it decrypts transparently for any authorized API call.

---

## Useful Commands

```bash
# Check API server is running
kubectl get pods -n kube-system -l component=kube-apiserver

# Check etcd health
kubectl get --raw /healthz/etcd

# Verify a secret is encrypted (look for k8s:enc:aescbc prefix)
kubectl -n kube-system exec etcd-cnpg-local -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/minikube/certs/etcd/ca.crt \
  --cert=/var/lib/minikube/certs/etcd/server.crt \
  --key=/var/lib/minikube/certs/etcd/server.key \
  get /registry/secrets/cnpg-test/pg-test-credentials | od -c | head -5

# Force re-encrypt all secrets
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```
