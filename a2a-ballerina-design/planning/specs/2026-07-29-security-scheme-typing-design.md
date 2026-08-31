# SecurityScheme / AgentCardSignature typing — design spec

## Context

`ballerina/a2a`'s data model currently leaves three AgentCard-related fields
untyped, tracked as a known gap in `A2A_Technical_Design.md` §12.1:

- `AgentCard.securitySchemes: map<json>` — should be a discriminated union
  of the 5 OpenAPI-style scheme shapes (API key, HTTP auth, OAuth2, OIDC,
  mTLS).
- `AgentCard.securityRequirements: json[]` and
  `AgentSkill.securityRequirements: json[]` — should be a structured list of
  scheme-name → required-scopes maps.
- `AgentCard.signatures: json[]` — should be a typed `AgentCardSignature[]`
  (RFC 7515 JWS fields).

Consequence of leaving these untyped: callers can't get typed field access
to a fetched AgentCard's security configuration without hand-rolling their
own `json` parsing.

This design was verified against the actual installed `a2a-sdk` 0.3.23
Python package source
(`C:/gitProject/A2A_Project/a2a-samples/samples/python/agents/adk_currency_agent/.venv/Lib/site-packages/a2a/types.py`),
this project's established ground-truth methodology, rather than relying
solely on spec-page prose (which has repeatedly truncated on fetch).

**Explicitly out of scope:** JWS signature *verification* (crypto
integration) — `A2A_Technical_Design.md` §12.1 already defers this
separately, pending a security review. This design only types the
`signatures` field's shape; it does not verify signatures.
**Also out of scope:** automatic client auth configuration from a fetched
scheme (e.g. auto-attaching an API key header based on a parsed
`ApiKeySecurityScheme`). This design only models the data; wiring it into
request auth is a separate, larger feature.

## New types (`a2a/types.bal`)

A discriminated union of 5 records, one per scheme shape, each carrying
its own literal `type` tag so Ballerina's `cloneWithType` can select the
correct variant during JSON-to-union conversion. Every new record follows
this codebase's established open-record-with-typed-rest pattern
(`json...;`), same as every existing type in `types.bal` (`Part`,
`Message`, `AgentCard`, etc.) — this preserves forward-compatible
tolerance for fields a newer spec revision might add to any one variant,
consistent with the "open-record tolerance" tests every other type has:

```ballerina
public type ApiKeySecurityScheme record {|
    string? description?;
    "query"|"header"|"cookie" in;
    string name;
    "apiKey" 'type = "apiKey";
    json...;
|};

public type HttpAuthSecurityScheme record {|
    string? description?;
    string scheme;
    string? bearerFormat?;
    "http" 'type = "http";
    json...;
|};

public type OAuth2SecurityScheme record {|
    string? description?;
    OAuthFlows flows;
    string? oauth2MetadataUrl?;
    "oauth2" 'type = "oauth2";
    json...;
|};

public type OpenIdConnectSecurityScheme record {|
    string? description?;
    string openIdConnectUrl;
    "openIdConnect" 'type = "openIdConnect";
    json...;
|};

public type MutualTlsSecurityScheme record {|
    string? description?;
    "mutualTLS" 'type = "mutualTLS";
    json...;
|};

public type SecurityScheme ApiKeySecurityScheme|HttpAuthSecurityScheme|OAuth2SecurityScheme
    |OpenIdConnectSecurityScheme|MutualTlsSecurityScheme;

public type OAuthFlows record {|
    AuthorizationCodeOAuthFlow? authorizationCode?;
    ClientCredentialsOAuthFlow? clientCredentials?;
    ImplicitOAuthFlow? implicit?;
    PasswordOAuthFlow? password?;
    json...;
|};

public type AuthorizationCodeOAuthFlow record {|
    string authorizationUrl;
    string? refreshUrl?;
    map<string> scopes;
    string tokenUrl;
    json...;
|};

public type ClientCredentialsOAuthFlow record {|
    string? refreshUrl?;
    map<string> scopes;
    string tokenUrl;
    json...;
|};

public type ImplicitOAuthFlow record {|
    string authorizationUrl;
    string? refreshUrl?;
    map<string> scopes;
    json...;
|};

public type PasswordOAuthFlow record {|
    string? refreshUrl?;
    map<string> scopes;
    string tokenUrl;
    json...;
|};

public type SecurityRequirement map<string[]>;

public type AgentCardSignature record {|
    map<json>? header?;
    string protected;
    string signature;
    json...;
|};
```

`SecurityRequirement` is a plain `map<string[]>` alias, not a record — its
homogeneous-map shape already accepts arbitrary additional scheme-name
keys natively, so no `json...;` rest descriptor applies (or is needed)
here.

