#!/usr/bin/env bash
# Offline tests of the helpers in scripts/lab.sh: no Terraform, no Azure, no network. Run by CI and by
# `make test`; works with bash 3.2 (macOS) and current bash.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lab.sh
source "$here/lab.sh"

fails=0
eq() { # name got want
  if [[ $2 == "$3" ]]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: got %q, want %q\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/t.tfvars" <<'TF'
# location = "commented"
tags = {
  location = "nested"
}
location   = "swedencentral" # trailing comment
node_count = 1
TF
eq "tfvar reads a top-level string" "$(tfvar "$work/t.tfvars" location)" swedencentral
eq "tfvar reads a number" "$(tfvar "$work/t.tfvars" node_count)" 1
eq "tfvar is empty for a missing key" "$(tfvar "$work/t.tfvars" prefix)" ""
eq "tfvar is empty for a missing file" "$(tfvar "$work/none.tfvars" prefix)" ""

mkdir -p "$work/root/foundation"
cat >"$work/root/foundation/variables.tf" <<'TF'
variable "location" {
  type    = string
  default = "swedencentral" # ADR-0016
}
TF
eq "tfdefault reads a default" "$(repo="$work/root" tfdefault foundation location)" swedencentral

prefix_ok() { [[ $1 =~ ^[a-z0-9]{1,11}$ ]] && echo yes || echo no; }
eq "prefix rule accepts foundation's form" "$(prefix_ok shw1)" yes
eq "prefix rule refuses a hyphen" "$(prefix_ok my-lab)" no
eq "prefix rule refuses 12 characters" "$(prefix_ok abcdefghijkl)" no
same=no
if grep -q 'prefix =~ ^\[a-z0-9\]{1,11}\$' "$here/lab.sh" &&
  grep -q 'regex("^\[a-z0-9\]{1,11}\$"' "$here/../foundation/variables.tf"; then
  same=yes
fi
eq "lab.sh and foundation use the same prefix rule" "$same" yes

# An empty array expands under set -u in bash 3.2 only with the ${a[@]+...} form price() uses.
empty=()
eq "empty array expands under set -u" "$(printf '[%s]' ${empty[@]+"${empty[@]}"} x)" "[x]"

# Flux install: the manifest preparation and the objects, offline.
cat >"$work/fake.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: flux-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kustomize-controller
spec:
  template:
    spec:
      containers:
      - args:
        - --watch-all-namespaces
        - --log-level=info
        image: ghcr.io/fluxcd/kustomize-controller:v1.10.1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-reflector-controller
spec:
  template:
    spec:
      containers:
      - args:
        - --watch-all-namespaces
        image: ghcr.io/fluxcd/image-reflector-controller:v1.3.0
YAML
real_images=$FLUX_IMAGES
FLUX_IMAGES="kustomize-controller=v1.10.1@sha256:$(printf 'a%.0s' {1..64})"
rc=0
out=$(flux_prepare "$work/fake.yaml" "$work/fake.out" 2>&1) || rc=$?
# The fake holds one kept Deployment, not four: the final count check must refuse it, after the rewrite is done.
eq "flux_prepare refuses a manifest without four controllers" "$rc" 1
eq "flux_prepare pins the image by digest" "$(grep -c 'kustomize-controller:v1.10.1@sha256:a' "$work/fake.out")" 1
eq "flux_prepare adds the multi-tenancy flag" "$(grep -c -- '--no-cross-namespace-refs=true' "$work/fake.out")" 1
eq "flux_prepare sets the default service account" "$(grep -c -- '--default-service-account=flux-applier' "$work/fake.out")" 1
eq "flux_prepare adds flux-applier with cluster-admin" "$(grep -c 'name: flux-applier\|name: cluster-admin' "$work/fake.out")" 4
eq "flux_prepare drops the image controllers" "$(grep -c 'image-reflector' "$work/fake.out")" 0
cat >>"$work/fake.yaml" <<'YAML'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: source-watcher
  namespace: flux-system
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: imagepolicies.image.toolkit.fluxcd.io
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: gitrepositories.source.toolkit.fluxcd.io
YAML
FLUX_IMAGES="kustomize-controller=v1.10.1@sha256:$(printf 'a%.0s' {1..64})"
flux_prepare "$work/fake.yaml" "$work/fake3.out" 2>/dev/null || true
eq "flux_prepare drops the ServiceAccount of a dropped controller" "$(grep -c 'name: source-watcher' "$work/fake3.out")" 0
eq "flux_prepare drops the image CRDs" "$(grep -c 'image.toolkit.fluxcd.io' "$work/fake3.out")" 0
eq "flux_prepare keeps the other CRDs" "$(grep -c 'gitrepositories.source.toolkit' "$work/fake3.out")" 1
FLUX_IMAGES="kustomize-controller=v1.9.0@sha256:$(printf 'a%.0s' {1..64})"
rc=0
flux_prepare "$work/fake.yaml" "$work/fake2.out" 2>/dev/null || rc=$?
eq "flux_prepare refuses an image whose tag is not the pinned one" "$rc" 1
FLUX_IMAGES=$real_images
eq "flux.env pins four controllers" "$(wc -w <<<"$FLUX_IMAGES" | tr -d ' ')" 4
eq "flux.env pins a checksum" "$([[ $FLUX_INSTALL_SHA256 =~ ^[0-9a-f]{64}$ ]] && echo yes)" yes

# shellcheck disable=SC2016
cfg='{"repository_url":"https://example.org/o/r","branch":"cluster/lab","substitute":{"ANALYZER_CLIENT_ID":"a b","X":"$(touch /tmp/x)"}}'
objs=$(flux_objects "$cfg")
eq "flux_objects names the GitRepository fleet" "$(jq -r '.items[0].metadata.name' <<<"$objs")" fleet
eq "flux_objects tracks the branch every 60 s" "$(jq -r '.items[0].spec | "\(.ref.branch) \(.interval)"' <<<"$objs")" "cluster/lab 1m"
eq "flux_objects applies ./clusters/lab as Kustomization lab" "$(jq -r '.items[1] | "\(.metadata.name) \(.spec.path)"' <<<"$objs")" "lab ./clusters/lab"
# shellcheck disable=SC2016
eq "flux_objects passes substitutions as data" "$(jq -r '.items[1].spec.postBuild.substitute.X' <<<"$objs")" '$(touch /tmp/x)'
eq "flux_validate accepts a plain URL and branch" "$(flux_validate "$cfg" >/dev/null 2>&1 && echo ok)" ok
bad=$(jq '.branch = "a b;c"' <<<"$cfg")
eq "flux_validate refuses an odd branch" "$( (flux_validate "$bad" >/dev/null 2>&1) && echo ok || echo refused)" refused
bad=$(jq '.repository_url = "http://example.org/o/r"' <<<"$cfg")
eq "flux_validate refuses plain http" "$( (flux_validate "$bad" >/dev/null 2>&1) && echo ok || echo refused)" refused

# flux_install is called as `flux_install || die`, where set -e is off: a failing step must still make it return
# non-zero, and it must not claim success. Every external command is a stub; $failing names the one that breaks.
(
  tmp=$work/fi
  mkdir -p "$tmp"
  echo manifest >"$tmp/flux.yaml"
  subscription=s
  test_cfg=$cfg
  FLUX_POLL=0
  need() { :; }
  flux_validate() { :; }
  confirm() { :; }
  info() { :; }
  tf() { [[ $failing == tf ]] && return 1; if [[ $3 == flux ]]; then echo "$test_cfg"; else echo name; fi; }
  az() { [[ $failing == az ]] && return 1; return 0; }
  kubelogin() { [[ $failing == kubelogin ]] && return 1; return 0; }
  kubectl() {
    case " $* " in
      *" can-i "*) [[ $failing == auth ]] && echo no || echo yes ;;
      *" apply "*" -f - "*) cat >/dev/null; [[ $failing == apply ]] && return 1; return 0 ;;
      *" apply "*) [[ $failing == apply ]] && return 1; return 0 ;;
      *" wait "*) [[ $failing == "wait" ]] && return 1; return 0 ;;
    esac
    return 0
  }
  for failing in none tf az kubelogin auth apply wait; do
    rc=0
    out=$(flux_install 2>&1) || rc=$?
    if [[ $failing == none ]]; then
      eq "flux_install succeeds when every step does" "$rc $(grep -c 'syncs ./clusters/lab' <<<"$out")" "0 1"
    else
      eq "flux_install returns non-zero when $failing fails, in || context" "$rc $(grep -c 'syncs ./clusters/lab' <<<"$out")" "1 0"
    fi
  done
  exit "$fails"
) || fails=$?

