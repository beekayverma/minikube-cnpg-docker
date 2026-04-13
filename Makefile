# minikube-cnpg-docker - one-command local CloudNativePG on minikube
#
# Usage:
#   make            # same as `make help`
#   make up         # full bring-up: minikube + operator + cluster
#   make psql       # port-forward + drop into psql
#   make status     # health summary
#   make down       # tear down cluster + operator (keeps minikube VM)
#   make nuke       # delete the minikube VM entirely
#
# Tweakable knobs (override on command line: `make up MINIKUBE_MEMORY=8192`):

CLUSTER_NAME         ?= pg-test
NS                   ?= cnpg-test
SECRET_NAME          ?= $(CLUSTER_NAME)-credentials
PG_APP_USER          ?= testuser
PG_DB_NAME           ?= testdb

MINIKUBE_PROFILE     ?= cnpg-local
MINIKUBE_CPUS        ?= 4
MINIKUBE_MEMORY      ?= 6144
MINIKUBE_DISK        ?= 20g
MINIKUBE_DRIVER      ?= docker
MINIKUBE_K8S_VERSION ?= v1.30.0

CNPG_VERSION         ?= 1.24.0
CNPG_MANIFEST        := manifests/operator/cnpg-$(CNPG_VERSION).yaml

KC                   := kubectl --context=$(MINIKUBE_PROFILE)

.PHONY: help check start operator namespace secret cluster up status psql logs reset down nuke

help:
	@echo "minikube-cnpg-docker - local CloudNativePG on minikube"
	@echo ""
	@echo "Targets:"
	@echo "  make check      Verify minikube, kubectl, docker are on PATH"
	@echo "  make up         Full bring-up (check + start + operator + cluster)"
	@echo "  make start      Start minikube VM only"
	@echo "  make operator   Install CNPG operator only"
	@echo "  make namespace  Create the test namespace"
	@echo "  make secret     Generate a fresh credentials Secret"
	@echo "  make cluster    Apply the Cluster CR and wait for Ready"
	@echo "  make status     Print pod + cluster summary"
	@echo "  make psql       Port-forward 5432 and open psql in the primary"
	@echo "  make logs       Tail operator + cluster logs"
	@echo "  make reset      Delete + recreate the cluster (keeps minikube)"
	@echo "  make down       Delete cluster + operator + namespace"
	@echo "  make nuke       minikube delete - full teardown"
	@echo ""
	@echo "Knobs (override on the command line):"
	@echo "  MINIKUBE_MEMORY=$(MINIKUBE_MEMORY)  MINIKUBE_CPUS=$(MINIKUBE_CPUS)  MINIKUBE_DISK=$(MINIKUBE_DISK)"
	@echo "  CNPG_VERSION=$(CNPG_VERSION)  NS=$(NS)  CLUSTER_NAME=$(CLUSTER_NAME)"

check:
	@command -v minikube >/dev/null 2>&1 || { echo >&2 "ERROR: minikube not found on PATH"; exit 1; }
	@command -v kubectl  >/dev/null 2>&1 || { echo >&2 "ERROR: kubectl not found on PATH"; exit 1; }
	@command -v docker   >/dev/null 2>&1 || { echo >&2 "ERROR: docker not found on PATH"; exit 1; }
	@echo "Prereqs OK."

start: check
	@if minikube status -p $(MINIKUBE_PROFILE) >/dev/null 2>&1; then \
		echo "minikube profile '$(MINIKUBE_PROFILE)' already exists, starting…"; \
		minikube start -p $(MINIKUBE_PROFILE); \
	else \
		echo "Creating fresh minikube profile '$(MINIKUBE_PROFILE)'…"; \
		minikube start -p $(MINIKUBE_PROFILE) \
			--driver=$(MINIKUBE_DRIVER) \
			--cpus=$(MINIKUBE_CPUS) \
			--memory=$(MINIKUBE_MEMORY) \
			--disk-size=$(MINIKUBE_DISK) \
			--kubernetes-version=$(MINIKUBE_K8S_VERSION) \
			--extra-config=kubelet.syncFrequency=15s; \
	fi
	@$(KC) get nodes

