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

((fails == 0)) || { printf '%d failed\n' "$fails"; exit 1; }
