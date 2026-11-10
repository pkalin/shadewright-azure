<p align="center"><img src=".github/logo.png" alt="Shadewright" width="120"></p>

<p align="center">
  Part of <a href="https://shadewright.io">Shadewright</a>, a safe-remediation controller for Kubernetes clusters run with GitOps: it turns untrusted proposals, from rules or an LLM, into typed, bounded changes tied to policy and to the object's real source in Git, delivers them only as reviewed pull requests, and verifies the effect.
</p>

# shadewright-azure

Terraform for a reference [Shadewright](https://shadewright.io) lab in Azure: a disposable AKS cluster, a model endpoint in Microsoft Foundry, workload identities, and storage for analysis records. Designed to run in a subscription of its own, with a small monthly budget.

| Root | What | Lifetime |
| --- | --- | --- |
| `bootstrap/` | Storage account for Terraform state | Permanent |
| `foundation/` | VNet, Key Vault (GitHub App key), analyzer and executor identities, AI Services account and model deployments, analysis records storage, budget alert | Permanent, near-zero fixed cost |
| `lab/` | AKS, federated credentials for both identities; the values Flux needs (`make lab-up` then installs Flux pointed at the fleet repository) | Apply for a session, destroy after |

Defaults to Sweden Central. Design and decisions: [shadewright.io](https://shadewright.io).

## Prerequisites

- Terraform (version in `.terraform-version`, `tfenv` picks it up), Azure CLI, logged in with `az login`, plus `jq`,
  `curl` and GNU Make for the lab commands.
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
   - Repository permissions: **Contents** read and write, **Pull requests** read and write, **Issues** read and write, **Checks** read and write (the check run `shadewright/review` for reviewer hints; the executor names this permission in every token request, so an App without it gets no token). **Metadata** read-only is added automatically. Nothing else, no organization or account permissions.
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

   Expect your App's name, the four write permissions (contents, pull requests, issues, checks) plus metadata, no events, and one installation with `selected` repositories.

## Lab session

The `lab` root reads the foundation's outputs from its state and creates the AKS cluster, the federated
credentials of both identities and, with `flux_enabled = true` and `fleet_repository_url` set to your own copy of
the fleet repository, Flux pointed at its `clusters/lab` (off by default: a bare cluster; see "Flux" below). Apply it for a session and destroy it after: the node is the main
cost. Once, fill in the variables:

```bash
cp lab/terraform.tfvars.example lab/terraform.tfvars        # fill in; state_backend matches backend.hcl
```

To run the `make scenario-*` targets in `shadewright-fleet`, set `fleet_branch = "cluster/lab"` in `lab/terraform.tfvars` so Flux tracks that branch and the agent's pull requests target it (ADR-0022 in the operator repository). The default `main` makes the scenario harness refuse to run. Changing this value is a Terraform change: it goes through `make lab-plan` and an explicit `yes` like any other.

With `flux_enabled = true`, also set `github_app_client_id` and `github_app_installation_id` (the GitHub App the agent
opens pull requests with; neither is a secret). The `flux` output passes them to the fleet with the repository URL, the
branch and the App key's Key Vault ID, and the fleet renders the agent's `RemediationSettings` from them, so nothing is
applied by hand after `make lab-up`. The plan refuses `flux_enabled` without them.

Then every session is two commands, run from the repository root (`make help` lists them all):

```bash
make lab-up      # init, plan to lab/lab-up.tfplan, plan summary and price per hour, then asks; apply on "yes"
eval "$(terraform -chdir=lab output -raw get_credentials)"   # kubeconfig for the session
kubelogin convert-kubeconfig -l azurecli                     # replaces an earlier lab's entry of the same name

# ... work ...

make lab-down    # plan the destroy of lab, ask, apply on "yes", then check that nothing is left
make lab-up YES=1    # the same without asking (still asks when the plan deletes or replaces anything)
make lab-down YES=1  # destroy without asking
```

| Command | What it does | Changes Azure |
| --- | --- | --- |
| `make lab-plan` | `terraform plan` of `lab`, nothing saved | No |
| `make lab-up` | Saves a plan, prints it with a count of creates, updates and deletes (and names every delete or replace), prices the lab, asks; applies exactly the saved plan after a typed `yes`, then installs Flux when `flux_enabled` (see "Flux") | After `yes` |
| `make lab-flux` | Only the Flux step of `lab-up`, on a cluster that is up and has `flux_enabled = true`; asks for `yes` | In the cluster only |
| `make lab-down` | Saves a destroy plan of `lab`, prints it, asks; applies it after a typed `yes`, then runs `lab-check` | After `yes` |
| `make lab-cost` | Price per hour, per session and per month from the Azure Retail Prices API (public, no login) | No |
| `make lab-check` | Lists every resource in the subscription by group: lab, foundation, bootstrap, other. Fails while a lab resource group or resource remains, or when anything billed by the hour (VMs, disks, public IPs, load balancers, clusters, NAT gateways, ...) exists outside the lab | No |

The logic is in `scripts/lab.sh`. It reads the subscription and prefix from `lab/terraform.tfvars` and the state
resource group from `backend.hcl`, and prints resource names and types, never IDs. Only `lab` is ever planned
or destroyed: there is no way to point it at `foundation` or `bootstrap`. The confirmation is read from the
terminal, not from standard input, so `yes | make lab-up` cannot apply. `YES=1` on the make command line (or `--yes`
on `scripts/lab.sh up|flux|down`) approves without asking, after printing the plan and the price as usual; `YES` from
the environment is ignored, and `lab-up YES=1` still asks when the plan deletes or replaces anything, so a drifted
state cannot quietly replace the cluster. Use it for a session you just decided to start or end, not in automation.
Answering anything but `yes` (lower case) applies nothing, and the saved plan file is removed on exit either way.

### Flux

Flux is not an AKS extension and not a Terraform resource: the extension took 17 minutes 15 seconds to create after the
cluster (measured 2026-11-04), and a Terraform `kubernetes` provider would have to be configured from a cluster created in the same apply.
With `flux_enabled = true`, `make lab-up` does it after the apply, in about two minutes, from your own kubeconfig
(a private temporary file; yours is not touched). It needs `kubectl`, `kubelogin`, `curl`, `jq` and `az`, and your
account needs the `Azure Kubernetes Service RBAC Cluster Admin` role that `lab` grants it.

1. Downloads the pinned Flux `install.yaml` (`scripts/flux.env`, the release the fleet's Kind cluster uses), refuses it
   unless its SHA-256 matches, and pins the four controller images by digest. The image controllers and
   `source-watcher` are left out with their ServiceAccounts, Services and the `image.toolkit.fluxcd.io` CRDs: the lab
   uses none of them. (The shared `crd-controller` ClusterRoleBinding still lists their ServiceAccounts, harmlessly.)
2. Replicates the multi-tenancy the extension enables by default
   ([Microsoft Learn](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-gitops-flux2#multi-tenancy)):
   `--no-cross-namespace-refs=true` on the kustomize, helm and notification controllers (every Flux object stays in
   `flux-system` and refers to sources there), and `--default-service-account=flux-applier` on the kustomize and helm
   controllers, so objects are applied by impersonating a `flux-applier` ServiceAccount in `flux-system` that is bound
   to `cluster-admin`, as the extension's cluster-scope configuration did.
3. Applies it server-side, waits for the controllers, then creates the `GitRepository` `fleet` (the `lab` output's
   `fleet_branch` of `fleet_repository_url`, every 60 seconds) and the root Kustomization `lab`
   (`./clusters/lab`, every 2 minutes, with the `postBuild` substitutions from the `flux` output of `lab`).

Before the plan is shown, `make lab-up` checks the tools and downloads, verifies and prepares the manifest, so a
missing tool or a bad download fails before anything is billed. After the install it waits (up to five minutes) for the
`GitRepository` and the root Kustomization to be Ready; on a timeout it fails and points at `make lab-flux` and
`kubectl -n flux-system describe`.

Everything is a server-side apply, so it is safe to repeat: `make lab-flux` runs just this step on a cluster that is up
(after a failed download, a slow API server or a timeout), and a second `make lab-up` with nothing to apply runs it
too. Both ask for a typed `yes` first, like every command that changes something; after an apply the `yes` for the
plan covers the Flux step. There is no
`flux bootstrap`: it would commit manifests to the fleet repository, which holds none. The cluster dies with
`make lab-down`, and so does everything Flux made; nothing outside the cluster is created. Upgrading Flux is a
change to `scripts/flux.env`, together with the fleet's `scripts/tools.env`: `scripts/lab_test.sh` compares the two
(version, checksum, the four digests) whenever it finds the fleet's file, and CI fetches it from the fleet's `main`, so
bump the fleet first. A lab applied with the AKS extension (before this change) must be destroyed first
(`make lab-down`); applying this version on top would destroy the extension and its configuration in the plan.

When `lab-check` fails after `lab-down`, it names what is left. Run `make lab-down` again (a destroy interrupted
half way leaves state behind); for a resource outside the state, delete it in the portal or with `az` after
checking it is yours.

## Troubleshooting

### AllocationFailed on the node pool

Azure can have no capacity for the node size in the region. On 2026-11-04 `make lab-up` failed after about four
minutes with `AllocationFailed` for `Standard_B2as_v2` in Sweden Central. The cluster is then left in Azure in
`Failed` state but is not in the Terraform state (the resource group, the AKS identity and the subnet role
assignment are). A new plan wants to create the cluster again and fails because it exists, and `make lab-down`
cannot remove it, because it destroys only what the state holds. `make lab-up` says so when an apply fails.

See the error on the node scale set, in the node resource group (`rg-<prefix>-lab-aks-nodes`):

```bash
az vmss list --subscription <subscription-id> -g rg-<prefix>-lab-aks-nodes --query '[].name' -o tsv
az vmss get-instance-view --subscription <subscription-id> -g rg-<prefix>-lab-aks-nodes -n <scale-set-name> \
  --query 'statuses' -o json
```

Recover:

1. `make lab-check` lists what is left. Delete the failed cluster:
   `az aks delete --subscription <subscription-id> -g rg-<prefix>-lab-aks -n <cluster-name> --yes`.
2. Set another size in the git-ignored `lab/terraform.tfvars`, for example `node_vm_size = "Standard_B2s_v2"`.
3. `make lab-plan`, read it, then `make lab-up`. Run `make lab-check` after the session as always.

Fallback sizes, Azure Retail Prices API, EUR per hour, Linux pay as you go, `swedencentral`, checked 2026-11-04
(`make lab-cost` prices the size in your tfvars):

| Size | EUR per hour |
| --- | ---: |
| `Standard_B2s_v2` | 0.0776 |
| `Standard_D2as_v5` | 0.0826 |
| `Standard_D4as_v5` | 0.1652 |

The default `Standard_B2as_v2` costs 0.0698 (checked 2026-11-03), see "Cost".

### Working from a new network

`admin_ip_cidrs` is the only way through the firewalls of the state storage (bootstrap), Key Vault, Foundry and
the analysis store (foundation), and of the AKS API server (lab). From a new address every Terraform command fails
with 403 on the state storage, including the bootstrap plan that would add the address, because bootstrap's own
state lives behind that firewall. So the first step is outside Terraform. Use your current address
(`curl -s https://api.ipify.org`), here `<new-ip>`; the storage rule takes no `/32`.

1. Let the address through the state storage firewall. The names are in `backend.hcl`:
   `az storage account network-rule add --subscription <subscription-id> -g <state-resource-group> --account-name <state-storage-account> --ip-address <new-ip>`
2. Add `"<new-ip>/32"` to `admin_ip_cidrs` in `bootstrap/terraform.tfvars`, `foundation/terraform.tfvars` and
   `lab/terraform.tfvars`.
3. `terraform -chdir=bootstrap plan`: no changes expected on the storage account except that Terraform now
   finds the rule it would add already there. Read it. Apply only if it shows a change you understand.
4. `terraform -chdir=foundation plan`, read it (expect in-place updates of the network ACLs, for example Key
   Vault, Foundry and the analysis store), then `terraform -chdir=foundation apply` after your own yes.
5. `make lab-plan`, then `make lab-up` (the API server's `authorized_ip_ranges` follows `admin_ip_cidrs`).

To remove a temporary address later: delete it from `admin_ip_cidrs` in all three tfvars, then plan and apply
foundation, then bootstrap. The rule added with the CLI is not in the state, and the bootstrap apply replaces the
storage account's rule list with the one in the tfvars, so it disappears there. Run the bootstrap plan from an
address that is still listed. Check with
`az storage account show --subscription <subscription-id> -g <state-resource-group> -n <state-storage-account> --query networkRuleSet.ipRules`.

## Checks

Every pull request runs these workflows. The `main` ruleset requires `Conventional PR title`, `terraform fmt`
and `terraform validate` for each of the three roots. CodeQL (`Analyze (actions)`) also runs on every pull request.

- `PR title`: the title follows Conventional Commits (see `AGENTS.md`, "Commits").
- `Terraform`: `terraform fmt -check -recursive`, then `terraform init -backend=false -lockfile=readonly` and
  `terraform validate` for `bootstrap`, `foundation` and `lab`, with the version from `.terraform-version`.
  It needs no cloud credentials and never reads the state.

`make check` runs the same `fmt` and `validate` locally. Shell scripts in `scripts/` use `set -euo pipefail`; run
`shellcheck scripts/*.sh` when you change them.

CI runs on Linux, so every `.terraform.lock.hcl` must hold hashes for `linux_amd64` as well as your platform.
The three roots pin the same provider versions (`lab` has no `random`). After `init -upgrade` or a provider
change, refresh all three, so they stay on the same versions:

```bash
for r in bootstrap foundation lab; do
  terraform -chdir=$r providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
done
```

`init` and `validate` start the provider binaries the lock files name, so a pull request from a fork runs code it
chose on a GitHub runner (read-only token, no secrets). Keep "Require approval for all external contributors" on
for Actions in the repository settings.

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

The foundation has no fixed compute: Key Vault, storage, Log Analytics and the AI Services account are billed per
use. The lab is billed by the hour while it exists and costs nothing once `make lab-down` has passed its check.

Lab with the defaults (one `Standard_B2as_v2` node, Sweden Central), Azure Retail Prices API, EUR, pay as you go,
checked 2026-11-03:

| Resource | Meter | EUR per hour | EUR per month (730 h) |
| --- | --- | ---: | ---: |
| AKS node, `Standard_B2as_v2` Linux | Virtual Machines Basv2 Series, B2as v2 | 0.0698 | 50.95 |
| OS disk, 32 GB managed | Premium SSD Managed Disks, P4 LRS Disk (5.2132 per month) | 0.0071 | 5.21 |
| Standard Load Balancer, outbound rule | Load Balancer, Standard Included LB Rules and Outbound Rules (Global) | 0.0224 | 16.35 |
| Public IPv4 for outbound | Virtual Network, Standard IPv4 Static Public IP | 0.0045 | 3.28 |
| AKS cluster management, Free tier | none ([pricing tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)) | 0 | 0 |
| Flux (four controllers in the cluster, installed by `make lab-up`) | none: runs on the node above | 0 | 0 |
| **Total** | | **about 0.10** | **about 76** |

An 8-hour session costs about 0.83 EUR; a lab forgotten for a month costs about 76 EUR. Usage-based extras
(load balancer data processed 0.0045 per GB, internet egress, model tokens) come on top. `make lab-cost` repeats
the lookup for the current prices and your `node_vm_size`, `node_count` and `location`; `OS_DISK_TIER=E4` prices
a Standard SSD OS disk (2.15 per month), `CURRENCY=USD` and `SESSION_HOURS=4` change the other columns. Prices
are also noted in comments next to the resources, with the date they were checked.
