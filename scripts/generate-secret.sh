#!/bin/sh
# Generate a fresh CNPG bootstrap Secret with a random password.
#
# Writes manifests/cluster/secret.yaml (which is .gitignored).
# Safe to run repeatedly - each run regenerates the password.
#
# Usage:
#   scripts/generate-secret.sh <namespace> <secret-name> <username>

set -eu

NS="${1:-cnpg-test}"
NAME="${2:-pg-test-credentials}"
USER="${3:-testuser}"

# 32 random url-safe chars (no /, +, =)
PASSWORD=$(head -c 64 /dev/urandom | base64 | tr -d '/+=' | head -c 32)

OUT_DIR="$(dirname "$0")/../manifests/cluster"
OUT_FILE="$OUT_DIR/secret.yaml"

mkdir -p "$OUT_DIR"

cat > "$OUT_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $NAME
  namespace: $NS
type: kubernetes.io/basic-auth
stringData:
  username: $USER
  password: $PASSWORD
EOF

chmod 600 "$OUT_FILE"

echo "Generated $OUT_FILE (username=$USER, password=<${#PASSWORD} chars, saved to file)"
echo "To view later:  kubectl -n $NS get secret $NAME -o jsonpath='{.data.password}' | base64 -d"
