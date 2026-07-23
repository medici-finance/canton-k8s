#!/usr/bin/env bash
# substitute.sh — mimic Flux postBuild.substituteFrom locally / in CI.
#
# Reads the data: keys of an env ConfigMap and substitutes EXACTLY those
# variables (and no others) into a rendered manifest stream, matching Flux's
# "undefined variables are left untouched" semantics closely enough for
# validation. (Difference: Flux's envsubst also evaluates bash-style default
# forms; this repo's manifests and scripts deliberately avoid them — CI greps
# to enforce that.)
#
# Usage: substitute.sh <rendered.yaml> <env-configmap.yaml>
set -euo pipefail

MANIFEST="$1"
ENV_CM="$2"

command -v yq >/dev/null 2>&1 || { echo "FATAL: yq is required" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "FATAL: envsubst (gettext) is required" >&2; exit 1; }

VARS=""
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  export "$k=$v"
  VARS="$VARS \${$k}"
done < <(yq eval '.data | to_entries | .[] | .key + "=" + .value' "$ENV_CM")

envsubst "$VARS" < "$MANIFEST"
