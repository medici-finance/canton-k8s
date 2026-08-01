#!/usr/bin/env bash
# mint-token.sh — mint a bearer token for Canton/Keycloak diagnostics.
#
# Usage:
#   mint-token.sh svc <client-id>       RS256 service token (client_credentials).
#                                       Secret from $CLIENT_SECRET, else
#                                       $CREDS_DIR/<client-id>-client-secret.
#   mint-token.sh user <username>       Per-user RS256 token (password grant via
#                                       the public frontend client). Password
#                                       from $KC_USER_PASSWORD, else
#                                       $CREDS_DIR/app-user-password.
#   mint-token.sh admin                 Keycloak master-realm admin token
#                                       (for the Keycloak Admin API). Creds from
#                                       $CREDS_DIR/admin-user + admin-password.
#   mint-token.sh hs256                 DEV-ONLY static HS256 token signed with
#                                       the Splice disableAuth shared secret
#                                       ("unsafe"). Works only on a participant
#                                       running the dev overlay. Use it ONLY to
#                                       confirm the participant is up — it masks
#                                       every RS256-path failure.
#
# Env (defaults suit the canton-admin pod):
#   KEYCLOAK_URL   public Keycloak base URL INCLUDING relative path (…/auth)
#   KC_REALM       realm name (e.g. AppUser)
#   KC_FRONTEND_CLIENT_ID  public client for the password grant
#   CREDS_DIR      directory of mounted credential files (optional)
#   CANTON_AUDIENCE  audience for the hs256 token (default
#                    https://canton.network.global)
#
# Compose:
#   T=$(mint-token.sh svc oracle-svc)
#   curl -s -H "Authorization: Bearer $T" "$CANTON_URL/v2/state/ledger-end"
#
# NOTE (scripts shipped via Flux-substituted ConfigMaps): keep this file free
# of bash colon-dash/colon-equals default expansions (VAR:-x, VAR:=x) — Flux's postBuild envsubst
# evaluates those forms at apply time.
set -euo pipefail

