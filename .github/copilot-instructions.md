# Review instructions

`AGENTS.md` at the repository root is the source of truth for this project; read its "Rules" section before reviewing. Comment only on real problems: correctness, security, cost. Skip formatting that `terraform fmt` handles.

## What to check in every pull request

- **Nothing personal is committed.** No subscription, tenant or object IDs, IP addresses, emails, secrets, keys or kubeconfigs in committed files or in variable defaults. Those belong in git-ignored `*.tfvars` and `backend.hcl`.
- **Identity.** Workload identity federation only: flag client secrets, PATs, storage account keys, shared access keys or local accounts. The GitHub App private key exists only as a non-exportable Key Vault key.
- **Least privilege.** Flag role assignments wider than needed (scope or role), `Owner` or `Contributor` given to workload identities, and data-plane access that is not Entra-only.
- **Network exposure.** Public endpoints must be limited by IP rules or authorized ranges; flag `0.0.0.0/0` and disabled firewalls.
- **Cost.** Every new resource needs a price check noted in a comment with the date. Flag Bastion, NAT Gateway, Defender plans, Container Insights, paid AKS tiers and anything always-on in the disposable `lab/` root.
- **State and roots.** Shared values come from `terraform_remote_state` or data sources, never copied IDs. `foundation/` must not depend on `lab/`, so the lab can be destroyed alone. `.terraform.lock.hcl` changes should match provider version changes.
- **Destructive changes.** Call out anything that forces replacement of the state account, Key Vault, model deployment or analysis records storage.
- No long dashes (em or en) in text.
