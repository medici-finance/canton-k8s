#!/usr/bin/env bash
# probe-canton.sh — quick Canton health + state summary.
#
# READ-ONLY. This script issues GETs and nothing else: a diagnostic that
# changes the system it measures is worse than no diagnostic.
#
# Exit status: 0 when every line reported OK, 1 when any line reported FAIL —
# so a caller can gate on it instead of scraping the output.
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

FAILED=0

# get <path> — GET the endpoint and echo whatever came back. Never aborts:
# curl exits non-zero when it cannot connect at all, and under
# `set -e -o pipefail` that killed the probe outright instead of reporting FAIL.
get() {
  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$CANTON_URL$1" 2>&1 || true
}

# json_len <body> <field> — echo the length of the named JSON array, or nothing
# when the body is not JSON, the field is absent, or it is not an array.
# `select(type=="array")` matters: on a 401 the body IS valid JSON, just without
# the field, and a bare `.field | length` answers 0 for null — a plausible-looking
# count that is really "the request failed".
# The previous code printed OK unconditionally, so a 502 HTML page from an
# ingress with no backend reported "packages:  loaded" — or, once jq failed
# under pipefail, killed the script before it printed anything at all.
json_len() {
  local n
  n=$(printf '%s' "$1" | jq -r ".$2 | select(type==\"array\") | length" 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$n"
}

# snippet <body> — first line of an unreadable body, for the FAIL line.
snippet() {
  printf '%s' "$1" | tr -d '\r' | head -n1 | cut -c1-100
}

# report <label> <body> <field> <suffix>
report() {
  local label="$1" body="$2" field="$3" suffix="$4" n
  n=$(json_len "$body" "$field")
  if [ -n "$n" ]; then
    ok "$label: $n$suffix"
  else
    bad "$label: no readable $field list — $(snippet "$body")"
    FAILED=1
  fi
}

# ledger-end
LE=$(get /v2/state/ledger-end)
OFFSET=$(printf '%s' "$LE" | jq -r '.offset // empty' 2>/dev/null || true)
if [ -n "$OFFSET" ]; then
  ok "ledger-end: offset=$OFFSET"
else
  CODE=$(printf '%s' "$LE" | jq -r '.code // empty' 2>/dev/null || true)
  if [ -z "$CODE" ]; then CODE="no readable answer — $(snippet "$LE")"; fi
  bad "ledger-end: $CODE"
  FAILED=1
fi

# packages
report "packages" "$(get /v2/packages)" packageIds " loaded"

# parties — a READ.
# /v2/parties answers a POST by ALLOCATING a party, and this probe used to send
# one (with an empty body). Every health check therefore minted a junk party on
# the ledger, and the "count" it printed was the field count of the allocation
# response, not the number of parties. GET is the read the skills/ docs already
# document, and the only listing endpoint there is — POST is allocate. If it is
# slow on your build, raise the timeout — never allocate from a diagnostic.
#
# GET /v2/parties is paginated (pageSize/pageToken), so on a participant with
# more parties than the server's default page this count is the first page, not
# the total. Still a read, and still honest about being a party count — unlike
# what it replaced.
report "parties" "$(get /v2/parties)" partyDetails ""

# users
report "users" "$(get /v2/users)" users ""

if [ "$FAILED" -ne 0 ]; then
  echo "done — WITH FAILURES (see FAIL lines above)."
  exit 1
fi
echo "done."
