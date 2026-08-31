# SecurityScheme / AgentCardSignature Typing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the untyped `json`/`map<json>` shapes of `AgentCard.securitySchemes`, `AgentCard.securityRequirements`, `AgentSkill.securityRequirements`, and `AgentCard.signatures` with modelled types, without breaking this library's forward-compatibility tolerance for unrecognized fields or unrecognized security-scheme shapes, and fix the v0.3 `security` vs. v1.0 `securityRequirements` AgentCard field-name gap discovered during design.

**Architecture:** Add a discriminated union of 5 closed-with-rest-field records (`SecurityScheme`), 4 nested OAuth2 flow records, a `SecurityRequirement` map alias, and an `AgentCardSignature` record to `types.bal`. Parse `securitySchemes` through a dedicated tolerant helper (drops unrecognized entries instead of failing the whole card) rather than via the single-shot `cloneWithType(AgentCard)` every other field uses. Fix the v0.3 AgentCard field-name gap with a presence-based JSON rename pass in `compat_v03.bal`, run before typed parsing.

**Tech Stack:** Ballerina (records, closed-with-rest-field types, tagged unions, `cloneWithType`/`ensureType`), `ballerina/test`.

**Design spec:** `a2a/docs/superpowers/specs/2026-07-29-security-scheme-typing-design.md` — read this once at the start; it has the full rationale for every decision below.

## Global Constraints

- No change to any existing public method signature in `client.bal`.
- `securitySchemes`, `securityRequirements` (on both `AgentCard` and `AgentSkill`), and `signatures` all keep their current empty defaults (`{}`/`[]`) when absent from the wire — a card omitting them must still parse successfully, not error.
- Every new record type follows this codebase's established open-record-with-typed-rest pattern: `record {| <fields>; json...; |}` — no new type may be a fully closed record.
- An entry in `AgentCard.securitySchemes` whose `type` doesn't match any of the 5 known `SecurityScheme` variants (or is otherwise malformed) must be silently dropped from the parsed map — it must never cause the whole `AgentCard` parse to fail.
- JWS signature *verification* and automatic client auth configuration derived from a parsed scheme are explicitly out of scope for this plan.
- `in` and `type` are Ballerina reserved words; use the escaped identifiers `'in` / `'type` at every field declaration and access site. The wire JSON key stays the unescaped `in`/`type`.
- Follow existing test conventions exactly: `@test:Config {}` + `original.toJson().cloneWithType(T)` + `test:assertEquals(decoded, original)` for round-trips; a `json payload = {...}` literal with a `futureField` for tolerance tests. See `a2a/tests/types_test.bal` for the pattern used by every other type.

---

### Task 1: OAuth2 flow types

**Files:**
- Modify: `a2a/types.bal` (append near the end of the file, after the last existing type)
- Test: `a2a/tests/types_test.bal` (append near the end of the file)

