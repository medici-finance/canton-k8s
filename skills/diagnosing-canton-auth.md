# How to diagnose auth issues on Canton

## The five failure classes every Canton dApp hits — and the diagnostic tooling that catches them

This article is the narrative companion to the runnable playbook in
[`skills/canton-auth/`](canton-auth/). The playbook gives you the probes; this
article gives you the architecture behind each failure — why the surface
symptom misleads, and how each class was actually diagnosed the first time
someone hit it. Read this for the why; use
[`canton-auth/diagnosis-flow.md`](canton-auth/diagnosis-flow.md) for the how.

---

### Abstract

Every team building on Canton eventually hits the same five auth failures. A
token that looks valid to `jwt.io` gets a masked 403 from the JSON API. An
admin call succeeds and a contract-create fails, identically, and the error
body says nothing useful. A `3600` that works as a number in every other
system is silently rejected as a DAML `Int`. A party name you typed by hand
404s because the real identity is `party::1220d6f8...` and the truncation in
the error message only shows the first few characters.

These failures are knowable — each has a root cause a few lines deep in
Canton's architecture — but they are not guessable from the surface symptoms.
They require a **diagnostic playbook**: a structured sequence of probes, log
correlations, and typed checks that isolates the layer before anything gets
changed. On a production Canton/Splice deployment we operated, we encoded that
playbook into an agent-runnable diagnostic skill and a set of typed-client
invariants that make four of the five failure classes structurally impossible.
The former is the cure (diagnose after breakage); the latter is the vaccine
(prevent the class). Both are published in this repository, parameterized for
any Canton deployment.

This article walks through the five failure classes — each as a case study in
what broke, why the surface symptom misled, and the discriminating probe that
found the root cause — then describes how the knowledge is encoded into
tooling an agent can run, so the next team does not need to rediscover it.

---

### 1. userId == sub: the Authorizer rule ClaimAdmin does not waive

**The failure.** On a clean-install deploy, every admin operation succeeds —
party allocation, user create, DAR upload, `GrantUserRights` all return green.
Then the first contract-create `SubmitAndWait` returns HTTP 403 with a body
that says only `{"cause":"A security-sensitive error has been received"}`. The
admin path looks entirely healthy, so the failure reads like a rights problem
or a Canton bug. It is neither.

**The root cause.** Canton's `Authorizer` checks, on every command submission,
that the submission's `userId` field equals the token's `sub` claim.
`ClaimAdmin` does **not** waive this check — it gates admin operations, not
command submissions. In the incident that taught us this, a deploy Job
authenticated with a token whose `sub` was `ledger-api-user` but sent every
submission with a `userId` naming a *different* Canton user — an admin
identity hardcoded into the Job's script. Canton rejected each submission with
`PERMISSION_DENIED` before ever consulting rights.

**Why the admin ops masked it.** Admin operations (`AllocateParty`, user
create, DAR upload, `GrantUserRights`) carry no submission `userId` and check
only `ClaimAdmin`. So they pass cleanly against any admin token while every
command submission fails silently. The fingerprint is specific and
counterintuitive: **admin calls succeed but contract creates 403** is a
`userId` mismatch, not a rights gap — the exact inversion of the usual "token
decodes fine but the Canton user lacks rights" diagnosis.

**The discriminating probe.** The real error lives only in the participant
log, not the API response body. Grep for:

```
PERMISSION_DENIED: Claims are only valid for userId '<sub>', actual userId is '<wrong>'
```

This line is retained for approximately one to two minutes, so the recipe is:
replay the failing command, then immediately run your
`participant_log_command` (in this base:
`kubectl logs deploy/participant -c participant --since=1m | grep "userId"`).
If the fix were structural rather than procedural, a typed submission client
would refuse to send a `userId` that differs from the token `sub` — one of the
invariants described in §6.

