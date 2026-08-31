# Client Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every client-side gap found in the spec-compliance audit
(`a2a-interop-tests/SPEC_COMPLIANCE_REPORT.md`) so the A2A client is
production-solid for developers calling other agents — without touching the
server/listener side, which is explicitly out of scope for this round and
will be scoped separately later.

**Architecture:** Each task is additive to the existing `Client` class
(`client.bal`) and type model (`types.bal`) — no breaking changes to existing
public signatures except where noted (Tasks 8–9 add new constructor options).
Tasks 1–7 hardening features are independent of each other; Tasks 8–9
(REST/gRPC transport bindings) are the two largest items and are scoped as
**design-spec-writing tasks** in this plan, matching this project's own
established practice (every prior major feature — v0.3 compat, remaining
operations, security-scheme typing — got its own dated design spec in
`docs/superpowers/specs/` before a bite-sized plan was written against it).
Two open technical unknowns (Ballerina gRPC codegen's server-streaming return
type; REST binding's SSE confirmation) must be resolved as part of writing
those specs — see Tasks 8–9 for exactly how.

**Tech Stack:** Ballerina (current release track this repo already targets),
`ballerina/http`, `ballerina/crypto` (new, for Task 4), `ballerina/grpc`
(new, for Task 9 spec-resolution step only in this plan — actual gRPC client
code is a follow-up plan).

## Global Constraints

- Every new test uses the existing scripted mock server pattern in
  `tests/testutil.bal` (`mockListener` on `localhost:19199`,
  `setNextJsonResponse`/`setNextSseResponse`/`setWellKnownOverride`) — do not
  introduce a second mock server or a different port.
- No existing public function signature changes without a default value that
  preserves current caller behavior exactly (this library's stated
  compatibility bar — see `REPO_MAP.md` §4's description of how `agentCard`
  was added to `Client.init` as an optional trailing parameter).
- Follow existing code style: `isolated` functions/classes throughout,
  doc comments with `# + param - description` / `# + return - description`
  on every public function, `A2AError` subtypes (never bare `error`) for
  anything the caller should be able to pattern-match on.
- Every task ends green: `bal test` run from `a2a-ballerina/a2a/` with zero
  failures before moving to the next task.
- Commit after every task (this repo's own CLAUDE.md-equivalent convention
  per `REPO_MAP.md`'s workflow section: one branch/PR per unit of work — for
  this plan, one commit per task is the minimum bar; a full PR-per-task is
  fine too if that's preferred at execution time).

---

## Task 1: AgentCard caching in `resolveAgentCard`

**Files:**
- Modify: `client.bal:81-101` (`resolveAgentCard`)
- Test: `tests/client_test.bal` (new test functions, existing file)

**Interfaces:**
- Consumes: nothing new — uses `http:Response` headers already available
  from the existing `discoveryClient->get(...)` call at `client.bal:90`.
- Produces: `resolveAgentCard` gains an optional `AgentCard? previousCard`
  parameter and an optional out-of-band way to read cache metadata. Kept
  minimal: add a `CachedAgentCard` wrapper type instead of overloading the
  existing return type, so no existing caller (which pattern-matches
  `AgentCard|error`) breaks.

- [ ] **Step 1: Write the failing test — a 304 response reuses the previous card**

```ballerina
// tests/client_test.bal
@test:Config {}
function testResolveAgentCardHonors304() returns error? {
    setWellKnownOverride(defaultMockAgentCard(), 200);
    CachedAgentCard first = check resolveAgentCardCached(getServerBaseUrl());
    test:assertTrue(first.etag is string, "first fetch should capture an ETag if the mock sends one");

    setWellKnownConditionalOverride(304);
    CachedAgentCard second = check resolveAgentCardCached(getServerBaseUrl(), previous = first);
    test:assertEquals(second.card, first.card, "a 304 response should return the previously cached card unchanged");
}
```

- [ ] **Step 2: Run it, confirm it fails** — `resolveAgentCardCached` and
  `setWellKnownConditionalOverride` don't exist yet.

Run: `bal test --tests testResolveAgentCardHonors304`
Expected: FAIL — compile error, undefined function.

- [ ] **Step 3: Add the mock-server conditional-response support**

In `tests/testutil.bal`, extend `MockWellKnownScript` with an `etag` field
and add:

```ballerina
public isolated function setWellKnownConditionalOverride(int statusCode) {
    lock {
        wellKnownScript.conditionalStatus = statusCode;
    }
}
```

Extend the `get \.well\-known/agent\-card\.json` resource to check the
incoming `If-None-Match` header against the scripted ETag and, if
`conditionalStatus` is set and the header matches, respond with that status
and no body instead of the card.

- [ ] **Step 4: Implement `CachedAgentCard` and `resolveAgentCardCached` in `client.bal`**

```ballerina
# An AgentCard together with the HTTP caching metadata needed to make a
# conditional follow-up request.
public type CachedAgentCard record {|
    AgentCard card;
    string? etag;
|};

# Fetches an agent's Agent Card, reusing a previous fetch's body when the
# server confirms nothing changed (HTTP 304), per standard HTTP caching —
# resolveAgentCard's original per-call fetch was always correct but never
# cheap; this adds the standard conditional-GET optimization on top without
# changing resolveAgentCard's own behavior.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + previous - A card previously returned by this function, to enable a
#              conditional (If-None-Match) request
# + return - The parsed AgentCard plus its caching metadata, or an error
public isolated function resolveAgentCardCached(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        CachedAgentCard? previous = ()) returns CachedAgentCard|error {
    http:Client discoveryClient = check new (agentBaseUrl, clientConfig);
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    string? prevEtag = previous?.etag;
    if prevEtag is string {
        reqHeaders["If-None-Match"] = prevEtag;
    }
    http:Response resp = check discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp.statusCode == 304 && previous is CachedAgentCard {
        return previous;
    }
    if resp.statusCode != 200 {
        return error A2AInternalError(
            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,
            code = resp.statusCode
        );
    }
    json body = check resp.getJsonPayload();
    AgentCard card = check parseAgentCardBody(body);
    string|error etagHeader = resp.getHeader("ETag");
    return {card, etag: etagHeader is string ? etagHeader : ()};
}
```

- [ ] **Step 5: Run the test, confirm it passes**

Run: `bal test --tests testResolveAgentCardHonors304`
Expected: PASS

- [ ] **Step 6: Add a doc-comment cross-reference** on the existing
  `resolveAgentCard` pointing to `resolveAgentCardCached` as the
  cache-aware alternative (one line, no behavior change to
  `resolveAgentCard` itself — it stays as-is for callers who don't need
  caching).

- [ ] **Step 7: Run the full suite, then commit**

Run: `bal test`
Expected: all passing, no regressions

```bash
git add a2a/client.bal a2a/tests/client_test.bal a2a/tests/testutil.bal
git commit -m "feat: add cache-aware AgentCard resolution via ETag/If-None-Match"
```

---

## Task 2: `A2A-Extensions` header support

**Files:**
- Modify: `client.bal:130-184` (`Client` class fields, `init`, `buildHeaders`)
- Test: `tests/client_test.bal`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Client.init` gains an optional `string[] requestedExtensions =
  []` parameter. `buildHeaders` sends it as a comma-joined `A2A-Extensions`
  header when non-empty. A new `getGrantedExtensions()` isolated remote-free
  method... actually kept as a plain method (not a remote call) that reads
  the extensions header off the *last* response, mirroring the existing
  `defaultHeaders`/`tenant` field pattern. Exposed as
  `client.lastGrantedExtensions()`.

- [ ] **Step 1: Write the failing test**

```ballerina
@test:Config {}
function testSendMessageSendsRequestedExtensionsHeader() returns error? {
    setNextJsonResponse({"task": defaultTaskJson()});
    Client c = check new (getServerBaseUrl(), requestedExtensions = ["urn:example:ext-a", "urn:example:ext-b"]);
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    map<string> headers = getLastRequestHeaders();
    test:assertEquals(headers["A2A-Extensions"], "urn:example:ext-a,urn:example:ext-b");
}

@test:Config {}
function testSendMessageCapturesGrantedExtensionsFromResponse() returns error? {
    setNextJsonResponse({"task": defaultTaskJson()}, extensionsHeader = "urn:example:ext-a");
    Client c = check new (getServerBaseUrl(), requestedExtensions = ["urn:example:ext-a"]);
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);
    test:assertEquals(c.lastGrantedExtensions(), ["urn:example:ext-a"]);
}
```

- [ ] **Step 2: Run, confirm both fail** — `requestedExtensions`,
  `getLastRequestHeaders`, the `extensionsHeader` param on
  `setNextJsonResponse`, and `lastGrantedExtensions()` don't exist yet.

Run: `bal test --tests testSendMessageSendsRequestedExtensionsHeader`
Expected: FAIL — compile errors.

- [ ] **Step 3: Extend `tests/testutil.bal`**

Add `map<string> lastRequestHeaders` (isolated, mirroring
`lastRequestBody`'s pattern) captured in the `post .` resource via
`req.getHeaderNames()`/`req.getHeader(name)`, plus `getLastRequestHeaders()`.
Add an optional `extensionsHeader` param to `setNextJsonResponse` that sets
`A2A-Extensions` (server → client direction) on the scripted response — per
spec §14.2.2, the response direction uses the exact same header name as the
request direction, not a distinct `X-`-prefixed name.

```ballerina
public isolated function setNextJsonResponse(json body, int statusCode = 200, string? extensionsHeader = ()) {
    lock {
        rpcScript = {jsonBody: body.clone(), statusCode, isSse: false, delaySeconds: 0, extensionsHeader};
    }
}
```

(Add `extensionsHeader` to `MockRpcScript` and set it on the response in the
`post .` resource when present.)

- [ ] **Step 4: Implement in `client.bal`**

```ballerina
private final string[] & readonly requestedExtensions;
private string[] grantedExtensions = [];
```

In `init`, add `string[] requestedExtensions = []` parameter, store as
`.cloneReadOnly()`.

In `buildHeaders`:

```ballerina
if self.requestedExtensions.length() > 0 {
    headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
}
```

After every `rpcCall`/`openSseStream` response is read, capture the
response's own extensions header (spec §14.2.2: `A2A-Extensions`, the same
header name used on the request side — the protocol has no separate
response-side name) into `self.grantedExtensions` — add this inside
`rpcCall` right after `http:Response resp = check
self.httpClient->post(...)`:

```ballerina
string|error extHeader = resp.getHeader("A2A-Extensions");
if extHeader is string {
    lock {
        self.grantedExtensions = extHeader.length() > 0 ? re `,`.split(extHeader) : [];
    }
}
```

(`Client` is already an `isolated client class`, so mutating
`grantedExtensions` needs a `lock` block, and the field must be declared
without `final`.)

Add:

```ballerina
# Returns the extensions the remote agent granted on the most recent call,
# per the response's A2A-Extensions header. Empty until the first call
# completes, or if the agent never sent the header.
#
# + return - the granted extension URIs
public isolated function lastGrantedExtensions() returns string[] {
    lock {
        return self.grantedExtensions.clone();
    }
}
```

- [ ] **Step 5: Run both tests, confirm pass**

Run: `bal test --tests testSendMessageSendsRequestedExtensionsHeader,testSendMessageCapturesGrantedExtensionsFromResponse`
Expected: PASS

- [ ] **Step 6: Repeat the capture wiring for `openSseStream`** (same
  header-read snippet after the stream's initial response, before handing
  off to `readSseStream`) — add one more test asserting
  `lastGrantedExtensions()` after `sendMessageStream`.

- [ ] **Step 7: Full suite, then commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal a2a/tests/testutil.bal
git commit -m "feat: add A2A-Extensions request/response header support"
```

---

## Task 3: Automatic client-auth wiring from `AgentCard.securitySchemes`

**Files:**
- Create: `auth.bal` (new file, root module — keeps `client.bal` focused,
  matches this codebase's existing pattern of splitting concerns into
  dedicated files: `errors.bal`, `sse.bal`, `compat_v03.bal`)
- Modify: `client.bal:155-165` (`Client.init` — new optional parameter)
- Test: `tests/auth_test.bal` (new file)

**Interfaces:**
- Consumes: `AgentCard.securitySchemes` (`types.bal:159`, `map<SecurityScheme>`),
  `SecurityRequirement` (`types.bal:497`, `map<string[]>`),
  `ApiKeySecurityScheme`/`HttpAuthSecurityScheme` (`types.bal:434-454`) —
  OAuth2/OpenIdConnect/MutualTLS are explicitly **not** auto-wired in this
  task (they need a token-acquisition flow / client cert, which is a
  separate, larger feature — this task only closes the two schemes that
  reduce to "one string" a caller already has in hand: an API key value or
  a bearer/basic token).
- Produces: a new `public isolated function buildAuthFromCard(AgentCard
  card, map<string> credentials) returns http:ClientConfiguration|error` in
  `auth.bal`, and `Client.init` gains an optional `AgentCard? authFromCard`
  + `map<string> credentials = {}` pair that, when given, calls this and
  merges the result into `clientConfig` before constructing `self.httpClient`.

- [ ] **Step 1: Design note before writing any test** —
  `http:ClientConfiguration` has no generic "static header" slot; that's
  what `Client.init`'s existing `headers` parameter is for
  (`client.bal:142-143`), not `clientConfig`. So `buildAuthFromCard`'s
  return type must be a small pair, not `http:ClientConfiguration` alone —
  define this type first, then write every test directly against it (no
  throwaway draft):

```ballerina
# The result of resolving an AgentCard's declared security requirements
# against a caller-supplied credential map: HTTP client auth config for
# schemes http:ClientConfiguration.auth natively supports (HTTP Bearer/Basic),
# plus a header map for schemes that don't (API key).
public type ResolvedAuth record {|
    http:ClientConfiguration clientConfig;
    map<string> headers;
|};
```

- [ ] **Step 2: Write the three failing tests against `ResolvedAuth`**

```ballerina
// tests/auth_test.bal
import ballerina/test;
import ballerina/http;

@test:Config {}
function testBuildAuthFromCardApiKeyHeader() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "apiKeyAuth": {'type: "apiKey", 'in: "header", name: "X-Api-Key"}
        },
        securityRequirements: [{"apiKeyAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"apiKeyAuth": "secret-123"});
    test:assertEquals(resolved.headers["X-Api-Key"], "secret-123");
}

@test:Config {}
function testBuildAuthFromCardHttpBearer() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": {'type: "http", scheme: "Bearer"}
        },
        securityRequirements: [{"bearerAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"bearerAuth": "tok-abc"});
    http:BearerTokenConfig|http:CredentialsConfig|() auth = resolved.clientConfig.auth;
    test:assertTrue(auth is http:BearerTokenConfig, "http+Bearer scheme should resolve to BearerTokenConfig");
    if auth is http:BearerTokenConfig {
        test:assertEquals(auth.token, "tok-abc");
    }
}

@test:Config {}
function testBuildAuthFromCardMissingCredentialErrors() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {"apiKeyAuth": {'type: "apiKey", 'in: "header", name: "X-Api-Key"}},
        securityRequirements: [{"apiKeyAuth": []}],
        skills: []
    };
    ResolvedAuth|error result = buildAuthFromCard(card, {});
    test:assertTrue(result is error, "missing a required scheme's credential should error, not silently send an unauthenticated request");
}
```

- [ ] **Step 3: Run, confirm all three fail** (implementation still missing)

- [ ] **Step 4: Implement `auth.bal`**

```ballerina
// Automatic client-auth wiring from an AgentCard's declared security
// schemes — closes the gap where a developer previously had to read
// card.securitySchemes by hand and build http:ClientConfiguration.auth
// themselves. Scoped to ApiKeySecurityScheme and HttpAuthSecurityScheme
// only: both reduce to "one credential string the caller already has."
// OAuth2/OpenIdConnect need a token-acquisition flow and MutualTLS needs a
// client certificate — none of those reduce to a single string, so they're
// deliberately left for the caller to wire through clientConfig directly,
// same as today.

import ballerina/http;

# HTTP client configuration resolved from an AgentCard's security
# requirements: http:ClientConfiguration.auth for scheme types it natively
# supports, plus a header map for scheme types (like API key) that don't
# map onto ClientConfiguration.auth at all.
public type ResolvedAuth record {|
    http:ClientConfiguration clientConfig;
    map<string> headers;
|};

# Resolves an AgentCard's first satisfiable SecurityRequirement (a logical
# OR across card.securityRequirements, each entry a logical AND of the
# scheme names it lists — spec section on SecurityRequirement) against a
# caller-supplied credential map, keyed by scheme name exactly as declared
# in card.securitySchemes.
#
# + card - the AgentCard whose securitySchemes/securityRequirements to read
# + credentials - one credential string per scheme name this call should
#                 satisfy; a scheme absent from securityRequirements is
#                 ignored even if a credential is supplied for it
# + return - resolved auth config, or an error if no SecurityRequirement
#            entry can be fully satisfied by the given credentials
public isolated function buildAuthFromCard(AgentCard card, map<string> credentials) returns ResolvedAuth|error {
    foreach SecurityRequirement requirement in card.securityRequirements {
        string[] schemeNames = requirement.keys();
        boolean allSatisfiable = true;
        foreach string schemeName in schemeNames {
            if !credentials.hasKey(schemeName) || !card.securitySchemes.hasKey(schemeName) {
                allSatisfiable = false;
                break;
            }
        }
        if !allSatisfiable {
            continue;
        }
        http:ClientConfiguration clientConfig = {};
        map<string> headers = {};
        foreach string schemeName in schemeNames {
            SecurityScheme scheme = card.securitySchemes.get(schemeName);
            string credential = credentials.get(schemeName);
            if scheme is ApiKeySecurityScheme {
                if scheme.'in == "header" {
                    headers[scheme.name] = credential;
                } else {
                    return error(string `apiKey scheme "${schemeName}" uses 'in: "${scheme.'in}"', which buildAuthFromCard does not automate yet — set it manually via Client.init's headers or serviceUrl query string`);
                }
            } else if scheme is HttpAuthSecurityScheme {
                if scheme.scheme.toLowerAscii() == "bearer" {
                    clientConfig.auth = {token: credential};
                } else if scheme.scheme.toLowerAscii() == "basic" {
                    // http:CredentialsConfig expects username+password, not
                    // one combined string. Caller must instead have supplied
                    // "username:password" as the credential value.
                    string[] parts = re `:`.split(credential);
                    if parts.length() != 2 {
                        return error(string `http Basic scheme "${schemeName}" requires credential in "username:password" form`);
                    }
                    clientConfig.auth = {username: parts[0], password: parts[1]};
                } else {
                    return error(string `http auth scheme "${scheme.scheme}" (name: "${schemeName}") is not automated yet`);
                }
            } else {
                return error(string `security scheme "${schemeName}" (type ${scheme.'type}) is not automated yet — OAuth2/OpenIdConnect/mutualTLS need manual clientConfig wiring`);
            }
        }
        return {clientConfig, headers};
    }
    return error("no SecurityRequirement in the AgentCard could be satisfied by the given credentials");
}
```

- [ ] **Step 5: Run all three new tests, confirm pass**

Run: `bal test --tests testBuildAuthFromCardApiKeyHeader,testBuildAuthFromCardHttpBearer,testBuildAuthFromCardMissingCredentialErrors`
Expected: PASS

- [ ] **Step 6: Wire an optional convenience path into `Client.init`**

Add `map<string> credentials = {}` parameter to `Client.init`; when
`agentCard` is given and `credentials` is non-empty, call
`buildAuthFromCard`, merge its `clientConfig` into the caller-supplied
`clientConfig` (caller-supplied values win on conflict — never silently
override an explicit choice), and merge its `headers` into the `headers`
map the same way. Add one integration test in `client_test.bal` proving a
`Client` constructed this way sends the resolved API-key header on an
actual `sendMessage` call (reusing `getLastRequestHeaders` from Task 2).

- [ ] **Step 7: Full suite, then commit**

```bash
git add a2a/auth.bal a2a/client.bal a2a/tests/auth_test.bal a2a/tests/client_test.bal
git commit -m "feat: auto-wire client auth from AgentCard securitySchemes (API key, HTTP Bearer/Basic)"
```

---

## Task 4: AgentCard signature (JWS) verification

**Files:**
- Create: `signature.bal` (new file, root module)
- Test: `tests/signature_test.bal` (new file)

**Interfaces:**
- Consumes: `AgentCardSignature` (`types.bal:503-511`: `protected` (base64url
  JWS protected header), `signature` (base64url), `header` (unprotected,
  optional)).
- Produces: `public isolated function verifyAgentCardSignature(AgentCard
  card, crypto:PublicKey publicKey, int signatureIndex = 0) returns
  boolean|error` — verifies one signature entry against a caller-supplied
  key (this library doesn't fetch keys itself — JWK-set resolution from a
  `jku`/`kid` is a separate, larger feature; this task closes "verification
  is possible at all" using a key the caller already has, e.g. pinned or
  fetched out-of-band).

**Known limitation (confirmed during the final whole-branch review, not
fixed in this pass):** spec §8.4.1 ("Canonicalization Requirements")
requires Agent Card signing to use RFC 8785 JSON Canonicalization Scheme
(JCS) before computing the JWS signing input, so that different JSON
serializers' field ordering and formatting don't produce different bytes
to sign over. `signature.bal` does not implement JCS — it reconstructs the
signing payload via Ballerina's own `toJsonString()` (record-declaration
field order, Ballerina's own number/string formatting), with no
canonicalization step. This was a deliberate choice, not an oversight:
implementing RFC 8785 correctly (recursive Unicode-code-point key sorting,
ECMAScript-`Number::toString`-compatible number formatting, ECMA-262
string escaping) has enough intricate edge cases — especially numbers,
since `AgentCard` and its nested records are open (`json...`) and can
carry arbitrary caller/extension data — that a partial or subtly-incorrect
implementation risked being worse than clearly documenting the gap. The
function is fail-closed (rejects valid non-Ballerina-signed cards; never
accepts a forged one), so this is a completeness gap, not a security hole.
A caller verifying a card signed by a spec-conformant JCS signer (e.g. a
Python or Java reference implementation) will currently get a `false`
result even for a genuinely validly-signed card. See the LIMITATION note
on `verifyAgentCardSignature`'s doc comment in `signature.bal` for the
same statement at the call site.

**Confirmed API facts this task is built on** (resolved during planning,
not left open):
- `ballerina/crypto`'s verified public surface: `crypto:verifyRsaSha256Signature(byte[]
  data, byte[] signature, crypto:PublicKey publicKey) returns
  boolean|crypto:Error` (RS256) and
  `crypto:verifySha256withEcdsaSignature(byte[] data, byte[] signature,
  crypto:PublicKey publicKey) returns boolean|crypto:Error` (ES256).
  **`ballerina/crypto` has no Ed25519/EdDSA verification function at
  all** — so `verifyAgentCardSignature` supports RS256 and ES256 only, and
  returns a typed error for any other `alg`. This is a permanent scope
  limit of this task, not a gap to fill later in this same plan (RS256/ES256
  cover the overwhelming majority of real-world JWS deployments, so this is
  a reasonable initial scope, not a half-measure).
- `ballerina/crypto` has **no `fromBase64Url` function** and **no
  key-generation function** (no `generateRsaKeys`/`generateEcKeys`
  equivalent). Both are worked around below: a small local base64url helper,
  and a static pre-generated test keypair checked into the test file
  instead of generating one at test time.
- Public key loading: `crypto:decodeRsaPublicKeyFromContent(byte[]
  content) returns crypto:PublicKey|crypto:Error` accepts raw certificate
  bytes directly (no temp file needed) — used for the RS256 path. The
  ECDSA equivalent found is file-based only
  (`crypto:decodeEcPublicKeyFromCertFile(string certFile)`), so the ES256
  test path writes its static test certificate to a temp file first
  (`ballerina/file`'s `file:createTemp` or a fixed path under a test
  `resources/` directory — either is fine, pick one and use it
  consistently).

- [ ] **Step 1: Write the failing test — RS256-signed card verifies, and a
  tampered card fails**

```ballerina
// tests/signature_test.bal
import ballerina/test;
import ballerina/crypto;

