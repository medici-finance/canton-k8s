# canton-k8s

A reusable, parametrized Kubernetes base for running a **self-contained
Canton/Splice network** — participant, domain (sequencer + mediator), scan,
founding Super Validator, validator, and a Keycloak IdP — deployed with
**FluxCD**, plus generic **DAR-deploy tooling** and an **admin/debug pod**.

Downstream (private) repos customize it **purely by supplying per-environment
values** via Flux `postBuild.substituteFrom` — no forking, no sed, no
copy-paste of manifests. Intentional environment differences (dev's permissive
auth, debug RBAC) are expressed as small kustomize overlays.

License: Apache-2.0.

## Layout

| Path | What it is |
|---|---|
| `base/canton/` | The parametrized Canton/Splice base (HelmReleases for the six Splice charts + Keycloak + ingress/TLS/CORS). Secure-by-default: RS256-only auth. |
| `examples/overlays/dev/` | Dev overlay: `disableAuth` + HS256 fixed tokens + the jwt-jwks re-append, debug RBAC. |
| `examples/overlays/prod/` | Prod overlay: the base as-is + a capacity patch example. |
| `examples/env-config.yaml` | Example per-environment ConfigMap — the full variable set with example values. |
| `examples/flux/` | How a consumer wires this repo in (GitRepository pinned by tag/SHA + Kustomization with `substituteFrom`). |
| `deploy/` | Generic DAR-deploy Job + scripts (`gen-dar-configmaps.sh`, versioned Job names, on-cluster verification). |
| `admin/` | Read-only admin/debug pod + diagnostic scripts (`probe-canton.sh`, `verify-user.sh`, `mint-token.sh`). |
| `skills/canton-auth/` | A cloneable, parameterized diagnostic playbook for the five recurring Canton auth failure classes. |
| `docs/usage.md` | Full usage guide: variables reference, required secrets, overlay pattern, sharp edges. |

## Quickstart

1. **In your private repo**, create a per-environment ConfigMap from
   [`examples/env-config.yaml`](examples/env-config.yaml) (namespaces,
   hostnames, chart version, sizes).
2. Create the [required Secrets](docs/usage.md#required-secrets) in the canton
   namespace (Postgres credentials, Keycloak credentials, Splice ledger-api
   auth) — e.g. SOPS-encrypted in your repo.
3. Add a Flux `GitRepository` **pinned to a tag or commit SHA** of this repo
   and a `Kustomization` with `postBuild.substituteFrom` pointing at your
   ConfigMap — see [`examples/flux/canton-base.yaml`](examples/flux/canton-base.yaml).
   Point `path:` at `examples/overlays/dev` (or your own overlay).
4. Push. Flux applies the base with your values substituted.
5. To ship your application's DAR, wire up [`deploy/`](deploy/) — build the
   DAR, run `deploy/gen-dar-configmaps.sh`, bump `DAR_VERSION` +
   `DAR_DEPLOY_JOB_VERSION`, push, then **verify on-cluster**:
   `kubectl logs job/dar-deploy-<ver>` must say `RESULT: UPLOADED`.

> **Supply-chain note:** this is a public repo. Always pin the
> `GitRepository` by tag or SHA, never track a branch.

## What the consumer supplies

* **Values** — one ConfigMap per environment (the whole variable set is
  documented in [docs/usage.md](docs/usage.md#variables-reference)).
* **Secrets** — credential material never lives in this repo, encrypted or
  otherwise. The base references Secrets by name only.
* **Overlays** — optional kustomize patches for anything structural
  (extra realm clients, resource sizing, your own ingresses).
* **DAR ConfigMaps** — generated into *your* repo by
  `deploy/gen-dar-configmaps.sh`.

## Sharp edges (read before operating)

Condensed here; full explanations in
[docs/usage.md § Sharp edges](docs/usage.md#sharp-edges):

1. **`ADDITIONAL_CONFIG_*` names are semantic** — the Splice image entrypoint
   concatenates them **alphabetically**; an appending var must sort *after*
   `ADDITIONAL_CONFIG_DISABLE_AUTH` or the chart's assignment silently wipes
   your append (and every RS256 token 401s).
2. **Issuer/JWKS split** — tokens carry the **public** IdP URL in `iss`; the
   participant fetches the JWKS over **in-cluster HTTP**. Breaking either half
   breaks all RS256 auth.
3. **Job specs are immutable** — the DAR-deploy Job name carries a version
   suffix; bump it on *every* change or Flux deploys nothing while looking
   green. Verify with the `RESULT: UPLOADED` log line, never the Job's exit
   code.
4. **Two substitution layers** — Flux substitutes `${VARS}` at apply time;
   the Keycloak realm-import container substitutes secret placeholders at pod
   start. Keep the namespaces of those variable names disjoint, and keep
   `${VAR:-default}` bashisms out of ConfigMap-shipped scripts.

Auth debugging beyond that: start from
[`skills/canton-auth/`](skills/canton-auth/) — symptom → discriminating
probe → one-line fix, parameterized to any Canton deployment.

## Validation

CI (`.github/workflows/validate.yml`) builds every kustomization, substitutes
the example values from `examples/env-config.yaml` (Flux-style: only defined
variables are replaced), schema-validates the result with kubeconform, and
runs a secret/denylist scan. Run it locally with the same commands — see
[docs/usage.md § Validating locally](docs/usage.md#validating-locally).
