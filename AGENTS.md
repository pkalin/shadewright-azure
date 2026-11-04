# shadewright-azure: guide for coding agents

Terraform for a reference Shadewright lab in Azure. Anyone should be able to apply it in their own subscription by filling in `*.tfvars` and `backend.hcl` from the `.example` files. Nothing personal is committed.

## Roots

Apply in this order, destroy in reverse:

1. `bootstrap/`: state storage account (Entra-only auth, IP firewall, versioning, delete lock). Stays for the life of the lab.
2. `foundation/`: Key Vault for the GitHub App key, user-assigned identities for the analyzer and the executor, the model deployment in Microsoft Foundry, the analysis records container (blob, lifecycle retention; must survive the lab), budget alert. Cheap, stays up.
3. `lab/`: the AKS cluster with its OIDC issuer, federated credentials for both identities, and, when `flux_enabled`, Flux pointed at `shadewright-fleet`. Terraform only outputs what Flux needs (`flux` in `lab/flux.tf`); `scripts/lab.sh up` installs Flux after the apply (pins in `scripts/flux.env`, the same release as the fleet's `scripts/tools.env`: bump both together). `lab_test.sh` checks that file against the fleet's (CI fetches it from the fleet's `main`). No Terraform kubernetes or helm provider, no `flux bootstrap`. A lab applied with the old AKS extension must be destroyed (`make lab-down`) before applying this version. Disposable: apply for a session, destroy after.

Each root keeps its state in the bootstrap account under its own key (`<root>.tfstate`) and reads shared values through `terraform_remote_state` or data sources, never by copying IDs.

## Commands

```bash
cd <root>
terraform init -backend-config=../backend.hcl     # bootstrap's very first run: terraform init -backend=false
terraform fmt -recursive && terraform validate
terraform plan -out=x.tfplan                      # read it: no surprise destroys
terraform apply x.tfplan && rm x.tfplan
```

Terraform version is pinned in `.terraform-version` (tfenv). Commit `.terraform.lock.hcl`, with hashes for
`linux_amd64` (CI) as well as the macOS platforms, the same provider versions in all three roots (README, "Checks").

## Rules

- Cost: the lab must stay well inside a small monthly credit. Price every new resource first (Azure Retail Prices API) and note the price and the date checked in a comment next to it. No Bastion, NAT Gateway, Defender plans, Container Insights or paid AKS tiers.
- AKS: Free tier, Entra ID with Azure RBAC, local accounts disabled, public API server limited by `authorized_ip_ranges` (a private cluster would block local development of the operator).
- Identity: workload identity federation only. No client secrets, PATs or storage keys anywhere; the GitHub App private key lives only in Key Vault.
- No secrets, subscription or tenant IDs, IPs or object IDs in committed files or variable defaults.
- Never run `terraform apply` or `destroy` without showing the plan first.
- Region: Sweden Central by default (operator repo ADR-0016: cheapest EU node, OpenAI and Anthropic models). Every root takes `location` as a variable.

## Commits

Every commit on `main` follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope)!: summary`. Pull requests are squash-merged with the pull request title as the commit message,
so the **pull request title** is what counts; a required check (`Conventional PR title`) validates it.

- Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`, `revert`.
- Scope is optional; when used it is one of: `bootstrap`, `foundation`, `lab`, `scripts`, `docs`, `ci`, `deps`.
- Summary in English, imperative, starting lower case, no full stop: `feat(policy): refuse decreases by default`.
- `!` after the type or scope, plus a `BREAKING CHANGE:` footer in the description, for incompatible changes
  (API fields, CRD schema, flags, Helm values).
- This repository is not released; the convention keeps the history readable and consistent with the operator.

## Working agreement

- Every change goes through a branch and a pull request; `main` is protected by a ruleset (required checks,
  squash merge, no force push). Keep pull requests small and say why in the description.
- Run `terraform fmt -check -recursive`, `terraform validate` and a `plan` locally before opening a pull request, and add or update tests in the same pull request. CI (`.github/workflows/terraform.yml`) repeats `fmt` and `validate` for every root; `plan` runs only locally (README, "Checks"), so put its summary in the pull request description.
- Leave the code safer than you found it: when you notice a security or reliability problem nearby, fix it
  or raise it in the pull request, do not ignore it.
- Prefer boring, well-known solutions and the project's existing patterns over new dependencies or clever code.

## Engineering and security practices

- Pin provider versions (`~>` on a minor line) and commit `.terraform.lock.hcl`; never use unpinned modules.
- Least privilege: the narrowest scope and the narrowest built-in role, or a custom role when no built-in one is
  narrow enough (the executor's sign-only role on the App key); data-plane access through Entra ID
  only, local auth and shared keys disabled.
- Network: public endpoints only with IP rules or authorized ranges; no `0.0.0.0/0`.
- Stateful resources (state storage, Key Vault, analysis records) keep soft delete, versioning or locks; a
  plan that replaces or destroys them needs an explicit note in the pull request.
- Sensitive values only as `sensitive = true` variables or outputs, never in defaults, descriptions or tags.
- Prefer native Azure features over extra resources; every new resource gets a price check first.
