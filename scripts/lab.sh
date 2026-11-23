#!/usr/bin/env bash
# Brings the disposable lab (the `lab` root, ADR-0008) up and down, prices it, and checks that nothing is left.
#
#   scripts/lab.sh plan    plan the lab; changes nothing
#   scripts/lab.sh up      plan to a file, show it and the cost per hour, ask for "yes", apply that saved plan, then
#                          install Flux and point it at the fleet when flux_enabled is true (when nothing is to
#                          apply, the Flux step alone, after its own "yes")
#   scripts/lab.sh flux    only that Flux step, for a cluster that is up, after a "yes" (idempotent: run it again
#                          after a failure)
#   scripts/lab.sh provider  switch the model provider of a running lab to LAB_MODEL_PROVIDER (README, "Model provider"),
#                          after a "yes": no Terraform apply, only the cluster
#   scripts/lab.sh down    plan the destroy of `lab` (never foundation or bootstrap), ask for "yes", apply it,
#                          then run `check`
#   scripts/lab.sh cost    the lab's price per hour from the Azure Retail Prices API (public, no login)
#   scripts/lab.sh check   list what is left in the subscription; fails when anything of the lab remains
#
# Reads the subscription and prefix from the git-ignored lab/terraform.tfvars and the state resource group from
# ../backend.hcl. Prints names and types only, never subscription IDs or resource IDs. Up, flux and down need a
# terminal and a typed "yes", unless the command line says `--yes` (`make lab-up YES=1`): then the plan and the
# price are still printed and the apply goes ahead without asking, except that `up --yes` still asks for a plan
# that deletes or replaces anything. Setting LAB_ANTHROPIC_KEY_FILE or LAB_OPENAI_KEY_FILE to a file that holds a
# model API key makes the Flux step create the Secret shadewright-anthropic or shadewright-openai in shadewright-system
# from it (README, "Model API key"). LAB_MODEL_KEYS_FROM_VAULT=true does the same with the keys kept in the
# foundation's Key Vault (README, "Model API keys"); setting it together with a file variable is an error.
# LAB_MODEL_PROVIDER (foundry by default, anthropic or openai; anything else is an error before anything is billed) is the
# model provider the fleet's agent runs against: up and flux write it to the cluster, provider switches a running lab. Standard input never approves (`yes | make lab-up` does not work).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lab_dir="$repo/lab"
lab_tfvars="$lab_dir/terraform.tfvars"
backend="$repo/backend.hcl"
currency=${CURRENCY:-EUR}
# 32 GB managed OS disk (lab/aks.tf). AKS puts it on Premium SSD (P4) for sizes with premium storage, like the
# default B2as_v2; set OS_DISK_TIER=E4 to price a Standard SSD instead.
os_disk_tier=${OS_DISK_TIER:-P4}
session_hours=${SESSION_HOURS:-8}
prices_api="https://prices.azure.com/api/retail/prices"
# 1 when the command line said --yes (parse_args); confirm then approves without asking.
auto_yes=0
# shellcheck source=scripts/flux.env
. "$repo/scripts/flux.env"

die() { printf 'lab: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

usage() { sed -n '2,26s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed"; done; }

# Value of a top-level `key = "string"` or `key = number` in a tfvars file (not one nested in a block); empty
# when absent or commented out.
tfvar() {
  [[ -f $1 ]] || return 0
  sed -n -E "s/^$2[[:space:]]*=[[:space:]]*\"?([^\"#[:space:]]*)\"?.*/\1/p" "$1" | head -n 1
}

# Default of a variable in a root's variables.tf, so the defaults have one source.
tfdefault() {
  awk -v v="variable \"$2\"" '
    index($0, v) == 1 { inside = 1; next }
    inside && /^}/ { exit }
    inside && $1 == "default" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/"/, ""); print; exit }
  ' "$repo/$1/variables.tf"
}

setting() { # root key: tfvars value, else the variable's default
  local v
  v=$(tfvar "$repo/$1/terraform.tfvars" "$2")
  [[ -n $v ]] || v=$(tfdefault "$1" "$2")
  printf '%s' "$v"
}

lab_config() {
  [[ -f $lab_tfvars ]] || die "missing lab/terraform.tfvars: copy lab/terraform.tfvars.example and fill it in"
  [[ -f $backend ]] || die "missing backend.hcl: see README, First run"
  subscription=$(tfvar "$lab_tfvars" subscription_id)
  prefix=$(tfvar "$lab_tfvars" prefix)
  state_rg=$(tfvar "$backend" resource_group_name)
  [[ $subscription =~ ^[0-9a-fA-F-]{36}$ ]] || die "subscription_id in lab/terraform.tfvars is not a GUID"
  # The same rule as foundation/variables.tf, so the group names below are the ones Terraform built.
  [[ $prefix =~ ^[a-z0-9]{1,11}$ ]] || die "prefix in lab/terraform.tfvars must be 1 to 11 lower-case letters or digits"
  [[ -n $state_rg ]] || die "resource_group_name missing in backend.hcl"
  # Names as lab/main.tf, lab/aks.tf and foundation/main.tf build them.
  lab_rg="rg-$prefix-lab-aks"
  node_rg="rg-$prefix-lab-aks-nodes"
  foundation_rg="rg-$prefix-lab"
}

tf() { terraform -chdir="$lab_dir" "$@"; }

tf_init() {
  info "terraform init (lab)"
  tf init -input=false -backend-config=../backend.hcl >/dev/null
}

# Asks on the terminal, never on stdin, so piped input or `yes |` cannot approve an apply. With --yes on the
# command line it approves without asking and says so.
confirm() {
  local answer
  if [[ $auto_yes == 1 ]]; then
    printf '\n%s Approved by --yes.\n' "$1" >&2
    return 0
  fi
  { exec 3</dev/tty; } 2>/dev/null || die "no terminal to ask for confirmation: run this interactively"
  printf '\n%s Type yes to continue: ' "$1" >/dev/tty
  IFS= read -r answer <&3 || answer=
  exec 3<&-
  [[ $answer == yes ]] || die "not confirmed (got '${answer}'), nothing applied"
}

# Counts of the planned actions; warns about deletes and replacements by address.
plan_summary() {
  local json
  json=$(tf show -json "$1")
  jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | "Plan: \($c | map(select(.change.actions == ["create"])) | length) to create, "
      + "\($c | map(select(.change.actions == ["update"])) | length) to update, "
      + "\($c | map(select(.change.actions | index("delete"))) | length) to delete or replace."
    , ($c[] | select(.change.actions | index("delete")) | "  delete: \(.address) \(.change.actions | join("/"))")
  ' <<<"$json"
}

# Number of resources a saved plan deletes or replaces.
plan_deletes() {
  tf show -json "$1" | jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length'
}

# The command and its options: `<command> [--yes]`. Sets $command and auto_yes; --yes only for up, flux, provider and down.
parse_args() {
  command=${1:-help}
  [[ $# -gt 0 ]] && shift
  auto_yes=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --yes) auto_yes=1 ;;
      *) return 2 ;;
    esac
    shift
  done
  case $command in
    up | flux | down | provider) ;;
    *) [[ $auto_yes == 0 ]] || return 2 ;;
  esac
}