**Caution: a 400 does not prove submission auth passed.** Malformed command
arguments return `COMMAND_PREPROCESSING_FAILED` (HTTP 400) before the
Authorizer's `userId` check runs. Fix the arguments first; the 403 with the
`Authorizer` log line is the real auth verdict. A 400 tells you nothing about
whether the `userId` is correct.

The rule: **a command submission's `userId` must equal the token's `sub`
claim. Always.** No exception for admin. No exception for `ClaimAdmin`. If the
fix feels like a bash heredoc variable substitution, the problem is in the
tooling, not the operator — and the typed client is how you lift it out of the
operator's hands.

---

### 2. The issuer/JWKS split: mint public, verify internal

**The failure.** Every RS256 token returns 401 on every endpoint, even
`/v2/state/ledger-end`. The HS256 dev token works fine, so "Canton is up"
passes the health check and the investigation goes in the wrong direction. The
participant log shows `JwtException: null` or the more specific
`The provided Algorithm doesn't match the one defined in the JWT's Header`
paired with `IdentityProviderConfigByIssuerNotFound(<public issuer>)`.

This failure has two distinct root causes that produce identical symptoms, and
they must be disentangled before anything gets changed.

**Root cause A: the RS256 validator was never loaded.** The Splice participant
image concatenates `ADDITIONAL_CONFIG_*` environment variables
**alphabetically** at startup. The chart's `disableAuth` flag injects
`ADDITIONAL_CONFIG_DISABLE_AUTH` with an `auth-services = [hs256]`
**assignment**. If the JWKS append variable sorts alphabetically before
`DISABLE_AUTH` (e.g. `ADDITIONAL_CONFIG_AUTH_JWT_JWKS` — `A` < `D`), the
assignment silently overwrites it and the participant starts with only the
HS256 validator. The RS256 validator never exists, so every RS256 token fails
at the algorithm-mismatch gate regardless of JWKS reachability.

The fix is to name the append variable to sort after `DISABLE_AUTH` (this
base's dev overlay uses `ADDITIONAL_CONFIG_JWT_JWKS` — `J` > `D`; see
`examples/overlays/dev/patch-participant-dev-auth.yaml`) and use HOCON append
syntax: `+= { … }` as a bare object, not `[{…}]` which appends a nested list
and fails startup with `Expected type OBJECT. Found LIST`.

**Root cause B: JWKS unreachable due to TLS trust.** The participant's
`jwt-jwks` validator fetches the JSON Web Key Set over a URL whose TLS
certificate the participant JVM must trust. If the certificate is self-signed,
re-issued after a cold-start, or signed by an untrusted CA (a Let's Encrypt
rate limit falling back to a staging cert is a classic trigger), the fetch
fails — and the failure surfaces as `JwtException: null`, the same generic
401.

The fix is the split pattern that has become Canton convention: **mint tokens
from the public IdP URL** (so the `iss` claim matches the IdP-config
`issuer`), but **fetch JWKS over in-cluster HTTP** (so the TLS validation step
is eliminated entirely — no certificate to trust). The two URLs differ on
purpose: the issuer is public and the JWKS endpoint is internal. The JWKS
holds only public keys, so the in-cluster hop leaks nothing. In the
vocabulary of the [`canton-auth` skill config](canton-auth/config.example.yaml):

```yaml
# Correct split (dev example):
idp_issuer: "https://keycloak.dev.example.com/realms/app-users"
jwks_url:   "http://keycloak.canton-dev.svc.cluster.local:8080/realms/app-users/protocol/openid-connect/certs"
```

The split applies to **every server-side JWKS consumer**, not just the
participant — in this base the sv-app and validator-app `auth.jwksUrl` use the
same in-cluster HTTP form. Only browser-facing issuer URLs use the public
hostname.

