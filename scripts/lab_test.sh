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

# The two Secret steps flux_install runs, in its order (checked below against lab.sh).
flux_install_keys() { anthropic_key_secret || return 1; openai_key_secret || return 1; }
eq "flux_install makes both key Secrets, Anthropic first" "$(awk '/^flux_install\(\)/,/^}/' "$here/lab.sh" | grep -o '^  [a-z]*_key_secret' | tr -d ' ' | tr '\n' ' ')" "anthropic_key_secret openai_key_secret "
eq "cmd_up checks both keys before the plan" "$(awk '/^cmd_up\(\)/,/^}/' "$here/lab.sh" | grep -o '^  [a-z]*_key_check' | tr -d ' ' | tr '\n' ' ')" "anthropic_key_check openai_key_check "
eq "cmd_flux checks both keys before the plan" "$(awk '/^cmd_flux\(\)/,/^}/' "$here/lab.sh" | grep -o '^  [a-z]*_key_check' | tr -d ' ' | tr '\n' ' ')" "anthropic_key_check openai_key_check "

# The optional model API key: unset does nothing and prints nothing; a valid file reaches kubectl as a path, never as
# content; an empty or missing file fails without printing the content. kubectl is a stub that records its arguments.
(
  tmp=$work/ak
  mkdir -p "$tmp"
  secret_text="sk-test-$$-not-a-real-key"
  printf '%s\n' "$secret_text" >"$work/key.txt"
  : >"$work/empty.txt"
  calls=$tmp/calls
  setting() { echo "${test_flux:-true}"; }
  kubectl() {
    printf '%s\n' "$*" >>"$calls"
    case " $* " in
      *" apply "*) cat >/dev/null ;;
      *) echo "kind: stub" ;;
    esac
  }
  : >"$calls"
  rc=0; out=$(unset LAB_ANTHROPIC_KEY_FILE; anthropic_key_check 2>&1 && anthropic_key_secret 2>&1) || rc=$?
  eq "key: unset prints nothing, calls nothing" "$rc [$out] $(wc -l <"$calls" | tr -d ' ')" "0 [] 0"
  rc=0; out=$(LAB_ANTHROPIC_KEY_FILE=$work/key.txt anthropic_key_check 2>&1 && LAB_ANTHROPIC_KEY_FILE=$work/key.txt anthropic_key_secret 2>&1) || rc=$?
  eq "key: a valid file succeeds" "$rc" 0
  eq "key: kubectl gets the file as a path" "$(grep -c -- "create secret generic shadewright-anthropic .*--from-file=api-key=$work/key.txt" "$calls")" 1
  eq "key: the Anthropic file does not make an OpenAI Secret" "$(grep -c shadewright-openai "$calls")" 0
  eq "key: the Secret goes to shadewright-system" "$(grep -c -- '-n shadewright-system create secret' "$calls")" 1
  eq "key: the content is in no argument and not printed" "$( { cat "$calls"; echo "$out"; } | grep -c -- "$secret_text")" 0
  : >"$calls"
  rc=0; out=$( (LAB_ANTHROPIC_KEY_FILE=$work/empty.txt anthropic_key_check) 2>&1) || rc=$?
  eq "key: an empty file fails" "$rc" 1
  eq "key: the failure names the variable" "$(grep -c 'LAB_ANTHROPIC_KEY_FILE' <<<"$out")" 1
  rc=0; out=$( (LAB_ANTHROPIC_KEY_FILE=$work/none.txt anthropic_key_check) 2>&1) || rc=$?
  eq "key: a missing file fails" "$rc" 1
  rc=0; out=$( (LAB_ANTHROPIC_KEY_FILE=$work/empty.txt anthropic_key_secret) 2>&1) || rc=$?
  eq "key: the Secret step refuses an empty file, no kubectl call" "$rc $(wc -l <"$calls" | tr -d ' ')" "1 0"
  rc=0; out=$( (test_flux=false LAB_ANTHROPIC_KEY_FILE=$work/key.txt anthropic_key_check) 2>&1) || rc=$?
  eq "key: refused when flux_enabled is false" "$rc" 1

  # The OpenAI key goes through the same code: its own variable, its own Secret.
  : >"$calls"
  rc=0; out=$(unset LAB_OPENAI_KEY_FILE; openai_key_check 2>&1 && openai_key_secret 2>&1) || rc=$?
  eq "openai key: unset prints nothing, calls nothing" "$rc [$out] $(wc -l <"$calls" | tr -d ' ')" "0 [] 0"
  rc=0; out=$(LAB_OPENAI_KEY_FILE=$work/key.txt openai_key_check 2>&1 && LAB_OPENAI_KEY_FILE=$work/key.txt openai_key_secret 2>&1) || rc=$?
  eq "openai key: a valid file succeeds" "$rc" 0
  eq "openai key: kubectl gets the file as a path, Secret shadewright-openai" "$(grep -c -- "create secret generic shadewright-openai .*--from-file=api-key=$work/key.txt" "$calls")" 1
  eq "openai key: the Secret goes to shadewright-system" "$(grep -c -- '-n shadewright-system create secret' "$calls")" 1
  eq "openai key: the OpenAI file does not make an Anthropic Secret" "$(grep -c shadewright-anthropic "$calls")" 0
  eq "openai key: the content is in no argument and not printed" "$( { cat "$calls"; echo "$out"; } | grep -c -- "$secret_text")" 0
  rc=0; out=$( (LAB_OPENAI_KEY_FILE=$work/empty.txt openai_key_check) 2>&1) || rc=$?
  eq "openai key: an empty file fails, naming the variable" "$rc $(grep -c 'LAB_OPENAI_KEY_FILE' <<<"$out")" "1 1"
  rc=0; out=$( (LAB_OPENAI_KEY_FILE=$work/none.txt openai_key_check) 2>&1) || rc=$?
  eq "openai key: a missing file fails" "$rc" 1
  : >"$calls"
  rc=0; out=$( (LAB_OPENAI_KEY_FILE=$work/empty.txt openai_key_secret) 2>&1) || rc=$?
  eq "openai key: the Secret step refuses an empty file, no kubectl call" "$rc $(wc -l <"$calls" | tr -d ' ')" "1 0"
  rc=0; out=$( (test_flux=false LAB_OPENAI_KEY_FILE=$work/key.txt openai_key_check) 2>&1) || rc=$?
  eq "openai key: refused when flux_enabled is false" "$rc" 1
  : >"$calls"
  rc=0; out=$(LAB_ANTHROPIC_KEY_FILE=$work/key.txt LAB_OPENAI_KEY_FILE=$work/key.txt flux_install_keys 2>&1) || rc=$?
  eq "both keys: two Secrets are made" "$rc $(grep -c 'create secret generic' "$calls")" "0 2"
  exit "$fails"
) || fails=$?