# One price from the Retail Prices API: filter, then a jq selector over .Items. Follows NextPageLink.
price() {
  local url="$prices_api" page out
  local -a args=(-G --data-urlencode "currencyCode=$currency" --data-urlencode "\$filter=$1")
  while [[ -n $url ]]; do
    # --retry covers 429: the API rate-limits bursts of anonymous calls.
    # ${args[@]+...}: bash 3.2 (macOS) treats an empty array as unset under set -u.
    page=$(curl -fsS --max-time 20 --retry 4 --retry-delay 3 ${args[@]+"${args[@]}"} "$url") ||
      { printf 'lab: Retail Prices API request failed\n' >&2; return 1; }
    out=$(jq -r "[.Items[] | $2 | .retailPrice] | first // empty" <<<"$page")
    [[ -n $out ]] && { printf '%s' "$out"; return 0; }
    url=$(jq -r '.NextPageLink // empty' <<<"$page")
    args=()
  done
  return 1
}

cmd_cost() {
  need curl jq awk
  local location vm count disk_product vm_h disk_m ip_h lb_h
  location=$(setting foundation location)
  vm=$(setting lab node_vm_size)
  count=$(setting lab node_count)
  [[ $count =~ ^[0-9]+$ ]] || die "node_count is not a number"
  case $os_disk_tier in
    P*) disk_product="Premium SSD Managed Disks" ;;
    E*) disk_product="Standard SSD Managed Disks" ;;
    *) die "OS_DISK_TIER must be a Premium (P..) or Standard SSD (E..) tier" ;;
  esac

  info "Lab price, $currency, $location, Azure Retail Prices API, $(date -u +%F)"
  vm_h=$(price "serviceName eq 'Virtual Machines' and armRegionName eq '$location' and armSkuName eq '$vm' and priceType eq 'Consumption'" \
    'select((.productName | test("Windows|Cloud Services")) or (.meterName | test("Spot|Low Priority")) | not)') ||
    die "no Linux pay-as-you-go price for $vm in $location"
  disk_m=$(price "serviceName eq 'Storage' and armRegionName eq '$location' and productName eq '$disk_product' and meterName eq '$os_disk_tier LRS Disk'" 'select(.type == "Consumption")') ||
    die "no price for a $os_disk_tier LRS disk in $location"
  ip_h=$(price "serviceName eq 'Virtual Network' and armRegionName eq '$location' and meterName eq 'Standard IPv4 Static Public IP'" 'select(.type == "Consumption")') ||
    die "no price for a Standard public IPv4 in $location"
  # Standard Load Balancer rules are billed on a Global meter; AKS creates one outbound rule (first five included).
  lb_h=$(price "serviceName eq 'Load Balancer' and armRegionName eq 'Global' and meterName eq 'Standard Included LB Rules and Outbound Rules'" 'select(.type == "Consumption")') ||
    die "no price for Standard Load Balancer rules"

  awk -v n="$count" -v vm="$vm" -v vm_h="$vm_h" -v tier="$os_disk_tier" -v disk_m="$disk_m" -v ip_h="$ip_h" \
    -v lb_h="$lb_h" -v s="$session_hours" -v cur="$currency" '
    function row(name, h) { printf "%-42s %9.4f %9.2f %9.2f\n", name, h, h * s, h * 730; total += h }
    BEGIN {
      printf "%-42s %9s %9s %9s\n", "Resource", "per hour", s " hours", "730 h"
      row(n " x " vm " node (Linux)", n * vm_h)
      row(n " x " tier " managed OS disk (" disk_m " per month)", n * disk_m / 730)
      row("Standard public IPv4 (outbound)", ip_h)
      row("Standard Load Balancer, first 5 rules", lb_h)
      row("AKS Free tier, Flux (in-cluster, no add-on)", 0)
      printf "%-42s %9.4f %9.2f %9.2f  %s\n", "Total", total, total * s, total * 730, cur
    }'
  cat <<'EOF'
Not included, usage-based: load balancer data processed, internet egress, model tokens and Log Analytics
ingestion in foundation. Foundation's fixed cost is near zero and stays when the lab is down.
EOF
}

