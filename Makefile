# Lab session commands (README, "Lab session"). The logic, and the confirmation before any apply, is in
# scripts/lab.sh; these targets only name it. Nothing here touches foundation or bootstrap.
SHELL := bash
# GNU Make 3.81 (macOS) ignores .SHELLFLAGS, so recipes also exit on their own errors.
.SHELLFLAGS := -euo pipefail -c
ROOTS := bootstrap foundation lab

.PHONY: help lab-plan lab-up lab-flux lab-down lab-cost lab-check check test

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

lab-plan: ## Plan the lab; changes nothing
	@scripts/lab.sh plan

lab-up: ## Plan, show the plan and the price per hour, ask for yes, apply the saved plan
	@scripts/lab.sh up

lab-flux: ## Repeat the Flux install after lab-up (idempotent; for a cluster that is up and flux_enabled)
	@scripts/lab.sh flux

lab-down: ## Destroy the lab (only), after a yes, then check that nothing is left
	@scripts/lab.sh down

lab-cost: ## Price the lab per hour (Azure Retail Prices API, no login)
	@scripts/lab.sh cost

lab-check: ## List what is left in the subscription; fails while lab resources remain
	@scripts/lab.sh check

check: ## terraform fmt and validate for every root, as CI runs them (no backend, no cloud)
	terraform fmt -check -recursive
	for r in $(ROOTS); do \
	  terraform -chdir=$$r init -backend=false -input=false -lockfile=readonly >/dev/null || exit 1; \
	  terraform -chdir=$$r validate || exit 1; \
	done

test: ## Offline tests of the lab script (no Terraform, no Azure)
	scripts/lab_test.sh
