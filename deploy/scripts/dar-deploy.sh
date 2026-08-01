#!/usr/bin/env bash
# dar-deploy.sh — upload a DAR to a Canton participant (JSON API v2) and
# verify the result on-ledger. Generic: knows nothing about your templates.
#
# Inputs (env, set by dar-deploy-job.yaml):
#   API                  Canton JSON API v2 base URL
#   PACKAGE_NAME         DAML package name (zip entries look like
#                        <name>-<version>-<package-id>/...)
#   EXPECTED_DAR_VERSION version the DAR ConfigMaps must hold (fail closed)
# Mounts:
#   /etc/dar/part1..part3/dar.b64   raw DAR slices (from gen-dar-configmaps.sh)
#   /etc/dar/admin/token            admin bearer token
#
# Exit contract: prints exactly one "RESULT: ..." line on success —
#   RESULT: UPLOADED         a new package landed on the ledger
#   RESULT: ALREADY-CURRENT  the ledger already had this exact package
# Anything else (FATAL + non-zero exit) means the deploy did NOT converge.
#
# NOTE (scripts shipped via Flux-substituted ConfigMaps): keep this file free
# of bash colon-dash/colon-equals default expansions (VAR:-x, VAR:=x) — Flux's postBuild envsubst
# evaluates those forms. Plain "$VAR" with names outside the documented
# substitution set is safe.
set -euo pipefail

# HARDENING TODO (finding CK13): this Job installs its own dependencies at
# deploy time, so EVERY deploy needs egress to a Debian mirror and races
# whatever state that mirror is in — an outage or a moved package turns a
# routine DAR upload into a failed deploy for reasons unrelated to the DAR.
# The fix is a base image that already ships curl + unzip; set
# dar-deploy-job.yaml's image to one and this block becomes a no-op.
# Until then it is at least conditional: an image that already has the tools is
# never touched, and an install failure falls through to the explicit checks
# below so the operator gets a named tool rather than an apt-get traceback.
if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  echo "  installing curl/unzip at deploy time (needs egress to the package mirror)"
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl unzip >/dev/null 2>&1 || true
fi
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl not installed"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "FATAL: unzip not installed"; exit 1; }

echo "============================================"
echo "  DAR deploy — package $PACKAGE_NAME, expected version $EXPECTED_DAR_VERSION"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================"

if [ -z "$API" ] || [ -z "$PACKAGE_NAME" ] || [ -z "$EXPECTED_DAR_VERSION" ]; then
  echo "FATAL: API, PACKAGE_NAME and EXPECTED_DAR_VERSION must all be set"
  exit 1
fi

# `|| true` for the same reason as below: a missing token mount made `cat` fail,
# and pipefail then aborted the script before this FATAL could name the problem.
TOKEN=$(cat /etc/dar/admin/token 2>/dev/null | tr -d '\n\r' | xargs || true)
if [ -z "$TOKEN" ]; then
  echo "FATAL: admin token is empty or /etc/dar/admin/token is not mounted"
  exit 1
fi
AUTH="Authorization: Bearer $TOKEN"

# ── Reassemble the DAR from the part ConfigMaps ─────────────────────────────
cat /etc/dar/part1/dar.b64 /etc/dar/part2/dar.b64 /etc/dar/part3/dar.b64 > /tmp/app.dar
DAR_SIZE=$(wc -c < /tmp/app.dar | tr -d ' ')
echo "  DAR size: $DAR_SIZE bytes"
if [ "$DAR_SIZE" -lt 1000 ]; then
  echo "FATAL: DAR too small ($DAR_SIZE bytes) — check the dar-part ConfigMaps"
  exit 1
fi

# ── Version gate (fail closed) ──────────────────────────────────────────────
# The ConfigMaps are the ONLY DAR this Job can deploy — it does not build from
# source. If they are stale, the upload is a silent no-op that reports
# success. Fail loudly instead.
#
# `|| true` is load-bearing, not decoration: this runs under `set -o pipefail`
# inside a command substitution, so on the commonest first-run failure — a
# PACKAGE_NAME that does not match this DAR — grep matched nothing, the
# substitution returned non-zero, and the script died on the spot with a bare
# exit status. The fail-closed diagnostic below never printed. Tolerate the
# empty match, then say what actually went wrong.
DAR_VERSION=$(unzip -l /tmp/app.dar 2>/dev/null | grep -oE "$PACKAGE_NAME-[0-9]+\.[0-9]+\.[0-9]+" | head -n1 | sed "s/^$PACKAGE_NAME-//" || true)
if [ -z "$DAR_VERSION" ]; then
  echo "FATAL: no entry matching '$PACKAGE_NAME-<major>.<minor>.<patch>' inside the DAR."
  echo "       Either PACKAGE_NAME is wrong for this DAR, or the dar-part ConfigMaps do not hold a DAR."
  echo "       The archive's own entries are:"
  unzip -l /tmp/app.dar 2>/dev/null | head -n 12 || echo "       (not a readable zip archive)"
  exit 1
fi
echo "  DAR version (from ConfigMaps): $DAR_VERSION"
if [ "$DAR_VERSION" != "$EXPECTED_DAR_VERSION" ]; then
  echo "FATAL: DAR ConfigMaps hold '$DAR_VERSION' but this Job expects '$EXPECTED_DAR_VERSION'."
  echo "       Regenerate the dar-part ConfigMaps (gen-dar-configmaps.sh) and bump the Job name."
  exit 1
fi