cmd_check() {
  need az jq
  lab_config
  info "Resources left in the lab subscription"
  local groups resources
  groups=$(az group list --subscription "$subscription" --query '[].name' -o json)
  resources=$(az resource list --subscription "$subscription" --query '[].{rg:resourceGroup,type:type,name:name}' -o json)

  jq -r -n --argjson groups "$groups" --argjson res "$resources" \
    --arg lab "$lab_rg" --arg nodes "$node_rg" --arg foundation "$foundation_rg" --arg state "$state_rg" '
    # Types billed by the hour whatever group they are in: none belongs outside a running lab.
    def hourly: test("^Microsoft\\.(Compute/(virtualMachines|virtualMachineScaleSets|disks|snapshots)|ContainerService/managedClusters|Network/(publicIPAddresses|loadBalancers|natGateways|bastionHosts|applicationGateways|azureFirewalls|virtualNetworkGateways|privateEndpoints|vpnGateways|expressRouteGateways|virtualHubs|ddosProtectionPlans|dnsResolvers)|ContainerRegistry/registries)$"; "i");
    def kind($g): ($g | ascii_downcase) as $l
      | if $l == ($lab | ascii_downcase) or $l == ($nodes | ascii_downcase) or ($l | startswith("mc_" + ($lab | ascii_downcase))) then "lab"
        elif $l == ($foundation | ascii_downcase) then "foundation"
        elif $l == ($state | ascii_downcase) then "bootstrap"
        else "other" end;
    def line: "  \(.rg) | \(.type) | \(.name)";
    ($res | map(. + {kind: kind(.rg)})) as $r
    | ($groups | map(select(kind(.) == "lab"))) as $lab_groups
    | ($r | map(select(.kind == "lab"))) as $lab_res
    | ($r | map(select(.kind != "lab" and (.type | hourly)))) as $hourly
    | "Lab (must be empty): \($lab_res | length) resources, \($lab_groups | length) resource groups",
      ($lab_groups[] | "  resource group \(.)"), ($lab_res[] | line),
      "Foundation (expected, stays): \($r | map(select(.kind == "foundation")) | length) resources",
      ($r[] | select(.kind == "foundation") | line),
      "Bootstrap (expected, stays): \($r | map(select(.kind == "bootstrap")) | length) resources",
      ($r[] | select(.kind == "bootstrap") | line),
      "Not managed by this repository: \($r | map(select(.kind == "other")) | length) resources",
      ($r[] | select(.kind == "other") | line),
      (if ($hourly | length) > 0 then "Billed by the hour outside the lab (unexpected):", ($hourly[] | line) else empty end),
      "RESULT \(if ($lab_res | length) + ($lab_groups | length) + ($hourly | length) == 0 then "ok" else "fail" end)"
  ' >"$tmp/check.txt"

  grep -v '^RESULT ' "$tmp/check.txt"
  if grep -qx 'RESULT ok' "$tmp/check.txt"; then
    printf '\nOK: nothing of the lab is left and nothing is billed by the hour.\n'
  else
    printf '\nFAIL: the resources above still cost money. Run make lab-down again or delete them by hand.\n' >&2
    return 1
  fi
}

cmd_plan() {
  need terraform
  lab_config
  tf_init
  info "terraform plan (lab): read-only, nothing is saved or applied"
  tf plan -input=false
}

# --- Flux, installed after the apply (ADR-0022, amended 2026-11-04) -----------------------------------------------
# Not a Terraform resource: the AKS extension took 17 minutes (2026-11-04), and a Terraform kubernetes provider would be
# configured from the cluster created in the same apply. Everything here is idempotent (server-side apply), so a
# failed step is repaired by running it again.

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# flux_prepare <install.yaml> <out>: the release manifest with (1) every controller image pinned by digest
# (FLUX_IMAGES), (2) the multi-tenancy the AKS extension enables by default (Microsoft Learn, "GitOps with Flux v2",
# Multi-tenancy): --no-cross-namespace-refs on the kustomize, helm and notification controllers, and
# --default-service-account=flux-applier on the kustomize and helm controllers, so Flux objects are applied by
# impersonating the flux-applier ServiceAccount, which gets a cluster-admin binding as the extension's cluster-scope
# configuration did, and (3) everything of the image-reflector, image-automation and source-watcher controllers left
# out (Deployment, ServiceAccount, Service, and the image.toolkit.fluxcd.io CRDs): the lab uses none of them. The
# shared ClusterRoleBinding still names their ServiceAccounts as subjects, which is harmless without the accounts.
flux_prepare() {
  awk -v pins="$FLUX_IMAGES" '
    BEGIN {
      n = split(pins, p, " ")
      for (i = 1; i <= n; i++) { split(p[i], kv, "="); want[kv[1]] = kv[2] }
      split("image-automation-controller image-reflector-controller source-watcher", d, " ")
      for (i in d) drop[d[i]] = 1
      split("helm-controller kustomize-controller notification-controller", x, " ")
      for (i in x) noxns[x[i]] = 1
      defsa["helm-controller"] = 1; defsa["kustomize-controller"] = 1
    }
    function flush() {
      if (doc == "") return
      # The Deployment, ServiceAccount and Service of a dropped controller, and the image CRDs, are left out.
      if (!((name in drop) || (kind == "CustomResourceDefinition" && name ~ /\.image\.toolkit\.fluxcd\.io$/))) printf "---\n%s", doc
      doc = ""; isdep = 0; name = ""; kind = ""
    }
    /^---$/ { flush(); next }
    {
      if ($0 ~ /^kind: /) kind = $2
      if ($0 == "kind: Deployment") isdep = 1
      if (name == "" && $0 ~ /^  name: /) name = $2
      line = $0
      if (isdep && $0 ~ /^        image: ghcr.io\/fluxcd\//) {
        img = $2; sub(/^ghcr.io\/fluxcd\//, "", img)
        split(img, t, ":")
        if (!(name in drop)) {
          if (!(t[1] in want)) { print "unpinned image " img > "/dev/stderr"; bad = 1 }
          else if (substr(want[t[1]], 1, index(want[t[1]], "@") - 1) != t[2]) { print "image " img " is not the pinned tag" > "/dev/stderr"; bad = 1 }
          else line = "        image: ghcr.io/fluxcd/" t[1] ":" want[t[1]]
        }
      }
      doc = doc line "\n"
      if (isdep && ($0 == "        - --watch-all-namespaces") && (name in noxns)) doc = doc "        - --no-cross-namespace-refs=true\n"
      if (isdep && ($0 == "        - --watch-all-namespaces") && (name in defsa)) doc = doc "        - --default-service-account=flux-applier\n"
    }
    END {
      flush()
      printf "---\napiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: flux-applier\n  namespace: flux-system\n"
      printf "---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata:\n  name: flux-applier\n"
      printf "roleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: cluster-admin\n"
      printf "subjects:\n- kind: ServiceAccount\n  name: flux-applier\n  namespace: flux-system\n"
      exit bad
    }
  ' "$1" >"$2" || return 1
  # The result is checked, not trusted: four controllers, all pinned, three with the multi-tenancy flag.
  [[ $(grep -c '^kind: Deployment$' "$2") == 4 ]] || { printf 'lab: the Flux manifest does not hold four Deployments\n' >&2; return 1; }
  [[ $(grep -c -- '--no-cross-namespace-refs=true$' "$2") == 3 ]] || { printf 'lab: multi-tenancy flag missing\n' >&2; return 1; }
  [[ $(grep -c -- '--default-service-account=flux-applier$' "$2") == 2 ]] || { printf 'lab: default service account flag missing\n' >&2; return 1; }
  if grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]]' "$2" | grep -vqE '@sha256:[0-9a-f]{64}$'; then
    printf 'lab: an image in the Flux manifest is not pinned by digest\n' >&2
    return 1
  fi
}

