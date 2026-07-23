#!/bin/sh
# Gate on validator-app readiness: on a fresh Splice install the deploy Job
# can race ahead of validator-app and fail hard before it ever reaches
# Running; participant-only readiness is not enough. validator-app's own
# readinessProbe polls /api/validator/readyz unauthenticated and only 200s
# once truly ready, so `curl -f` here is a correct hard gate (unlike
# wait-for-canton.sh — see the 401 note there). $VALIDATOR_URL is injected
# by the Job env.
set -eu
echo "Waiting for validator-app ($VALIDATOR_URL)..."
until curl -sf -o /dev/null --max-time 5 "$VALIDATOR_URL/api/validator/readyz"; do
  echo "  ...not ready yet"
  sleep 10
done
echo "Validator-app ready."
