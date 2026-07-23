# Canton Auth Diagnosis Skill

A parameterized diagnostic playbook for the five recurring auth failure classes on
Canton. Self-contained, cloneable, and designed for adoption by any Canton dApp team.
Strips out all deployment-specific coupling — configure once, diagnose against your
own participant.

## Quick start

```bash
git clone <this-repo> canton-auth-skill
cd canton-auth-skill
cp config.example.yaml config.yaml
# Edit config.yaml with your participant URL, IdP issuer, JWKS URL, and package name.
```

The skill is a structured reference, not an executable binary. It encodes a diagnosis
flow: for each of the five failure classes, it tells you the symptom, the discriminating
probe, and the one-line fix. You can run the probes manually, wrap them in a script, or
load the reference into an agent that follows it as a runbook.

## How to adopt

1. **Clone this directory** into your own repository. It has no dependencies on any
   parent project's code, config, or naming conventions.
2. **Edit `config.example.yaml`** or create your own with five values:
   - `participant_url` — the JSON API v2 endpoint (e.g. `https://canton.example.com`)
   - `idp_issuer` — the public issuer URL your tokens carry in the `iss` claim
   - `jwks_url` — the in-cluster JWKS endpoint (HTTP, not HTTPS)
   - `package_name` — your DAML package identifier (e.g. `#my-package`)
   - `participant_log_command` — how to access the participant log in your environment
3. **Keep the diagnosis reference** (`diagnosis-flow.md`) as the canonical playbook.
   Extend it with your own failure classes as you find them.
4. **Build typed-client invariants** around the four preventable classes (see
   `typed-client-invariants.md`) so they become structurally impossible in your own
   client layer.

## The five failure classes

| # | Failure class | Symptom | Preventable by typed client? |
|---|---|---|---|
| 1 | `userId` != token `sub` | Admin ops green, contract creates 403 | Yes |
| 2 | Issuer/JWKS split broken | Every RS256 token 401s, HS256 works | Yes |
| 3 | Security-sensitive error mask | 403/500 with no reason in response body | No (upstream mask) |
| 4 | DAML Int/Numeric as bare JSON number | Masked 500 on valid-looking command bodies | Yes |
| 5 | Party hint used instead of full fingerprint | Unknown-party errors with truncated fingerprints | Yes |

Full diagnosis flow, discriminating probes, and fix recipes: `diagnosis-flow.md`.

## Parameterized config

All deployment-specific values live in one config file. The diagnosis flow references
them as variables — no hardcoded URLs, party names, or realm identifiers appear in any
diagnosis step. If your deployment uses a different identity provider, a different
k8s distribution, or a different log-access mechanism, change the config values, not
the procedure.

Example config: `config.example.yaml`.

## What this is not

- Not a Canton replacement or wrapper. It diagnoses auth failures on the standard JSON
  API v2; it does not replace or extend it.
- Not a specific product's internal tool. It has no coupling to any particular DAML
  package, party naming convention, or identity provider realm.
- Not a substitute for reading the participant log. The masked-error unmask technique
  (class 3) requires log access; the skill tells you what to grep for, not how to
  bypass the mask at the API layer.

## Companion article

The technical article "[How to diagnose auth issues on Canton](../diagnosing-canton-auth.md)"
walks through the same five failure classes as case studies, explains the Canton
architecture behind each one, and describes how the diagnostic skill and typed-client
invariants relate — the skill as cure (diagnose after breakage), the typed client as
vaccine (prevent the class). Read the article for the why; use this directory for the
how.

## License and attribution

This diagnostic reference is published as a generic Canton tooling artifact. It carries
no dependency on any specific dApp's code, config, or naming conventions. Adopt,
modify, and extend it for your own deployment.

---

*Canton Auth Diagnosis Skill — generic tooling artifact · v1.0 · July 2026*