**Discrimination note:** adding `json...;` to each variant does not weaken
discrimination — `cloneWithType` still rejects a variant whenever the
JSON's `type` value doesn't match that variant's literal (e.g. `"http"`
against `ApiKeySecurityScheme`'s `"apiKey"` literal fails regardless of
open-ness), so the union still resolves to exactly one variant per valid
`type` value.

Field shapes and required/optional status verified field-by-field against
the sdk source classes: `APIKeySecurityScheme` (line 28),
`HTTPAuthSecurityScheme` (447), `OAuth2SecurityScheme` (1500),
`OpenIdConnectSecurityScheme` (757), `MutualTLSSecurityScheme` (742),
`OAuthFlows` (1297) and its 4 flow classes (204, 231, 473, 787),
`AgentCardSignature` (51).

**Naming note:** `in` and `type` are reserved words in Ballerina.
Implementation must use the escaped identifiers `'in`/`'type` at both the
field declaration and every access site; the wire JSON key stays the
unescaped `in`/`type` — Ballerina's identifier-escaping is a source-level
concern only and does not change the serialized field name.

**Assumption requiring verification during implementation:** the `in`
field's three lowercase literal values (`"query"`/`"header"`/`"cookie"`)
are taken directly from the sdk source's `In` enum, which itself mirrors
OpenAPI 3.0's Security Scheme Object convention. Unlike this project's own
`TaskState`/`Role` enums (which the A2A spec renders as
`SCREAMING_SNAKE_CASE`), this field is inherited unmodified from OpenAPI,
so no v0.3/v1.0 divergence is expected here — but this has not been
independently confirmed against the official v1.0 spec page (which has
repeatedly truncated on fetch in this project). The implementation task
must attempt to confirm this against the live spec page or a real v1.0
AgentCard response before treating it as settled; if it cannot be
confirmed, proceed with this assumption but flag it explicitly in the
task's report.

### `AgentCard` / `AgentSkill` field changes

- `AgentCard.securitySchemes: map<json>` → `map<SecurityScheme>`
- `AgentCard.securityRequirements: json[]` → `SecurityRequirement[]`
- `AgentSkill.securityRequirements: json[]` → `SecurityRequirement[]`
- `AgentCard.signatures: json[]` → `AgentCardSignature[]`

All four fields keep their current default (`{}`/`[]`) so a card omitting
them still parses to an empty collection, not an error.

## Tolerant parsing for `securitySchemes`

A single whole-card `cloneWithType(AgentCard)` would reject the *entire*
card if even one `securitySchemes` entry has an unrecognized `type` or is
otherwise malformed — a regression from today's fully-permissive
`map<json>`, and in tension with this library's established open-record
tolerance philosophy (already covered by dedicated tests for other types).

Design: parse `securitySchemes` separately from the rest of the card.

```ballerina
# Parses each entry of a raw securitySchemes JSON object independently,
# silently omitting entries that don't match any known SecurityScheme
# variant (unrecognized `type`, or malformed shape) rather than failing
# the whole AgentCard parse. Forward-compatible with future scheme kinds
# a server might add.
#
# + raw - the raw JSON value of the AgentCard's `securitySchemes` field
# + return - a map containing only the entries that parsed successfully
public isolated function parseSecuritySchemes(json raw) returns map<SecurityScheme>|error {
    map<json> rawMap = check raw.ensureType();
    map<SecurityScheme> result = {};
    foreach [string, json] [name, schemeJson] in rawMap.entries() {
        SecurityScheme|error scheme = schemeJson.cloneWithType(SecurityScheme);
        if scheme is SecurityScheme {
            result[name] = scheme;
        }
    }
    return result;
}
```

`resolveAgentCard` and `getExtendedAgentCard` change from a single
`cloneWithType(AgentCard)` call to:

1. Take the raw `json` body (after the v0.3 field-name pre-pass below).
2. Extract and remove the `securitySchemes` key (if present) before
   cloning the rest of the card, so a malformed entry inside it can't fail
   the outer clone.
3. `cloneWithType(AgentCard)` on the remainder (with `securitySchemes`
   defaulting to `{}` since the closed record's field default applies
   when the key is absent).
4. If the raw body had a `securitySchemes` key, call
   `parseSecuritySchemes` on it and assign the result onto the parsed
   card's `securitySchemes` field.

## v0.3 field-name fix: `security` → `securityRequirements`

The installed v0.3 sdk names this field `security` (verified: `AgentCard`
line 1796, `AgentSkill` line 167 of the sdk source) — not
`securityRequirements`, which is the v1.0 name this library's field already
assumes. Because no `parseV03AgentCard` exists today (unlike every other
type in this library, `AgentCard` is parsed with one direct
`cloneWithType`), this field is currently unreachable from a real v0.3
card — its data lands in the open record's untyped rest-field bucket
instead.

Fix: a **presence-based**, not `detectProtocolMode`-based, JSON-level
rename pass — this sidesteps the chicken-and-egg problem that
`detectProtocolMode` itself needs an already-parsed `AgentCard` to
determine dialect.

