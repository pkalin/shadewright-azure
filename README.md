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
   az keyvault key import --vault-name "$KV" --name github-app --pem-file ~/Downloads/<app>.private-key.pem \
     --ops sign --protection software --exportable false
   rm ~/Downloads/<app>.private-key.pem
   ```

5. **Check** the whole path (JWT signed in Key Vault, then GitHub's view of the App):

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

## Network and peering

All address ranges are decided in `foundation` and read by `lab`: VNet `10.42.0.0/16` (AKS nodes `10.42.0.0/22`), services `10.43.0.0/16`, pods `10.245.0.0/16` (Azure CNI overlay). They avoid the AKS defaults so the lab can be peered with an existing cluster's VNet later. Before peering, check that none of these overlap the remote VNet or its cluster's ranges, then add the remote VNet to `peerings` (lab side) and create the matching peering on the remote side.

## Cost

The foundation has no fixed compute: Key Vault, storage and the AI Services account are billed per use. The AKS node in `lab` is the main cost and only runs while the lab exists. Prices are noted in comments with the date they were checked.
