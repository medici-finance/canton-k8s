#!/usr/bin/env bash
# substitute.sh — mimic Flux postBuild.substituteFrom locally / in CI.
#
# Reads the data: keys of an env ConfigMap and substitutes those variables into
# a rendered manifest stream. Flux's substituter is NOT GNU envsubst: it is
# fluxcd/pkg/envsubst (a fork of drone/envsubst), and it differs from GNU
# envsubst in three ways that matter here. Two are emulated below; the third is
# a deliberate divergence.
#
#   1. `$$` is an ESCAPE. Flux consumes the pair and emits one literal `$`,
#      left to right, so `$${VAR}` renders as the literal `${VAR}` (that is how
#      a placeholder survives postBuild to be expanded by a pod at runtime) and
#      `$$${VAR}` renders as `$` followed by the value. GNU envsubst has no such
#      rule and would render `$${VAR}` as `$<value>`. EMULATED, by replacing
#      each `$$` with a sentinel byte before the envsubst call and restoring it
#      afterwards.
#
#   2. Only the BRACED form is a substitution site. Flux's scanner opens a
#      variable only on the two-byte sequence `${` (scanLbrack in
#      fluxcd/pkg/envsubst/parse/scan.go), so a bare `$VAR` is left alone —
#      which is exactly what ConfigMap-shipped shell scripts rely on. GNU
#      envsubst substitutes `$VAR` too. EMULATED, by sentinelling every `$` that
#      does not open a `${`.
#
#   3. An UNDEFINED variable expands to the EMPTY STRING under Flux (the
#      non-strict mapping returns vars[s], i.e. "", for an unknown key —
#      varSubstitution in fluxcd/pkg/kustomize/kustomize_varsub.go). This script
#      instead leaves `${UNDEFINED}` standing. DELIBERATE DIVERGENCE: a
#      placeholder the env ConfigMap does not define is a defect, and leaving it
#      visible keeps it diagnosable instead of silently blanking it. CI does not
#      depend on that divergence to catch such placeholders — the guard in
#      .github/workflows/validate.yml inspects the PRE-substitution artifact.
#
# Bash-style default forms (`${VAR:-x}`) are still not emulated; Flux evaluates
# them, and this repo's manifests deliberately avoid them (CI greps to enforce
# that, and the placeholder guard rejects them as non-identifier sites).
#
# Usage: substitute.sh <rendered.yaml> <env-configmap.yaml>
set -euo pipefail

MANIFEST="$1"
ENV_CM="$2"

command -v yq >/dev/null 2>&1 || { echo "FATAL: yq is required" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "FATAL: envsubst (gettext) is required" >&2; exit 1; }

# Two bytes that cannot occur in a Kubernetes manifest stand in for a `$` that
# envsubst must not see. If either is somehow present the round trip would
# corrupt the output, so refuse rather than emit a wrong artifact.
ESC=$(printf '\001')   # a `$` produced by consuming a `$$` escape
LIT=$(printf '\002')   # a `$` that does not open a `${` substitution site
if LC_ALL=C grep -q "[$ESC$LIT]" "$MANIFEST"; then
  echo "FATAL: $MANIFEST contains a U+0001/U+0002 byte, used here as a sentinel" >&2
  exit 1
fi

VARS=""
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  export "$k=$v"
  VARS="$VARS \${$k}"
done < <(yq eval '.data | to_entries | .[] | .key + "=" + .value' "$ENV_CM")

# Order matters: escapes are consumed first (left to right, exactly as Flux
# pairs them), and only then is every surviving non-site `$` protected.
sed -e 's/\$\$/'"$ESC"'/g' \
    -e 's/\$\([^{]\)/'"$LIT"'\1/g' \
    -e 's/\$$/'"$LIT"'/' "$MANIFEST" \
  | envsubst "$VARS" \
  | tr "$ESC$LIT" '$$'
