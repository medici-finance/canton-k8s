# Typed Client Invariants

The five failure classes in `diagnosis-flow.md` are diagnostic — they find a failure after it occurs. Four of the five can be made **structurally impossible** by encoding them as invariants in a typed Canton client. This document describes each invariant as a language-agnostic pattern — a constraint your client layer enforces, regardless of whether it is written in Go, TypeScript, Python, or Rust.

The point is not "use a specific library." The point is: these four failure classes are known, they recur across every Canton dApp, and lifting them from operator discipline to type-enforced code is a one-time investment with a permanent return.

---

## Invariant 1: `userId` always equals token `sub`

**What it prevents.** Class 1 — admin ops succeed, contract creates 403.

**The constraint.** A `SubmitAndWait` command carries a `userId` field. That field must equal the token's `sub` claim. The client enforces this at the submission layer: the `userId` is never a free parameter the caller sets; it is always derived from the token.

**Implementation pattern.**

```python
# Pseudocode — language-agnostic pattern.
class SubmitAndWaitCommand:
    def __init__(self, token: Token, commands: list[Command]):
        self.userId = token.sub           # Derived, never caller-supplied.
        self.commands = commands
        # No setter. No override. No free parameter.
```

```go
// Go pattern — the userId field is private, set once from the token.
type CommandSubmission struct {
    userId   string  // unexported; set at construction only
    commands []Command
}

func NewSubmission(token *Token, commands []Command) *CommandSubmission {
    return &CommandSubmission{userId: token.Sub, commands: commands}
}
```

**Test.** Construct a submission with a token whose `sub` is `X`. Assert that `submission.userId == X` without any caller intervention.

---

## Invariant 2: Token minting uses public issuer; JWKS fetch uses internal URL

**What it prevents.** Class 2 — every RS256 token 401s.

**The constraint.** The client accepts two URLs at configuration time:

- `idp_issuer` — the public URL (goes into the `iss` claim; must match the IdP config on the participant).
- `jwks_url` — the internal HTTP URL (used by the participant to fetch keys; no TLS validation).

The client refuses to start if `jwks_url` starts with `https://` or if `idp_issuer` is not an `https://` URL. Token minting always targets the public issuer. JWKS configuration always references the internal URL.

**Implementation pattern.**

```go
type ClientConfig struct {
    IDPIssuer string  // Must be https:// — used for token minting.
    JWKSURL   string  // Must be http://  — used for participant IdP config.
}

func (c ClientConfig) Validate() error {
    if !strings.HasPrefix(c.IDPIssuer, "https://") {
        return fmt.Errorf("idp_issuer must be https://, got %s", c.IDPIssuer)
    }
    if !strings.HasPrefix(c.JWKSURL, "http://") {
        return fmt.Errorf("jwks_url must be http:// (in-cluster, no TLS), got %s", c.JWKSURL)
    }
    return nil
}
```

**Test.** Pass `jwks_url = "https://..."`. Assert the client refuses to start with a clear error message naming the invariant.

---

## Invariant 3: DAML `Int` and `Numeric` are always serialized as quoted strings

**What it prevents.** Class 4 — masked 500 on valid-looking command bodies.

**The constraint.** Any DAML `Int` or `Numeric` value is represented in the client as a type that serializes to a quoted JSON string, not a bare JSON number. The serialization boundary is the single chokepoint — no caller can accidentally emit a bare number by choosing the wrong JSON library.

**Implementation pattern.**

```python
# Python pattern — a wrapper type that always serializes as a string.
class DamlInt:
    def __init__(self, value: int):
        self._value = value

    def to_json(self) -> str:
        return str(self._value)  # "3600", not 3600

class DamlNumeric:
    def __init__(self, value: Decimal):
        self._value = value

    def to_json(self) -> str:
        return str(self._value)  # "1.5", not 1.5
```

```go
// Go pattern — custom JSON marshaler.
type DamlInt int64

func (d DamlInt) MarshalJSON() ([]byte, error) {
    return json.Marshal(strconv.FormatInt(int64(d), 10))
}
```

**Test.** Serialize `DamlInt(3600)`. Assert the JSON output is `"3600"` (string), not `3600` (number). Do the same for `DamlNumeric`.

---

## Invariant 4: Party aliases resolve to full `hint::fingerprint` identities once, at startup

**What it prevents.** Class 5 — unknown-party errors with truncated fingerprints.

**The constraint.** The client accepts party aliases (hints) in configuration but never sends them to the participant. At startup, it calls `GET /v2/parties`, resolves every configured alias to its full `hint::fingerprint` identity, and stores the resolved identities. All subsequent submissions use the resolved full identities. If a configured alias does not match any party, the client refuses to start with a clear error message naming the unresolved alias.

**Implementation pattern.**

```go
type PartyResolver struct {
    aliases map[string]string  // alias -> full identity
}

func (r *PartyResolver) Resolve(ctx context.Context, client *CantonClient) error {
    parties, err := client.ListParties(ctx)
    if err != nil {
        return fmt.Errorf("resolve parties: %w", err)
    }
    for alias := range r.aliases {
        found := false
        for _, p := range parties {
            if strings.HasPrefix(p.Identity, alias+"::") {
                r.aliases[alias] = p.Identity
                found = true
                break
            }
        }
        if !found {
            return fmt.Errorf("party alias %q not found on participant", alias)
        }
    }
    return nil
}
```

**Test.** Configure an alias that does not match any party. Assert the client refuses to start. Configure an alias that matches. Assert the client resolves it to the full `hint::fingerprint` identity and never sends the bare hint to the participant.

---

## What about the fifth class?

Class 3 (the masked security-sensitive error) cannot be prevented structurally because the mask lives in Canton's API, not in the client. A typed client can **automate the correlation** — emit the log-grep command alongside every non-2xx response — but it cannot remove the mask. The diagnostic skill (`diagnosis-flow.md`) remains the authoritative reference for this class.

---

## Adoption checklist

1. **Audit every code path that constructs a `SubmitAndWait`.** Does the `userId` come from the token or from a config file? If the latter, fix or add invariant 1.
2. **Audit your token-minting code and IdP config.** Are tokens minted against the public issuer? Is the JWKS URL internal HTTP? If either is wrong, fix or add invariant 2.
3. **Audit every DAML `Int`/`Numeric` value in every command body.** Is it serialized as a quoted string? If not, fix or add invariant 3.
4. **Audit every party reference in config and command construction.** Is the full `hint::fingerprint` identity used, or just the hint? If the latter, fix or add invariant 4.
5. **Add a startup health check** that exercises each invariant: mint a test token, resolve a known party, serialize a known `Int`. A client that fails any of these at startup is a client that will not deploy a latent auth bug.
