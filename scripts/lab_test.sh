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

((fails == 0)) || { printf '%d failed\n' "$fails"; exit 1; }
