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