# flux_fetch <out>: the pinned release's install.yaml, prepared; refuses a file that does not match its checksum.
flux_fetch() {
  local raw="$tmp/flux-install.yaml" got
  # Each attempt is bounded; retries ride out short outages of the release CDN (503 and 504 on 2026-11-08).
  curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 --retry 4 --retry-delay 10 -o "$raw" \
    "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml" ||
    die "cannot download the Flux $FLUX_VERSION manifest"
  got=$(sha256_of "$raw")
  [[ $got == "$FLUX_INSTALL_SHA256" ]] ||
    die "checksum mismatch for the Flux $FLUX_VERSION install.yaml: expected $FLUX_INSTALL_SHA256, got $got"
  flux_prepare "$raw" "$1" || die "cannot prepare the Flux manifest"
}

# flux_objects <the flux output as JSON>: the GitRepository "fleet" (60 s) and the root Kustomization "lab" that
# applies ./clusters/lab with the substitutions from Terraform and, optionally, the ConfigMap lab-model-provider (the
# model provider, see below), as a JSON List for kubectl. Values travel as jq data,
# never through shell or YAML quoting.
flux_objects() {
  jq -e '
    {apiVersion: "v1", kind: "List", items: [
      {apiVersion: "source.toolkit.fluxcd.io/v1", kind: "GitRepository",
       metadata: {name: "fleet", namespace: "flux-system"},
       spec: {interval: "1m", timeout: "60s", url: .repository_url, ref: {branch: .branch}}},
      {apiVersion: "kustomize.toolkit.fluxcd.io/v1", kind: "Kustomization",
       metadata: {name: "lab", namespace: "flux-system"},
       spec: {interval: "2m", retryInterval: "1m", timeout: "5m", sourceRef: {kind: "GitRepository", name: "fleet"},
              path: "./clusters/lab", prune: true, wait: false,
              postBuild: {substitute: .substitute,
                          substituteFrom: [{kind: "ConfigMap", name: "lab-model-provider", optional: true}]}}}]}
  ' <<<"$1"
}