# ── Upload ──────────────────────────────────────────────────────────────────
# fetch_packages <label> — list the package ids the participant reports, into
# /tmp/package-ids.txt. Returns non-zero, after printing a FATAL naming the HTTP
# status, when the listing itself failed.
#
# The previous form was `curl … | grep -oE '[0-9a-f]{64}' | …` inside a command
# substitution under `set -o pipefail`. On the other common first-run failure —
# a wrong or expired admin token — the 401 body carries no package hashes, grep
# matched nothing, and the script died with a bare exit status: no HTTP code, no
# body, nothing to distinguish "bad token" from "API unreachable". So: check the
# status explicitly, and tolerate an empty grep rather than dying on it.
fetch_packages() {
  local label="$1" http
  http=$(curl -sS --connect-timeout 10 --max-time 60 -H "$AUTH" \
    -o /tmp/packages.json -w '%{http_code}' "$API/v2/packages") || http="000"
  if [ "$http" != "200" ]; then
    echo "FATAL: could not list packages $label — HTTP $http from $API/v2/packages"
    echo "       401/403: the admin token is missing, expired, or lacks participant_admin."
    echo "       000:     the API was unreachable within the timeout."
    echo "       response body (first 500 bytes):"
    head -c 500 /tmp/packages.json 2>/dev/null || true
    echo
    return 1
  fi
  grep -oE '[0-9a-f]{64}' /tmp/packages.json | sort -u > /tmp/package-ids.txt || true
}

fetch_packages "before upload" || exit 1
BEFORE=$(tr '\n' ' ' < /tmp/package-ids.txt)
BEFORE_COUNT=$(wc -w < /tmp/package-ids.txt | tr -d ' ')
echo "  Packages before upload: $BEFORE_COUNT"

curl -sS --connect-timeout 10 --max-time 120 \
  -H "Content-Type: application/octet-stream" -H "$AUTH" \
  --data-binary @/tmp/app.dar \
  -o /tmp/upload-response.txt -w '%{http_code}' \
  "$API/v2/packages" > /tmp/upload-http.txt 2>/tmp/upload-err.txt || true
UPLOAD_HTTP=$(cat /tmp/upload-http.txt 2>/dev/null || echo "000")
if [ "$UPLOAD_HTTP" != "200" ] && [ "$UPLOAD_HTTP" != "201" ]; then
  echo "FATAL: DAR upload failed (HTTP $UPLOAD_HTTP)"
  head -c 500 /tmp/upload-response.txt || true
  exit 1
fi
echo "  Upload: HTTP $UPLOAD_HTTP"

fetch_packages "after upload" || exit 1
AFTER=$(tr '\n' ' ' < /tmp/package-ids.txt)
AFTER_COUNT=$(wc -w < /tmp/package-ids.txt | tr -d ' ')
echo "  Packages after upload: $AFTER_COUNT (before: $BEFORE_COUNT)"

PKG_HASH=$(grep -oE '[0-9a-f]{64}' /tmp/upload-response.txt | head -n1 || true)
if [ -z "$PKG_HASH" ]; then
  for id in $AFTER; do
    case " $BEFORE " in *" $id "*) ;; *) PKG_HASH="$id"; break;; esac
  done
fi

# ── Verify ──────────────────────────────────────────────────────────────────
echo "Verifying package..."
if [ -z "$PKG_HASH" ]; then
  # Legitimate no-op: re-uploading the same DAR yields no new package, so
  # there is no before/after diff to derive the package-id from. But the DAR
  # carries its own id: every zip entry lives under
  # "<name>-<version>-<package-id>/". Verify ALREADY-CURRENT as: the DAR's
  # own id is present in the fresh /v2/packages listing.
  echo "  NO-OP: package set did not advance — verifying ALREADY-CURRENT..."
  DAR_SELF_ID=$(unzip -l /tmp/app.dar 2>/dev/null | grep -oE "$PACKAGE_NAME-[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{64}" | head -n1 | grep -oE '[0-9a-f]{64}' || true)
  if [ -z "$DAR_SELF_ID" ]; then
    echo "FATAL: could not read the package id from the DAR's own entries."
    exit 1
  fi
  case " $AFTER " in
    *" $DAR_SELF_ID "*) ;;
    *)
      echo "FATAL: upload was a no-op but the DAR's own package id $DAR_SELF_ID is not in /v2/packages — contradictory ledger state."
      exit 1
      ;;
  esac
  PKG_HASH="$DAR_SELF_ID"
fi

case " $BEFORE " in
  *" $PKG_HASH "*) UPLOAD_RESULT="ALREADY-CURRENT" ;;
  *) UPLOAD_RESULT="UPLOADED" ;;
esac

# Final round-trip: the id must be listed on the ledger we just talked to.
# (A failed listing here is now reported as a failed listing — it used to be
# indistinguishable from "the package is missing", because the same
# `curl | grep -q` pipeline produced non-zero for both.)
fetch_packages "for the final round-trip" || exit 1
case " $(tr '\n' ' ' < /tmp/package-ids.txt) " in
  *" $PKG_HASH "*) ;;
  *)
    echo "FATAL: package $PKG_HASH not found on re-listing"
    exit 1
    ;;
esac

if [ "$UPLOAD_RESULT" = "UPLOADED" ]; then
  echo "RESULT: UPLOADED — new package $PKG_HASH (packages: $BEFORE_COUNT -> $AFTER_COUNT)"
else
  echo "RESULT: ALREADY-CURRENT — the DAR upload was a NO-OP."
  echo "(version $DAR_VERSION = EXPECTED_DAR_VERSION, package $PKG_HASH verified against /v2/packages)"
  echo "Fine on a re-run; a RED FLAG right after a version bump — regenerate the dar-part ConfigMaps."
fi
