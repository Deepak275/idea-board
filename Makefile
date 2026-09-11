# Idea Board — developer & operator entrypoints.
#
# Local dev uses docker compose; deploy/destroy drive Terraform + Helm against
# the cloud selected by CLOUD (aws|gcp). Nothing here is cloud-specific beyond
# passing $(CLOUD) through to the identical, contract-driven infra layers.

# ---- tunables ---------------------------------------------------------------
COMPOSE ?= docker compose
CLOUD   ?= aws                      # target cloud for infra targets: aws | gcp
RELEASE ?= idea-board
NAMESPACE ?= idea-board
CHART   ?= charts/idea-board
STACK   ?= infra/stacks/$(CLOUD)
PLATFORM ?= infra/platform

.DEFAULT_GOAL := help
.PHONY: help up down logs test tf-init deploy destroy lint

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ---- local development ------------------------------------------------------
up: ## Build and start the full local stack (db + backend + frontend)
	$(COMPOSE) up --build -d
	@echo "Frontend: http://localhost:5173   API: http://localhost:8000"

down: ## Stop the local stack and remove its volumes
	$(COMPOSE) down -v

logs: ## Tail logs from all local services
	$(COMPOSE) logs -f

test: ## Run backend tests in a throwaway backend container (starts db first)
	$(COMPOSE) run --rm -T backend sh -c "python -m pytest -q"

# ---- infrastructure (Terraform + Helm) --------------------------------------
tf-init: ## terraform init for the selected cloud stack (CLOUD=aws|gcp)
	terraform -chdir=$(STACK) init

deploy: ## Provision infra + add-ons, then install the chart (CLOUD=aws|gcp)
	terraform -chdir=$(STACK) init
	terraform -chdir=$(STACK) apply -auto-approve
	./scripts/get-kubeconfig.sh $(CLOUD)
	terraform -chdir=$(PLATFORM) init
	terraform -chdir=$(PLATFORM) apply -auto-approve
	helm upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		-f $(CHART)/values.yaml -f $(CHART)/values-$(CLOUD).yaml

destroy: ## Tear everything down for the selected cloud (CLOUD=aws|gcp)
	-helm uninstall $(RELEASE) --namespace $(NAMESPACE)
	-terraform -chdir=$(PLATFORM) destroy -auto-approve
	terraform -chdir=$(STACK) destroy -auto-approve

# ---- quality gates ----------------------------------------------------------
lint: ## Lint Terraform, Helm chart, and Python (matches CI)
	terraform fmt -check -recursive infra
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-$(CLOUD).yaml
	python -m ruff check app/backend ai