**Diagnostic priority.** Check root cause A first — it is cheaper to rule out
(one `grep auth-services` on the participant pod's generated config) and it
masquerades as root cause B, the JWKS/TLS problem, and every other RS256
failure. If the `auth-services` line shows only `[hs256]` with no JWKS entry,
the validator was never loaded and no amount of JWKS-url tuning will help.

---

### 3. Unmasking a security-sensitive error: the replay-and-grep technique

**The failure.** The JSON API returns HTTP 403 or 500 with a body that says
exactly:

```json
{"cause":"A security-sensitive error has been received"}
```

That is the entire message. No reason code. No discriminating field. No hint
about whether the problem is a missing right, a wrong `userId`, a DAML type
error, or a participant-internal failure. The body is deliberately opaque —
Canton masks error details from API consumers to avoid leaking internal state.

**The technique.** The full error lives in the participant log, but the log
line is retained for only one to two minutes under normal load. The recipe:

1. Replay the failing command exactly — same method, URL, headers, body, and
   token.
2. Immediately grep the participant log for the correlation window:
   `kubectl logs deploy/participant -c participant --since=1m | grep -E "PERMISSION_DENIED|UNAUTHENTICATED|INVALID_ARGUMENT|grpcCodeValue"`
3. The real error message — the one Canton masked — appears in the log output
   within a single line that names the check that failed, the expected value,
   and the actual value.

This is not a one-off. It is a structured diagnostic step: replay, then grep,
never guess. The unmasked log line is the discriminating evidence; the API
response body is only a signal that *something* failed.

**What the unmasked lines look like, by failure class:**

| Masked API response | Log line (the real error) | Actual problem |
|---|---|---|
| 403 security-sensitive | `PERMISSION_DENIED: Claims are only valid for userId 'X', actual userId is 'Y' c.d.c.a.Authorizer, SubmitAndWait` | userId != sub (§1) |
| 403 security-sensitive | `PERMISSION_DENIED: The caller does not hold the right CanActAs(party::...)` | Missing per-party right |
| 403 security-sensitive | `grpcCodeValue:7 ledger_api_error:"invalid token"` | User exists but lacks rights for this specific party |
| 500 security-sensitive | `ujson.Str (data: 3600)` | DAML `Int` sent as bare JSON number (§4) |
| 400 COMMAND_PREPROCESSING_FAILED | N/A — short-circuits before auth | Malformed command arguments |

The technique works across all five failure classes. The only variation is the
log grep pattern, and the table above captures the ones known to recur.

**Encoding into tooling.** A typed Canton client can automate this: on any
non-2xx response, log the correlation ID, timestamp, and replay instructions
so the operator does not need to remember the recipe. The diagnostic skill
(§6) encodes the table above as a lookup the agent runs before changing
anything.

---

### 4. DAML-to-JSON typing: Int, Numeric, and Time are quoted strings

**The failure.** A command submission that works in every other JSON context —
a `3600` sent as a bare JSON number for a DAML `Int` field, or a
`1784419200000` epoch-millis sent for a DAML `Time` field — returns a masked
500 from the JSON API. The command body looks correct to any human reader and
validates against any standard JSON Schema. The failure reads like a Canton
bug.

**The root cause.** Canton's JSON API uses a specific encoding for DAML types
that does not match JSON conventions:

| DAML type | JSON API encoding | Wrong (rejected) |
|---|---|---|
| `Int` | `"3600"` (quoted string) | `3600` (bare number) |
| `Numeric 10` | `"1.5"` (quoted string) | `1.5` (bare number) |
| `Time` | `"2026-07-19T00:00:00Z"` (string) | Correctly a string |
| `Text`, `Party`, `ContractId`, `Date` | strings | Correctly strings |

`Text`, `Party`, `ContractId`, `Date` and `Time` are string-valued in DAML, so
their string encoding surprises nobody. `Int` and `Numeric` are the outliers:
they are *numeric* in DAML and still arrive and leave as **quoted** strings.
That asymmetry — not the existence of string-valued primitives — is the whole
failure mode.

The JSON API wraps DAML `Int` and `Numeric` values in a `ujson.Str`
constructor internally. A bare JSON number is rejected at the serialization
boundary before the DAML interpreter ever sees it, producing a masked error
with `ujson.Str (data: 3600)` in the participant log.

**The diagnostic rule.** If a command submission that looks correct returns a
masked 500, grep the participant log for `ujson.Str` or `ujson.Num`. The
presence of either pattern means a DAML numeric type was sent as a bare JSON
number. The specific value in the log line (e.g. `data: 3600`) identifies the
offending field.

**Why this persists.** Every other JSON API your team uses accepts `3600` as a
number. Every OpenAPI spec generator emits `Int` as `type: integer`. The
encode step is a single-line fix (`String(value)` instead of `value`) but it
must be done for every `Int`/`Numeric` field in every command body across
every tool that submits to Canton — the deploy script, the agents, the
frontend, the admin probes. A typed Canton client enforces this at a single
chokepoint: every `Int` and `Numeric` value is stringified at the client
boundary, making the class impossible.

---

### 5. Named party fingerprints: the full identity and the truncating error

**The failure.** A submission names a party as `oracle`, or `admin`, or
`user-abc123`. The create call returns an error about an unknown party,
sometimes showing only a partial fingerprint: `unknown party: oracle::1220...`.
The operator checks the party list, confirms a party with hint `oracle`
exists, and cannot understand why it was not found.

**The root cause.** Canton parties have a two-part identity: a **hint** (the
human-readable prefix) and a **fingerprint** (a hex string derived from the
allocating transaction). The full identity is `hint::fingerprint` — e.g.
`oracle::1220d6f8e4a7b3c1...`. The hint alone is not an identity: two parties
with the same hint but different fingerprints are different parties. Canton
resolves a party from its full identity, and the hint alone matches nothing.

The truncation in error messages compounds the confusion. When a party is not
found, Canton's error message may show only a partial fingerprint —
`oracle::1220...` — which looks like a hint-plus-garbage rather than a
truncated real identity. The operator naturally reads it as "something is
wrong with the party name" rather than "the fingerprint portion is
incomplete."

**The resolution order.** The canonical source for a party's full identity is:

1. `GET /v2/parties` — returns every party the caller can see, each with its
   full `party::fingerprint` identity.
2. The `AllocateParty` response — the `partyDetails.party` field is the
   authoritative identity at creation time.
3. Never: the hint alone, a config file that lists only hints, or an error
   message showing a truncated fingerprint.

**The diagnostic rule.** Before concluding a party does not exist, verify
against the full party list. If a submission references a party by hint-only
alias, the fix is to resolve that alias to the full `hint::fingerprint`
identity at submission time. A typed Canton client resolves aliases once, at
startup or manifest-load, and never sends a bare hint to the participant.

**A note on the scale of the problem.** A team that provisions ten parties
across three environments and references them by hint in five different tools
has fifty-five alias-resolution points, any one of which can silently break
after a wipe-and-redeploy (because fingerprint values change). A single alias
resolver in a shared client reduces that to one.

---

### 6. Encoding the playbook: from skill to typed client

The five sections above are a diagnostic playbook — a human-readable procedure
an operator follows. But a playbook read by a human at 2 a.m. during a deploy
failure is a playbook that gets a step skipped. The next iteration is to
encode it into tooling — and that encoding lives in this repository, beside
this article.

**The diagnostic skill** ([`skills/canton-auth/`](canton-auth/)) is the
playbook as an agent-runnable artifact — a structured diagnostic flow a human
operator or an AI agent invokes when it detects an auth failure. It encodes:

- **Layer isolation before any change**: decode the token, probe the
  participant, check the user's granted rights, and identify the layer (token
  claims, IdP config, participant rights, or DAML encoding) before editing
  anything.
