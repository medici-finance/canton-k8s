#!/usr/bin/env bash
# probe-canton.sh — quick Canton health + state summary.
#
# Env (defaults suit the canton-admin pod; override for local use):
#   CANTON_URL   Canton JSON API v2 base URL            (required)
#   TOKEN_FILE   file holding an admin bearer token     (default in-pod mount)
#   ADMIN_TOKEN  token literal — overrides TOKEN_FILE
#
# NOTE (scripts shipped via Flux-substituted ConfigMaps): keep this file free
# of bash colon-dash/colon-equals default expansions (VAR:-x, VAR:=x) — Flux's postBuild envsubst
# evaluates those forms at apply time.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok() { echo -e "${GREEN}OK${NC}  $*"; }
bad() { echo -e "${RED}FAIL${NC} $*"; }

# read env safely under set -u without colon-dash default expansions (see note above)
CANTON_URL=$(printenv CANTON_URL || true)
TOKEN_FILE=$(printenv TOKEN_FILE || true)
ADMIN_TOKEN=$(printenv ADMIN_TOKEN || true)
if [ -z "$CANTON_URL" ]; then bad "CANTON_URL not set"; exit 1; fi
if [ -z "$TOKEN_FILE" ]; then TOKEN_FILE=/etc/canton-admin/token; fi
if [ -z "$ADMIN_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then ADMIN_TOKEN=$(cat "$TOKEN_FILE"); fi
if [ -z "$ADMIN_TOKEN" ]; then
  bad "No admin token — set ADMIN_TOKEN or provide TOKEN_FILE"
  exit 1
fi

# ledger-end
LE=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$CANTON_URL/v2/state/ledger-end" 2>&1)
OFFSET=$(echo "$LE" | jq -r '.offset // empty' 2>/dev/null)
if [ -n "$OFFSET" ]; then
  ok "ledger-end: offset=$OFFSET"
else
  CODE=$(echo "$LE" | jq -r '.code // "FAIL"' 2>/dev/null)
  bad "ledger-end: $CODE"
fi

# packages
PKGS=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$CANTON_URL/v2/packages" 2>&1)
PKG_COUNT=$(echo "$PKGS" | jq -r '.packageIds | length' 2>/dev/null)
ok "packages: $PKG_COUNT loaded"

# parties (POST — the GET listing has been slow/unreliable on some builds)
PARTIES=$(curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d '{}' "$CANTON_URL/v2/parties" 2>&1)
P_COUNT=$(echo "$PARTIES" | jq -r '.partyDetails | length' 2>/dev/null)
ok "parties: $P_COUNT"

# users
USERS=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$CANTON_URL/v2/users" 2>&1)
U_COUNT=$(echo "$USERS" | jq -r '.users | length' 2>/dev/null)
ok "users: $U_COUNT"

echo "done."
