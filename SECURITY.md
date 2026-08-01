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

## How we ship a fix

Two paths. Which one applies is decided by whether disclosure has to wait.

### Ordinary path — a normal pull request

A defect with **no live embargo** — one we found ourselves, or a reported one already
public — is fixed through the front door: branch, pull request, review, CI. It gets the
repository's full protection, and an advisory is published afterwards if the defect
warranted one. Advisories can be published for already-fixed problems; that is routine
and preferred.

**This is the default.** Use the embargoed path only when a fix must not be visible
before it ships.

### Embargoed path — private fork, and a recorded protection window

A fix that must stay private until release is developed in the **temporary private fork**
attached to its draft advisory. That fork is not publicly visible and neither is its pull
request, so the fix can be written and reviewed under embargo.

Merging it collides with this repository's protection, and the collision is by design
rather than by accident:

- `protect-main` requires **a pull request** and **passing status checks** on the default
  branch, and its bypass list is **empty** — the rules apply to everyone, maintainers
  included.
- An advisory merge is not a pull request against this repository, and **temporary private
  forks do not run GitHub Actions**, so the required checks cannot run and never will.

So an embargoed merge needs the protection relaxed for the duration of the merge, and that
window is the thing this section exists to bound.

**We do not add a bypass actor.** Ruleset bypass is granted per-actor over the whole
ruleset, with no way to scope it to advisory merges — an actor with bypass can push
anything to the default branch, unreviewed, indefinitely. A standing hole is not an
acceptable price for an occasional merge, and the security fix is the change we least want
merged without scrutiny.

**Procedure**

1. **Review under embargo, before touching protection.** The fix is reviewed in the fork's
   pull request and its checks are run manually — the fork has no Actions, so this is the
   only verification that will exist. Record the commands, exit codes and output in the
   fork's PR. The protection window is not a substitute for review; it exists only because
   the merge mechanism cannot satisfy the rules.
2. **Record the intent** on the advisory before opening the window: what is being merged,
   who reviewed it, and the head SHA.
3. **Open the window** — set `protect-main` enforcement to `evaluate`. Prefer `evaluate`
   over `disabled`: violations are still logged, so the window leaves a trace.
4. **Merge** from the advisory page.
5. **Close the window immediately** — restore enforcement to `active`. This is the step
   that matters; everything else is recoverable and this is not.
6. **Verify the restore, do not assume it.** The read-back is one command:

   ```
   gh api repos/medici-finance/canton-k8s/rulesets/19619632 \
     --jq '{name, enforcement, bypass_actors: (.bypass_actors|length), rules: [.rules[].type]}'
   ```

   The expected state, verbatim:

   ```json
   {"name":"protect-main","enforcement":"active","bypass_actors":0,
    "rules":["deletion","non_fast_forward","pull_request","required_status_checks"]}
   ```

   Anything else — `evaluate`, `disabled`, a non-zero `bypass_actors`, a missing rule —
   means the window is still open.
7. **Tag and publish.** Cut the release tag, set the advisory's patched version to it, and
   publish. Tag creation is unaffected by protection: `protect-release-tags` blocks
   `update`, `deletion` and `non_fast_forward`, not creation.
8. **Record the window** on the advisory — when it opened, when it closed, and the
   verification output from step 6.

**Closing the hole is not a memory exercise.** Step 5 relies on a human remembering, and a
forgotten restore leaves the default branch unprotected with nothing to announce it. The
verification in step 6 catches it only if someone runs it. Treat the expected state above
as an invariant to be asserted on a schedule, not only after a merge — a drift check that
alarms when `protect-main` is not `active` with an empty bypass list is what actually
closes this, and until one exists the procedure is only as good as the operator's memory.