**Interfaces:**
- Produces: `OAuthFlows`, `AuthorizationCodeOAuthFlow`, `ClientCredentialsOAuthFlow`, `ImplicitOAuthFlow`, `PasswordOAuthFlow` — all consumed by `OAuth2SecurityScheme` in Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testAuthorizationCodeOAuthFlowRoundTrip() returns error? {
    AuthorizationCodeOAuthFlow original = {
        authorizationUrl: "https://auth.example.com/authorize",
        refreshUrl: "https://auth.example.com/refresh",
        scopes: {"read": "Read access", "write": "Write access"},
        tokenUrl: "https://auth.example.com/token"
    };
    AuthorizationCodeOAuthFlow decoded = check original.toJson().cloneWithType(AuthorizationCodeOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAuthorizationCodeOAuthFlowToleratesUnrecognizedField() returns error? {
    json payload = {
        authorizationUrl: "https://auth.example.com/authorize",
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token",
        futureField: "some value from a newer spec revision"
    };

    AuthorizationCodeOAuthFlow decoded = check payload.cloneWithType(AuthorizationCodeOAuthFlow);

    test:assertTrue(decoded?.refreshUrl is (), "refreshUrl should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testClientCredentialsOAuthFlowRoundTrip() returns error? {
    ClientCredentialsOAuthFlow original = {
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token"
    };
    ClientCredentialsOAuthFlow decoded = check original.toJson().cloneWithType(ClientCredentialsOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testImplicitOAuthFlowRoundTrip() returns error? {
    ImplicitOAuthFlow original = {
        authorizationUrl: "https://auth.example.com/authorize",
        scopes: {"read": "Read access"}
    };
    ImplicitOAuthFlow decoded = check original.toJson().cloneWithType(ImplicitOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testPasswordOAuthFlowRoundTrip() returns error? {
    PasswordOAuthFlow original = {
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token"
    };
    PasswordOAuthFlow decoded = check original.toJson().cloneWithType(PasswordOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuthFlowsRoundTripWithAllFourFlows() returns error? {
    OAuthFlows original = {
        authorizationCode: {
            authorizationUrl: "https://auth.example.com/authorize",
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        },
        clientCredentials: {
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        },
        implicit: {
            authorizationUrl: "https://auth.example.com/authorize",
            scopes: {"read": "Read access"}
        },
        password: {
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        }
    };
    OAuthFlows decoded = check original.toJson().cloneWithType(OAuthFlows);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuthFlowsToleratesAllFieldsUnset() returns error? {
    json payload = {};

    OAuthFlows decoded = check payload.cloneWithType(OAuthFlows);

    test:assertTrue(decoded?.authorizationCode is (), "authorizationCode should be nil");
    test:assertTrue(decoded?.clientCredentials is (), "clientCredentials should be nil");
    test:assertTrue(decoded?.implicit is (), "implicit should be nil");
    test:assertTrue(decoded?.password is (), "password should be nil");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `"/c/Program Files/Ballerina/bin/bal.bat" test --tests testAuthorizationCodeOAuthFlowRoundTrip -- true` from `a2a-ballerina/a2a` (or, without a test filter, run the full suite; PowerShell equivalent: `& "C:\Program Files\Ballerina\bin\bal.bat" test`).
Expected: compile error — `OAuthFlows`/`AuthorizationCodeOAuthFlow`/etc. are undefined types.

- [ ] **Step 3: Add the types**

Append to `a2a/types.bal`:

```ballerina
# Configuration for one OAuth 2.0 Authorization Code flow.
public type AuthorizationCodeOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl;
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# Configuration for one OAuth 2.0 Client Credentials flow.
public type ClientCredentialsOAuthFlow record {|
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# Configuration for one OAuth 2.0 Implicit flow.
public type ImplicitOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl;
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    json...;
|};

# Configuration for one OAuth 2.0 Resource Owner Password flow.
public type PasswordOAuthFlow record {|
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# The set of OAuth 2.0 flows an OAuth2SecurityScheme supports. Each is
# independently optional; a scheme may support one or several.
public type OAuthFlows record {|
    AuthorizationCodeOAuthFlow? authorizationCode?;
    ClientCredentialsOAuthFlow? clientCredentials?;
    ImplicitOAuthFlow? implicit?;
    PasswordOAuthFlow? password?;
    json...;
|};
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2. Expected: all new tests pass, and the existing suite (168 passing / 0 failing in `a2a`, before this task) still passes in full — run the whole suite, not just the filtered tests, to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: add OAuth2 flow types (OAuthFlows and its 4 flow variants)"
```

---

### Task 2: SecurityScheme discriminated union

**Files:**
- Modify: `a2a/types.bal`
- Test: `a2a/tests/types_test.bal`

**Interfaces:**
- Consumes: `OAuthFlows` from Task 1.
- Produces: `SecurityScheme` (used by Task 3's `AgentCard.securitySchemes` field type, and Task 4's `parseSecuritySchemes`).

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testApiKeySecuritySchemeRoundTrip() returns error? {
    ApiKeySecurityScheme original = {
        description: "API key passed as a header",
        'in: "header",
        name: "X-API-Key"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is ApiKeySecurityScheme, "should decode as ApiKeySecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testHttpAuthSecuritySchemeRoundTrip() returns error? {
    HttpAuthSecurityScheme original = {
        scheme: "bearer",
        bearerFormat: "JWT"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is HttpAuthSecurityScheme, "should decode as HttpAuthSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuth2SecuritySchemeRoundTrip() returns error? {
    OAuth2SecurityScheme original = {
        flows: {
            clientCredentials: {
                tokenUrl: "https://auth.example.com/token",
                scopes: {"read": "Read access"}
            }
        }
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is OAuth2SecurityScheme, "should decode as OAuth2SecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testOpenIdConnectSecuritySchemeRoundTrip() returns error? {
    OpenIdConnectSecurityScheme original = {
        openIdConnectUrl: "https://auth.example.com/.well-known/openid-configuration"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is OpenIdConnectSecurityScheme, "should decode as OpenIdConnectSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testMutualTlsSecuritySchemeRoundTrip() returns error? {
    MutualTlsSecurityScheme original = {
        description: "Mutual TLS required"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is MutualTlsSecurityScheme, "should decode as MutualTlsSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testApiKeySecuritySchemeToleratesUnrecognizedField() returns error? {
    json payload = {
        'in: "query",
        name: "api_key",
        'type: "apiKey",
        futureField: "some value from a newer spec revision"
    };

    SecurityScheme decoded = check payload.cloneWithType(SecurityScheme);

    test:assertTrue(decoded is ApiKeySecurityScheme, "should decode as ApiKeySecurityScheme");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: compile error — `SecurityScheme`/`ApiKeySecurityScheme`/etc. are undefined types.

- [ ] **Step 3: Add the types**

Append to `a2a/types.bal`:

```ballerina
# A security scheme using an API key, per OpenAPI 3.0's Security Scheme
# Object.
public type ApiKeySecurityScheme record {|
    string? description?;
    # Where the API key is sent
    "query"|"header"|"cookie" 'in;
    # The header, query, or cookie parameter name
    string name;
    "apiKey" 'type = "apiKey";
    json...;
|};

# A security scheme using HTTP authentication (e.g. Bearer, Basic), per
# OpenAPI 3.0's Security Scheme Object.
public type HttpAuthSecurityScheme record {|
    string? description?;
    # The IANA HTTP Authentication Scheme name, e.g. "Bearer"
    string scheme;
    # Hint for how the bearer token is formatted, e.g. "JWT"
    string? bearerFormat?;
    "http" 'type = "http";
    json...;
|};

# A security scheme using OAuth 2.0, per OpenAPI 3.0's Security Scheme
# Object.
public type OAuth2SecurityScheme record {|
    string? description?;
    # The OAuth 2.0 flows this scheme supports
    OAuthFlows flows;
    # URL to the OAuth2 authorization server's RFC 8414 metadata
    string? oauth2MetadataUrl?;
    "oauth2" 'type = "oauth2";
    json...;
|};

# A security scheme using OpenID Connect, per OpenAPI 3.0's Security
# Scheme Object.
public type OpenIdConnectSecurityScheme record {|
    string? description?;
    # The OpenID Connect Discovery URL for the provider's metadata
    string openIdConnectUrl;
    "openIdConnect" 'type = "openIdConnect";
    json...;
|};

# A security scheme using mutual TLS authentication, per OpenAPI 3.0's
# Security Scheme Object.
public type MutualTlsSecurityScheme record {|
    string? description?;
    "mutualTLS" 'type = "mutualTLS";
    json...;
|};

# A security scheme an agent declares as available to authorize requests.
# Discriminated by the `type` field's literal value; cloneWithType against
# this union selects the one variant whose `type` literal matches the JSON.
public type SecurityScheme ApiKeySecurityScheme|HttpAuthSecurityScheme|OAuth2SecurityScheme
    |OpenIdConnectSecurityScheme|MutualTlsSecurityScheme;
```

- [ ] **Step 4: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, full suite still 0 failing.

- [ ] **Step 5: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: add SecurityScheme discriminated union (5 scheme variants)"
```

---

### Task 3: SecurityRequirement, AgentCardSignature, and AgentCard/AgentSkill field type changes

**Files:**
- Modify: `a2a/types.bal`
- Modify: `a2a/tests/types_test.bal` — includes fixing 2 existing tests whose literals no longer type-check after this task's field-type changes

**Interfaces:**
- Consumes: `SecurityScheme` from Task 2.
- Produces: `AgentCard.securitySchemes: map<SecurityScheme>`, `AgentCard.securityRequirements: SecurityRequirement[]`, `AgentSkill.securityRequirements: SecurityRequirement[]`, `AgentCard.signatures: AgentCardSignature[]` — consumed by Task 4's `parseSecuritySchemes` and Task 6's `resolveAgentCard`/`getExtendedAgentCard` changes.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testAgentCardSignatureRoundTrip() returns error? {
    AgentCardSignature original = {
        header: {"alg": "RS256", "kid": "key-1"},
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"
    };
    AgentCardSignature decoded = check original.toJson().cloneWithType(AgentCardSignature);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCardSignatureToleratesUnrecognizedField() returns error? {
    json payload = {
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ",
        futureField: "some value from a newer spec revision"
    };

    AgentCardSignature decoded = check payload.cloneWithType(AgentCardSignature);

    test:assertTrue(decoded?.header is (), "header should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testSecurityRequirementRoundTrip() returns error? {
    SecurityRequirement original = {"oauth": ["read", "write"], "apiKey": []};
    SecurityRequirement decoded = check original.toJson().cloneWithType(SecurityRequirement);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCardWithTypedSecurityFieldsRoundTrip() returns error? {
    AgentCard original = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer", bearerFormat: "JWT"},
            "apiKeyAuth": <ApiKeySecurityScheme>{'in: "header", name: "X-API-Key"}
        },
        securityRequirements: [{"bearerAuth": []}, {"apiKeyAuth": []}],
        signatures: [
            {protected: "eyJhbGciOiJSUzI1NiJ9", signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"}
        ],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city",
                securityRequirements: [{"bearerAuth": []}]
            }
        ]
    };
    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded, original);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: compile errors — `AgentCardSignature`/`SecurityRequirement` undefined, and `AgentCard.securitySchemes`/`securityRequirements`/`signatures` and `AgentSkill.securityRequirements` still typed as `map<json>`/`json[]` so the typed literals above don't type-check.

- [ ] **Step 3: Add the types and update `AgentCard`/`AgentSkill`**

Append to `a2a/types.bal` (after the `SecurityScheme` union from Task 2):

```ballerina
# One security requirement: a set of scheme names that must all be
# satisfied together (an AND), with each scheme's required OAuth scopes
# (empty for scheme types that don't use scopes). AgentCard/AgentSkill
# express a list of these, which is an OR across the list — "either this
# whole requirement, or that one."
public type SecurityRequirement map<string[]>;

# A JSON Web Signature (RFC 7515) computed over an AgentCard, for
# authenticity verification. This library captures the signature's shape
# but does not verify it — see the design spec for why verification is
# out of scope.
public type AgentCardSignature record {|
    # Unprotected JWS header values
    map<json>? header?;
    # Base64url-encoded protected JWS header
    string protected;
    # Base64url-encoded computed signature
    string signature;
    json...;
|};
```

In `AgentSkill`, replace:

```ballerina
    json[] securityRequirements = [];
```

with:

```ballerina
    SecurityRequirement[] securityRequirements = [];
```

(keep the existing doc comment above the field as-is, just fixing its "untyped pending full SecurityRequirement modelling" clause: replace the whole comment with `# Per-skill security override, following the same OR-of-ANDs semantics as AgentCard.securityRequirements`).

In `AgentCard`, replace:

```ballerina
    # Scheme shapes vary (API key, HTTP auth, OAuth2, OIDC, mTLS); untyped pending full modelling
    map<json> securitySchemes = {};
    # Which security schemes apply; untyped pending full SecurityRequirement
    # modelling, same as securitySchemes
    json[] securityRequirements = [];
```

with:

```ballerina
    # Security schemes available to authorize requests, keyed by scheme name
    map<SecurityScheme> securitySchemes = {};
    # Which security schemes apply; a logical OR across the list, each
    # entry a logical AND of the schemes it names
    SecurityRequirement[] securityRequirements = [];
```

and replace:

```ballerina
    # JWS signatures over this card, for authenticity verification
    json[] signatures = [];
```

with:

```ballerina
    # JWS signatures over this card. Captured but not verified — see
    # AgentCardSignature's doc comment
    AgentCardSignature[] signatures = [];
```

- [ ] **Step 4: Fix the 2 existing tests broken by the field-type change**

In `a2a/tests/types_test.bal`, `testAgentCardCompositeRoundTrip` currently has:

```ballerina
        securitySchemes: {"bearerAuth": {"type": "http", "scheme": "bearer"}},
```

Change to:

```ballerina
        securitySchemes: {"bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer"}},
```

`testAgentSkillRoundTrip`'s `securityRequirements: [{"bearerAuth": []}]` line needs no change — a `map<string[]>` literal already matches `SecurityRequirement`.

- [ ] **Step 5: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, the 2 fixed tests pass, full suite still 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: type AgentCard.securitySchemes/securityRequirements/signatures and AgentSkill.securityRequirements"
```

---

### Task 4: Tolerant `securitySchemes` parsing

**Files:**
- Modify: `a2a/types.bal` (add `parseSecuritySchemes` near the other types, or at file end — implementer's choice, matching where similar helper functions already sit in this file if any exist; otherwise append at file end)
- Test: `a2a/tests/types_test.bal`

**Interfaces:**
- Consumes: `SecurityScheme` from Task 2.
- Produces: `parseSecuritySchemes(json raw) returns map<SecurityScheme>|error` — consumed by Task 6's `resolveAgentCard`/`getExtendedAgentCard` changes.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testParseSecuritySchemesKeepsValidEntriesOfDifferentTypes() returns error? {
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "apiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 2);
    test:assertTrue(result.get("bearerAuth") is HttpAuthSecurityScheme);
    test:assertTrue(result.get("apiKeyAuth") is ApiKeySecurityScheme);
}

@test:Config {}
function testParseSecuritySchemesDropsUnrecognizedType() returns error? {
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "quantumAuth": {"type": "quantumEntanglement", "someField": "value"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 1);
    test:assertTrue(result.hasKey("bearerAuth"));
    test:assertFalse(result.hasKey("quantumAuth"));
}

@test:Config {}
function testParseSecuritySchemesDropsMalformedEntry() returns error? {
    // apiKey scheme missing the required "name" field
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "brokenApiKey": {"type": "apiKey", "in": "header"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 1);
    test:assertTrue(result.hasKey("bearerAuth"));
    test:assertFalse(result.hasKey("brokenApiKey"));
}

@test:Config {}
function testParseSecuritySchemesOnEmptyMap() returns error? {
    json raw = {};

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: compile error — `parseSecuritySchemes` is undefined.

- [ ] **Step 3: Implement `parseSecuritySchemes`**

Append to `a2a/types.bal`:

```ballerina
# Parses each entry of a raw securitySchemes JSON object independently,
# silently omitting entries that don't match any known SecurityScheme
# variant (unrecognized `type`, or otherwise malformed) rather than
# failing the whole AgentCard parse. This keeps AgentCard parsing
# forward-compatible with scheme kinds a server might add in the future.
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

- [ ] **Step 4: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, full suite still 0 failing.

- [ ] **Step 5: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: add parseSecuritySchemes for tolerant securitySchemes parsing"
```

---

### Task 5: v0.3 `security` field-name rename pass

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Produces: `renameV03SecurityField(json raw) returns json` — consumed by Task 6's `resolveAgentCard`/`getExtendedAgentCard` changes.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testRenameV03SecurityFieldRenamesTopLevelAndSkillLevel() returns error? {
    json v03Card = {
        name: "Legacy Agent",
        description: "A v0.3-style agent",
        version: "1.0.0",
        security: [{"oauth": ["read"]}],
        skills: [
            {
                id: "skill-1",
                name: "Skill One",
                description: "Does a thing",
                security: [{"apiKey": []}]
            }
        ]
    };

    json renamed = renameV03SecurityField(v03Card);
    map<json> renamedMap = check renamed.ensureType();

    test:assertFalse(renamedMap.hasKey("security"), "top-level security key should be gone");
    test:assertTrue(renamedMap.hasKey("securityRequirements"), "top-level securityRequirements key should exist");

    json[] skills = check renamedMap.skills.ensureType();
    map<json> firstSkill = check skills[0].ensureType();
    test:assertFalse(firstSkill.hasKey("security"), "skill-level security key should be gone");
    test:assertTrue(firstSkill.hasKey("securityRequirements"), "skill-level securityRequirements key should exist");
}

@test:Config {}
function testRenameV03SecurityFieldIsNoOpWhenV1FieldAlreadyPresent() returns error? {
    json v1Card = {
        name: "v1.0 Agent",
        description: "A v1.0 agent",
        version: "1.0.0",
        securityRequirements: [{"bearerAuth": []}],
        skills: []
    };

    json renamed = renameV03SecurityField(v1Card);
    map<json> renamedMap = check renamed.ensureType();

    test:assertFalse(renamedMap.hasKey("security"), "no stray security key should appear");
    json[] requirements = check renamedMap.securityRequirements.ensureType();
    test:assertEquals(requirements.length(), 1);
}

@test:Config {}
function testRenameV03SecurityFieldIsNoOpWhenNeitherKeyPresent() returns error? {
    json card = {
        name: "Bare Agent",
        description: "No security fields at all",
        version: "1.0.0",
        skills: []
    };

    json renamed = renameV03SecurityField(card);
    map<json> renamedMap = check renamed.ensureType();

    test:assertFalse(renamedMap.hasKey("security"));
    test:assertFalse(renamedMap.hasKey("securityRequirements"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: compile error — `renameV03SecurityField` is undefined.

- [ ] **Step 3: Implement `renameV03SecurityField`**

Append to `a2a/compat_v03.bal`:

```ballerina
# Renames the v0.3-dialect `security` key to the v1.0 field name
# `securityRequirements`, at the AgentCard's top level and within each
# element of `skills`, so a v0.3 server's security-requirement data
# populates the typed field instead of falling into the open record's
# untyped rest fields. Presence-based rather than mode-based: this must
# run before an AgentCard is typed-parsed at all, before the protocol
# dialect can be detected from the parsed card, so it looks at the raw
# JSON shape directly instead. A no-op when `securityRequirements` is
# already present (v1.0 cards) or `security` is absent (cards with no
# security fields at all).
#
# + raw - the raw JSON AgentCard body, before typed parsing
# + return - the body with `security` renamed to `securityRequirements`
#            wherever applicable
isolated function renameV03SecurityField(json raw) returns json {
    if raw !is map<json> {
        return raw;
    }
    map<json> cardMap = raw.clone();
    if cardMap.hasKey("security") && !cardMap.hasKey("securityRequirements") {
        cardMap["securityRequirements"] = cardMap.remove("security");
    }

    json? skillsField = cardMap["skills"];
    if skillsField is json[] {
        json[] renamedSkills = [];
        foreach json skillJson in skillsField {
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

- [ ] **Step 4: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, full suite still 0 failing.

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add renameV03SecurityField for v0.3 AgentCard security field-name compat"
```

---

### Task 6: Wire tolerant parsing into `resolveAgentCard` and `getExtendedAgentCard`

**Files:**
- Modify: `a2a/client.bal`
- Test: `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `parseSecuritySchemes` (Task 4), `renameV03SecurityField` (Task 5).

This task changes both `AgentCard`-producing entry points from a single
`cloneWithType(AgentCard)` call to a 4-step sequence: rename → extract
`securitySchemes` → clone the remainder → parse and reattach
`securitySchemes`. Both call sites need the identical sequence, so factor
it into one shared private function first.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/client_test.bal`. This models the Java reference
server's rich field set (already named in `A2A_Technical_Design.md` §11.3
as this project's rich-field-tolerance target: populated `provider`,
`signatures`, populated `securitySchemes`), plus one v0.3-dialect
`security`-keyed card, plus one card with an unrecognized scheme entry.

```ballerina
@test:Config {}
function testResolveAgentCardParsesRichFieldSetWithTypedSecurity() returns error? {
    setWellKnownOverride({
        name: "Rich Agent",
        description: "An agent with a full field set",
        version: "2.0.0",
        provider: {organization: "Acme Corp", url: "https://acme.example.com"},
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC"}
        ],
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "apiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
        },
        securityRequirements: [{"bearerAuth": []}],
        signatures: [
            {protected: "eyJhbGciOiJSUzI1NiJ9", signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"}
        ],
        skills: []
    });

    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    test:assertEquals(card.securitySchemes.length(), 2);
    test:assertTrue(card.securitySchemes.get("bearerAuth") is HttpAuthSecurityScheme);
    test:assertTrue(card.securitySchemes.get("apiKeyAuth") is ApiKeySecurityScheme);
    test:assertEquals(card.securityRequirements, [{"bearerAuth": []}]);
    test:assertEquals(card.signatures.length(), 1);
    test:assertEquals(card.provider?.organization, "Acme Corp");
}

@test:Config {}
function testResolveAgentCardDropsUnrecognizedSecuritySchemeEntry() returns error? {
    setWellKnownOverride({
        name: "Agent With Unknown Scheme",
        description: "Advertises a scheme type this client doesn't know",
        version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "quantumAuth": {"type": "quantumEntanglement", "someField": "value"}
        },
        skills: []
    });

    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    test:assertEquals(card.securitySchemes.length(), 1);
    test:assertTrue(card.securitySchemes.hasKey("bearerAuth"));
    test:assertFalse(card.securitySchemes.hasKey("quantumAuth"));
}

@test:Config {}
function testResolveAgentCardTranslatesV03SecurityField() returns error? {
    setWellKnownOverride({
        name: "v0.3 Agent",
        description: "Uses the v0.3 dialect's security field name",
        version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        security: [{"oauth": ["read"]}],
        skills: []
    });

    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    test:assertEquals(card.securityRequirements, [{"oauth": ["read"]}]);
}
```

`setWellKnownOverride(json? body, int statusCode = 200)` and
`getServerBaseUrl()` are the exact existing signatures in
`a2a/tests/testutil.bal` (lines 8 and 90) — used above as written, no
adjustment needed.

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: `testResolveAgentCardDropsUnrecognizedSecuritySchemeEntry` and
`testResolveAgentCardTranslatesV03SecurityField` fail (current
`cloneWithType(AgentCard)` either errors on the unrecognized scheme or
never populates `securityRequirements` from the v0.3 `security` key).
`testResolveAgentCardParsesRichFieldSetWithTypedSecurity` should already
pass once Tasks 1-5 are in place, since that card has no malformed
entries — if it doesn't pass yet, that's this task's job too.

- [ ] **Step 3: Implement the shared parsing sequence**

In `a2a/client.bal`, add a private helper function (placed above
`resolveAgentCard`):

```ballerina
# Parses a raw AgentCard JSON body into a typed AgentCard, applying the
# v0.3 security field-name rename and the tolerant securitySchemes parse
# before the main typed clone, so neither a v0.3-dialect card nor a card
# advertising an unrecognized security scheme fails to parse entirely.
#
# + body - the raw JSON AgentCard body, straight off the wire
# + return - the parsed AgentCard, or an error if the remainder of the
#            card (everything but securitySchemes) doesn't match the
#            AgentCard shape
isolated function parseAgentCardBody(json body) returns AgentCard|error {
    json renamed = renameV03SecurityField(body);
    map<json> cardMap = check renamed.ensureType();

    json? securitySchemesJson = cardMap.hasKey("securitySchemes") ? cardMap.remove("securitySchemes") : ();

    AgentCard card = check cardMap.cloneWithType(AgentCard);

    if securitySchemesJson is json {
        card.securitySchemes = check parseSecuritySchemes(securitySchemesJson);
    }

    return card;
}
```

Then change `resolveAgentCard`'s last line from:

```ballerina
    json body = check resp.getJsonPayload();
    return check body.cloneWithType(AgentCard);
```

to:

```ballerina
    json body = check resp.getJsonPayload();
    return check parseAgentCardBody(body);
```

And change `getExtendedAgentCard`'s last line from:

```ballerina
        json result = check self.rpcCall("GetExtendedAgentCard", params);
        return check result.cloneWithType(AgentCard);
```

to:

```ballerina
        json result = check self.rpcCall("GetExtendedAgentCard", params);
        return check parseAgentCardBody(result);
```

- [ ] **Step 4: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, full suite still 0 failing.

- [ ] **Step 5: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: wire tolerant securitySchemes parsing and v0.3 security field rename into AgentCard parsing"
```

---

### Task 7: Update `A2A_Technical_Design.md`

**Files:**
- Modify: `a2a/docs/A2A_Technical_Design.md`

- [ ] **Step 1: Update §12.1's securitySchemes-typing line**

Find this line (from §12.1, "Known simplifications"):

```
> * **securitySchemes typing.** Typed as map\<json\> rather than a modelled union of the five scheme shapes. Consequence: no automatic client configuration from a fetched Agent Card. Still not implemented as of the remaining-operations branch; deferred to a follow-up.  
```

Replace with:

```
> * **securitySchemes/securityRequirements/signatures typing.** Now modelled: securitySchemes is a discriminated union of the 5 OpenAPI-style scheme shapes (parsed tolerantly — an entry with an unrecognized type is dropped rather than failing the whole card); securityRequirements (on both AgentCard and AgentSkill) is a list of scheme-name-to-scopes maps; signatures is a typed AgentCardSignature list capturing the JWS fields, but not verifying them. A v0.3-dialect card's "security" field name is also now translated to "securityRequirements" during parsing. Still not implemented: automatic client auth configuration derived from a parsed scheme, and JWS signature verification — both explicitly out of scope (see the design spec at docs/superpowers/specs/2026-07-29-security-scheme-typing-design.md).  
```

- [ ] **Step 2: Update the "Agent Card signature verification" line**

The existing §12.1 line:

```
> * **Agent Card signature verification.** The signatures field is captured but never verified. A malicious actor could serve a forged card. Deferred pending a security review and crypto integration.  
```

stays as-is — signature verification is still out of scope; the field is now typed but this caveat is still accurate and does not need to change.

- [ ] **Step 3: Commit**

```bash
git add a2a/docs/A2A_Technical_Design.md
git commit -m "docs: update A2A_Technical_Design.md for SecurityScheme/AgentCardSignature typing"
```

---

### Task 8: Tolerant parsing for `securityRequirements` (AgentCard and AgentSkill) and `signatures`

**Added after the final whole-branch review of Tasks 1-7.** That review found: only `securitySchemes` got tolerant per-entry parsing (Task 4/6); `AgentCard.securityRequirements`, `AgentSkill.securityRequirements`, and `AgentCard.signatures` moved from fully-permissive `json[]` to strict typed arrays with no equivalent tolerance path. A single malformed entry in any of these three now fails the *entire* `AgentCard` parse — a real regression from pre-branch behavior (where the data just sat inert in an untyped rest-field bucket), and in tension with this library's forward-compatibility tolerance guarantees, particularly relevant since the Java reference server (`A2A_Technical_Design.md` §11.3's stated rich-field-tolerance target) is known to emit populated `signatures` and `security`-family fields. This task closes that gap using the same drop-the-bad-entry pattern already established for `securitySchemes`.

**Files:**
- Modify: `a2a/types.bal` (two new helper functions)
- Modify: `a2a/client.bal` (`parseAgentCardBody`)
- Test: `a2a/tests/types_test.bal`, `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `SecurityRequirement`, `AgentCardSignature` (Task 3), `parseAgentCardBody` (Task 6, being extended here).
- Produces: `parseSecurityRequirements(json raw) returns SecurityRequirement[]|error`, `parseAgentCardSignatures(json raw) returns AgentCardSignature[]|error`.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testParseSecurityRequirementsKeepsValidEntriesDropsMalformed() returns error? {
    json raw = [
        {"oauth": ["read"]},
        {"apiKey": "not-an-array"}
    ];

    SecurityRequirement[] result = check parseSecurityRequirements(raw);

    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0], {"oauth": ["read"]});
}

@test:Config {}
function testParseSecurityRequirementsOnEmptyArray() returns error? {
    json raw = [];

    SecurityRequirement[] result = check parseSecurityRequirements(raw);

    test:assertEquals(result.length(), 0);
}

@test:Config {}
function testParseAgentCardSignaturesKeepsValidEntriesDropsMalformed() returns error? {
    json raw = [
        {"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "dGhpcyBpcyBhIHNpZ25hdHVyZQ"},
        {"header": {"alg": "RS256"}}
    ];

    AgentCardSignature[] result = check parseAgentCardSignatures(raw);

    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0].protected, "eyJhbGciOiJSUzI1NiJ9");
}

@test:Config {}
function testParseAgentCardSignaturesOnEmptyArray() returns error? {
    json raw = [];

    AgentCardSignature[] result = check parseAgentCardSignatures(raw);

    test:assertEquals(result.length(), 0);
}
```

Append to `a2a/tests/client_test.bal` (uses `setWellKnownOverride`/`getServerBaseUrl`, same as Task 6's tests — remember the `setWellKnownOverride(())` reset convention this file uses):

```ballerina
@test:Config {}
function testResolveAgentCardDropsMalformedSignatureAndSecurityRequirementEntries() returns error? {
    setWellKnownOverride({
        name: "Agent With Some Malformed Security Data",
        description: "Has one good and one bad entry in signatures, securityRequirements, and a skill's securityRequirements",
        version: "1.0.0",
        capabilities: {},
        securityRequirements: [
            {"oauth": ["read"]},
            {"apiKey": "not-an-array"}
        ],
        signatures: [
            {"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "dGhpcyBpcyBhIHNpZ25hdHVyZQ"},
            {"header": {"alg": "RS256"}}
        ],
        skills: [
            {
                id: "skill-1",
                name: "Skill One",
                description: "Has a mix of good and bad securityRequirements entries",
                securityRequirements: [
                    {"oauth": ["write"]},
                    {"broken": "not-an-array"}
                ]
            }
        ]
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals(card.securityRequirements.length(), 1);
    test:assertEquals(card.securityRequirements[0], {"oauth": ["read"]});
    test:assertEquals(card.signatures.length(), 1);
    test:assertEquals(card.signatures[0].protected, "eyJhbGciOiJSUzI1NiJ9");
    test:assertEquals(card.skills[0].securityRequirements.length(), 1);
    test:assertEquals(card.skills[0].securityRequirements[0], {"oauth": ["write"]});
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the full suite. Expected: compile error — `parseSecurityRequirements`/`parseAgentCardSignatures` undefined; once those compile, the `client_test.bal` test should still fail at runtime since `parseAgentCardBody` doesn't yet apply tolerant parsing to these 3 fields (a malformed entry currently fails the whole card parse).

- [ ] **Step 3: Add the two helper functions**

Append to `a2a/types.bal`:

```ballerina
# Parses a raw JSON array into a list of SecurityRequirement values,
# silently dropping any entry that doesn't clone into map<string[]>.
# Used for both AgentCard.securityRequirements and each AgentSkill's
# securityRequirements, so one malformed entry can't fail the whole
# AgentCard parse.
#
# + raw - the raw JSON value of a securityRequirements field
# + return - a list containing only the entries that parsed successfully
public isolated function parseSecurityRequirements(json raw) returns SecurityRequirement[]|error {
    json[] rawArray = check raw.ensureType();
    SecurityRequirement[] result = [];
    foreach json entry in rawArray {
        SecurityRequirement|error req = entry.cloneWithType(SecurityRequirement);
        if req is SecurityRequirement {
            result.push(req);
        }
    }
    return result;
}

# Parses a raw JSON array into a list of AgentCardSignature values,
# silently dropping any entry that doesn't match the AgentCardSignature
# shape, rather than failing the whole AgentCard parse over one
# malformed signature.
#
# + raw - the raw JSON value of the AgentCard's `signatures` field
# + return - a list containing only the entries that parsed successfully
public isolated function parseAgentCardSignatures(json raw) returns AgentCardSignature[]|error {
    json[] rawArray = check raw.ensureType();
    AgentCardSignature[] result = [];
    foreach json entry in rawArray {
        AgentCardSignature|error sig = entry.cloneWithType(AgentCardSignature);
        if sig is AgentCardSignature {
            result.push(sig);
        }
    }
    return result;
}
```

- [ ] **Step 4: Extend `parseAgentCardBody` in `a2a/client.bal`**

Replace the current body of `parseAgentCardBody`:

```ballerina
isolated function parseAgentCardBody(json body) returns AgentCard|error {
    json renamed = renameV03SecurityField(body);
    map<json> cardMap = check renamed.ensureType();

    boolean hasSecuritySchemes = cardMap.hasKey("securitySchemes");
    json securitySchemesJson = hasSecuritySchemes ? cardMap.remove("securitySchemes") : {};

    AgentCard card = check cardMap.cloneWithType(AgentCard);

    if hasSecuritySchemes {
        card.securitySchemes = check parseSecuritySchemes(securitySchemesJson);
    }

    return card;
}
```

with:

```ballerina
isolated function parseAgentCardBody(json body) returns AgentCard|error {
    json renamed = renameV03SecurityField(body);
    map<json> cardMap = check renamed.ensureType();

    boolean hasSecuritySchemes = cardMap.hasKey("securitySchemes");
    json securitySchemesJson = hasSecuritySchemes ? cardMap.remove("securitySchemes") : {};

    boolean hasSecurityRequirements = cardMap.hasKey("securityRequirements");
    json securityRequirementsJson = hasSecurityRequirements ? cardMap.remove("securityRequirements") : [];

    boolean hasSignatures = cardMap.hasKey("signatures");
    json signaturesJson = hasSignatures ? cardMap.remove("signatures") : [];

    // Skill-level securityRequirements needs the same tolerant treatment,
    // but every other AgentSkill field should still be strictly validated
    // by the main clone below -- so only that one sub-field is pulled out
    // of each skill first, not the whole skill.
    json? skillsField = cardMap["skills"];
    SecurityRequirement[][] perSkillSecurityRequirements = [];
    if skillsField is json[] {
        json[] strippedSkills = [];
        foreach json skillJson in skillsField {
            if skillJson is map<json> {
                map<json> skillMap = skillJson.clone();
                json skillSecurityRequirementsJson = skillMap.hasKey("securityRequirements")
                    ? skillMap.remove("securityRequirements") : [];
                perSkillSecurityRequirements.push(check parseSecurityRequirements(skillSecurityRequirementsJson));
                strippedSkills.push(skillMap);
            } else {
                perSkillSecurityRequirements.push([]);
                strippedSkills.push(skillJson);
            }
        }
        cardMap["skills"] = strippedSkills;
    }

    AgentCard card = check cardMap.cloneWithType(AgentCard);

    if hasSecuritySchemes {
        card.securitySchemes = check parseSecuritySchemes(securitySchemesJson);
    }
    if hasSecurityRequirements {
        card.securityRequirements = check parseSecurityRequirements(securityRequirementsJson);
    }
    if hasSignatures {
        card.signatures = check parseAgentCardSignatures(signaturesJson);
    }
    foreach int i in 0 ..< card.skills.length() {
        if i < perSkillSecurityRequirements.length() {
            card.skills[i].securityRequirements = perSkillSecurityRequirements[i];
        }
    }

    return card;
}
```

Also update this function's doc comment to mention all 3 now-tolerant fields, not just `securitySchemes`.

If any of this doesn't compile exactly as written (e.g. array-of-array mutation syntax, or index-based `card.skills[i].securityRequirements = ...` assignment behaving unexpectedly), you have latitude to restructure as long as the net behavior is preserved: explain any deviation in your report, same as Task 6.

- [ ] **Step 5: Run tests to verify they pass**

Run the full suite. Expected: all new tests pass, full suite still 0 failing overall (baseline before this task: 195 passing / 0 failing in `a2a`, 3 passing / 0 failing in `a2a.transport`).

- [ ] **Step 6: Update the doc comment in `A2A_Technical_Design.md`'s §12.1**

Task 7 already updated this section's securitySchemes-typing bullet to say securityRequirements/signatures are "now modelled" with a general framing. Find that bullet and add one clause noting all four fields (`securitySchemes`, both `securityRequirements` fields, `signatures`) now share the same tolerant, entry-dropping parsing behavior — not just `securitySchemes`.

- [ ] **Step 7: Commit**

```bash
git add a2a/types.bal a2a/client.bal a2a/tests/types_test.bal a2a/tests/client_test.bal a2a/docs/A2A_Technical_Design.md
git commit -m "feat: extend tolerant parsing to securityRequirements and signatures"
```