# flux_validate <flux output JSON>: refuse anything that is not a plain HTTPS URL and a plain branch name.
flux_validate() {
  local url branch
  url=$(jq -r '.repository_url // empty' <<<"$1")
  branch=$(jq -r '.branch // empty' <<<"$1")
  [[ $url =~ ^https://[A-Za-z0-9._/-]+$ ]] || die "fleet_repository_url must be a plain https:// URL"
  [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "fleet_branch has characters a branch name does not need"
  jq -e '.substitute | type == "object" and all(.[]; type == "string")' <<<"$1" >/dev/null ||
    die "the flux output has no string substitutions"
}

kc() { kubectl --kubeconfig "$tmp/kubeconfig" "$@"; }

# flux_preflight: what can fail without a cluster, checked before anything is billed: the tools, and the pinned
# manifest (download, checksum, prepare) into $tmp/flux.yaml. Only when flux_enabled is true in tfvars or by default;
# before the first apply the flux output does not exist yet, so the setting is read the way cost does.
flux_preflight() {
  [[ $(setting lab flux_enabled) == true ]] || return 0
  need kubectl kubelogin curl jq az awk
  info "Flux $FLUX_VERSION: download, verify, pin"
  flux_fetch "$tmp/flux.yaml"
}

# The optional model API keys (ADR-0037 decision 7 for Anthropic, ADR-0042 for OpenAI). LAB_ANTHROPIC_KEY_FILE and
# LAB_OPENAI_KEY_FILE each name a file that holds one key; unset means nothing happens and nothing is printed. A key is
# never read into a shell variable, never goes through Terraform and is never printed: kubectl reads the file itself.
# A bad file stops `up` and `flux` before anything is billed; the messages name the variable, never the path or the
# content. Both keys share the code below.
# model_key_check <file variable>
model_key_check() {
  local var=$1
  [[ -n ${!var:-} ]] || return 0
  [[ -f ${!var} && -r ${!var} && -s ${!var} ]] ||
    die "$var is set but is not a readable, non-empty file"
  [[ $(setting lab flux_enabled) == true ]] ||
    die "$var is set but flux_enabled is false: the lab has no fleet to use the key"
}
anthropic_key_check() { model_key_check LAB_ANTHROPIC_KEY_FILE; }
openai_key_check() { model_key_check LAB_OPENAI_KEY_FILE; }

foundation_tf() { terraform -chdir="$repo/foundation" "$@"; }

# The optional LAB_MODEL_KEYS_FROM_VAULT=true (README, "Model API keys"): each key is downloaded from the foundation's
# Key Vault into a private file under $tmp (umask 077, removed by the exit trap) and its file variable is pointed at
# it, so the path below is the same as for a file the operator made. The value is never read into a shell variable,
# never on a command line, never printed. Runs before anything is billed: a refused read stops `up` and `flux`. A
# secret that is absent from the vault (Azure answers SecretNotFound) is skipped with one line naming it; when neither
# is there, that is an error. The messages name the variable and the secret name, never the vault, the path or the
# content.
# vault_key_download <file variable> <secret name> <vault> <dir>: returns 0 when downloaded, 1 when the secret is absent.
vault_key_download() {
  local var=$1 secret=$2 vault=$3 dir=$4 err
  err="$dir/$secret.err"
  # --file must not exist yet. The value goes from Azure to the file; stdout is dropped and stderr goes to a private
  # file that is only searched, never printed, so a failure cannot leak anything.
  if az keyvault secret download --vault-name "$vault" --name "$secret" --file "$dir/$secret" \
    --encoding utf-8 --subscription "$subscription" >/dev/null 2>"$err"; then
    printf -v "$var" '%s' "$dir/$secret"
    export "${var?}"
    return 0
  fi
  # Only a definite "absent" skips; any other failure (no login, firewall, no role) is an error to retry.
  ! grep -q SecretNotFound "$err" ||
    return 1
  die "LAB_MODEL_KEYS_FROM_VAULT: cannot read the secret $secret from the foundation's Key Vault: set it once (README, Model API keys), check az login and that your IP is in admin_ip_cidrs, then retry"
}

model_keys_from_vault() {
  case ${LAB_MODEL_KEYS_FROM_VAULT:-} in
    "" | false) return 0 ;;
    true) ;;
    *) die "LAB_MODEL_KEYS_FROM_VAULT must be true or unset" ;;
  esac
  [[ -z ${LAB_ANTHROPIC_KEY_FILE:-} ]] ||
    die "LAB_MODEL_KEYS_FROM_VAULT and LAB_ANTHROPIC_KEY_FILE are both set: use one"
  [[ -z ${LAB_OPENAI_KEY_FILE:-} ]] ||
    die "LAB_MODEL_KEYS_FROM_VAULT and LAB_OPENAI_KEY_FILE are both set: use one"
  [[ $(setting lab flux_enabled) == true ]] ||
    die "LAB_MODEL_KEYS_FROM_VAULT is set but flux_enabled is false: the lab has no fleet to use the key"
  need az jq terraform
  local out vault dir found=0 provider var secret
  foundation_tf init -input=false -backend-config=../backend.hcl >/dev/null ||
    die "LAB_MODEL_KEYS_FROM_VAULT: cannot initialise the foundation root to find the vault: retry"
  out=$(foundation_tf output -json key_vault) ||
    die "LAB_MODEL_KEYS_FROM_VAULT: cannot read the foundation's key_vault output: is the foundation applied? retry"
  vault=$(jq -r '.name // empty' <<<"$out")
  [[ -n $vault ]] ||
    die "LAB_MODEL_KEYS_FROM_VAULT: the foundation's key_vault output has no vault name: apply the foundation first"
  dir=$(umask 077; mktemp -d "$tmp/vault-key.XXXXXX") || die "cannot create a private directory for the key"
  for provider in anthropic openai; do
    case $provider in
      anthropic) var=LAB_ANTHROPIC_KEY_FILE ;;
      openai) var=LAB_OPENAI_KEY_FILE ;;
    esac
    secret=$(jq -r --arg p "$provider" '.model_key_secrets[$p] // empty' <<<"$out")
    [[ -n $secret ]] ||
      die "LAB_MODEL_KEYS_FROM_VAULT: the foundation's key_vault output has no name for the $provider key secret: apply the foundation first"
    if vault_key_download "$var" "$secret" "$vault" "$dir"; then
      found=1
    else
      info "LAB_MODEL_KEYS_FROM_VAULT: the secret $secret is not in the Key Vault: skipped"
    fi
  done
  ((found == 1)) || die "LAB_MODEL_KEYS_FROM_VAULT: neither model key secret is in the Key Vault: set one (README, Model API keys)"
}

