#!/bin/sh
# Wait until the Canton JSON API actually answers.
#
# This used to be a bare `curl -s`, which succeeds on ANY HTTP response — so a
# 502 from an ingress with no backend read as "Canton ready." and the deploy
# marched on against a participant that was not there. Gate on the status code
# instead. NOTE: still no `curl -f` — an unauthenticated /v2/packages
# legitimately answers 401 (or 403), and that IS proof the API is up; a 5xx, a
# 404 from an ingress with no matching rule, or no response at all is not.
# The status is printed on every retry so a stuck wait names its own cause.
# $API is injected by the Job env.
set -eu
echo "Waiting for Canton JSON API ($API)..."
while true; do
  CODE=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$API/v2/packages") || CODE=000
  case "$CODE" in
    2[0-9][0-9] | 401 | 403)
      echo "Canton ready (HTTP $CODE)."
      break
      ;;
    000)
      echo "  ...not ready yet (no HTTP response)"
      ;;
    *)
      echo "  ...not ready yet (HTTP $CODE — an HTTP response, but not an API answer)"
      ;;
  esac
  sleep 10
done