```ballerina
# Renames the v0.3-dialect `security` key to the v1.0 field name
# `securityRequirements`, at the AgentCard's top level and within each
# element of `skills`, so a v0.3 server's security-requirement data
# populates the typed field instead of falling into the open record's
# untyped rest fields. A no-op when `securityRequirements` is already
# present (v1.0 cards) or `security` is absent.
#
# + raw - the raw JSON AgentCard body, before typed parsing
# + return - the body with `security` renamed to `securityRequirements`
#            wherever applicable
isolated function renameV03SecurityField(json raw) returns json {
    map<json> cardMap = raw is map<json> ? raw.clone() : {};
    if cardMap.hasKey("security") && !cardMap.hasKey("securityRequirements") {
        cardMap["securityRequirements"] = cardMap.remove("security");
    }
    json[]? skillsJson = cardMap["skills"] is json[] ? <json[]>cardMap["skills"] : ();
    if skillsJson is json[] {
        json[] renamedSkills = [];
        foreach json skillJson in skillsJson {
            if skillJson is map<json> {
                map<json> skillMap = skillJson.clone();
                if skillMap.hasKey("security") && !skillMap.hasKey("securityRequirements") {
                    skillMap["securityRequirements"] = skillMap.remove("security");
                }
                renamedSkills.push(skillMap);
            } else {
                renamedSkills.push(skillJson);
            }
        }
        cardMap["skills"] = renamedSkills;
    }
    return cardMap;
}
```

This runs in both `resolveAgentCard` and `getExtendedAgentCard`, before
step 2 of the tolerant-parsing sequence above (i.e. the full pre-clone
sequence is: rename pass → extract `securitySchemes` → clone remainder →
parse and reattach `securitySchemes`).

## Testing plan

- **Round-trip + open-record-tolerance tests**, one pair per new type
  (`ApiKeySecurityScheme`, `HttpAuthSecurityScheme`, `OAuth2SecurityScheme`
  with each of its 4 flow sub-types populated, `OpenIdConnectSecurityScheme`,
  `MutualTlsSecurityScheme`, `AgentCardSignature`), using fixtures shaped
  from the sdk source's own field examples — same pattern as every other
  type in `types_test.bal`.
- **`parseSecuritySchemes` tests:**
  - A map with 2 valid entries of different types + 1 entry with an
    unrecognized `type` value → result contains exactly the 2 valid
    entries, correctly typed.
  - A map with 1 entry whose shape is malformed in a way unrelated to
    `type` (e.g. `apiKey` scheme missing required `name`) → that entry is
    also omitted, siblings still present.
  - An empty map → empty result, no error.
- **`renameV03SecurityField` tests:**
  - A v0.3-shaped card JSON with top-level `security` and one skill with
    `security` → both become `securityRequirements` after the rename.
  - A v1.0-shaped card already carrying `securityRequirements` → untouched,
    no collision/overwrite even if a stray `security` key were also
    present (v1.0-key wins).
  - A card with neither key → untouched, no error.
- **End-to-end `resolveAgentCard` test** against a scripted mock card
  modeled on the Java reference server's rich field set (already named in
  `A2A_Technical_Design.md` §11.3 as this project's rich-field-tolerance
  target): populated `provider`, `signatures`, and multiple
  `securitySchemes` entries including one deliberately-unknown `type` —
  asserts the known entries parse, the unknown one is silently dropped,
  and `signatures`/`securityRequirements` are typed correctly.

## Files touched

- `a2a/types.bal` — new types; `AgentCard`/`AgentSkill` field type changes.
- `a2a/client.bal` — `resolveAgentCard`/`getExtendedAgentCard` change from
  one `cloneWithType` call to the rename → extract → clone → reattach
  sequence; `parseSecuritySchemes` helper (co-located with `types.bal`,
  since it's a data-model parsing concern, not v0.3-compat-specific).
- `a2a/compat_v03.bal` — new `renameV03SecurityField` function.
- `a2a/tests/types_test.bal` — new type round-trip/tolerance tests,
  `parseSecuritySchemes` tests.
- `a2a/tests/compat_v03_test.bal` — `renameV03SecurityField` tests.
- `a2a/tests/client_test.bal` — end-to-end `resolveAgentCard` rich-card
  test.
- `a2a/docs/A2A_Technical_Design.md` — remove the "securitySchemes typing
  ... not implemented" line from §12.1; add a short note on the tolerant
  parsing behavior and the v0.3 `security` field-name fix.

## Global constraints carried into the implementation plan

- No change to any existing public method signature.
- `securitySchemes`/`securityRequirements`/`signatures` all keep their
  current empty defaults when absent from the wire.
- Unknown/malformed `securitySchemes` entries are dropped silently, never
  surfaced as a parse error for the whole card.
- JWS signature verification and auto-derived client auth configuration
  are explicitly out of scope for this feature.
