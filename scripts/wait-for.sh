#!/bin/sh
# Poll until all pods matching a label selector are Ready.
#
# Usage:
#   scripts/wait-for.sh <namespace> <label-selector> [timeout-seconds]
#
# Example:
#   scripts/wait-for.sh cnpg-test cnpg.io/cluster=pg-test 180
#
# Exits 0 on success, 1 on timeout. POSIX sh, no bashisms.

set -eu

NS="${1:?namespace required}"
SEL="${2:?label selector required}"
TIMEOUT="${3:-180}"

start=$(date +%s)
while :; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "ERROR: timeout after ${TIMEOUT}s waiting for pods matching '$SEL' in namespace '$NS'" >&2
        kubectl -n "$NS" get pods -l "$SEL" >&2 || true
        exit 1
    fi

    # Pod phase + readiness: only 'Running' pods whose every container is ready count.
    total=$(kubectl -n "$NS" get pods -l "$SEL" --no-headers 2>/dev/null | wc -l || echo 0)
    if [ "$total" -eq 0 ]; then
        sleep 3
        continue
    fi

    ready=$(kubectl -n "$NS" get pods -l "$SEL" \
        -o 'jsonpath={range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null \
        | grep -c '^true$' || true)

    if [ "$ready" -eq "$total" ] && [ "$total" -gt 0 ]; then
        echo "OK: $total/$total pods ready in $NS matching '$SEL' (${elapsed}s)"
        exit 0
    fi

    printf "  waiting… %s/%s ready (%ds)\r" "$ready" "$total" "$elapsed"
    sleep 3
done
