# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. This repository ships
Kubernetes configuration that real clusters consume — public disclosure before a fix
puts those deployments at risk.

Use GitHub's **private vulnerability reporting** instead:
[Report a vulnerability](https://github.com/medici-finance/canton-k8s/security/advisories/new)
(Security tab → "Report a vulnerability"). Reports go directly and privately to the
maintainers.

Please include: the affected file/manifest, the deployment scenario where it matters,
and — if you have one — a suggested fix. You'll get an acknowledgement as soon as a
maintainer reviews it; there is no formal SLA on this repository.

## Scope

In scope: anything in this repository — manifest misconfigurations with security
impact, unsafe defaults, workflow/CI weaknesses, documentation that leads operators
into insecure setups.

Out of scope: vulnerabilities in Canton, Splice, Keycloak, or other upstream software
these manifests deploy — report those upstream. Issues in private medici-finance
deployments are not addressable via this repository.

## What happens after you report

Two paths, decided by whether disclosure has to wait.

**Most fixes take the ordinary path.** A defect with no live embargo — one we found
ourselves, or a reported one already public — is fixed through the front door: branch,
pull request, review, CI, with the repository's full branch protection applying. If it
warranted an advisory, we publish one once the fix has shipped. Publishing an advisory for
an already-fixed problem is routine and is what we prefer.

**A fix that must not be visible before it ships** is developed privately, in the
temporary private fork attached to its draft advisory, and reviewed there before it lands.
We use this path only when early visibility would put deployments at risk — not by
default.

Either way, what you can expect: the fix lands, a release tag is cut so consumers can move
to it, and the advisory names that tag as the patched version. If you reported the issue
and want credit, say so and we will name you.

**A note on the mechanics.** An embargoed fix is merged from the advisory page by a
maintainer, which is a different path from an ordinary pull request. We do **not** relax
this repository's branch protection to do it, and we do **not** grant any actor a standing
bypass of that protection — ruleset bypass cannot be scoped to a single merge path, so it
would mean unreviewed pushes to the default branch indefinitely. The step-by-step is a
maintainer runbook kept with our internal operations documentation.

## Staying current

Fixes reach you only if you move your pin. This repository is consumed by tag or commit
SHA (see [`docs/usage.md`](docs/usage.md)), and a pinned consumer does not receive a
security fix until the pin is bumped — nothing in Flux will tell you one exists.

Watch **Releases** and **Security advisories** on this repository. Advisories name the
patched version, and every consumer-relevant change ships as a tag.
