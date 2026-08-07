#!/bin/bash
# --- PUBLIC-FACING: no private hostnames/namespaces ---
# Verify the documented local-validation check (pre-substitution + comm)
# produces zero unmatched variables. Mirrors CI's guard in
# .github/workflows/validate.yml and matches the command given in
# docs/usage.md under "Validating locally".
#
# This is the check that verify step 3 in brief 05 targets.
# The post-substitution grep alternative (grep -n '\${' after
# substitute.sh, excluding ${KC_INIT_) can never be empty because the
# Keycloak realm-import init container legitimately carries pod-runtime
# ${APP_USER_*}, ${ADMIN_PASSWORD}, and ${VALIDATOR_APP_BACKEND_CLIENT_SECRET}
# placeholders after Flux collapses $$ -> $.  docs/usage.md explains why.

set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)

echo "=== Building base/canton ==="
kustomize build "$REPO/base/canton" > /tmp/canton_base.check.yaml

echo "=== Extracting placeholders from pre-substitution artifact ==="
sed 's/\$\$//g' /tmp/canton_base.check.yaml \
  | yq eval 'select(.kind != "ConfigMap")' - \
  | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}' | sort -u \
  > /tmp/canton_base.used.txt

echo "=== Placeholders used in non-ConfigMap documents ==="
cat /tmp/canton_base.used.txt

echo "=== Env-config keys ==="
yq eval '.data | keys | .[]' "$REPO/examples/env-config.yaml" | sort -u \
  > /tmp/canton_base.env_keys.txt
cat /tmp/canton_base.env_keys.txt

echo ""
echo "=== Variables in base but NOT in env-config (must be empty) ==="
UNMATCHED=$(comm -23 /tmp/canton_base.used.txt /tmp/canton_base.env_keys.txt || true)
if [ -n "$UNMATCHED" ]; then
  echo "FAIL: the following placeholders have no env-config definition:"
  echo "$UNMATCHED"
  exit 1
fi
echo "PASS: all placeholders are covered by env-config keys."
