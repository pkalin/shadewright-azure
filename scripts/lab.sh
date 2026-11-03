#!/usr/bin/env bash
# Brings the disposable lab (the `lab` root, ADR-0008) up and down, prices it, and checks that nothing is left.
#
#   scripts/lab.sh plan    plan the lab; changes nothing
#   scripts/lab.sh up      plan to a file, show it and the cost per hour, ask for "yes", apply that saved plan
#   scripts/lab.sh down    plan the destroy of `lab` (never foundation or bootstrap), ask for "yes", apply it,
#                          then run `check`
#   scripts/lab.sh cost    the lab's price per hour from the Azure Retail Prices API (public, no login)
#   scripts/lab.sh check   list what is left in the subscription; fails when anything of the lab remains
#
# Reads the subscription and prefix from the git-ignored lab/terraform.tfvars and the state resource group from
# ../backend.hcl. Prints names and types only, never subscription IDs or resource IDs. There is no flag to skip
# the confirmation: up and down need a terminal and a typed "yes".
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

die() { printf 'lab: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

usage() { sed -n '2,13s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

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

# Asks on the terminal, never on stdin, so piped input or `yes |` cannot approve an apply.
confirm() {
  local answer
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
      row("AKS Free tier, Flux extension on AKS", 0)
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

cmd_up() {
  need terraform jq curl az
  lab_config
  tf_init
  local plan="lab-up.tfplan" rc=0
  info "terraform plan (lab) to $plan"
  tf plan -input=false -detailed-exitcode -out="$plan" || rc=$?
  case $rc in
    0) printf '\nThe lab is up to date: nothing to apply.\n'; return 0 ;;
    2) ;;
    *) die "terraform plan failed" ;;
  esac
  plan_summary "$plan"
  # A subshell, because cmd_cost exits through die: a price lookup failure only warns.
  (cmd_cost) || printf 'lab: price lookup failed, check the README cost table\n' >&2
  confirm "Apply exactly this plan to the lab?"
  info "terraform apply $plan"
  tf apply -input=false "$plan" ||
    die "terraform apply failed: parts of the lab may be up and billed; run make lab-down or make lab-check"
  cat <<'EOF'

The lab is up and costs money by the hour. Get a kubeconfig, and destroy it when done:
  eval "$(terraform -chdir=lab output -raw get_credentials)"
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

case ${1:-help} in
  plan) cmd_plan ;;
  up) cmd_up ;;
  down) cmd_down ;;
  cost) cmd_cost ;;
  check) cmd_check ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
