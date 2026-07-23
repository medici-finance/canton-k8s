# Contributing

Thanks for your interest. A few expectations up front, so nobody is surprised:

- **This repository is consumed by production clusters.** Changes are conservative by
  design: parametrization stays backward-compatible, defaults stay safe, and anything
  touching auth or the Splice releases gets extra scrutiny.
- **External PRs and issues are reviewed at maintainer discretion.** There is no SLA.
  Small, well-scoped PRs with a clear problem statement fare best.
- **Automation acts only on maintainer-approved items.** The maintainers run automated
  tooling (including AI-assisted review) over this repository. That tooling deliberately
  ignores issues, PRs, and comments from outside contributors until a maintainer has
  engaged with them. If your item hasn't been picked up, it is waiting for a human
  maintainer — commenting more won't summon the bots.
- **CI for fork PRs requires maintainer approval** before it runs. This is intentional.
- **Security problems**: see [SECURITY.md](SECURITY.md) — never a public issue.

## Practical notes

- Validate locally before pushing: the `validate` workflow runs kustomize builds over
  base + examples, kubeconform schema checks, and a content scan. Reproduce with the
  commands in `.github/workflows/validate.yml`.
- Every substitution variable you add or change must be reflected in the reference
  table in `docs/usage.md`.
- License: Apache-2.0. By contributing you agree your contribution is licensed the same.
