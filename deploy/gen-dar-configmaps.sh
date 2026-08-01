#!/usr/bin/env bash
# gen-dar-configmaps.sh — slice a built DAR into dar-part{1..N} ConfigMaps.
#
# Run this from YOUR (private) repo; commit the generated YAML there — never
# to this public base. The dar-deploy Job (dar-deploy-job.yaml) reassembles
# the parts in order and uploads the result.
#
# WHY parts: the API server caps a ConfigMap at 1048576 decoded bytes; DARs are
# bigger. Each part holds an equal contiguous slice (see LIMIT below).
#
# REMINDER (Job-name versioning rule): after regenerating, bump BOTH
# DAR_VERSION and DAR_DEPLOY_JOB_VERSION in your env ConfigMap, or Flux will
# not re-run the (immutable, completed) Job and the new DAR never reaches
# Canton — the old Job's success keeps looking green.
#
# Usage:
#   gen-dar-configmaps.sh --namespace <ns> --out <dir> [--parts N] [--prefix dar-part] <path/to/app.dar>
set -euo pipefail

NAMESPACE=""
OUT_DIR=""
PARTS=3
PREFIX="dar-part"
DAR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --out)       OUT_DIR="$2";   shift 2 ;;
    --parts)     PARTS="$2";     shift 2 ;;
    --prefix)    PREFIX="$2";    shift 2 ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *)           DAR="$1";       shift ;;
  esac
done

[ -n "$NAMESPACE" ] || { echo "FATAL: --namespace is required" >&2; exit 1; }
[ -n "$OUT_DIR" ]   || { echo "FATAL: --out is required" >&2; exit 1; }
[ -n "$DAR" ] && [ -f "$DAR" ] || { echo "FATAL: DAR path missing or not a file: '$DAR'" >&2; exit 1; }
mkdir -p "$OUT_DIR"

SIZE=$(wc -c < "$DAR" | tr -d ' ')

# The cap this gate exists to enforce is the API server's, and it is measured on
# the DECODED bytes — not on the base64 text in the YAML:
#
#   ValidateConfigMap()   totalSize += len(value) for each binaryData value
#   BinaryData            map[string][]byte  (already decoded)
#   MaxSecretSize         1 * 1024 * 1024 = 1048576
#   (k8s pkg/apis/core/validation/validation.go, pkg/apis/core/types.go)
#
# So a raw chunk of N bytes costs N against 1048576, however long its base64
# rendering is. LIMIT must therefore sit just BELOW 1048576 — the previous
# 1050000 sat 1424 bytes ABOVE it, which is the whole defect: a chunk in
# 1048577..1050000 passed this gate and was then rejected by the API server
# ("may not exceed 1048576 bytes"), i.e. the fuse was useless in exactly the
# direction it existed for.
#
# 8576 bytes of headroom below the cap covers the ConfigMap's own overhead.
#
# Do NOT raise LIMIT to "fit one more part" — raise --parts instead (and wire
# the extra ConfigMap through dar-deploy-job.yaml + dar-deploy.sh).
LIMIT=1040000
CHUNK=$(( (SIZE + PARTS - 1) / PARTS ))
if [ "$CHUNK" -gt "$LIMIT" ]; then
  echo "FATAL: DAR is $SIZE bytes; each of $PARTS parts is $CHUNK bytes, over the $LIMIT-byte per-part budget (the API server's 1048576-byte ConfigMap cap, less headroom)." >&2
  echo "       Re-run with --parts $((PARTS + 1)) AND add the extra ConfigMap volume/mount to dar-deploy-job.yaml" >&2
  echo "       plus the extra 'cat' input in dar-deploy.sh." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Slice the DAR into PARTS contiguous chunks: part n = bytes [(n-1)*CHUNK, n*CHUNK).
n=1
while [ "$n" -le "$PARTS" ]; do
  head -c "$(( n * CHUNK ))" "$DAR" | tail -c "+$(( (n - 1) * CHUNK + 1 ))" > "$TMP/p$n"
  n=$((n + 1))
done

b64() { base64 < "$1" | tr -d '\n'; }
sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

n=1
while [ "$n" -le "$PARTS" ]; do
  {
    echo "---"
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: $PREFIX$n"
    echo "  namespace: $NAMESPACE"
    echo "  labels:"
    echo "    app: dar-deploy"
    echo "    component: dar-part"
    echo "binaryData:"
    printf '  dar.b64: %s\n' "$(b64 "$TMP/p$n")"
  } > "$OUT_DIR/$PREFIX$n.yaml"
  n=$((n + 1))
done

part_sizes=""
n=1
while [ "$n" -le "$PARTS" ]; do
  part_sizes="$part_sizes part$n=$(wc -c < "$TMP/p$n" | tr -d ' ')"
  n=$((n + 1))
done
echo "DAR:      $DAR"
echo "size:     $SIZE bytes ($PARTS parts:$part_sizes)"
echo "sha256:   $(sha256 "$DAR")"
echo "wrote:    $OUT_DIR/$PREFIX{1..$PARTS}.yaml"
echo "REMINDER: bump DAR_VERSION and DAR_DEPLOY_JOB_VERSION in your env ConfigMap,"
echo "          or Flux will not re-run the (immutable, completed) deploy Job."