WHAT=""
if [ $# -ge 1 ]; then WHAT="$1"; fi
if [ -z "$WHAT" ]; then sed -n '2,27p' "$0" >&2; exit 2; fi

KEYCLOAK_URL=$(printenv KEYCLOAK_URL || true)
KC_REALM=$(printenv KC_REALM || true)
KC_FRONTEND_CLIENT_ID=$(printenv KC_FRONTEND_CLIENT_ID || true)
CREDS_DIR=$(printenv CREDS_DIR || true)
CANTON_AUDIENCE=$(printenv CANTON_AUDIENCE || true)
if [ -z "$KC_REALM" ]; then KC_REALM="AppUser"; fi
if [ -z "$CREDS_DIR" ]; then CREDS_DIR=/etc/canton-admin/creds; fi
if [ -z "$CANTON_AUDIENCE" ]; then CANTON_AUDIENCE="https://canton.network.global"; fi

cred() { cat "$CREDS_DIR/$1" 2>/dev/null || echo ""; }
_json_val() { jq -r ".$1 // empty" 2>/dev/null; }

# Secrets must not travel in curl's argv: /proc/<pid>/cmdline is world-readable,
# so `-d "password=$PW"` exposes the password to every process in the container
# for the life of the request. curl's `--data-urlencode name@file` reads the
# value from a file instead and URL-encodes it — which also fixes the separate
# bug that raw values (and the space in a two-word `scope`) were sent
# un-encoded into an application/x-www-form-urlencoded body.
SECRET_DIR=$(mktemp -d)
chmod 700 "$SECRET_DIR"
trap 'rm -rf "$SECRET_DIR"' EXIT
# write_secret <name> <value> — 0600 file, no trailing newline; prints its path.
# Shell function arguments live in this process's memory, not in any argv.
write_secret() {
  _f="$SECRET_DIR/$1"
  ( umask 077; printf %s "$2" > "$_f" )
  printf %s "$_f"
}
require_kc() {
  if [ -z "$KEYCLOAK_URL" ]; then
    echo "KEYCLOAK_URL not set (public Keycloak base URL incl. relative path)" >&2
    exit 1
  fi
}

TOKEN=""
case "$WHAT" in
  hs256)
    # DEV-ONLY god token: sub=ledger-api-user, HMAC key "unsafe" (the Splice
    # disableAuth model). This is not a secret — it is the documented dev
    # shared key; it grants nothing on an RS256-only (base) participant.
    HEADER='{"alg":"HS256","typ":"JWT"}'
    NOW=$(date +%s)
    EXP=$((NOW+86400))
    PAYLOAD="{\"sub\":\"ledger-api-user\",\"aud\":\"$CANTON_AUDIENCE\",\"exp\":$EXP,\"iat\":$NOW}"
    b64url() { openssl base64 -A | tr '/+' '_-' | tr -d '='; }
    H=$(printf %s "$HEADER" | b64url)
    P=$(printf %s "$PAYLOAD" | b64url)
    SIG=$(printf %s "$H.$P" | openssl dgst -sha256 -hmac "unsafe" -binary | b64url)
    TOKEN="$H.$P.$SIG"
    ;;

  admin)
    require_kc
    AUSER=$(cred admin-user)
    APW=$(cred admin-password)
    if [ -z "$APW" ]; then echo "no admin-password in $CREDS_DIR" >&2; exit 1; fi
    APW_FILE=$(write_secret admin-password "$APW")
    TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
      --data-urlencode 'grant_type=password' --data-urlencode 'client_id=admin-cli' \
      --data-urlencode "username=$AUSER" --data-urlencode "password@$APW_FILE" \
      --data-urlencode 'scope=openid' | _json_val access_token)
    ;;

  user)
    require_kc
    USERNAME=""
    if [ $# -ge 2 ]; then USERNAME="$2"; fi
    if [ -z "$USERNAME" ]; then echo "usage: mint-token.sh user <username>" >&2; exit 2; fi
    if [ -z "$KC_FRONTEND_CLIENT_ID" ]; then echo "KC_FRONTEND_CLIENT_ID not set" >&2; exit 1; fi
    UPW=$(printenv KC_USER_PASSWORD || true)
    if [ -z "$UPW" ]; then UPW=$(cred app-user-password); fi
    if [ -z "$UPW" ]; then echo "no user password — set KC_USER_PASSWORD or provide $CREDS_DIR/app-user-password" >&2; exit 1; fi
    UPW_FILE=$(write_secret user-password "$UPW")
    TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KC_REALM/protocol/openid-connect/token" \
      --data-urlencode 'grant_type=password' --data-urlencode "client_id=$KC_FRONTEND_CLIENT_ID" \
      --data-urlencode "username=$USERNAME" --data-urlencode "password@$UPW_FILE" \
      --data-urlencode 'scope=openid daml_ledger_api' | _json_val access_token)
    ;;

  svc)
    require_kc
    CLIENT_ID=""
    if [ $# -ge 2 ]; then CLIENT_ID="$2"; fi
    if [ -z "$CLIENT_ID" ]; then echo "usage: mint-token.sh svc <client-id>" >&2; exit 2; fi
    SECRET=$(printenv CLIENT_SECRET || true)
    if [ -z "$SECRET" ]; then SECRET=$(cred "$CLIENT_ID-client-secret"); fi
    if [ -z "$SECRET" ]; then echo "no secret — set CLIENT_SECRET or provide $CREDS_DIR/$CLIENT_ID-client-secret" >&2; exit 1; fi
    SECRET_FILE=$(write_secret client-secret "$SECRET")
    TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KC_REALM/protocol/openid-connect/token" \
      --data-urlencode 'grant_type=client_credentials' --data-urlencode "client_id=$CLIENT_ID" \
      --data-urlencode "client_secret@$SECRET_FILE" \
      --data-urlencode 'scope=basic audience_canton_network daml_ledger_api' | _json_val access_token)
    ;;

  *)
    echo "unknown subcommand '$WHAT' (svc|user|admin|hs256)" >&2
    exit 2
    ;;
esac

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "token mint failed (check creds / Keycloak reachability at $KEYCLOAK_URL)" >&2
  exit 1
fi
echo "$TOKEN"