- **The symptom-to-cause table**: the five failure classes mapped to their
  discriminating probes and the one-line fix, so the agent consults the table
  rather than guessing ([`diagnosis-flow.md`](canton-auth/diagnosis-flow.md)).
- **The replay-and-grep procedure**: the exact log invocation with the right
  `--since` window and grep patterns for each failure class.

The skill is not a replacement for operator knowledge — it is the knowledge,
encoded so it can be executed reliably by either a human operator or an agent
on the operator's behalf. An agent that runs the skill before editing config
is an agent that does not turn a TLS problem into a Keycloak realm re-import.

**The typed client (vaccine).** The diagnostic skill is the cure — it finds
the failure after it occurs. The typed-client invariants
([`typed-client-invariants.md`](canton-auth/typed-client-invariants.md)) are
the vaccine — they make four of the five failure classes structurally
impossible:

1. **userId == sub** is enforced at the submission layer: the client refuses
   to emit a `SubmitAndWait` with a `userId` that differs from the token's
   `sub`.
2. **The issuer/JWKS split** is enforced at token-mint time: the client reads
   the IdP issuer from config and constructs the JWKS URL from
   cluster-internal coordinates, never the public URL.
3. **DAML JSON typing** is enforced at serialization: every `Int` and
   `Numeric` value is stringified before it reaches the wire.
