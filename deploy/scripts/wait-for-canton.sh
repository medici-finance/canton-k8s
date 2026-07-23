#!/bin/sh
# Wait until the Canton JSON API answers HTTP at all. NOTE: no `curl -f` —
# an unauthenticated /v2/packages legitimately answers 401, and that still
# proves the API is up. $API is injected by the Job env.
set -eu
echo "Waiting for Canton JSON API ($API)..."
until curl -s -o /dev/null --max-time 5 "$API/v2/packages"; do
  echo "  ...not ready yet"
  sleep 10
done
echo "Canton ready."
