#!/bin/bash
# --- PUBLIC-FACING: no private hostnames/namespaces ---
# Verify the documented local-validation check (pre-substitution + comm)
# produces zero unmatched variables. Mirrors CI's guard in
# .github/workflows/validate.yml exactly: both the (a) SHAPE check and the
# (b) RESOLUTION check, over the same five kustomize targets CI validates
# (base/canton, examples/overlays/dev, examples/overlays/prod, deploy,
# admin). Matches the command given in docs/usage.md under "Validating
# locally".
#
# This is the check that verify step 3 in brief 05 targets.
# The post-substitution grep alternative (grep -n '\${' after
# substitute.sh, excluding ${KC_INIT_) can never be empty because the
# Keycloak realm-import init container legitimately carries pod-runtime
# ${APP_USER_*}, ${ADMIN_PASSWORD}, and ${VALIDATOR_APP_BACKEND_CLIENT_SECRET}
# placeholders after Flux collapses $$ -> $.  docs/usage.md explains why.

set -euo pipefail

command -v kustomize >/dev/null 2>&1 || { echo "FATAL: kustomize is required" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "FATAL: yq is required" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "=== Env-config keys ==="
yq eval '.data | keys | .[]' "$REPO/examples/env-config.yaml" | sort -u > "$WORK/env-keys.txt"
cat "$WORK/env-keys.txt"

for target in base/canton examples/overlays/dev examples/overlays/prod deploy admin; do
  name=$(echo "$target" | tr '/' '-')

  echo ""
  echo "=== Building $target ==="
  kustomize build "$REPO/$target" > "$WORK/$name.yaml"

  # `$$` is Flux's escape — it consumes the pair and emits one literal `$`.
  # Deleting the pairs left-to-right leaves exactly the set of `${` sites
  # Flux will act on.
  sed 's/\$\$//g' "$WORK/$name.yaml" > "$WORK/$name.sites.yaml"

  echo "=== check (a) SHAPE: $target ==="
  # On a `${` that is not a well-formed `${IDENT}`, Flux's substituter
  # either rejects the whole Kustomization or applies a default expansion
  # (docs/usage.md sharp edge 4). Delete the well-formed sites; whatever
  # still opens a brace is bad.
  #
  # shellcheck disable=SC2016
  if sed 's/\${[A-Za-z_][A-Za-z0-9_]*}//g' "$WORK/$name.sites.yaml" | grep -n '\${'; then
    echo "FAIL: \${ in $target that is not a plain \${IDENT} — Flux's substituter"
    echo "      either rejects the whole Kustomization or applies a default expansion."
    exit 1
  fi

  echo "=== check (b) RESOLUTION: $target ==="
  # Every substitution site outside ConfigMap data must be defined by the
  # example env ConfigMap; an undefined one is replaced with the empty
  # string when Flux reconciles. ConfigMap data is exempt because its
  # scripts hold runtime shell variables (bare $VAR, not braced ${VAR}).
  #
  # shellcheck disable=SC2016
  yq eval 'select(.kind != "ConfigMap")' "$WORK/$name.sites.yaml" \
    | { grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' || true; } \
    | tr -d '${}' | sort -u \
    > "$WORK/$name.used.txt"
  cat "$WORK/$name.used.txt"

  comm -23 "$WORK/$name.used.txt" "$WORK/env-keys.txt" > "$WORK/$name.undef.txt"
  if [ -s "$WORK/$name.undef.txt" ]; then
    echo "FAIL: the following placeholders in $target have no env-config definition:"
    sed 's/^/  /' "$WORK/$name.undef.txt"
    exit 1
  fi
done

echo ""
echo "PASS: all placeholders are covered by env-config keys across all 5 targets."