# LAB_MODEL_KEYS_FROM_VAULT: the key is downloaded by az into a private file that the exit trap removes; both
# variables set is an error; a failed read stops before anything is billed; nothing of the value is printed or put on a
# command line. terraform and az are stubs; az writes the fake secret to the --file it is given.
(
  tmp=$work/vk
  mkdir -p "$tmp"
  subscription=s
  umask 077 # as lab.sh sets it; az writes the file under it
  secret_text="sk-test-$$-vault-not-a-real-key"
  calls=$tmp/calls
  : >"$calls"
  setting() { echo "${test_flux:-true}"; }
  need() { :; }
  foundation_tf() {
    [[ $vfail == tf ]] && return 1
    [[ $1 == init ]] && return 0
    printf '%s' '{"name":"kv-test","uri":"https://kv-test.vault.azure.net/","github_app_key":"github-app","model_key_secrets":{"anthropic":"anthropic-api-key","openai":"openai-api-key"}}'
  }
  az() {
    printf '%s\n' "$*" >>"$calls"
    [[ $vfail == az ]] && { echo "ERROR: $secret_text" >&2; return 1; }
    local file='' name=''
    while [[ $# -gt 0 ]]; do [[ $1 == --file ]] && file=$2; [[ $1 == --name ]] && name=$2; shift; done
    case " $vabsent " in
      *" $name "*) echo "ERROR: (SecretNotFound) A secret with name $name was not found in this key vault." >&2; return 1 ;;
    esac
    [[ ! -e $file ]] || return 1 # the real command refuses an existing file as well
    printf '%s\n' "$secret_text" >"$file"
  }
  vfail=none
  vabsent=
  rc=0; out=$(unset LAB_MODEL_KEYS_FROM_VAULT LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE; model_keys_from_vault 2>&1) || rc=$?
  eq "vault key: unset does nothing, calls nothing" "$rc [$out] $(wc -l <"$calls" | tr -d ' ')" "0 [] 0"
  rc=0; out=$(LAB_MODEL_KEYS_FROM_VAULT=false model_keys_from_vault 2>&1) || rc=$?
  eq "vault key: false does nothing" "$rc [$out] $(wc -l <"$calls" | tr -d ' ')" "0 [] 0"
  rc=0; out=$( (LAB_MODEL_KEYS_FROM_VAULT=yes model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: a value other than true is refused" "$rc" 1
  rc=0; out=$( (LAB_MODEL_KEYS_FROM_VAULT=true LAB_ANTHROPIC_KEY_FILE=$work/key.txt model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: both variables set is an error, no az call" "$rc $(wc -l <"$calls" | tr -d ' ')" "1 0"
  eq "vault key: the both-set error names both variables" "$(grep -c 'LAB_MODEL_KEYS_FROM_VAULT and LAB_ANTHROPIC_KEY_FILE' <<<"$out")" 1
  rc=0; out=$( (LAB_MODEL_KEYS_FROM_VAULT=true LAB_OPENAI_KEY_FILE=$work/key.txt model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: an OpenAI file with the vault is an error, no az call" "$rc $(wc -l <"$calls" | tr -d ' ') $(grep -c 'LAB_MODEL_KEYS_FROM_VAULT and LAB_OPENAI_KEY_FILE' <<<"$out")" "1 0 1"
  rc=0; out=$( (test_flux=false LAB_MODEL_KEYS_FROM_VAULT=true model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: refused when flux_enabled is false" "$rc $(wc -l <"$calls" | tr -d ' ')" "1 0"

  # Success, run in the shell itself (not a subshell): the variable must be set for the next step, and the file must
  # be gone once the trap's rm has run.
  export LAB_MODEL_KEYS_FROM_VAULT=true
  unset LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE
  rc=0; model_keys_from_vault >"$tmp/out" 2>&1 || rc=$?
  eq "vault key: a successful read" "$rc" 0
  eq "vault key: LAB_OPENAI_KEY_FILE is set, under the private tmp, holding the secret, mode 600" "$([[ $LAB_OPENAI_KEY_FILE == "$tmp"/* ]] && [[ $(cat "$LAB_OPENAI_KEY_FILE") == "$secret_text" ]] && [[ $(stat -c %a "$LAB_OPENAI_KEY_FILE" 2>/dev/null || stat -f %Lp "$LAB_OPENAI_KEY_FILE") == 600 ]] && echo yes)" yes
  eq "vault key: the OpenAI check accepts the file" "$(openai_key_check >/dev/null 2>&1 && echo ok)" ok
  eq "vault key: az reads the OpenAI secret by name" "$(grep -c -- 'keyvault secret download --vault-name kv-test --name openai-api-key --file .* --encoding utf-8' "$calls")" 1
  eq "vault key: no skip line when both are there" "$(grep -c skipped "$tmp/out")" 0
  eq "vault key: LAB_ANTHROPIC_KEY_FILE is set" "$([[ -n ${LAB_ANTHROPIC_KEY_FILE:-} ]] && echo yes)" yes
  eq "vault key: the file is under the private tmp" "$([[ $LAB_ANTHROPIC_KEY_FILE == "$tmp"/* ]] && echo yes)" yes
  eq "vault key: the file holds the secret" "$(cat "$LAB_ANTHROPIC_KEY_FILE")" "$secret_text"
  eq "vault key: the file is private (mode 600)" "$(stat -c %a "$LAB_ANTHROPIC_KEY_FILE" 2>/dev/null || stat -f %Lp "$LAB_ANTHROPIC_KEY_FILE")" 600
  eq "vault key: the existing check accepts the file" "$(anthropic_key_check >/dev/null 2>&1 && echo ok)" ok
  eq "vault key: az gets the vault, the secret name and --file" "$(grep -c -- 'keyvault secret download --vault-name kv-test --name anthropic-api-key --file .* --encoding utf-8' "$calls")" 1
  eq "vault key: nothing of the value in output or arguments" "$( { cat "$tmp/out" "$calls"; } | grep -c -- "$secret_text")" 0
  # The exit trap of lab.sh removes $tmp, which holds the private directory: the same call here, then the check.
  key_path=$LAB_ANTHROPIC_KEY_FILE
  key_path2=$LAB_OPENAI_KEY_FILE
  rm -rf "$tmp"
  eq "vault key: the OpenAI temp file is removed too" "$([[ -e $key_path2 ]] && echo present || echo gone)" gone
  eq "vault key: the temp file is removed with the tmp dir on exit" "$([[ -e $key_path ]] && echo present || echo gone)" gone
  eq "vault key: lab.sh's exit trap removes \$tmp" "$(grep -c "trap 'rm -rf \"\$tmp\"" "$here/lab.sh")" 1

  # A failed read stops, names the variable and the secret, and leaks nothing, whatever the cause.
  mkdir -p "$tmp"; : >"$calls"
  unset LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE
  # One secret absent: skipped with one line naming it, the other is used.
  vabsent=openai-api-key
  rc=0; model_keys_from_vault >"$tmp/out" 2>&1 || rc=$?
  eq "vault key: an absent OpenAI secret is skipped, not an error" "$rc" 0
  eq "vault key: one line names the skipped secret" "$(grep -c 'openai-api-key is not in the Key Vault: skipped' "$tmp/out") $(grep -c skipped "$tmp/out")" "1 1"
  eq "vault key: the Anthropic key is still set, the OpenAI one is not" "$([[ -n ${LAB_ANTHROPIC_KEY_FILE:-} && -z ${LAB_OPENAI_KEY_FILE:-} ]] && echo yes)" yes
  unset LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE
  vabsent=anthropic-api-key
  rc=0; model_keys_from_vault >"$tmp/out" 2>&1 || rc=$?
  eq "vault key: an absent Anthropic secret is skipped, not an error" "$rc $(grep -c 'anthropic-api-key is not in the Key Vault: skipped' "$tmp/out")" "0 1"
  eq "vault key: the OpenAI key is set, the Anthropic one is not" "$([[ -z ${LAB_ANTHROPIC_KEY_FILE:-} && -n ${LAB_OPENAI_KEY_FILE:-} ]] && echo yes)" yes
  unset LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE
  vabsent="anthropic-api-key openai-api-key"
  rc=0; out=$( (model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: neither secret present is an error naming both" "$rc $(grep -c 'neither model key secret is in the Key Vault' <<<"$out") $(grep -c skipped <<<"$out")" "1 1 2"
  vabsent=
  # A refused read (not SecretNotFound) is an error to retry, not a skip.
  unset LAB_ANTHROPIC_KEY_FILE LAB_OPENAI_KEY_FILE
  vfail=az
  rc=0; out=$( (model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: a refused read stops" "$rc" 1
  eq "vault key: the failure names the variable and the secret" "$(grep -c 'LAB_MODEL_KEYS_FROM_VAULT: cannot read the secret anthropic-api-key' <<<"$out")" 1
  eq "vault key: the failure prints nothing of the value" "$(grep -c -- "$secret_text" <<<"$out")" 0
  vfail=tf
  rc=0; out=$( (model_keys_from_vault) 2>&1) || rc=$?
  eq "vault key: an unreadable foundation output stops, as an error to retry" "$rc $(grep -c retry <<<"$out")" "1 1"

  # Order: up and flux run the vault step before the plan and before the Flux step, so a failure bills nothing.
  eq "vault key: cmd_up reads the vault before terraform init" "$(awk '/^cmd_up\(\)/,/^}/' "$here/lab.sh" | grep -n 'model_keys_from_vault\|tf_init' | cut -d: -f2 | tr -d ' ' | tr '\n' ' ')" "model_keys_from_vault tf_init "
  eq "vault key: cmd_flux reads the vault before terraform init" "$(awk '/^cmd_flux\(\)/,/^}/' "$here/lab.sh" | grep -n 'model_keys_from_vault\|tf_init' | cut -d: -f2 | tr -d ' ' | tr '\n' ' ')" "model_keys_from_vault tf_init "
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