# model_key_secret <file variable> <Secret name>: creates or updates the Secret (key api-key) in shadewright-system.
# The namespace is created here, plainly, before Flux applies the fleet: the fleet's own Namespace object (Pod Security
# labels, prune disabled) is then applied over it by Flux, and the Secret is there when the agent starts. Called as
# `anthropic_key_secret || ...`: every step ends in `|| return 1`.
model_key_secret() {
  local var=$1 name=$2
  [[ -n ${!var:-} ]] || return 0
  model_key_check "$var" || return 1
  info "Model API key: Secret $name in shadewright-system"
  kc create namespace shadewright-system --dry-run=client -o yaml |
    kc apply --server-side --field-manager=shadewright-lab -f - >/dev/null ||
    { flux_fail "creating the namespace shadewright-system failed"; return 1; }
  kc -n shadewright-system create secret generic "$name" \
    --from-file=api-key="${!var}" --dry-run=client -o yaml |
    kc apply --server-side --field-manager=shadewright-lab -f - >/dev/null ||
    { flux_fail "creating the Secret $name failed"; return 1; }
}
anthropic_key_secret() { model_key_secret LAB_ANTHROPIC_KEY_FILE shadewright-anthropic; }
openai_key_secret() { model_key_secret LAB_OPENAI_KEY_FILE shadewright-openai; }

# flux_fail <message>: the one way out of flux_install on an error.
flux_fail() { printf 'lab: %s\n' "$1" >&2; return 1; }

# cluster_credentials: a private kubeconfig for the lab cluster (kc uses it) and a wait until the API server accepts it.
# Called as `cluster_credentials || return 1`.
cluster_credentials() {
  local rg cluster i=0
  info "Kubeconfig (a private file, removed on exit; your own kubeconfig is not touched)"
  rg=$(tf output -raw resource_group_name) || { flux_fail "cannot read resource_group_name"; return 1; }
  cluster=$(tf output -raw cluster_name) || { flux_fail "cannot read cluster_name"; return 1; }
  az aks get-credentials --subscription "$subscription" -g "$rg" -n "$cluster" --file "$tmp/kubeconfig" \
    --overwrite-existing >/dev/null || { flux_fail "az aks get-credentials failed"; return 1; }
  kubelogin convert-kubeconfig -l azurecli --kubeconfig "$tmp/kubeconfig" || { flux_fail "kubelogin failed"; return 1; }
  # A new cluster, and a role assignment that has just been made, can take a minute to answer.
  until [[ $(kc auth can-i create clusterroles 2>/dev/null) == yes ]]; do
    i=$((i + 1))
    ((i <= 36)) || { flux_fail "the API server did not accept your credentials within 3 minutes"; return 1; }
    sleep "${FLUX_POLL:-5}"
  done
}

# --- The model provider (README, "Model provider") ---------------------------------------------------------------------
# The fleet holds one variant per provider (foundry, anthropic, openai) and the Flux Kustomizations shadewright and
# shadewright-config end their path in ${MODEL_PROVIDER:=foundry}, which the root Kustomization lab substitutes from the
# optional ConfigMap lab-model-provider in flux-system. This script writes that ConfigMap; nothing is committed to the
# fleet to switch. LAB_MODEL_PROVIDER names the provider, foundry when unset.

# provider_check: sets $provider from LAB_MODEL_PROVIDER, or dies before anything is billed. The value is not echoed.
provider_check() {
  provider=${LAB_MODEL_PROVIDER:-foundry}
  case $provider in
    foundry | anthropic | openai) ;;
    *) die "LAB_MODEL_PROVIDER must be foundry, anthropic or openai" ;;
  esac
}

# provider_secret_name: the name of the Secret the provider reads its key from, empty for foundry (no key).
provider_secret_name() {
  case $provider in
    anthropic) printf 'shadewright-anthropic' ;;
    openai) printf 'shadewright-openai' ;;
  esac
}

# provider_needs_key: for `up`, before anything is billed: a fresh cluster has no Secret, so the provider's key file
# (or the vault, which sets the same variable) must be given. Not for `flux` and `provider`, which may find the Secret
# in the cluster already; provider_secret_check looks there.
provider_needs_key() {
  case $provider in
    anthropic) [[ -n ${LAB_ANTHROPIC_KEY_FILE:-} ]] || die "LAB_MODEL_PROVIDER=anthropic needs LAB_ANTHROPIC_KEY_FILE or LAB_MODEL_KEYS_FROM_VAULT=true: the lab has no Secret for the Anthropic key yet" ;;
    openai) [[ -n ${LAB_OPENAI_KEY_FILE:-} ]] || die "LAB_MODEL_PROVIDER=openai needs LAB_OPENAI_KEY_FILE or LAB_MODEL_KEYS_FROM_VAULT=true: the lab has no Secret for the OpenAI key yet" ;;
  esac
}

# provider_secret_check: the provider's Secret must be in the cluster (created just before from the key file, or there
# from an earlier run). Only a definite NotFound says it is absent; any other failed read is an error to retry.
# Called as `provider_secret_check || return 1`.
provider_secret_check() {
  local name err="$tmp/provider-secret.err"
  name=$(provider_secret_name)
  [[ -n $name ]] || return 0
  kc -n shadewright-system get secret "$name" -o name >/dev/null 2>"$err" && return 0
  if grep -q NotFound "$err"; then
    flux_fail "LAB_MODEL_PROVIDER=$provider needs the Secret $name in shadewright-system and the cluster has none: set the key file variable of that provider (or LAB_MODEL_KEYS_FROM_VAULT=true) and run again"
  else
    flux_fail "cannot read the Secret $name in shadewright-system: retry"
  fi
  return 1
}

# provider_configmap: the ConfigMap the root Kustomization reads (optional there, so a lab without it runs foundry).
provider_configmap() {
  info "Model provider: $provider (ConfigMap lab-model-provider in flux-system)"
  kc -n flux-system create configmap lab-model-provider --from-literal=MODEL_PROVIDER="$provider" --dry-run=client -o yaml |
    kc apply --server-side --force-conflicts --field-manager=shadewright-lab -f - >/dev/null ||
    { flux_fail "writing the ConfigMap lab-model-provider failed"; return 1; }
}