operator: start
	@echo "Installing CNPG operator v$(CNPG_VERSION)…"
	$(KC) apply --server-side -f $(CNPG_MANIFEST)
	@$(KC) -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s
	@echo "CNPG operator ready."

namespace: operator
	$(KC) apply -f manifests/cluster/namespace.yaml

secret: namespace
	@scripts/generate-secret.sh $(NS) $(SECRET_NAME) $(PG_APP_USER)
	$(KC) apply -f manifests/cluster/secret.yaml

cluster: secret
	$(KC) apply -f manifests/cluster/cluster.yaml
	@echo "Waiting for $(CLUSTER_NAME)-1 pod to become Ready (up to 5 min)…"
	@scripts/wait-for.sh $(NS) cnpg.io/cluster=$(CLUSTER_NAME) 300
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════"
	@echo " CNPG cluster '$(CLUSTER_NAME)' is up."
	@echo "═══════════════════════════════════════════════════════════════"
	@echo " Namespace:    $(NS)"
	@echo " Database:     $(PG_DB_NAME)"
	@echo " App user:     $(PG_APP_USER)"
	@echo " Secret:       $(SECRET_NAME)"
	@echo ""
	@echo " Connect:      make psql"
	@echo " Port-forward: kubectl -n $(NS) port-forward svc/$(CLUSTER_NAME)-rw 5432:5432"
	@echo " Status:       make status"
	@echo " Teardown:     make down  (or make nuke for the full VM)"
	@echo "═══════════════════════════════════════════════════════════════"

up: cluster

status:
	@echo "=== minikube ==="
	@minikube status -p $(MINIKUBE_PROFILE) || true
	@echo ""
	@echo "=== cnpg-system ==="
	@$(KC) -n cnpg-system get pods 2>/dev/null || echo "(operator not installed)"
	@echo ""
	@echo "=== $(NS) ==="
	@$(KC) -n $(NS) get pods 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== cluster ==="
	@$(KC) -n $(NS) get cluster $(CLUSTER_NAME) 2>/dev/null || echo "(cluster CR not found)"

psql:
	@echo "Connecting to the current primary via pg-test-rw service (exit with \\q)…"
	@PRIMARY=$$($(KC) -n $(NS) get cluster $(CLUSTER_NAME) -o jsonpath='{.status.currentPrimary}') && \
	$(KC) -n $(NS) exec -it $$PRIMARY -c postgres -- psql -U $(PG_APP_USER) -d $(PG_DB_NAME)

logs:
	@echo "=== CNPG operator logs (last 50) ==="
	@$(KC) -n cnpg-system logs deploy/cnpg-controller-manager --tail=50 || true
	@echo ""
	@echo "=== Cluster primary logs (last 50) ==="
	@$(KC) -n $(NS) logs $(CLUSTER_NAME)-1 -c postgres --tail=50 || true

reset:
	@echo "Deleting Cluster CR (PVC will be recreated)…"
	-$(KC) -n $(NS) delete cluster $(CLUSTER_NAME) --ignore-not-found
	-$(KC) -n $(NS) delete pvc --all --ignore-not-found
	@sleep 3
	@$(MAKE) cluster

down:
	-$(KC) -n $(NS) delete cluster $(CLUSTER_NAME) --ignore-not-found
	-$(KC) delete -f manifests/cluster/namespace.yaml --ignore-not-found
	-$(KC) delete -f $(CNPG_MANIFEST) --ignore-not-found
	@echo "Cluster + operator removed. minikube VM still running (make nuke to delete it)."

nuke:
	@echo "Deleting minikube profile '$(MINIKUBE_PROFILE)'…"
	minikube delete -p $(MINIKUBE_PROFILE)
	-rm -f manifests/cluster/secret.yaml
	@echo "Everything removed. Run 'make up' to start fresh."
