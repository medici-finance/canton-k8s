#!/usr/bin/env bash
# verify-user.sh — Canton auth diagnostics for a single user.
#
# Usage:
#   verify-user.sh <sub>            check user existence + granted rights
#   verify-user.sh --token <jwt>    also decode claims and probe the auth layer
#
# Env (defaults suit the canton-admin pod):
#   CANTON_URL   Canton JSON API v2 base URL            (required)
#   TOKEN_FILE   file holding an admin bearer token
#   ADMIN_TOKEN  token literal — overrides TOKEN_FILE
#   IDP_ISSUER_SUBSTRING  optional; warn when the token iss does not contain it
#
# Checks:
#   1. Canton user existence  (GET /v2/users/<sub>)
#   2. Granted rights         (GET /v2/users/<sub>/rights — NOTE: some Canton
#      builds mask this endpoint as security-sensitive for all tokens; an
#      empty/erroring result is then a limitation of the endpoint, not proof
#      of missing rights)
#   3. Token claims           (alg, iss, scope) — only in --token mode
#   4. ledger-end probe       (auth layer check) — only in --token mode
#
# NOTE (scripts shipped via Flux-substituted ConfigMaps): keep this file free
# of bash colon-dash/colon-equals default expansions (VAR:-x, VAR:=x) — Flux's postBuild envsubst
# evaluates those forms at apply time.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}OK${NC}   $*"; }
fail() { echo -e "${RED}FAIL${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }
hr()  { echo "------------------------------------------"; }

# read env safely under set -u without colon-dash default expansions (see note above)
CANTON_URL=$(printenv CANTON_URL || true)
TOKEN_FILE=$(printenv TOKEN_FILE || true)
ADMIN_TOKEN_IN=$(printenv ADMIN_TOKEN || true)
IDP_ISSUER_SUBSTRING=$(printenv IDP_ISSUER_SUBSTRING || true)
if [ -z "$CANTON_URL" ]; then fail "CANTON_URL not set"; exit 1; fi
if [ -z "$TOKEN_FILE" ]; then TOKEN_FILE=/etc/canton-admin/token; fi
if [ -z "$ADMIN_TOKEN_IN" ] && [ -f "$TOKEN_FILE" ]; then ADMIN_TOKEN_IN=$(cat "$TOKEN_FILE"); fi
if [ -z "$ADMIN_TOKEN_IN" ]; then
  fail "Admin token not set — set ADMIN_TOKEN or provide TOKEN_FILE"
  exit 1
fi

# The public JSON API wraps GET /v2/users/<id> in a "user" key; some builds
# return it flat. Handle both.
_user_val() { jq -r "(.user.$1 // .$1) // empty" 2>/dev/null; }

b64pad() {
  local s="$1" m
  m=$(( 4 - $( printf %s "$s" | wc -c | tr -d ' ' ) % 4 ))
  if [ "$m" = "4" ]; then m=0; fi
  printf '%s' "$s"
  local i=0
  while [ "$i" -lt "$m" ]; do printf '='; i=$((i+1)); done
}

# b64url_decode <segment> — decode one JWT segment.
#
# JWT segments are base64URL (RFC 7515 §2): where standard base64 spells '+'
# and '/', base64url spells '-' and '_'. `base64 -d` implements the STANDARD
# alphabet only — busybox (the reference ADMIN_IMAGE, alpine/k8s) and GNU
# coreutils both stop at the first '-' or '_' and emit truncated garbage. Any
# token carrying a non-ASCII claim value (a directory display name, say) hits
# those characters, and this diagnostic then decoded nothing.
#
# Translate the alphabet before decoding, and swallow a decode failure: the
# caller checks for an empty result and prints the script's own diagnostic. An
# unguarded failure here would abort the whole script under `set -e -o pipefail`
# with a bare exit status and no message at all.
b64url_decode() {
  b64pad "$1" | tr '_-' '/+' | base64 -d 2>/dev/null || true
}

SUB=""; TOKEN=""; PAYLOAD=""
if [ $# -eq 0 ]; then
  echo "Usage: verify-user.sh <sub> | verify-user.sh --token <jwt>"
  exit 1
fi
if [ "$1" = "--token" ]; then
  TOKEN="$2"
  PAYLOAD=$(echo "$TOKEN" | cut -d. -f2)
  SUB=$(b64url_decode "$PAYLOAD" | jq -r '.sub // empty' 2>/dev/null || true)
  if [ -z "$SUB" ]; then
    fail "Could not decode sub from token"
    exit 1
  fi
  echo "sub=$SUB (from token)"
else
  SUB="$1"
fi

echo "target user: $SUB"
hr

# 1. Canton user existence
echo -n "Canton user exists?  "
USER_RESP=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN_IN" "$CANTON_URL/v2/users/$SUB" 2>&1)
USER_ID=$(echo "$USER_RESP" | _user_val id)
if [ -n "$USER_ID" ]; then
  PP=$(echo "$USER_RESP" | _user_val primaryParty)
  pass "YES  primaryParty=$PP"
else
  CODE=$(echo "$USER_RESP" | jq -r '.code // "UNKNOWN"' 2>/dev/null)
  fail "NO  code=$CODE"
  echo "  -> the token sub must equal an existing Canton user id; create the user or fix the sub"
  exit 1
fi

# 2. Granted rights
echo -n "Granted rights?      "
RIGHTS_RESP=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN_IN" "$CANTON_URL/v2/users/$SUB/rights" 2>&1)
RIGHTS_COUNT=$(echo "$RIGHTS_RESP" | jq -r '.rights | length' 2>/dev/null)
if [ -z "$RIGHTS_COUNT" ]; then RIGHTS_COUNT=0; fi
if [ "$RIGHTS_COUNT" -gt 0 ]; then
  pass "$RIGHTS_COUNT right(s)"
  echo "$RIGHTS_RESP" | jq -r '.rights[]? | "    \(.kind | keys[0]): \(.kind[.kind|keys[0]].value.party // "-")"' 2>/dev/null
else
  warn "none visible (either no rights granted, or this Canton build masks the rights endpoint)"
fi

# 3. Token-based probes
if [ -n "$TOKEN" ]; then
  hr
  echo "token-based probes:"

  echo -n "Token claims?        "
  ALG=$(b64url_decode "$(echo "$TOKEN" | cut -d. -f1)" | jq -r '.alg // "?"' 2>/dev/null || true)
  if [ -z "$ALG" ]; then ALG="?"; fi
  CLAIMS=$(b64url_decode "$PAYLOAD")
  ISS=$(echo "$CLAIMS" | jq -r '.iss // empty' 2>/dev/null || true)
  SCOPE=$(echo "$CLAIMS" | jq -r '.scope // empty' 2>/dev/null || true)
  flags=""
  if [ "$ALG" != "RS256" ]; then flags="$flags alg=$ALG"; fi
  if [ -n "$IDP_ISSUER_SUBSTRING" ]; then
    case "$ISS" in *"$IDP_ISSUER_SUBSTRING"*) ;; *) flags="$flags iss!";; esac
  fi
  case "$SCOPE" in *daml_ledger_api*) ;; *) flags="$flags scope!";; esac
  if [ -z "$flags" ]; then
    pass "alg=$ALG iss=$ISS scope=$SCOPE"
  else
    warn "alg=$ALG iss=$ISS scope=$SCOPE [$flags]"
  fi

  echo -n "ledger-end?          "
  LE_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "$CANTON_URL/v2/state/ledger-end" 2>&1)
  LE_OFFSET=$(echo "$LE_RESP" | jq -r '.offset // empty' 2>/dev/null)
  if [ -n "$LE_OFFSET" ]; then
    pass "offset=$LE_OFFSET"
  else
    LE_CODE=$(echo "$LE_RESP" | jq -r '.code // "NA"' 2>/dev/null)
    LE_GRPC=$(echo "$LE_RESP" | jq -r '.grpcCodeValue // "?"' 2>/dev/null)
    fail "grpc=$LE_GRPC code=$LE_CODE  (token rejected at auth layer)"
  fi
fi

hr
echo "done."