hint=$(apply_failed_hint)
eq "failed-apply hint mentions a cluster outside the state" "$(grep -c 'outside the Terraform state' <<<"$hint")" 1
eq "failed-apply hint points at make lab-check" "$(grep -c 'make lab-check' <<<"$hint")" 1
eq "failed-apply hint points at az aks delete" "$(grep -c 'az aks delete' <<<"$hint")" 1

# scripts/flux.env must hold the release and digests of the fleet's scripts/tools.env (README, "Flux"). Compared when
# that file is found: FLEET_TOOLS_ENV, else the sibling checkout. CI downloads it from the fleet's main.
fleet_env=${FLEET_TOOLS_ENV:-$here/../../shadewright-fleet/scripts/tools.env}
if [[ -f $fleet_env ]]; then
  # shellcheck source=/dev/null
  envval() { (. "$1"; printf '%s' "${!2}"); } # envval <file> <variable>
  eq "flux.env FLUX_VERSION equals the fleet's" "$(envval "$here/flux.env" FLUX_VERSION)" "$(envval "$fleet_env" FLUX_VERSION)"
  eq "flux.env checksum equals the fleet's" "$(envval "$here/flux.env" FLUX_INSTALL_SHA256)" "$(envval "$fleet_env" FLUX_INSTALL_SHA256)"
  for v in helm-controller kustomize-controller notification-controller source-controller; do
    want=$(envval "$fleet_env" "FLUX_IMAGE_${v//-/_}")
    got=$(envval "$here/flux.env" FLUX_IMAGES | tr ' ' '\n' | sed -n "s/^${v}=//p")
    eq "flux.env pins $v as the fleet does" "$got" "$want"
  done
