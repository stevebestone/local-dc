# Datacenter-in-a-Box — operator shortcuts
# Override the compose command if you use podman-compose:  make COMPOSE="podman-compose" up
COMPOSE ?= podman compose
KUBECONFIG_FILE := $(CURDIR)/output/kubeconfig.yaml

.PHONY: up down wipe status logs kubeconfig backstage verify help

help:
	@echo "Datacenter-in-a-Box"
	@echo "  make up         Bootstrap the local datacenter (k3s + ArgoCD + GitOps sync)"
	@echo "  make down       Stop it (cluster state + image cache preserved for fast restart)"
	@echo "  make wipe       Full teardown (delete all volumes + kubeconfig)"
	@echo "  make status     Show containers, nodes, and ArgoCD applications"
	@echo "  make logs       Follow the bootstrapper logs"
	@echo "  make kubeconfig Print the export line for host kubectl"
	@echo "  make backstage  Build the custom Backstage image and load it into the node"
	@echo "  make verify     Confirm /dev/kvm passthrough + KubeVirt readiness"

up:
	@test -f .env || cp .env.example .env
	$(COMPOSE) up -d
	@echo "Bootstrapping... follow with 'make logs'. UIs come up on http://localhost:30080-30085"

down:
	$(COMPOSE) down

wipe:
	$(COMPOSE) down -v
	@rm -f $(KUBECONFIG_FILE)
	@echo "Datacenter wiped."

status:
	$(COMPOSE) ps
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes 2>/dev/null || true
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get applications -n argocd 2>/dev/null || true

logs:
	$(COMPOSE) logs -f bootstrap

kubeconfig:
	@echo "export KUBECONFIG=$(KUBECONFIG_FILE)"

# Build the custom Backstage image and import it into the containerized node's
# containerd store as localhost/backstage-idp:latest (matches the Deployment,
# which uses imagePullPolicy: Never).
backstage:
	podman build -t localhost/backstage-idp:latest -f backstage/Dockerfile backstage/
	podman save localhost/backstage-idp:latest -o /tmp/backstage-idp.tar
	@CID=$$($(COMPOSE) ps -q server); \
	  podman cp /tmp/backstage-idp.tar $$CID:/tmp/backstage-idp.tar; \
	  podman exec $$CID k3s ctr -n k8s.io images import /tmp/backstage-idp.tar
	@rm -f /tmp/backstage-idp.tar
	@echo "Backstage image loaded. Restart the pod if it was already running:"
	@echo "  KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n platform rollout restart deploy/backstage"

verify:
	@CID=$$($(COMPOSE) ps -q server); \
	  echo "== /dev/kvm inside the node =="; \
	  podman exec $$CID ls -l /dev/kvm && echo "OK: hardware virtualization is available to KubeVirt" \
	    || echo "WARNING: /dev/kvm missing — KubeVirt would fall back to slow software emulation"
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null \
	  && echo " (KubeVirt phase)" || true