# flux_reconcile <kustomization>: asks Flux to reconcile it now (the annotation `flux reconcile` sets) and waits until
# the controller reports that exact request as handled (status.lastHandledReconcileAt). The request is a unique token,
# compared for equality only: no clocks are compared. A failed read is retried until the limit, never taken as an answer.
flux_reconcile() {
  local name=$1 token got i=0
  token="lab-$$-${RANDOM}-$(date -u +%s)"
  kc -n flux-system annotate --overwrite "kustomization/$name" "reconcile.fluxcd.io/requestedAt=$token" >/dev/null ||
    { flux_fail "cannot ask Flux to reconcile kustomization/$name"; return 1; }
  while :; do
    got=$(kc -n flux-system get "kustomization/$name" -o jsonpath='{.status.lastHandledReconcileAt}' 2>/dev/null) || got=
    [[ $got == "$token" ]] && return 0
    i=$((i + 1))
    ((i <= ${PROVIDER_POLL_TRIES:-60})) ||
      { flux_fail "Flux did not handle the reconcile request of kustomization/$name in time: kubectl -n flux-system describe kustomization $name"; return 1; }
    sleep "${FLUX_POLL:-5}"
  done
}

# provider_readback: what the cluster says is active, and the check that it is the requested provider. The settings
# hold the provider (empty is Foundry, the CRD default); the Flux path of both Kustomizations ends in the variant.
provider_readback() {
  local want path_agent path_cfg got model
  case $provider in foundry) want=Foundry ;; anthropic) want=Anthropic ;; openai) want=OpenAICompatible ;; esac
  path_agent=$(kc -n flux-system get kustomization shadewright -o jsonpath='{.spec.path}') ||
    { flux_fail "cannot read kustomization/shadewright: retry"; return 1; }
  path_cfg=$(kc -n flux-system get kustomization shadewright-config -o jsonpath='{.spec.path}') ||
    { flux_fail "cannot read kustomization/shadewright-config: retry"; return 1; }
  got=$(kc get remediationsettings default -o jsonpath='{.spec.analysis.models.triage.provider}') ||
    { flux_fail "cannot read the RemediationSettings: retry"; return 1; }
  model=$(kc get remediationsettings default -o jsonpath='{.spec.analysis.models.triage.deployment}') ||
    { flux_fail "cannot read the RemediationSettings: retry"; return 1; }
  [[ -n $got ]] || got=Foundry
  if [[ $path_agent != */"$provider" || $path_cfg != */"$provider" || $got != "$want" ]]; then
    flux_fail "the cluster does not run $provider: Flux paths ${path_agent##*/} and ${path_cfg##*/}, settings provider $got"
    return 1
  fi
  printf '\nModel provider now active: %s (settings provider %s, deployment %s)\n' "$provider" "$got" "$model"
}

# provider_switch [ask]: switches a running lab: its Secret, the ConfigMap, a reconcile of lab and then of the two
# children, the analyzer's rollout, and the read-back. Called as `provider_switch || ...`: every step ends in `|| return 1`.
provider_switch() {
  local cfg
  cfg=$(tf output -json flux) || { flux_fail "cannot read the flux output of the lab: is the lab applied?"; return 1; }
  if [[ $(jq -r 'type' <<<"$cfg") != object ]]; then
    flux_fail "flux_enabled is false: the lab has no fleet to switch"
    return 1
  fi
  need kubectl kubelogin az
  [[ -z ${1:-} ]] || confirm "Switch the model provider of the running lab to $provider?"
  cluster_credentials || return 1
  anthropic_key_secret || return 1
  openai_key_secret || return 1
  provider_secret_check || return 1
  provider_configmap || return 1
  info "Flux: reconcile lab, shadewright, shadewright-config"
  flux_reconcile lab || return 1
  flux_reconcile shadewright || return 1
  flux_reconcile shadewright-config || return 1
  kc -n flux-system wait --for=condition=Ready kustomization/lab kustomization/shadewright kustomization/shadewright-config \
    --timeout="${PROVIDER_READY_TIMEOUT:-600s}" >/dev/null ||
    { flux_fail "a Kustomization is not Ready after the switch: kubectl -n flux-system get kustomization, and describe helmrelease shadewright (the chart may not support $provider)"; return 1; }
  info "The analyzer rolls out"
  kc -n shadewright-system rollout status deployment/shadewright-analyzer --timeout="${PROVIDER_ROLLOUT_TIMEOUT:-300s}" >/dev/null ||
    { flux_fail "the analyzer did not roll out: kubectl -n shadewright-system get pods"; return 1; }
  provider_readback || return 1
}