else
  printf 'skip flux.env vs the fleet (no %s)\n' "$fleet_env"
fi

# --yes: accepted only after up, flux and down; anything else is a usage error.
pa() { local rc=0; parse_args "$@" || rc=$?; echo "$rc ${command:-} $auto_yes"; }
eq "parse_args: up alone asks" "$(pa up)" "0 up 0"
eq "parse_args: up --yes approves" "$(pa up --yes)" "0 up 1"
eq "parse_args: down --yes approves" "$(pa down --yes)" "0 down 1"
eq "parse_args: flux --yes approves" "$(pa flux --yes)" "0 flux 1"
eq "parse_args: no command is help" "$(pa)" "0 help 0"
eq "parse_args: --yes is refused for plan" "$(pa plan --yes | cut -d' ' -f1)" 2
eq "parse_args: --yes is refused for check" "$(pa check --yes | cut -d' ' -f1)" 2
eq "parse_args: an unknown option is refused" "$(pa up -y | cut -d' ' -f1)" 2
eq "parse_args: yes without dashes is refused" "$(pa down yes | cut -d' ' -f1)" 2

# confirm with --yes approves without a terminal and says so. (Without --yes it reads only /dev/tty, unchanged.)
eq "confirm approves with --yes, no terminal" "$(auto_yes=1; confirm "Apply?" 2>/dev/null </dev/null && echo ok)" ok
eq "confirm says it was approved by --yes" "$(auto_yes=1; confirm "Apply?" 2>&1 >/dev/null </dev/null | grep -c 'Approved by --yes')" 1

# plan_deletes counts deletes and replacements, so up --yes can fall back to asking.
(
  tf() { cat "$work/plan.json"; }
  printf '%s' '{"resource_changes":[{"change":{"actions":["create"]}},{"change":{"actions":["update"]}}]}' >"$work/plan.json"
  eq "plan_deletes is 0 for creates and updates" "$(plan_deletes x)" 0
  printf '%s' '{"resource_changes":[{"change":{"actions":["delete","create"]}},{"change":{"actions":["delete"]}},{"change":{"actions":["no-op"]}}]}' >"$work/plan.json"
  eq "plan_deletes counts a replace and a delete" "$(plan_deletes x)" 2
  printf '%s' '{}' >"$work/plan.json"
  eq "plan_deletes is 0 for an empty plan" "$(plan_deletes x)" 0
  exit "$fails"
) || fails=$((fails + $?))

((fails == 0)) || { printf '%d failed\n' "$fails"; exit 1; }