@test:Config {}
function testVerifyAgentCardSignatureRs256Valid() returns error? {
    AgentCard signedCard = buildRs256SignedTestCard();
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean result = check verifyAgentCardSignature(signedCard, publicKey);
    test:assertTrue(result, "signature over an unmodified card should verify");
}

@test:Config {}
function testVerifyAgentCardSignatureRs256TamperedCardFails() returns error? {
    AgentCard signedCard = buildRs256SignedTestCard();
    AgentCard tampered = signedCard.clone();
    tampered.description = "a different description than what was signed";
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean result = check verifyAgentCardSignature(tampered, publicKey);
    test:assertFalse(result, "signature should not verify once card content changes");
}

@test:Config {}
function testVerifyAgentCardSignatureUnsupportedAlgErrors() returns error? {
    AgentCard card = buildRs256SignedTestCard();
    // Rewrite the protected header's alg to something this library
    // deliberately doesn't support (e.g. EdDSA, since ballerina/crypto has
    // no verification function for it) and confirm a clear typed error,
    // not a crash or a false "true".
    card.signatures[0].protected = encodeProtectedHeaderWithAlg("EdDSA");
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey);
    test:assertTrue(result is error, "an alg this library can't verify should error, not silently return false or true");
}
```

- [ ] **Step 2: Run, confirm compile failure** (`verifyAgentCardSignature`,
  `buildRs256SignedTestCard`, `testRs256CertBytes`,
  `encodeProtectedHeaderWithAlg` don't exist).

- [ ] **Step 3: Implement the base64url helper and `signature.bal`**

```ballerina
// AgentCard JWS signature verification (RFC 7515). This library has
// always captured AgentCardSignature's shape (types.bal) without
// verifying it — a forged or tampered card would go undetected. This
// closes that gap for a caller who already holds the expected public key
// (pinned, or fetched out-of-band); automatic key discovery via a JWK set
// URL is a separate, larger feature and not in scope here.
//
// Scoped to RS256 and ES256 — the two algorithms ballerina/crypto actually
// has verification functions for. A card signed with any other alg (e.g.
// EdDSA, which ballerina/crypto cannot verify at all) is rejected with a
// clear error rather than silently skipped or falsely accepted.