# flux_install [ask]: with an argument, asks for a typed yes first (a step that is not part of an applied plan).
# Called as `flux_install || ...`, which switches set -e off inside it: every step ends in `|| return 1`.
flux_install() {
  local cfg manifest="$tmp/flux.yaml"
  cfg=$(tf output -json flux) || { flux_fail "cannot read the flux output of the lab: is the lab applied?"; return 1; }
  if [[ $(jq -r 'type' <<<"$cfg") != object ]]; then
    printf '\nflux_enabled is false: Flux is not installed.\n'
    return 0
  fi
  need kubectl kubelogin curl jq az awk
  flux_validate "$cfg"
  [[ -z ${1:-} ]] || confirm "Install Flux $FLUX_VERSION in the running lab cluster and point it at the fleet repository?"
  if [[ ! -s $manifest ]]; then
    info "Flux $FLUX_VERSION: download, verify, pin"
    flux_fetch "$manifest" || return 1
  fi

  cluster_credentials || return 1

  anthropic_key_secret || return 1
  openai_key_secret || return 1
  provider_secret_check || return 1

  info "Flux: install"
  kc apply --server-side --force-conflicts --field-manager=shadewright-lab -f "$manifest" >/dev/null ||
    { flux_fail "applying the Flux manifest failed"; return 1; }
  kc wait --for=condition=Established crd -l app.kubernetes.io/part-of=flux --timeout=120s >/dev/null ||
    { flux_fail "the Flux CRDs are not Established"; return 1; }
  kc -n flux-system wait --for=condition=Available deployment --all --timeout=300s >/dev/null ||
    { flux_fail "the Flux controllers are not Available: kubectl -n flux-system get pods"; return 1; }

  provider_configmap || return 1

  info "Flux: GitRepository fleet and Kustomization lab"
  flux_objects "$cfg" | kc apply --server-side --force-conflicts --field-manager=shadewright-lab -f - >/dev/null ||
    { flux_fail "applying the GitRepository and the Kustomization failed"; return 1; }
  kc -n flux-system wait --for=condition=Ready gitrepository/fleet kustomization/lab --timeout=300s >/dev/null ||
    { flux_fail "the GitRepository fleet or the Kustomization lab is not Ready within 5 minutes: run make lab-flux again, or kubectl -n flux-system describe gitrepository fleet kustomization lab"; return 1; }
  printf '\nFlux %s syncs ./clusters/lab; the root Kustomization is flux-system/lab.\n' "$FLUX_VERSION"
}

cmd_flux() {
  need terraform jq
  provider_check
  lab_config
  model_keys_from_vault
  anthropic_key_check
  openai_key_check
  tf_init
  flux_preflight
  flux_install ask || die "the Flux step failed: run make lab-flux again"
}

cmd_provider() {
  need terraform jq
  provider_check
  lab_config
  model_keys_from_vault
  anthropic_key_check
  openai_key_check
  tf_init
  provider_switch ask || die "the switch failed: run make lab-provider again (it is safe to repeat)"
}

# The text after a failed apply. A cluster that Azure created but could not finish (for example AllocationFailed) is
# not in the state, so `make lab-down` cannot remove it.
apply_failed_hint() {
  printf '%s' "terraform apply failed: parts of the lab may be up and billed, and a cluster may exist in Azure outside the Terraform state (for example after AllocationFailed). Run make lab-check to list what is left; delete a failed cluster with az aks delete, then plan again (README, Troubleshooting). Run make lab-down for what the state holds."
}

cmd_up() {
  need terraform jq curl az
  provider_check
  lab_config
  model_keys_from_vault
  anthropic_key_check
  openai_key_check
  provider_needs_key
  tf_init
  flux_preflight
  local plan="lab-up.tfplan" rc=0
  info "terraform plan (lab) to $plan"
  tf plan -input=false -detailed-exitcode -out="$plan" || rc=$?
  case $rc in
    0) printf '\nThe lab is up to date: nothing to apply.\n'; flux_install ask || die "the Flux step failed: run make lab-flux again"; return 0 ;;
    2) ;;
    *) die "terraform plan failed" ;;
  esac
  plan_summary "$plan"
  # A subshell, because cmd_cost exits through die: a price lookup failure only warns.
  (cmd_cost) || printf 'lab: price lookup failed, check the README cost table\n' >&2
  if [[ $auto_yes == 1 ]] && [[ $(plan_deletes "$plan") != 0 ]]; then
    printf '\nlab: --yes does not approve a plan that deletes or replaces anything; asking instead.\n' >&2
    auto_yes=0
  fi
  confirm "Apply exactly this plan to the lab (then install Flux, when flux_enabled)?"
  info "terraform apply $plan"
  tf apply -input=false "$plan" ||
    die "$(apply_failed_hint)"
  flux_install ||
    die "the Flux step failed: the cluster is up and billed; run make lab-flux to repeat it, or make lab-down"
  cat <<'EOF'

The lab is up and costs money by the hour. Get a kubeconfig, and destroy it when done:
  eval "$(terraform -chdir=lab output -raw get_credentials)"   # --overwrite-existing: replaces an earlier lab's entry
  kubelogin convert-kubeconfig -l azurecli
  make lab-down
EOF
}

cmd_down() {
  need terraform jq az
  lab_config
  tf_init
  local plan="lab-down.tfplan" rc=0
  info "terraform plan -destroy (lab only) to $plan"
  tf plan -destroy -input=false -detailed-exitcode -out="$plan" || rc=$?
  case $rc in
    0) printf '\nNothing to destroy in the lab state.\n' ;;
    2)
      plan_summary "$plan"
      confirm "Destroy the lab (foundation and bootstrap stay)?"
      info "terraform apply $plan (destroy)"
      if ! tf apply -input=false "$plan"; then
        printf 'lab: the destroy failed; what is left:\n' >&2
        cmd_check || true
        die "terraform apply (destroy) failed: run make lab-down again"
      fi
      ;;
    *) die "terraform plan -destroy failed" ;;
  esac
  cmd_check
}

# Sourced by scripts/lab_test.sh for the helpers only.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

umask 077 # saved plans hold the planned values in clear text
tmp=$(mktemp -d)
# The only cleanup of the saved plans, on every exit.
trap 'rm -rf "$tmp"; rm -f "$lab_dir/lab-up.tfplan" "$lab_dir/lab-down.tfplan"' EXIT

parse_args "$@" || { usage >&2; exit 2; }
case $command in
  plan) cmd_plan ;;
  up) cmd_up ;;
  down) cmd_down ;;
  cost) cmd_cost ;;
  check) cmd_check ;;
  flux) cmd_flux ;;
  provider) cmd_provider ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
