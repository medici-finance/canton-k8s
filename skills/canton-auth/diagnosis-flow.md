# Diagnosis Flow

For each of the five recurring Canton auth failure classes: the symptom, the discriminating probe, the root cause, and the fix. All deployment-specific values are parameterized — replace the `$CONFIG_*` variables with values from your `config.yaml` before running any probe.

---

## Class 1: `userId` != token `sub`

**Symptom.** Admin operations (party allocation, user create, DAR upload, `GrantUserRights`) all succeed. Every command submission (`SubmitAndWait`) returns HTTP 403 with body `{"cause":"A security-sensitive error has been received"}`. The admin path looks healthy, so the failure reads like a rights problem. It is not.

**Discriminating probe.** Replay the failing `SubmitAndWait` call, then immediately grep the participant log:

```bash
# Replay the failing command with the exact same token, URL, headers, and body.
curl -s -X POST "$CONFIG_PARTICIPANT_URL/v2/commands/submit-and-wait" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$COMMAND_BODY"

# Grep the participant log within the retention window (typically 1-2 minutes).
$CONFIG_PARTICIPANT_LOG_COMMAND --since=1m | grep "userId"
```

The unmasked log line reads:
```
PERMISSION_DENIED: Claims are only valid for userId '<token_sub>', actual userId is '<submission_userId>'
```

If you see this line, the failure class is confirmed.

**Root cause.** Canton's `Authorizer` requires that the submission's `userId` field equals the token's `sub` claim on every `SubmitAndWait`. `ClaimAdmin` does not waive this check — it gates admin operations, not command submissions. Admin operations carry no submission `userId`, so they pass regardless of the mismatch.

**Fix.** Set the submission `userId` to the token's `sub`. If minting programmatically:

```python
# Decode the token to extract sub, then use it in the submission.
import jwt
claims = jwt.decode(token, options={"verify_signature": False})
submission_user_id = claims["sub"]
```

**Caution.** A 400 (`COMMAND_PREPROCESSING_FAILED`) means the command arguments are malformed and the Authorizer check was never reached. Fix the arguments first; a 400 tells you nothing about whether the `userId` is correct.

**Typed-client invariant.** A typed submission client refuses to emit a `SubmitAndWait` whose `userId` differs from the token's `sub`. The invariant is checked at the serialization boundary, so the mismatch never reaches the wire.

---

## Class 2: Issuer/JWKS split

**Symptom.** Every RS256 token returns 401 on every endpoint, including `/v2/state/ledger-end`. An HS256 dev token works fine, so health checks pass and the investigation goes in the wrong direction.

**Step 1: check whether the RS256 validator was loaded (cheaper to rule out first).**

```bash
$CONFIG_PARTICIPANT_LOG_COMMAND | grep "auth-services"
```

If the output shows only `[hs256]` with no JWKS entry, the RS256 validator was never loaded. Skip to fix A. If the output includes a JWKS entry, proceed to step 2.

**Fix A: validator not loaded.** The participant image concatenates `ADDITIONAL_CONFIG_*` environment variables alphabetically. An assignment variable that sorts before an append variable silently overwrites it. Name the JWKS append variable to sort after any assignment variable (e.g. use a `Z`-prefix or namespace it late in the alphabet), and use HOCON append syntax:

```hocon
# Correct: bare object append, sorts after DISABLE_AUTH.
ADDITIONAL_CONFIG_Z_JWT_JWKS = += {
  type = jwt-jwks
  url = $CONFIG_JWKS_URL
  target-audience = https://canton.network.global
}
```

**Step 2: validator loaded but JWKS unreachable.** If the validator exists but RS256 still 401s, the JWKS fetch is failing — typically because the participant JVM does not trust the TLS certificate at the JWKS URL.

```bash
$CONFIG_PARTICIPANT_LOG_COMMAND | grep -E "JwtException|null|cert|trust"
```

**Fix B: JWKS unreachable.** Use the split pattern that has become Canton convention:

- **Mint tokens from the public IdP URL** — so the `iss` claim matches the IdP-config `issuer`: `$CONFIG_IDP_ISSUER`
- **Fetch JWKS over in-cluster HTTP** — eliminates TLS validation: `$CONFIG_JWKS_URL` (must be an `http://` URL, not `https://`)

The two URLs differ on purpose. The issuer is public; the JWKS endpoint is internal.

**Typed-client invariant.** A typed client reads the IdP issuer from config and constructs the JWKS URL from cluster-internal coordinates. It never uses the public URL for JWKS fetches. It mints tokens against the public issuer only.

---

## Class 3: Masked security-sensitive error

**Symptom.** The JSON API returns HTTP 403 or 500 with body:
```json
{"cause":"A security-sensitive error has been received"}
```
No reason code. No discriminating field. No hint about the actual failure.

**Discriminating probe.** The full error lives in the participant log, retained for approximately 1-2 minutes. Replay the failing call, then grep immediately:

```bash
# Replay the exact failing command.
curl -s -X POST "$CONFIG_PARTICIPANT_URL/v2/commands/submit-and-wait" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$COMMAND_BODY"

# Grep the participant log for the real error.
$CONFIG_PARTICIPANT_LOG_COMMAND --since=1m | grep -E "PERMISSION_DENIED|UNAUTHENTICATED|INVALID_ARGUMENT|grpcCodeValue|ujson"
```

**Grep pattern → failure class lookup:**