import ballerina/crypto;
import ballerina/lang.array;

# Decodes a base64url string (RFC 4648 §5 — the alphabet JWS uses
# throughout: '-'/'_' instead of '+'/'/', no padding), which
# ballerina/crypto and ballerina/lang.array only provide standard-alphabet
# base64 decoding for.
#
# + encoded - the base64url-encoded string
# + return - the decoded bytes, or an error if not valid base64url
isolated function decodeBase64Url(string encoded) returns byte[]|error {
    string standard = re `-`.replaceAll(re `_`.replaceAll(encoded, "/"), "+");
    int padNeeded = (4 - standard.length() % 4) % 4;
    string padded = standard + "=".repeat(padNeeded);
    return array:fromBase64(padded);
}

# Verifies one of an AgentCard's JWS signatures (RFC 7515) against a
# caller-supplied public key. The JWS payload is the AgentCard's own JSON
# serialization with the `signatures` field itself removed (a signature
# can't cover itself) — reconstructed here rather than trusting any
# embedded payload, since JWS's compact form for a detached signature
# carries no payload of its own.
#
# + card - the AgentCard to verify, including its `signatures` entries
# + publicKey - the key to verify against
# + signatureIndex - which entry of card.signatures to verify, if more
#                     than one is present; defaults to the first
# + return - true if the signature is valid for this exact card content,
#            false if it doesn't match (not an error — a tampered or
#            wrongly-keyed card is an expected, checkable outcome), or an
#            error if signatureIndex is out of range, the JWS structure is
#            malformed, or the protected header's alg is anything other
#            than RS256/ES256 (the only algorithms ballerina/crypto can
#            verify)
public isolated function verifyAgentCardSignature(
        AgentCard card,
        crypto:PublicKey publicKey,
        int signatureIndex = 0) returns boolean|error {
    if signatureIndex >= card.signatures.length() {
        return error(string `signatureIndex ${signatureIndex} out of range: card has ${card.signatures.length()} signature(s)`);
    }
    AgentCardSignature sig = card.signatures[signatureIndex];

    byte[] headerBytes = check decodeBase64Url(sig.protected);
    json header = check string:fromBytes(headerBytes).fromJsonString();
    string alg = check (check header.alg).ensureType();

    AgentCard unsigned = card.clone();
    unsigned.signatures = [];
    byte[] payload = unsigned.toJsonString().toBytes();

    // JWS compact-form signing input is base64url(protected header) + "." +
    // base64url(payload) — reconstructed here since AgentCardSignature only
    // stores the protected header and the signature, not the payload
    // (detached-payload JWS, per the spec's own AgentCardSignature shape).
    string signingInput = sig.protected + "." + array:toBase64(payload);
    byte[] signatureBytes = check decodeBase64Url(sig.signature);

    if alg == "RS256" {
        return crypto:verifyRsaSha256Signature(signingInput.toBytes(), signatureBytes, publicKey);
    } else if alg == "ES256" {
        return crypto:verifySha256withEcdsaSignature(signingInput.toBytes(), signatureBytes, publicKey);
    }
    return error(string `unsupported JWS alg "${alg}" — this library can only verify RS256 and ES256`);
}
```

- [ ] **Step 4: Add the static RS256 test fixture** to
  `tests/signature_test.bal`: generate a real RSA keypair and a
  self-signed certificate once, offline (e.g. `openssl req -x509 -newkey
  rsa:2048 -keyout test_key.pem -out test_cert.pem -days 3650 -nodes
  -subj "/CN=a2a-test"`), then hand-sign a fixed test `AgentCard`'s
  `toJsonString()` bytes with that private key using the same offline
  tooling (or a short one-off Ballerina script using
  `crypto:signRsaSha256` against the decoded private key, run once to
  produce the signature, then hardcode the resulting base64url string) —
  ship the resulting protected-header/signature strings and the
  certificate bytes as constants in the test file, e.g.:

```ballerina
// Fixed RSA test keypair generated once offline (ballerina/crypto has no
// key-generation function); only the public certificate and a
// known-valid signature are needed here, so the private key itself is
// not checked in.
isolated function testRs256CertBytes() returns byte[] => base16 `...`; // paste the DER cert bytes here

