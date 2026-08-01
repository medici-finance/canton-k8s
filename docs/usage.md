# Usage guide

This repo is a **public, parametrized base**. You consume it from a private
repo via FluxCD; you never edit it to deploy. This page covers the
consumption pattern, the full variables reference, required secrets, the
overlay pattern, the DAR-deploy workflow, the admin pod, and the sharp edges.

## The Flux consumption pattern

Two objects in your private repo (full example:
[`examples/flux/canton-base.yaml`](../examples/flux/canton-base.yaml)):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: canton-splice-base
  namespace: flux-system
spec:
  url: https://github.com/medici-finance/canton-k8s
  ref:
    tag: v0.1.1          # ALWAYS a tag or commit SHA — never a branch
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: canton-dev
  namespace: flux-system
spec:
  sourceRef: {kind: GitRepository, name: canton-splice-base}
  path: ./examples/overlays/dev      # or your own overlay
  prune: true
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: canton-env-config      # your per-env values
```

**Pin by tag or SHA.** This repo is a public supply-chain source. A branch
ref means any future commit here flows straight into your cluster on the next
reconcile. Review changes, then bump the pin deliberately.

**Then watch for updates — pinning is only half of it.** A pin that is never
bumped is a deployment frozen on the day you adopted it, including any security
fix published since. Nothing in Flux will tell you: a `GitRepository` pinned to
a tag reconciles happily forever against that tag.

So pair the pin with a notification path. On this repo:

- **Watch → Custom → Releases** for `medici-finance/canton-k8s`. Every change
  that consumers should take arrives as a new tag; there is no other channel.
- **Watch → Custom → Security alerts**, and check
  the [repository's Security Advisories page](https://github.com/medici-finance/canton-k8s/security/advisories)
  for any security-related updates.
- When a new tag lands, diff it against your pin before bumping
  (`git diff <your-pin>..<new-tag>`). That is the review the pin exists to let
  you do.

If you cannot commit to watching, pin to a tag anyway and set yourself a
recurring reminder to check. Tracking `main` to "stay current" trades a known
review step for an unreviewed one and is the worse option, not the convenient
one.

**Substitution semantics** (Flux `postBuild`): only variables *defined* in
`substituteFrom`/`substitute` are replaced; undefined `${VARS}` are left
untouched. That is what lets the Keycloak realm keep its pod-start
placeholders (below). It also means a typo'd variable name fails *soft* — the
literal `${TYPO}` lands in the cluster object. Grep your rendered output for
`${` when something looks off (CI here does exactly that for the example
values).

### Your own overlay

If `examples/overlays/dev` / `prod` don't fit, keep an overlay in *your*
repo whose `kustomization.yaml` references this repo's base — Flux supports
that when you vendor the base with a second GitRepository, or simpler: fork
the two example overlay directories into your repo and point `path:` at your
copy while keeping `resources: [<relative path into the GitRepository>]`. In
practice most consumers point `path:` at one of the shipped overlays and put
every env difference into the ConfigMap.

## Variables reference

All variables are consumed via Flux `postBuild.substituteFrom`. Example
values: [`examples/env-config.yaml`](../examples/env-config.yaml).

### base/canton

| Variable | Example | Used for |
|---|---|---|
| `CANTON_NAMESPACE` | `canton-dev` | Namespace for every Canton/Splice/Keycloak object; also derives all in-cluster service URLs (`postgres.<ns>.svc…`, `keycloak.<ns>.svc…`). |
| `BASE_DOMAIN` | `dev.example.com` | Wildcard certificate (`*.<BASE_DOMAIN>`). |
| `KEYCLOAK_HOST` | `keycloak.dev.example.com` | Keycloak ingress host, public issuer URL (`KC_HOSTNAME_URL`), UI-auth issuer URLs. JWKS fetches deliberately do NOT use it — see sharp edge 2. |
| `CANTON_API_HOST` | `canton.dev.example.com` | Participant JSON API ingress host. |
| `VALIDATOR_HOST` | `validator.dev.example.com` | Validator API ingress host. |
| `FRONTEND_URL` | `https://app.dev.example.com` | CORS allow-origin, frontend client redirect URIs / web origins. |
| `INGRESS_CLASS` | `traefik` | `ingressClassName` on all ingresses. The CORS middleware object itself is Traefik-specific — replace `traefik-cors.yaml` via overlay for other controllers. |
| `TLS_SECRET_NAME` | `dev-wildcard-tls` | Certificate secret + ingress TLS ref. |
| `CLUSTER_ISSUER` | `letsencrypt-production` | cert-manager ClusterIssuer (needs a DNS-01 solver for the wildcard). |
| `EXTERNAL_DNS_TARGET` | `ingress.example.com` | `external-dns` target annotation on every ingress. |
| `KEYCLOAK_REALM` | `AppUser` | Realm name; appears in every issuer/JWKS URL. |
| `KEYCLOAK_REALM_LOWER` | `appuser` | Keycloak's auto-generated `default-roles-<realm-lowercase>` role name in the realm import. |
| `FRONTEND_CLIENT_ID` | `app-web` | Public OIDC client for browsers; also fed to the Splice UI auth secrets. |
| `CANTON_AUDIENCE` | `https://canton.network.global` | `aud` mapped into tokens; participant/sv/validator `targetAudience`/`audience`. |
| `PARTICIPANT_ADMIN_USER` | `app-user-validator` | The participant admin ledger-api user name (must equal the validator service client's token `sub`). |
| `VALIDATOR_WALLET_USER` | `wallet-admin` | splice-validator `validatorWalletUser`. |
| `KEYCLOAK_DB_RESET` | `"enabled"` / `"disabled"` | `enabled` (dev): drop + re-import the Keycloak DB on every rollout so realm ConfigMap edits take effect. **Destroys all Keycloak state — never on an env with real users.** (Deliberately not true/false: a substituted bare boolean breaks env-var string typing.) |
| `REALM_CHECKSUM` | `v1` | Pod-template annotation; bump to force a Keycloak rollout after realm edits. |
| `SPLICE_VERSION` | `0.6.11` | Chart version for ALL six splice-* HelmReleases — keep them identical. |
| `SPLICE_IS_DEV_NET` | `"true"` / `"false"` | HOCON boolean injected into the sv-app (`onboarding.is-dev-net`). |
| `POSTGRES_VOLUME_SIZE` | `20Gi` | splice-postgres PVC size. |
| `STORAGE_CLASS` | `standard` | Postgres volume + sv-app domain-migration PVC storage class. |

### deploy/ (additionally)

| Variable | Example | Used for |
|---|---|---|
| `ADMIN_NAMESPACE` | `canton-tools-dev` | Namespace of the deploy Job (and admin pod). |
| `CANTON_API_URL` | `http://participant.canton-dev.svc.cluster.local:7575` | JSON API the Job talks to (no nested substitution — spell it out). |
| `DAR_PACKAGE_NAME` | `my-package` | Your DAML package name (`daml.yaml` `name:`); used for the version gate. |
| `DAR_VERSION` | `0.1.0` | Version the Job expects in the DAR ConfigMaps (fail-closed gate). |
| `DAR_DEPLOY_JOB_VERSION` | `v1` | Job-name suffix — bump on EVERY Job/script/DAR change (immutable Job specs, see below). |
| `DAR_DEPLOY_DEADLINE_SECONDS` | `900` | `activeDeadlineSeconds` for the whole Job, init-waits included — a hung bring-up fails loudly as `DeadlineExceeded` instead of sitting `Init:0/2` forever. Raise for slow first installs. |

### admin/ (additionally)

| Variable | Example | Used for |
|---|---|---|
| `ADMIN_IMAGE` | `alpine/k8s:1.31.1` | Debug pod image; needs bash, curl, jq, kubectl. |
| `KEYCLOAK_PUBLIC_URL` | `https://keycloak.dev.example.com/auth` | Public Keycloak base **including** the `/auth` relative path (token minting). |

## Required secrets

The base **never ships credential material**. Create these in
`${CANTON_NAMESPACE}` from your private repo (SOPS, sealed-secrets, ESO —
your choice):

| Secret | Keys | Consumed by |
|---|---|---|
| `postgres-secrets` | `postgresPassword` (cluster admin), `username`, `password` (app user) | splice-postgres, splice-domain, keycloak (DB init + JDBC) |
| `keycloak-credentials` | `admin-user`, `admin-password` (Keycloak bootstrap admin); `admin-realm-password`, `app-user-password` (realm bootstrap users); `app-user-validator-client-secret`, `app-user-sv-client-secret`, `validator-app-backend-client-secret` | keycloak realm import |
| `splice-app-validator-ledger-api-auth` | `ledger-api-user`, `url`, `client-id`, `client-secret`, `audience` (RS256 client-credentials) — or `ledger-api-user`, `audience`, `token` under the dev overlay's fixed-token model | splice-validator |
| `splice-app-sv-ledger-api-auth` | same shape as above | splice-sv-node, splice-scan |
| `canton-admin-token` | `token` — an admin bearer token for the JSON API | deploy/ Job, admin/ pod (in `${ADMIN_NAMESPACE}`) |

`admin-realm-password` belongs to the realm's `admin` bootstrap user, which
holds the `realm-management` client role `realm-admin` — full administrative
rights **over `${KEYCLOAK_REALM}`** (not over Keycloak as a whole; that is the
separate master-realm account behind `admin-user` / `admin-password`). Treat it
as a privileged credential, or drop the user in your overlay if you administer
the realm some other way.

Extend `keycloak-credentials` with one `<client-id>-client-secret` key per
service client your application adds to the realm (and mirror it into the
realm-import init container's env + export list — see
`base/canton/keycloak.yaml`).

## The overlay pattern (intentional env divergence)

Scalars (hostnames, sizes, versions) belong in the env ConfigMap.
**Structural** differences belong in overlays:

* `examples/overlays/dev` — participant `disableAuth: true` **plus** the
  `ADDITIONAL_CONFIG_JWT_JWKS` re-append, `cluster.fixedTokens: true` for
  scan/sv/validator, Keycloak `start-dev`, debug-pod RBAC. Pair with
  `KEYCLOAK_DB_RESET: "enabled"`.
* `examples/overlays/prod` — the base as-is (the base *is* the production
  shape) + a capacity patch example. Pair with `KEYCLOAK_DB_RESET: "disabled"`.

Add your own structural changes the same way: a strategic-merge patch on the
HelmRelease `values`, or replace a whole resource (e.g. ship your own
`keycloak-realm.yaml` ConfigMap with your application's clients).

## DAR deploy workflow (deploy/)

The Job does **not** build from source; it uploads whatever DAR the
`dar-part{1..3}` ConfigMaps hold. The ship sequence is:

```bash
# 1. build your DAR (dpm/daml build) in your app repo
# 2. regenerate the part ConfigMaps into your private k8s repo:
deploy/gen-dar-configmaps.sh --namespace canton-tools-dev \
    --out k8s/dev/ .daml/dist/my-package-0.1.1.dar
# 3. bump BOTH in your env ConfigMap:
#      DAR_VERSION: "0.1.1"
#      DAR_DEPLOY_JOB_VERSION: "v2"
# 4. commit + push; Flux creates dar-deploy-v2
# 5. VERIFY ON-CLUSTER (never trust Job exit codes):
kubectl logs -n canton-tools-dev job/dar-deploy-v2 | grep RESULT:
#    RESULT: UPLOADED          <- what you want after a version bump
#    RESULT: ALREADY-CURRENT   <- fine on a re-run; a red flag after a bump
```

Why the double bump: Kubernetes Job `spec.template` is **immutable** and a
completed Job never re-runs — Flux can only replace a Job under a *new name*.
And the version gate (`EXPECTED_DAR_VERSION` vs. the version read out of the
DAR zip itself) makes a stale-ConfigMap deploy fail loudly instead of
"succeeding" as a silent no-op.

The Job also carries `activeDeadlineSeconds`
(`DAR_DEPLOY_DEADLINE_SECONDS`, default example `900`) covering the
init-waits too: if the participant/validator never come up, the Job fails
**loudly** with `DeadlineExceeded` instead of hanging `Init:0/2` forever. A
`DeadlineExceeded` dar-deploy Job is the intended failure mode for a broken
bring-up — investigate the waits' logs, fix, then bump
`DAR_DEPLOY_JOB_VERSION` to re-run.

## Admin pod (admin/)

A read-only jump-box with the admin token and diagnostic scripts mounted:

```bash
kubectl exec -n canton-tools-dev deploy/canton-admin -- probe-canton.sh
kubectl exec -n canton-tools-dev deploy/canton-admin -- verify-user.sh <sub>
kubectl exec -n canton-tools-dev deploy/canton-admin -- verify-user.sh --token "<jwt>"
T=$(kubectl exec -n canton-tools-dev deploy/canton-admin -- mint-token.sh svc oracle-svc)
```

`mint-token.sh hs256` mints the dev-only static HS256 token (Splice
`disableAuth` shared key). Use it **only** to confirm the participant is up:
it masks every RS256-path failure. After any participant restart or upgrade,
smoke-test with a real RS256 token (`mint-token.sh svc <client-id>`).

To let the pod read participant logs across namespaces, apply the dev
overlay's `debug-pod-rbac.yaml`.

## Sharp edges

### 1. `ADDITIONAL_CONFIG_*` names concatenate ALPHABETICALLY

The Splice image entrypoint concatenates every `ADDITIONAL_CONFIG_*` env var
in bash `${!ADDITIONAL_CONFIG@}` order — **alphabetical**. The chart's
`disableAuth` injects `ADDITIONAL_CONFIG_DISABLE_AUTH` containing a plain
`auth-services = [hs256]` **assignment**. Any var of yours that must run
after it (like the dev overlay's jwt-jwks `+=` append) must sort **after**
`DISABLE_AUTH`. A name sorting before `D` gets silently wiped: the
participant runs with only the HS256 validator and every RS256 token 401s
("Algorithm doesn't match"), masked by the HS256 god token. Corollary: HOCON
`+=` takes a bare object — wrapping it in `[ ]` appends a nested list and
fails startup with "Expected type OBJECT. Found LIST".

### 2. Issuer/JWKS split

Mint tokens against the **public** IdP URL — the token `iss` must match the
issuer the participant expects. Fetch the JWKS over **in-cluster HTTP** — the
participant JVM validates TLS on that fetch, and an untrusted/self-signed
ingress cert (e.g. after a Let's Encrypt rate limit; see
`base/canton/certificate.yaml`) kills ALL RS256 auth with an opaque
`JwtException: null`. The JWKS holds only public keys; the in-cluster hop
leaks nothing. The split applies to **every server-side JWKS consumer**, not
just the participant: the sv-app and validator-app `auth.jwksUrl` in this
base use the same in-cluster HTTP form (and include Keycloak's `/auth`
relative path — a public URL without it 404s). Only browser-facing issuer
URLs (UI auth secrets, `KC_HOSTNAME_URL`) use `https://${KEYCLOAK_HOST}`.

### 3. Immutable Job specs → versioned Job names

See the DAR workflow above. General rule: any Job manifest in a Flux-managed
repo needs a name that changes when its spec changes.

### 4. Two substitution layers

Flux replaces `${VARS}` defined in your env ConfigMap at *apply* time. The
Keycloak realm-import init container replaces
`${APP_USER_VALIDATOR_CLIENT_SECRET}`-style placeholders at *pod start* from
the `keycloak-credentials` Secret. Never define a pod-start placeholder name
in your Flux ConfigMap — Flux would substitute it first. Related: Flux's
envsubst also evaluates bash-style default forms (`${VAR:-x}`, `${VAR:=x}`),
so shell scripts shipped through substituted ConfigMaps (deploy/, admin/)
must avoid those forms — this repo's scripts use `printenv` fallbacks
instead.

### 5. Wildcard certificate, DNS-01, and rate limits

One wildcard Certificate per environment, no `cluster-issuer` annotations on
ingresses (ingress-shim would mint per-host certs and re-trip the
Let's Encrypt per-identifier rate limit that motivates the wildcard in the
first place). Wildcards require a DNS-01 solver on the ClusterIssuer.

### 6. Splice chart workarounds baked into the base

`release-domain.yaml` carries three post-render patches for 0.6.x chart/image
mismatches (missing `CANTON_DOMAIN_POSTGRES_PORT`, bootstrap init vs.
manual-identity model, probes on the not-yet-serving sequencer public API);
`release-sv.yaml` fixes the `is-dev-net` string-vs-boolean chart bug, and
`release-scan.yaml`/`release-sv.yaml` document the founding-SV
(`found-dso` / `isFirstSv`) ordering: **sv must NOT depend on scan** (that's
a deadlock — see the comment in `release-sv.yaml`). Re-check all of these
when bumping `SPLICE_VERSION`.

## Validating locally

```bash
# what CI runs (see .github/workflows/validate.yml):
kustomize build base/canton > /tmp/base.yaml            # placeholders intact
./hack/substitute.sh /tmp/base.yaml examples/env-config.yaml > /tmp/base.sub.yaml
kubeconform -strict -ignore-missing-schemas /tmp/base.sub.yaml
grep -n '\${' /tmp/base.sub.yaml                        # must be empty
```

`hack/substitute.sh` mimics Flux's semantics with GNU envsubst restricted to
exactly the variables defined in the env ConfigMap.

## Auth diagnostics

For the recurring Canton auth failure classes (token sub vs. userId, the
issuer/JWKS split, masked security-sensitive errors, DAML numeric JSON
encoding, party-hint truncation) use the parameterized playbook in
[`skills/canton-auth/`](../skills/canton-auth/): copy
`config.example.yaml`, fill in your participant URL / issuer / JWKS URL /
package name, and follow `diagnosis-flow.md`. For the architecture behind
each failure class, read the companion article
[How to diagnose auth issues on Canton](../skills/diagnosing-canton-auth.md).
