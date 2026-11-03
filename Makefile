# Lab session commands (README, "Lab session"). The logic, and the confirmation before any apply, is in
# scripts/lab.sh; these targets only name it. Nothing here touches foundation or bootstrap.
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
ROOTS := bootstrap foundation lab

.PHONY: help lab-plan lab-up lab-down lab-cost lab-check check

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

lab-plan: ## Plan the lab; changes nothing
	@scripts/lab.sh plan

lab-up: ## Plan, show the plan and the price per hour, ask for yes, apply the saved plan
	@scripts/lab.sh up

lab-down: ## Destroy the lab (only), after a yes, then check that nothing is left
	@scripts/lab.sh down

lab-cost: ## Price the lab per hour (Azure Retail Prices API, no login)
	@scripts/lab.sh cost

lab-check: ## List what is left in the subscription; fails while lab resources remain
	@scripts/lab.sh check

check: ## terraform fmt and validate for every root, as CI runs them (no backend, no cloud)
	terraform fmt -check -recursive
	for r in $(ROOTS); do \
	  terraform -chdir=$$r init -backend=false -input=false -lockfile=readonly >/dev/null; \
	  terraform -chdir=$$r validate; \
	done
