<p align="center"><img src=".github/logo.png" alt="Shadewright" width="120"></p>

# shadewright-azure

Terraform for a reference [Shadewright](https://shadewright.io) lab in Azure: a disposable AKS cluster, a model endpoint in Microsoft Foundry, workload identities, and storage for analysis records. Designed to run in a subscription of its own, with a small monthly budget.

| Root | What | Lifetime |
| --- | --- | --- |
| `bootstrap/` | Storage account for Terraform state | Permanent |
| `foundation/` | VNet, Key Vault (GitHub App key), analyzer and executor identities, AI Services account and model deployments, analysis records storage, budget alert | Permanent, near-zero fixed cost |
| `lab/` | AKS, federated credentials for both identities, Flux (off by default) | Apply for a session, destroy after |

Defaults to Sweden Central. Design and decisions: [shadewright.io](https://shadewright.io).

## Prerequisites

- Terraform (version in `.terraform-version`, `tfenv` picks it up), Azure CLI, logged in with `az login`.
- Owner (or Contributor plus User Access Administrator) on the subscription.
- Your public IP: `curl -s https://api.ipify.org`. Every firewall here admits only `admin_ip_cidrs` and the AKS subnet; if your IP changes, update the tfvars and re-apply.

## First run

Every command below runs from the repository root; `-chdir` picks the root to apply, and the paths it takes
(`x.tfplan`, `../backend.hcl`) are relative to that root.

```bash
# 1. State storage, with local state first (a git-ignored override switches the backend to local)
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars        # fill in
printf 'terraform {\n  backend "local" {}\n}\n' > bootstrap/local_override.tf
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan -out=x.tfplan && terraform -chdir=bootstrap apply x.tfplan && rm bootstrap/x.tfplan
terraform -chdir=bootstrap output -raw backend_config > backend.hcl
rm bootstrap/local_override.tf
terraform -chdir=bootstrap init -migrate-state -backend-config=../backend.hcl   # move the state into the account
rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup

# 2. Foundation
cp foundation/terraform.tfvars.example foundation/terraform.tfvars        # fill in
terraform -chdir=foundation init -backend-config=../backend.hcl
terraform -chdir=foundation plan -out=x.tfplan && terraform -chdir=foundation apply x.tfplan && rm foundation/x.tfplan
```

Then register the GitHub App (next section) once. The cluster itself is a session: see "Lab session".

## GitHub App

The executor opens PRs and issues in the fleet repository as a GitHub App, whose private key lives only in Key Vault as a non-exportable key (ADR-0006).

1. **Create the App** (GitHub, Settings, Developer settings, GitHub Apps, New GitHub App):
   - Homepage URL: your fork's docs or repository URL.
   - Webhook: untick **Active**. The operator never receives inbound calls.
   - Repository permissions: **Contents** read and write, **Pull requests** read and write, **Issues** read and write. **Metadata** read-only is added automatically. Nothing else, no organization or account permissions.
   - Where can this App be installed: **Only on this account**.
2. **Generate a private key** on the App's page. A `.pem` file downloads.
3. **Install the App** on your account with **Only select repositories**: the fleet repository alone.
4. **Import the key** into Key Vault, then delete the file:

   ```bash
   KV=$(terraform -chdir=foundation output -json key_vault | jq -r .name)
   KEY=$(terraform -chdir=foundation output -json key_vault | jq -r .github_app_key)
   az keyvault key import --vault-name "$KV" --name "$KEY" --pem-file ~/Downloads/<app>.private-key.pem \
     --ops sign --protection software --exportable false
   rm ~/Downloads/<app>.private-key.pem
   ```

5. **Grant the executor sign on the key**: set `github_app_key_imported = true` in `foundation/terraform.tfvars` and apply the foundation again. The plan adds one role assignment, scoped to the key. Before this step the executor has no access to the vault. A foundation applied before this flag existed (the key imported, the executor on the vault-wide `Key Vault Crypto User`) needs the flag too: without it the upgrade removes the old grant and adds none.
6. **Check** the whole path (JWT signed in Key Vault, then GitHub's view of the App). The script runs as you (`az login`), not as the executor, so it does not test the executor's grant:

   ```bash
   scripts/github-app-check.sh "$KV" <client-id>
   ```

   Expect your App's name, the three write permissions plus metadata, no events, and one installation with `selected` repositories.

## Lab session

The `lab` root reads the foundation's outputs from its state and creates the AKS cluster, the federated
credentials of both identities and, when `flux_enabled` is set, Flux pointed at the fleet repository. Apply it
for a session and destroy it after: the node is the main cost.

```bash
cp lab/terraform.tfvars.example lab/terraform.tfvars        # fill in; state_backend matches backend.hcl
terraform -chdir=lab init -backend-config=../backend.hcl
terraform -chdir=lab plan -out=x.tfplan && terraform -chdir=lab apply x.tfplan && rm lab/x.tfplan
eval "$(terraform -chdir=lab output -raw get_credentials)"   # kubeconfig for the session
kubelogin convert-kubeconfig -l azurecli                     # once per kubeconfig

# ... work ...

terraform -chdir=lab destroy
```

## Checks

Every pull request runs two workflows; their checks are required in the `main` ruleset:

- `PR title`: the title follows Conventional Commits (see `AGENTS.md`, "Commits").
- `Terraform`: `terraform fmt -check -recursive`, then `terraform init -backend=false -lockfile=readonly` and
  `terraform validate` for `bootstrap`, `foundation` and `lab`, with the version from `.terraform-version`.
  It needs no cloud credentials and never reads the state.

CI runs on Linux, so every `.terraform.lock.hcl` must hold hashes for `linux_amd64` as well as your platform.
After `init -upgrade` or a provider change, refresh them in the root you changed:

```bash
terraform -chdir=<root> providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```

`plan` stays local. It needs the state, and the state account and Key Vault admit only `admin_ip_cidrs`,
so a GitHub-hosted runner cannot reach them without opening the firewalls (or paying for a runner inside
the VNet). It also needs the git-ignored tfvars, and a plan posted on a public pull request would show the IDs
and IPs this repository keeps out of Git. Run it yourself before every pull request and summarise it in the
description:

```bash
for r in bootstrap foundation lab; do terraform -chdir=$r plan; done   # after init -backend-config=../backend.hcl
```

## Network and peering

All address ranges are decided in `foundation` and read by `lab`: VNet `10.42.0.0/16` (AKS nodes `10.42.0.0/22`), services `10.43.0.0/16`, pods `10.245.0.0/16` (Azure CNI overlay). They avoid the AKS defaults so the lab can be peered with an existing cluster's VNet later. Before peering, check that none of these overlap the remote VNet or its cluster's ranges, then add the remote VNet to `peerings` (lab side) and create the matching peering on the remote side.

## Cost

The foundation has no fixed compute: Key Vault, storage and the AI Services account are billed per use. The AKS node in `lab` is the main cost and only runs while the lab exists. Prices are noted in comments with the date they were checked.