isolated function buildRs256SignedTestCard() returns AgentCard {
    AgentCard card = {
        name: "Test Agent", description: "fixture", version: "1.0.0",
        capabilities: {}, skills: [],
        signatures: [{
            protected: "...", // paste the real base64url protected header used when signing
            signature: "..."  // paste the real base64url RS256 signature over this exact card's JSON (minus signatures)
        }]
    };
    return card;
}

isolated function encodeProtectedHeaderWithAlg(string alg) returns string {
    json header = {"alg": alg};
    return array:toBase64(header.toJsonString().toBytes()); // note: standard base64 here is intentionally wrong padding/alphabet for a real JWS but fine for this negative test, which only needs decodeBase64Url + alg extraction to succeed before verifyAgentCardSignature rejects the alg
}
```

(The exact byte/string literals depend on the specific offline-generated
keypair — generate them once during implementation and hardcode the real
values; the structure above is complete and real, only the literal
constants are implementer-generated at execution time, which is normal
for any test fixture requiring an external cryptographic artifact.)

- [ ] **Step 5: Run all three tests, confirm pass/fail as expected**

Run: `bal test --tests testVerifyAgentCardSignatureRs256Valid,testVerifyAgentCardSignatureRs256TamperedCardFails,testVerifyAgentCardSignatureUnsupportedAlgErrors`
Expected: PASS on all three

- [ ] **Step 6: Full suite, then commit**

```bash
git add a2a/signature.bal a2a/tests/signature_test.bal
git commit -m "feat: add AgentCard JWS signature verification (RS256, ES256)"
```

---

## Task 5: Automatic SSE reconnection

**Files:**
- Modify: `sse.bal` (new wrapping generator), `client.bal:339-378,455-468`
  (`sendMessageStream`, `subscribeToTask`)
- Test: `tests/sse_test.bal`, `tests/client_test.bal`

**Interfaces:**
- Consumes: existing `subscribeToTask(taskId, tenant)` (`client.bal:455`) as
  the reconnect primitive — per spec §3.1.6 (already noted in
  `subscribeToTask`'s doc comment), resubscribing delivers the task's
  current state first, so a reconnect never loses information.
- Produces: `Client.init` gains an optional `int maxReconnectAttempts = 0`
  (0 = today's behavior, opt-in). When positive, `sendMessageStream`'s and
  `subscribeToTask`'s returned stream is wrapped in a new
  `ReconnectingStreamGenerator` that, on the underlying stream ending with
  an error (not a clean terminal-state close), waits briefly and calls
  `subscribeToTask` again internally up to `maxReconnectAttempts` times
  before giving up and surfacing the error.

- [ ] **Step 1: Write the failing test — stream drops once, reconnects, delivers the terminal event**

```ballerina
// tests/client_test.bal
@test:Config {}
function testSendMessageStreamReconnectsOnDrop() returns error? {
    // First script: a WORKING status then an abrupt close (simulated via a
    // short SSE event list the mock server closes after, no terminal event).
    setNextSseResponse([
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendMessageStream(msg);
    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first?.task is Task, "first event should be the initial task/message");

    StreamResponse second = check expectValue(s.next());
    test:assertEquals(second.statusUpdate?.status?.state, TASK_STATE_WORKING);

    // Script the reconnect's response (what subscribeToTask will receive)
    // before pulling the next value — the drop happens on this next() call.
    setNextSseResponse([
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_COMPLETED")}
    ]);
    StreamResponse third = check expectValue(s.next());
    test:assertEquals(third.statusUpdate?.status?.state, TASK_STATE_COMPLETED);
}
```

(`statusUpdateJson` is a small new helper added to `testutil.bal` building
a JSON-RPC-enveloped `TaskStatusUpdateEvent` result string — follow the
existing pattern other tests in `client_test.bal` already use for scripting
SSE bodies; check that file for the exact envelope shape already in use
before adding a new one.)

- [ ] **Step 2: Run, confirm compile failure** (`maxReconnectAttempts`
  doesn't exist).

- [ ] **Step 3: Implement `ReconnectingStreamGenerator` in `sse.bal`**

```ballerina
# Wraps an existing StreamResponse stream, transparently reconnecting via
# subscribeToTask when the underlying stream ends with an error instead of
# a clean terminal-state close — up to a caller-configured attempt limit.
# Per specification section 3.1.6, a resubscription's first delivered event
# is always the task's current state, so no event is lost across a
# reconnect, only possibly duplicated (a status the client already saw
# delivered again) — callers already need to tolerate duplicate/out-of-order
# status updates per the spec's own guidance on this, so this is not a new
# burden.
isolated class ReconnectingStreamGenerator {
    private stream<StreamResponse, error?> current;
    private final Client client;
    private final string taskId;
    private final int maxAttempts;
    private int attemptsUsed = 0;
    private boolean done = false;

    isolated function init(stream<StreamResponse, error?> initial, Client client, string taskId, int maxAttempts) {
        self.current = initial;
        self.client = client;
        self.taskId = taskId;
        self.maxAttempts = maxAttempts;
    }

    public isolated function next() returns record {| StreamResponse value; |}|error? {
        if self.done {
            return ();
        }
        record {| StreamResponse value; |}|error? result = self.current.next();
        if result is error && self.attemptsUsed < self.maxAttempts {
            self.attemptsUsed += 1;
            stream<StreamResponse, error?>|error reconnected = self.client->subscribeToTask(self.taskId);
            if reconnected is stream<StreamResponse, error?> {
                self.current = reconnected;
                return self.next();
            }
        }
        if result is () || result is error {
            self.done = true;
        }
        return result;
    }

    public isolated function close() returns error? {
        self.done = true;
        return self.current.close();
    }
}
```

- [ ] **Step 4: Wire it into `client.bal`**

Add `private final int maxReconnectAttempts;` field, `int
maxReconnectAttempts = 0` init parameter. In `sendMessageStream`, after
getting the initial `stream<StreamResponse, error?>` from
`self.openSseStream(...)`, if `self.maxReconnectAttempts > 0`, peel the
`taskId` off the stream's first event (a `Task` has `.id`, a `Message`
does not carry a task to resubscribe to — if the first event is a bare
`Message` with no task, reconnection is a no-op: wrap only when a task
exists) and wrap in `new ReconnectingStreamGenerator(rawStream, self,
taskId, self.maxReconnectAttempts)`. Apply the same wrapping in
`subscribeToTask` (there `taskId` is already the input parameter — no
peeling needed).

- [ ] **Step 5: Run the reconnect test, confirm pass**

Run: `bal test --tests testSendMessageStreamReconnectsOnDrop`
Expected: PASS

- [ ] **Step 6: Add a second test proving `maxReconnectAttempts = 0` (the
  default) preserves today's exact behavior** — a dropped stream surfaces
  the error immediately, no reconnect attempted. This is the regression
  guard that this is truly opt-in.

- [ ] **Step 7: Full suite, then commit**

```bash
git add a2a/sse.bal a2a/client.bal a2a/tests/sse_test.bal a2a/tests/client_test.bal a2a/tests/testutil.bal
git commit -m "feat: add opt-in automatic SSE reconnection for streaming calls"
```

---

## Task 6: Close achievable test-coverage gaps (mock-based, no live server needed)

**Files:**
- Modify: `tests/client_test.bal`, `tests/types_test.bal`

**Interfaces:** none new — pure test additions against existing code paths.

- [ ] **Step 1: `Part` file/data variant round-trip** — write and run in one
  pass (not separate red/green, since this exercises only existing
  `Part`/`toJson`/`cloneWithType` behavior with no new code expected):

```ballerina
// tests/types_test.bal
@test:Config {}
function testPartFileVariantRoundTrip() returns error? {
    Part original = {raw: "hello".toBytes(), filename: "greeting.txt", mediaType: "text/plain"};
    json encoded = original.toJson();
    Part decoded = check encoded.cloneWithType(Part);
    test:assertEquals(decoded, original);
}

@test:Config {}
function testPartDataVariantRoundTrip() returns error? {
    Part original = {data: {"key": "value", "count": 3}, mediaType: "application/json"};
    json encoded = original.toJson();
    Part decoded = check encoded.cloneWithType(Part);
    test:assertEquals(decoded, original);
}
```

Run: `bal test --tests testPartFileVariantRoundTrip,testPartDataVariantRoundTrip`
Expected: PASS immediately (this is coverage, not new behavior) — if either
fails, that's a genuine new bug this task surfaces; fix `Part`'s handling in
`types.bal` before continuing, using the failure output to scope the fix.

- [ ] **Step 2: `FAILED`/`REJECTED`/`AUTH_REQUIRED` task states through
  `sendMessage`/`getTask`**

```ballerina
// tests/client_test.bal
@test:Config {}
function testGetTaskReturnsFailedState() returns error? {
    setNextJsonResponse(taskJsonWithState("task-x", "TASK_STATE_FAILED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask("task-x");
    test:assertEquals(task.status.state, TASK_STATE_FAILED);
}

@test:Config {}
function testGetTaskReturnsRejectedState() returns error? {
    setNextJsonResponse(taskJsonWithState("task-y", "TASK_STATE_REJECTED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask("task-y");
    test:assertEquals(task.status.state, TASK_STATE_REJECTED);
}

@test:Config {}
function testGetTaskReturnsAuthRequiredState() returns error? {
    setNextJsonResponse(taskJsonWithState("task-z", "TASK_STATE_AUTH_REQUIRED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask("task-z");
    test:assertEquals(task.status.state, TASK_STATE_AUTH_REQUIRED);
}
```

Add `taskJsonWithState(string taskId, string state)` to `testutil.bal`
following the existing `defaultTaskJson()`-style helper already used
elsewhere in this test file (check `client_test.bal` for the exact current
helper name/shape before adding a near-duplicate).

Run: `bal test --tests testGetTaskReturnsFailedState,testGetTaskReturnsRejectedState,testGetTaskReturnsAuthRequiredState`
Expected: PASS

- [ ] **Step 3: `listTasks` filter-parameter wire encoding** — assert every
  `ListTasksFilter` field actually appears in the outbound JSON-RPC params,
  using `getLastRequestBody()` (already exists in `testutil.bal`):

```ballerina
@test:Config {}
function testListTasksSendsAllFilterFields() returns error? {
    setNextJsonResponse({"tasks": [], "nextPageToken": ()});
    Client c = check new (getServerBaseUrl());
    ListTasksResult _ = check c->listTasks(filter = {
        contextId: "ctx-1",
        status: TASK_STATE_WORKING,
        pageSize: 10,
        pageToken: "cursor-abc",
        historyLength: 5,
        statusTimestampAfter: "2026-01-01T00:00:00Z",
        includeArtifacts: true
    });
    json body = getLastRequestBody();
    map<json> params = check (check body.params).ensureType();
    test:assertEquals(params["contextId"], "ctx-1");
    test:assertEquals(params["status"], "TASK_STATE_WORKING");
    test:assertEquals(params["pageSize"], 10);
    test:assertEquals(params["pageToken"], "cursor-abc");
    test:assertEquals(params["historyLength"], 5);
    test:assertEquals(params["statusTimestampAfter"], "2026-01-01T00:00:00Z");
    test:assertEquals(params["includeArtifacts"], true);
}
```

Run: `bal test --tests testListTasksSendsAllFilterFields`
Expected: PASS

- [ ] **Step 4: Full suite, then commit**

```bash
git add a2a/tests/client_test.bal a2a/tests/types_test.bal a2a/tests/testutil.bal
git commit -m "test: cover file/data Part round-trip, FAILED/REJECTED/AUTH_REQUIRED states, listTasks filter encoding"
```

(Live-server gaps — `listTasks` pagination against a real paginated
dataset, `tenant` against a real multi-tenant `AgentInterface`, and
`deleteTaskPushNotificationConfig`'s success path — stay tracked in
`a2a-interop-tests/CLIENT_TEST_COVERAGE.md` as before; they need a real
server this plan can't provide and are explicitly out of scope here.)

---

## Task 7: Clean up `A2A_Technical_Design.md`'s superseded section

**Files:**
- Modify: `docs/A2A_Technical_Design.md`
- Create: `docs/archive/A2A_Technical_Design_superseded_listener_draft.md` (or
  similar — exact name at implementer's discretion)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Locate the exact superseded section boundaries** — search
  `A2A_Technical_Design.md` for the `⚠️ SUPERSEDED` marker noted in the
  audit (around lines 766–1404: "Listener & service design," "Agent Card
  and Skills — developer guide," the worked "weather agent" example) and
  confirm the exact start/end lines with `grep -n "SUPERSEDED"
  docs/A2A_Technical_Design.md`.

- [ ] **Step 2: Move that section verbatim** into the new archive file,
  with a one-line header noting it's an early unversioned draft kept for
  historical reference only (reusing language already in the existing
  marker).

- [ ] **Step 3: Replace the removed section in
  `A2A_Technical_Design.md` with a one-line pointer** to the archive file's
  path, so the history isn't lost, just no longer inline where a new reader
  could mistake it for current guidance.

- [ ] **Step 4: Commit**

```bash
git add a2a/docs/A2A_Technical_Design.md a2a/docs/archive/
git commit -m "docs: archive superseded listener/service draft out of the main design doc"
```

---

## Task 8: REST (HTTP+JSON) transport binding — design spec

**Files:**
- Create: `docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md`

**Interfaces:** none yet — this task's deliverable is the spec document
that Task 8's *implementation* (a separate, follow-up plan, written once
this spec is reviewed) will be built from. Per this project's own
established practice, a feature this size (a second transport binding,
touching every operation) gets a dated design spec before a bite-sized
plan, exactly like `2026-07-28-v03-client-compat-design.md` and
`2026-07-29-remaining-operations-design.md` did.

- [ ] **Step 1: Confirm the two open unknowns flagged during this plan's
  research** before writing the spec, not while writing code against
  guesses:
  - Whether `SendStreamingMessage`/`SubscribeToTask` are delivered over
    REST as SSE at the `:stream`/`:subscribe` paths (inferred from URL
    naming convention, not yet confirmed against spec prose describing the
    REST binding's streaming mechanics specifically).
  - Whether every REST body's camelCase JSON field names match this
    library's existing internal field names 1:1, or whether any diverge
    (do a direct side-by-side pass: for each of the 11 operations, list
    the REST request/response JSON shape next to the corresponding
    Ballerina type in `types.bal`, flag every mismatch found).

  Resolve both via `WebFetch` against the A2A spec's REST/HTTP+JSON
  binding section (and the `custom-protocol-bindings.md` topic doc referenced
  during this plan's research, if accessible) before writing Step 2.

- [ ] **Step 2: Write the spec**, covering (mirroring the structure of the
  existing specs in `docs/superpowers/specs/`):
  - Every operation's REST path/method (already gathered during this
    plan's research — reproduce the full table, don't re-derive it)
  - Exact request/response body shape per operation, and any field-name
    reconciliation needed against existing `types.bal` types
  - How the client selects the REST binding: extend `primaryUrl`
    (`client.bal:116-126`) — currently hardcoded to `"JSONRPC"` only — with
    either a `preferredBinding` parameter or new binding-specific
    functions; make an explicit call here, don't leave it open
  - How streaming works (resolved in Step 1)
  - Whether `Client`'s existing method bodies can conditionally branch to
    a REST code path (mode-based, like the existing V1_0/V0_3 split in
    `compat_v03.bal`) or need a wholly separate REST-specific client type
  - Error mapping: REST binding's HTTP status codes → the same `A2AError`
    hierarchy `errors.bal` already defines, so callers don't need to know
    which binding they're on to handle errors

- [ ] **Step 3: Commit**

```bash
git add a2a/docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md
git commit -m "docs: add REST transport binding design spec"
```

---

## Task 9: gRPC transport binding — design spec

**Files:**
- Create: `docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md`

**Interfaces:** none yet — same rationale as Task 8.

- [ ] **Step 1: Resolve the one open unknown flagged during this plan's
  research before writing the spec** — Ballerina's `bal grpc --input
  a2a.proto --mode client` codegen's exact output shape for
  server-streaming RPCs (`SendStreamingMessage`, `SubscribeToTask` in
  `a2a.proto`'s `A2AService`), specifically the generated client method's
  return type. Resolve empirically, not by reading docs alone:

  1. Fetch the real `a2a.proto` (already located during this plan's
     research: `a2aproject/A2A`, `specification/a2a.proto`,
     `package lf.a2a.v1`, service `A2AService` with all 11 rpcs).
  2. In a scratch directory, run `bal grpc --input a2a.proto --mode client
     --output <scratch-dir>` and inspect the generated `*_client.bal` file
     directly for how it exposes `SendStreamingMessage`/`SubscribeToTask` —
     confirm whether it's `stream<T, error?>` (matching this library's
     existing SSE stream shape, in which case the same `StreamResponse`
     consumption pattern callers already use for JSON-RPC streaming would
     carry over almost unchanged) or something else.
  3. Record the exact finding in the spec — this is the single fact that
     determines how much of the existing `Client` streaming API can be
     reused unchanged for the gRPC binding vs. needing a different shape.

- [ ] **Step 2: Write the spec**, covering:
  - The full rpc/message table (already gathered during this plan's
    research — reproduce it, including exact snake_case proto field names
    per message, don't re-derive)
  - The codegen workflow: where the checked-in `.proto` file lives in this
    repo, the exact `bal grpc` invocation to regenerate stubs, and how
    that's wired into the build (a `Ballerina.toml` entry, a documented
    manual step, or a build script — make an explicit call)
  - Confirmed server-streaming consumption pattern (from Step 1) and how
    it maps onto (or requires diverging from) the existing
    `stream<StreamResponse, error?>` shape `sendMessageStream`/
    `subscribeToTask` already return
  - How `primaryUrl`-equivalent binding selection extends to `"GRPC"` (same
    decision Task 8 makes for REST — keep the two consistent; if Task 8
    picks a `preferredBinding` parameter, Task 9's spec should use the same
    mechanism, not a second, different one)
  - Error mapping: gRPC status codes → `A2AError` hierarchy
  - Whether the generated protobuf message types can be converted to/from
    this library's existing `Task`/`Message`/`Part`/etc. types directly, or
    need dedicated `encodeGrpc*`/`decodeGrpc*` functions (likely the
    latter, mirroring `compat_v03.bal`'s `encodeV03*`/`decodeV03*` pattern
    already established in this codebase — note this as the recommended
    approach unless Step 1's findings suggest otherwise)

- [ ] **Step 3: Commit**

```bash
git add a2a/docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md
git commit -m "docs: add gRPC transport binding design spec"
```

---

## After this plan

Tasks 1–7 leave the client materially more solid: cache-aware discovery,
extension negotiation, automatic auth wiring for the two most common
scheme types, real signature verification, opt-in stream resilience, and
closed mock-based test gaps. Tasks 8–9 produce reviewed design specs for
the two remaining transport bindings; their bite-sized implementation
plans are the natural next two plans once those specs land — each should
follow this same file's format, scoped the same way v0.3 compat and the
remaining-operations work were.

Server/listener support remains explicitly out of scope for all of the
above, per this round's agreed focus on the client only.