4. **Party fingerprint resolution** is enforced at alias-load time: the client
   resolves every human-readable party alias to its full `hint::fingerprint`
   identity once, at startup, and never sends a bare hint.

The fifth failure class — the masked security-sensitive error — cannot be
prevented structurally because the mask lives in Canton's API, not in the
client. The client can automate the replay-and-grep correlation (emit the
log-grep command alongside the error), so the diagnosis is one step instead of
five, but the mask itself is upstream.

**The relationship.** The skill and the client are two encodings of the same
knowledge — one procedural (run this probe, read this log), one structural
(this class of JSON body cannot leave this process). Both are necessary. The
skill stays because novel failures — the ones not yet encoded in the client —
must still be diagnosed. The client makes the known failures impossible, so
the skill is invoked less often but for more interesting reasons.

---

### 7. Adopt this for your own deployment

Everything above is a generic Canton mechanism — it applies to any Canton
dApp. The `userId == sub` rule is in Canton's `Authorizer`. The issuer/JWKS
split is Canton's IdP config model. The DAML JSON typing rules are in the JSON
API spec. The party fingerprint identity is Canton's party model.

The diagnostic skill in [`skills/canton-auth/`](canton-auth/) is a
self-contained, cloneable directory with no deployment-specific party names,
realm references, k8s namespaces, or package names. All coordinates live in
one config file ([`config.example.yaml`](canton-auth/config.example.yaml))
with five values:

- `participant_url` — the JSON API v2 endpoint
- `idp_issuer` — the public issuer URL your tokens carry in the `iss` claim
- `jwks_url` — the in-cluster JWKS endpoint (HTTP, not HTTPS)
- `package_name` — your DAML package identifier
- `participant_log_command` — how to access the participant log in your
  environment

Its [README](canton-auth/README.md) explains how to clone, configure, and run
it against your own Canton participant. The typed-client invariants (§6) are
described as patterns — type constraints, serialization rules, alias
resolution — that any Canton client in any language can adopt. The point is
not "use our tool"; the point is "these five failure classes are structural,
and here is how to make them impossible in your own client layer, whatever
language it is written in."

If you deploy Canton with the manifests in this repository, two of the five
classes are already mitigated at the manifest layer: the base wires the
issuer/JWKS split into every server-side JWKS consumer (§2, root cause B), and
the dev overlay's `ADDITIONAL_CONFIG_JWT_JWKS` naming carries the
alphabetical-ordering fix (§2, root cause A). The remaining classes live in
your client code — which is exactly where the typed-client invariants go.

---

*Canton auth diagnosis article — generic tooling companion · v1.0 · July 2026*