| Log pattern | Actual failure |
|---|---|
| `PERMISSION_DENIED: Claims are only valid for userId` | userId != sub (Class 1) |
| `PERMISSION_DENIED: The caller does not hold the right CanActAs` | Missing per-party right |
| `grpcCodeValue:7 ledger_api_error:"invalid token"` | User exists but lacks rights for this specific party |
| `ujson.Str (data: N)` | DAML Int/Numeric sent as bare JSON number (Class 4) |
| `UNAUTHENTICATED` + `JwtException` | RS256 validation failure (Class 2) |

**Recovery.** Once the log line identifies the actual failure class, follow that class's fix recipe. Do not change config until the layer is identified — a JWKS failure fixed by editing Keycloak realm config is a wasted hour.

**Why this cannot be prevented structurally.** The mask lives in Canton's API, not in the client. A typed client can automate the correlation — emit the log-grep command alongside every non-2xx response — but it cannot remove the mask. This is the one class where the skill (cure) remains necessary even with a typed client (vaccine).

---

## Class 4: DAML Int/Numeric sent as bare JSON number

**Symptom.** A `SubmitAndWait` with a command body that looks correct — e.g. `{"settlementDelaySeconds": 3600}` — returns a masked 500. The body validates against any standard JSON Schema. The field value is a perfectly ordinary integer.

**Discriminating probe.** Grep the participant log for the JSON serialization error:

```bash
$CONFIG_PARTICIPANT_LOG_COMMAND --since=1m | grep "ujson"
```

If the log contains `ujson.Str (data: N)`, a DAML `Int` or `Numeric` field was sent as a bare JSON number.

**Root cause.** The Canton JSON API requires DAML `Int` and `Numeric` values as quoted strings:

| DAML type | Correct JSON API encoding | Incorrect (rejected) |
|---|---|---|
| `Int` | `"3600"` | `3600` |
| `Numeric 10` | `"1.5"` | `1.5` |
| `Time` | `"2026-07-19T00:00:00Z"` | (same format, but note: `Time` is the only primitive that maps to a bare JSON string; `Int` and `Numeric` also become strings despite being numeric in DAML) |
| `Bool` | `true` / `false` | Correct as bare boolean |
| `Text` | `"hello"` | Correct as bare string |

**Fix.** Stringify every `Int` and `Numeric` value before serialization. Identify the offending field from the `data: N` value in the log line.

**Typed-client invariant.** A typed client stringifies every `Int` and `Numeric` value at the serialization boundary. The invariant is type-level: a field typed as `DAML.Int` cannot be serialized as a JSON number, and the compiler or runtime type-checker enforces this at every call site.

---

## Class 5: Party hint used instead of full `hint::fingerprint` identity

**Symptom.** A submission references a party by its hint (e.g. `oracle`, `admin`, `user-abc123`). The create call returns an error about an unknown party, sometimes showing a partial fingerprint: `unknown party: oracle::1220...`. The operator checks the party list, confirms a party with that hint exists, and cannot understand the rejection.

**Discriminating probe.** List all parties and compare the submission's party reference against the full identities:

```bash
curl -s "$CONFIG_PARTICIPANT_URL/v2/parties" \
  -H "Authorization: Bearer $TOKEN" | jq '.data.partyDetails[].party'
```

Every entry is a full `hint::fingerprint` identity. If the submission used only the hint portion, it will not match any entry.

**Root cause.** Canton parties have a two-part identity: `hint::fingerprint`. The hint is a human-readable prefix. The fingerprint is a hex string derived from the allocating transaction. The hint alone is not an identity — two parties with the same hint but different fingerprints are different parties.

Error messages sometimes truncate the fingerprint (`oracle::1220...`), which looks like garbled output rather than a truncated real identity. The truncation is cosmetic in the error message; the actual identity is always the full `hint::fingerprint` string.

**Fix.** Resolve party aliases to full identities before submission. The canonical resolution order:

1. `GET /v2/parties` — returns every visible party with its full identity.
2. The `AllocateParty` response — the `partyDetails.party` field at creation time.
3. Never: a hint alone, a config file that lists only hints, or an error message showing a truncated fingerprint.

**Typed-client invariant.** A typed client resolves every human-readable party alias to its full `hint::fingerprint` identity once, at startup or manifest-load. All subsequent submissions use the resolved full identities. The client never sends a bare hint to the participant. After a wipe-and-redeploy (fingerprint values change), the client re-resolves on restart — no manual alias update is needed.

---

## General diagnostic rules

1. **Identify the layer before changing anything.** The five classes span token claims (class 1, 2), participant rights (class 3 sub-cases), JSON serialization (class 4), and party identity (class 5). Editing config in the wrong layer is the most common waste of time.
2. **Always decode the token first.** `iss`, `sub`, `aud`, `scope`, `exp` — all five must be correct before any other diagnosis is reliable.
3. **Always check the user's granted rights.** A perfectly decoded token is necessary but not sufficient. `GET /v2/users/<sub>/rights` (no `?identity-provider-id=` unless you run multiple IdPs) tells you what the Canton user can actually do. Do not assume a grant succeeded because the API returned 200 — read it back.
4. **An HS256 token that works masks every RS256 failure above.** Never conclude "auth is fine" from an HS256 token. Diagnose the RS256 path.
5. **A 400 is not an auth verdict.** `COMMAND_PREPROCESSING_FAILED` (HTTP 400) short-circuits before the Authorizer runs. Fix the arguments before trusting any auth diagnosis.
