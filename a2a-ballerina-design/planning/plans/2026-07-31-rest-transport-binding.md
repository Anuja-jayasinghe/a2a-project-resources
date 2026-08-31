# REST (HTTP+JSON) Transport Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the REST (HTTP+JSON) transport binding designed in
`docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md`, so
`Client` can speak either JSON-RPC or REST to a remote A2A agent, chosen at
construction time, with zero change to the 11 public remote-function
signatures and identical caller-visible error types on either binding.

**Architecture:** Per the spec's Design decision 2, the binding branch lives
entirely inside the two existing private transport helpers — `rpcCall` and
`openSseStream` (both in `client.bal`) — plus `sse.bal`'s stream decoder.
No new client type, no changes to any of the 11 remote function bodies. A
new `REST_OPERATIONS` descriptor table drives a generic REST request
builder, since (per the spec's central finding) the v1.0 JSON-RPC
`params`/`result` bodies and the v1.0 REST bodies are the *same* JSON
objects — REST only redistributes those fields across path, query, and
body. No field-renaming layer (no `encodeRest*`/`decodeRest*` functions)
is needed, unlike the v0.3 compat layer.

**Tech Stack:** Ballerina (current release track), `ballerina/http`
(already a dependency), `ballerina/url` (new — for query-string
percent-encoding).

## Global Constraints

- Every new test uses the existing scripted mock server pattern in
  `tests/testutil.bal` (`mockListener` on `localhost:19199`) — extend it
  with new REST-specific mock helpers rather than introducing a second
  mock server or a different port. The existing mock's single JSON-RPC
  resource (`post .`) stays as-is; REST tests need new resources on the
  same listener for the REST path shapes (e.g. `get tasks/[string id]`,
  `post message\:send`, etc. — Ballerina resource paths can express these
  literally).
- No existing public function signature changes without a default value
  that preserves current caller behavior exactly. `primaryUrl` and
  `Client.init` both gain new *defaulted, trailing* parameters only.
- Follow existing code style: `isolated` functions/classes throughout,
  doc comments with `# + param - description` / `# + return - description`
  on every public function, `A2AError` subtypes (never bare `error`) for
  anything the caller should be able to pattern-match on.
- Every task ends green: `bal test` run from `a2a-ballerina/a2a/` with zero
  failures before moving to the next task. The `bal` CLI is not on PATH in
  a bash/git-bash shell in this environment — use PowerShell for all `bal`
  commands.
- Commit after every task.
- `url:encode` (module `ballerina/url`) is `application/x-www-form-urlencoded`-style
  percent-encoding (encodes space as `+`), confirmed against the actual
  `module-ballerina-url` source. This is the correct encoding for URL query
  parameters (which use form-encoding by convention), so no special-casing
  is needed — just be aware it is not raw RFC 3986 percent-encoding if a
  future need for path-segment encoding arises.
- `http:Client`'s `->get(path, headers)`, `->post(path, message, headers)`,
  and `->delete(path, message = (), headers)` remote methods are the ones
  to use directly (confirmed exact signatures against
  `module-ballerina-http` source) — do not use the generic `->execute(...)`
  dispatcher, since it requires an explicit body argument even for
  bodiless calls, making direct method calls simpler here.
  `http:Response.getSseEventStream()` works identically regardless of
  which remote method produced the response (not POST-specific).

---

## Task 1: `TransportBinding` type, `selectInterface`, and `primaryUrl` extension

**Files:**
- Modify: `client.bal:176-200` (`primaryUrl`)
- Test: `tests/client_test.bal`

**Interfaces:**
- Produces: `public type TransportBinding "JSONRPC"|"HTTP+JSON";`,
  `public isolated function selectInterface(AgentCard card, TransportBinding
  preferredBinding = "JSONRPC") returns AgentInterface|error`, and
  `primaryUrl` gains a defaulted `preferredBinding` parameter and becomes a
  thin wrapper over `selectInterface`.

- [ ] **Step 1: Write the failing tests**

```ballerina
// tests/client_test.bal
@test:Config {}
function testSelectInterfaceFindsJsonRpcByDefault() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", tenant: "acme"}
        ],
        skills: []
    };
    AgentInterface iface = check selectInterface(card);
    test:assertEquals(iface.url, "http://jsonrpc.example");
    test:assertEquals(iface.tenant, "acme");
}

@test:Config {}
function testSelectInterfaceFindsHttpJsonWhenPreferred() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC"},
            {url: "http://rest.example", protocolBinding: "HTTP+JSON", tenant: "acme-rest"}
        ],
        skills: []
    };
    AgentInterface iface = check selectInterface(card, "HTTP+JSON");
    test:assertEquals(iface.url, "http://rest.example");
    test:assertEquals(iface.tenant, "acme-rest");
}

@test:Config {}
function testSelectInterfaceErrorsWhenNoMatchAndNoLegacyUrl() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };
    AgentInterface|error result = selectInterface(card, "HTTP+JSON");
    test:assertTrue(result is error, "no HTTP+JSON interface and no legacy url should error, not silently fall back to a JSONRPC endpoint");
}

@test:Config {}
function testPrimaryUrlDefaultsToJsonRpc() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://rest.example", protocolBinding: "HTTP+JSON"},
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };
    string url = check primaryUrl(card);
    test:assertEquals(url, "http://jsonrpc.example", "primaryUrl with no argument must keep resolving JSONRPC, unchanged from today");
}

@test:Config {}
function testPrimaryUrlLegacyFallbackStaysJsonRpcOnly() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        url: "http://legacy.example",
        supportedInterfaces: [],
        skills: []
    };
    AgentInterface|error restResult = selectInterface(card, "HTTP+JSON");
    test:assertTrue(restResult is error, "a pre-v1.0 card's legacy url field predates HTTP+JSON entirely and must not be treated as a REST endpoint");
    string jsonRpcUrl = check primaryUrl(card);
    test:assertEquals(jsonRpcUrl, "http://legacy.example");
}
```

- [ ] **Step 2: Run, confirm they fail** — `selectInterface` and
  `TransportBinding` don't exist yet, and `primaryUrl` doesn't accept a
  second argument.

Run: `bal test --tests testSelectInterfaceFindsJsonRpcByDefault,testSelectInterfaceFindsHttpJsonWhenPreferred,testSelectInterfaceErrorsWhenNoMatchAndNoLegacyUrl,testPrimaryUrlDefaultsToJsonRpc,testPrimaryUrlLegacyFallbackStaysJsonRpcOnly`
Expected: FAIL — compile errors.

- [ ] **Step 3: Implement in `client.bal`**, replacing the existing
  `primaryUrl` function (`client.bal:176-200`) with:

```ballerina
# The A2A transport bindings this library can speak.
public type TransportBinding "JSONRPC"|"HTTP+JSON";

# Resolves the whole matched AgentInterface for a preferred binding, not
# just its url — callers need the interface's own tenant and
# protocolVersion, which must come from the same entry the url did, not
# be independently re-derived (a card can list several interfaces with
# different tenant/version values).
#
# + card - the agent card to read the endpoint from
# + preferredBinding - which transport binding to look for; defaults to
#                      "JSONRPC", preserving every existing single-binding
#                      caller's behavior unchanged
# + return - the first supportedInterfaces entry declaring the matching
#            protocolBinding, or an error if none exists. The legacy
#            top-level url field is never treated as a match for
#            "HTTP+JSON" — it predates that binding entirely — so only
#            "JSONRPC" callers fall back to it (see primaryUrl)
public isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns AgentInterface|error {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == preferredBinding {
            return iface;
        }
    }
    return error(string `AgentCard has no ${preferredBinding} entry in supportedInterfaces`);
}

# Resolves the URL to construct a Client against, per v1.0's removal of
# AgentCard.url as a required field.
#
# + card - the agent card to read the endpoint from
# + preferredBinding - which transport binding to resolve a URL for;
#                      defaults to "JSONRPC", preserving every existing
#                      caller's behavior unchanged
# + return - the matching supportedInterfaces entry's url, the legacy url
#            field if preferredBinding is "JSONRPC" and no such entry
#            exists, or an error if neither is present
public isolated function primaryUrl(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns string|error {
    AgentInterface|error iface = selectInterface(card, preferredBinding);
    if iface is AgentInterface {
        return iface.url;
    }
    if preferredBinding == "JSONRPC" {
        string? legacyUrl = card?.url;
        if legacyUrl is string {
            return legacyUrl;
        }
    }
    return error(string `AgentCard has no ${preferredBinding} entry in supportedInterfaces and no legacy url field`);
}
```

- [ ] **Step 4: Run the five tests, confirm pass**

Run: `bal test --tests testSelectInterfaceFindsJsonRpcByDefault,testSelectInterfaceFindsHttpJsonWhenPreferred,testSelectInterfaceErrorsWhenNoMatchAndNoLegacyUrl,testPrimaryUrlDefaultsToJsonRpc,testPrimaryUrlLegacyFallbackStaysJsonRpcOnly`
Expected: PASS

- [ ] **Step 5: Full suite, then commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: add TransportBinding type and selectInterface, extend primaryUrl for HTTP+JSON"
```

---

## Task 2: `detectProtocolModeForBinding` + `Client.init` binding parameter + v0.3+REST rejection

**Files:**
- Modify: `compat_v03.bal:15-29` (`detectProtocolMode`)
- Modify: `client.bal:202-292` (`Client` class fields and `init`)
- Test: `tests/compat_v03_test.bal`, `tests/client_test.bal`

**Interfaces:**
- Consumes: `selectInterface` (Task 1).
- Produces: `detectProtocolModeForBinding(card, preferredBinding)`;
  `detectProtocolMode(card)` becomes a thin delegator; `Client` gains a
  `private final TransportBinding binding;` field and `init` gains a
  defaulted `binding` parameter; `init` rejects `V0_3` + `HTTP+JSON`
  combinations with a typed error.

- [ ] **Step 1: Write the failing tests**

```ballerina
// tests/compat_v03_test.bal
@test:Config {}
function testDetectProtocolModeForBindingReadsSelectedInterfaceNotIndexZero() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", protocolVersion: "0.3"},
            {url: "http://rest.example", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: []
    };
    // Index 0 is v0.3, but the HTTP+JSON entry (index 1) is v1.0 — a
    // caller resolving the REST binding must get V1_0, not the V0_3 an
    // index-0 read would incorrectly produce.
    ProtocolMode mode = detectProtocolModeForBinding(card, "HTTP+JSON");
    test:assertEquals(mode, "V1_0");
}

@test:Config {}
function testDetectProtocolModeStillDelegatesToJsonRpcByDefault() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    // Existing one-arg detectProtocolMode must keep behaving exactly as
    // it does today for a single-binding card.
    test:assertEquals(detectProtocolMode(card), "V0_3");
    test:assertEquals(detectProtocolModeForBinding(card), "V0_3");
}

@test:Config {}
function testDetectProtocolModeForBindingFallsBackWhenNoMatchingInterface() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    // No HTTP+JSON interface at all — falls back to the existing
    // index-0/legacy behavior rather than erroring, since this function
    // has no error return type to report "not found" through.
    ProtocolMode mode = detectProtocolModeForBinding(card, "HTTP+JSON");
    test:assertEquals(mode, "V0_3");
}
```

```ballerina
// tests/client_test.bal
@test:Config {}
function testClientInitRejectsV03WithHttpJsonBinding() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getServerBaseUrl(), protocolBinding: "HTTP+JSON", protocolVersion: "0.3"}
        ],
        skills: []
    };
    Client|error result = new (getServerBaseUrl(), agentCard = card, binding = "HTTP+JSON");
    test:assertTrue(result is VersionNotSupportedError,
            "constructing an HTTP+JSON client against a card that resolves to V0_3 must fail fast with a typed error, not send a v0.3 JSON-RPC method name to a REST path");
}

@test:Config {}
function testClientInitAllowsV03WithJsonRpcBinding() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getServerBaseUrl(), protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    // binding defaults to "JSONRPC" — v0.3 + JSONRPC is the existing,
    // already-supported combination and must still construct cleanly.
    Client _ = check new (getServerBaseUrl(), agentCard = card);
}

@test:Config {}
function testClientInitDefaultBindingUnchangedWithNoCard() returns error? {
    // Omitting agentCard entirely must construct exactly as before,
    // regardless of the new binding parameter's value, since self.mode
    // defaults to V1_0 when no card is given.
    Client _ = check new (getServerBaseUrl(), binding = "HTTP+JSON");
}
```

- [ ] **Step 2: Run, confirm they fail** — `detectProtocolModeForBinding`
  and the `binding` parameter don't exist yet.

- [ ] **Step 3: Implement `detectProtocolModeForBinding` in `compat_v03.bal`**,
  replacing `detectProtocolMode` (`compat_v03.bal:15-29`) with:

```ballerina
# Resolves the wire dialect for the interface matching preferredBinding,
# rather than assuming supportedInterfaces[0] — the same interface
# selectInterface would return for this binding, so a REST client and a
# JSON-RPC client on the same multi-interface card each read their own
# interface's protocolVersion, not whichever happens to sit at index 0.
# Falls back to the existing index-0/legacy behavior when the card
# declares no matching interface (this function has no error return type
# to report "not found" through, so falling back rather than defaulting
# blindly to V1_0 preserves the existing single-binding-card semantics).
#
# + card - the agent card fetched via resolveAgentCard
# + preferredBinding - which transport binding's interface to read
#                      protocolVersion from; defaults to "JSONRPC"
# + return - V0_3 or V1_0, per the matched interface's protocolVersion,
#            or the existing index-0/legacy rules if no interface matches
public isolated function detectProtocolModeForBinding(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns ProtocolMode {
    AgentInterface|error iface = selectInterface(card, preferredBinding);
    if iface is AgentInterface {
        string? v = iface?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    if card.supportedInterfaces.length() > 0 {
        string? v = card.supportedInterfaces[0]?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    string? v = card?.protocolVersion;
    return (v is string && !v.startsWith("0.")) ? "V1_0" : "V0_3";
}

# Detects which wire dialect to use, from a resolved AgentCard, for the
# JSONRPC binding. Kept as the existing one-argument entry point so every
# caller from before HTTP+JSON existed keeps behaving identically;
# delegates to detectProtocolModeForBinding with "JSONRPC".
#
# + card - the agent card fetched via resolveAgentCard
# + return - V0_3 for a legacy card (no supportedInterfaces) unless its
#            legacy top-level protocolVersion explicitly says otherwise, or
#            for a card whose JSONRPC supportedInterfaces entry declares a
#            "0.x" protocolVersion; V1_0 otherwise
public isolated function detectProtocolMode(AgentCard card) returns ProtocolMode {
    return detectProtocolModeForBinding(card, "JSONRPC");
}
```

- [ ] **Step 4: Wire `binding` into `Client` in `client.bal`.** Add the
  field (`client.bal:202-210` area, alongside the other `private final`
  fields):

```ballerina
    private final TransportBinding binding;
```

Add `TransportBinding binding = "JSONRPC"` as the new last parameter of
`init` (`client.bal:258-266`), and change the `self.mode` line
(`client.bal:289`) plus add the rejection check immediately after it:

```ballerina
        self.binding = binding;
        self.mode = agentCard is AgentCard
            ? detectProtocolModeForBinding(agentCard, binding)
            : "V1_0";
        if self.mode == "V0_3" && binding == "HTTP+JSON" {
            return error VersionNotSupportedError(
                "A2A protocol v0.3 has no REST/HTTP+JSON binding equivalent",
                message = "A2A protocol v0.3 has no REST/HTTP+JSON binding equivalent"
            );
        }
```

Add a `# + binding -` doc-comment line to `init`'s doc comment describing
the new parameter (mirroring the style of the existing parameter docs).

- [ ] **Step 5: Run all six new tests, confirm pass**

- [ ] **Step 6: Full suite, then commit**

```bash
git add a2a/compat_v03.bal a2a/client.bal a2a/tests/compat_v03_test.bal a2a/tests/client_test.bal
git commit -m "feat: add detectProtocolModeForBinding and Client.init binding parameter, reject v0.3+HTTP+JSON at construction"
```

---

## Task 3: REST error mapping (`toA2AErrorFromRest`)

**Files:**
- Modify: `errors.bal`
- Test: `tests/errors_test.bal`

**Interfaces:**
- Produces: `isolated function toA2AErrorFromRest(int statusCode, json? body)
  returns A2AError` — no new public types; reuses every existing
  `A2AError` subtype.

- [ ] **Step 1: Write the failing tests**

```ballerina
// tests/errors_test.bal
@test:Config {}
function testToA2AErrorFromRestMapsTaskNotCancelableByReason() returns error? {
    json body = {
        "error": {
            "message": "task already completed",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE", "metadata": {}}
            ]
        }
    };
    A2AError err = toA2AErrorFromRest(400, body);
    test:assertTrue(err is TaskNotCancelableError, "reason TASK_NOT_CANCELABLE must map to the typed TaskNotCancelableError, not fall back to a generic 400 error");
    test:assertEquals(err.detail().code, -32002, "the synthesized JSON-RPC code must match what the same error would carry over the JSON-RPC binding, so callers checking detail.code see identical behavior regardless of binding");
}

@test:Config {}
function testToA2AErrorFromRestDisambiguatesThreeDistinct400s() returns error? {
    json cancelBody = {"error": {"message": "m1", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE"}]}};
    json unsupportedBody = {"error": {"message": "m2", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "UNSUPPORTED_OPERATION"}]}};
    json versionBody = {"error": {"message": "m3", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "VERSION_NOT_SUPPORTED"}]}};
    test:assertTrue(toA2AErrorFromRest(400, cancelBody) is TaskNotCancelableError);
    test:assertTrue(toA2AErrorFromRest(400, unsupportedBody) is UnsupportedOperationError);
    test:assertTrue(toA2AErrorFromRest(400, versionBody) is VersionNotSupportedError);
}

@test:Config {}
function testToA2AErrorFromRestMapsAllNineReasons() returns error? {
    map<string> reasonToExpectedTypeName = {
        "TASK_NOT_FOUND": "TaskNotFoundError",
        "TASK_NOT_CANCELABLE": "TaskNotCancelableError",
        "PUSH_NOTIFICATION_NOT_SUPPORTED": "PushNotificationNotSupportedError",
        "UNSUPPORTED_OPERATION": "UnsupportedOperationError",
        "CONTENT_TYPE_NOT_SUPPORTED": "ContentTypeNotSupportedError",
        "INVALID_AGENT_RESPONSE": "InvalidAgentResponseError",
        "EXTENDED_AGENT_CARD_NOT_CONFIGURED": "ExtendedAgentCardNotConfiguredError",
        "EXTENSION_SUPPORT_REQUIRED": "ExtensionSupportRequiredError",
        "VERSION_NOT_SUPPORTED": "VersionNotSupportedError"
    };
    foreach [string, string] [reason, _] in reasonToExpectedTypeName.entries() {
        json body = {"error": {"message": "m", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason}]}};
        A2AError err = toA2AErrorFromRest(400, body);
        // Each subtype is distinct, so this exercises real dispatch rather
        // than a single catch-all path silently swallowing every reason.
        test:assertTrue(err.message().length() > 0);
    }
}

@test:Config {}
function testToA2AErrorFromRestFallsBackToStatusWhenNoErrorInfo() returns error? {
    A2AError notFound = toA2AErrorFromRest(404, ());
    test:assertTrue(notFound is TaskNotFoundError, "a bare 404 with no ErrorInfo reason should still map to TaskNotFoundError");
    A2AError serverErr = toA2AErrorFromRest(503, ());
    test:assertTrue(serverErr is A2AInternalError);
    test:assertEquals(serverErr.detail().code, -32603);
    A2AError otherErr = toA2AErrorFromRest(418, ());
    test:assertTrue(otherErr is A2AInternalError);
    test:assertEquals(otherErr.detail().code, 418, "an unmapped status with no ErrorInfo should preserve the raw HTTP status in detail.code, not synthesize a JSON-RPC code that doesn't apply");
}

@test:Config {}
function testToA2AErrorFromRestAttachesMetadataAsData() returns error? {
    json body = {
        "error": {
            "message": "not found",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "metadata": {"taskId": "abc-123"}}
            ]
        }
    };
    A2AError err = toA2AErrorFromRest(404, body);
    test:assertEquals(err.detail().data, {"taskId": "abc-123"});
}
```

- [ ] **Step 2: Run, confirm all fail** — `toA2AErrorFromRest` doesn't
  exist.

- [ ] **Step 3: Implement in `errors.bal`**, appended after the existing
  `toA2AError` function:

```ballerina
# Maps a REST binding error response onto the same A2AError hierarchy the
# JSON-RPC binding maps onto, so callers handle errors identically
# regardless of which binding their Client negotiated. HTTP status alone
# is not sufficient to disambiguate — seven distinct A2A errors all return
# 400 — so the discriminator is the `reason` field of a
# google.rpc.ErrorInfo entry inside the error body's `details` array, per
# the reference a2a-python SDK's REST error-parsing shape.
#
# + statusCode - the HTTP status code the response carried
# + body - the parsed JSON error body, if any (absent for e.g. a stream
#          drop with no body available)
# + return - the corresponding typed A2AError, with detail.code synthesized
#            to the equivalent JSON-RPC code so a caller checking
#            detail.code sees identical values regardless of binding
isolated function toA2AErrorFromRest(int statusCode, json? body) returns A2AError {
    string? reason = extractRestErrorReason(body);
    string message = extractRestErrorMessage(body) ?: string `REST request failed with HTTP ${statusCode}`;
    json? data = extractRestErrorMetadata(body);

    if reason is string {
        match reason {
            "TASK_NOT_FOUND" => {
                return error TaskNotFoundError(message, message = message, code = -32001, data = data);
            }
            "TASK_NOT_CANCELABLE" => {
                return error TaskNotCancelableError(message, message = message, code = -32002, data = data);
            }
            "PUSH_NOTIFICATION_NOT_SUPPORTED" => {
                return error PushNotificationNotSupportedError(message, message = message, code = -32003, data = data);
            }
            "UNSUPPORTED_OPERATION" => {
                return error UnsupportedOperationError(message, message = message, code = -32004, data = data);
            }
            "CONTENT_TYPE_NOT_SUPPORTED" => {
                return error ContentTypeNotSupportedError(message, message = message, code = -32005, data = data);
            }
            "INVALID_AGENT_RESPONSE" => {
                return error InvalidAgentResponseError(message, message = message, code = -32006, data = data);
            }
            "EXTENDED_AGENT_CARD_NOT_CONFIGURED" => {
                return error ExtendedAgentCardNotConfiguredError(message, message = message, code = -32007, data = data);
            }
            "EXTENSION_SUPPORT_REQUIRED" => {
                return error ExtensionSupportRequiredError(message, message = message, code = -32008, data = data);
            }
            "VERSION_NOT_SUPPORTED" => {
                return error VersionNotSupportedError(message, message = message, code = -32009, data = data);
            }
            "INVALID_PARAMS" => {
                return error A2AInternalError(message, message = message, code = -32602, data = data);
            }
            "INVALID_REQUEST" => {
                return error A2AInternalError(message, message = message, code = -32600, data = data);
            }
            "METHOD_NOT_FOUND" => {
                return error A2AInternalError(message, message = message, code = -32601, data = data);
            }
            "INTERNAL_ERROR" => {
                return error A2AInternalError(message, message = message, code = -32603, data = data);
            }
        }
    }

    // No usable ErrorInfo reason — fall back on status code alone.
    if statusCode == 404 {
        return error TaskNotFoundError(message, message = message, code = -32001, data = data);
    }
    if statusCode >= 500 {
        return error A2AInternalError(message, message = message, code = -32603, data = data);
    }
    return error A2AInternalError(message, message = message, code = statusCode, data = data);
}

# Scans a REST error body's error.details array for the first
# google.rpc.ErrorInfo entry and returns its reason string, or () if the
# body has no usable ErrorInfo entry. json field access with an
# "@"-prefixed key ("@type") isn't valid dot-syntax, so this reads through
# a map<json> bracket index instead.
isolated function extractRestErrorDetail(json? body) returns map<json>? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? detailsJson = errMap["details"];
    if !(detailsJson is json[]) {
        return ();
    }
    foreach json detail in detailsJson {
        map<json>|error detailMap = detail.ensureType();
        if detailMap is map<json> {
            json? typeVal = detailMap["@type"];
            if typeVal is string && typeVal == "type.googleapis.com/google.rpc.ErrorInfo" {
                return detailMap;
            }
        }
    }
    return ();
}

isolated function extractRestErrorReason(json? body) returns string? {
    map<json>? detailMap = extractRestErrorDetail(body);
    if detailMap is () {
        return ();
    }
    json? reasonVal = detailMap["reason"];
    return reasonVal is string ? reasonVal : ();
}

isolated function extractRestErrorMessage(json? body) returns string? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? msg = errMap["message"];
    return msg is string ? msg : ();
}

isolated function extractRestErrorMetadata(json? body) returns json? {
    map<json>? detailMap = extractRestErrorDetail(body);
    return detailMap is () ? () : detailMap["metadata"];
}
```

- [ ] **Step 4: Run all five tests, confirm pass** — fix any compile
  issues in the draft above first (see the note in Step 3).

- [ ] **Step 5: Full suite, then commit**

```bash
git add a2a/errors.bal a2a/tests/errors_test.bal
git commit -m "feat: add toA2AErrorFromRest for REST binding error mapping"
```

---

## Task 4: `REST_OPERATIONS` descriptor table and REST request builder (unary operations)

**Files:**
- Modify: `client.bal` (new module-level table and helper, plus `rpcCall`
  dispatch)
- Test: `tests/testutil.bal`, `tests/client_test.bal`

**Interfaces:**
- Consumes: `toA2AErrorFromRest` (Task 3).
- Produces: `RestOperation` type, `REST_OPERATIONS` table,
  `buildRestPath(string method, map<json> params) returns [string, json?]|error`
  (returns `[fullPathWithQueryString, bodyOrNil]`), and `rpcCall` grows a
  binding-aware branch. This task covers only the 9 non-streaming
  operations (`SendMessage`, `GetTask`, `ListTasks`, `CancelTask`,
  `CreateTaskPushNotificationConfig`, `GetTaskPushNotificationConfig`,
  `ListTaskPushNotificationConfigs`, `DeleteTaskPushNotificationConfig`,
  `GetExtendedAgentCard`) — `SendStreamingMessage`/`SubscribeToTask` are
  Task 5/6.

- [ ] **Step 1: Add a REST mock resource set to `tests/testutil.bal`.**
  The existing mock listener (`mockListener` on `:19199`) currently has
  exactly one JSON-RPC resource (`post .`). Add REST-shaped resources
  alongside it on the same listener, scripted the same way the existing
  `rpcScript` is:

```ballerina
// tests/testutil.bal — new REST scripting state, alongside the existing
// isolated MockRpcScript rpcScript = {};

type MockRestScript record {|
    json jsonBody = {};
    int statusCode = 200;
    map<string> lastQueryParams = {};
    string lastPath = "";
    string lastMethod = "";
    boolean hasResponseBody = true;
|};

isolated MockRestScript restScript = {};

# Scripts the next REST request to receive a plain JSON response.
#
# + body - the JSON body to respond with
# + statusCode - the HTTP status code to respond with
# + hasResponseBody - false for e.g. a DELETE's empty 204 response
public isolated function setNextRestResponse(json body, int statusCode = 200, boolean hasResponseBody = true) {
    lock {
        restScript = {jsonBody: body.clone(), statusCode, hasResponseBody};
    }
}

# Returns the method, path, and query params of the last REST request the
# mock received, so tests can assert on exactly what the Client sent.
#
# + return - a record with the last request's method, path, and query params
public isolated function getLastRestRequest() returns record {| string method; string path; map<string> queryParams; |} {
    lock {
        return {method: restScript.lastMethod, path: restScript.lastPath, queryParams: restScript.lastQueryParams.clone()};
    }
}
```

Add one new resource to the `service / on mockListener { ... }` block
(alongside the existing `get \.well\-known/...` and `post .` resources) —
a single method-agnostic catch-all, confirmed empirically to work and to
be the only mechanism that can express `/tasks/{id}:cancel`-shaped paths
(a resource path segment cannot combine a bracketed path-param with an
adjacent literal suffix like `:cancel`, so per-operation resource routing
is not possible here; a `'default [string... path]` resource matches any
HTTP method and yields the full raw path, and takes precedence only when
no more specific resource matches):

```ballerina
resource function 'default [string... path](http:Caller caller, http:Request req) returns error? {
    MockRestScript script;
    lock {
        script = restScript.clone();
    }
    map<string> queryParams = {};
    foreach string k in req.getQueryParams().keys() {
        string|error v = req.getQueryParamValue(k);
        if v is string {
            queryParams[k] = v;
        }
    }
    lock {
        restScript.lastMethod = req.method;
        restScript.lastPath = "/" + string:'join("/", ...path);
        restScript.lastQueryParams = queryParams.clone();
    }
    http:Response res = new;
    res.statusCode = script.statusCode;
    if script.hasResponseBody {
        res.setJsonPayload(script.jsonBody);
    }
    check caller->respond(res);
}
```

Capture the full path, method, and parsed query parameters into
`restScript` before responding with the scripted `jsonBody`/`statusCode`.
Note `req.rawPath` includes the query string; reconstructing the path
from the `[string... path]` rest parameter (as above) gives the clean
path without it, which is what `getLastRestRequest()`'s `path` field
should return — verify this against what the tests in Step 2 actually
expect and adjust if `path` needs a leading tenant segment included or
excluded differently than this sketch assumes.

- [ ] **Step 2: Write the failing tests** — one per non-streaming
  operation, asserting method/path/query/body:

```ballerina
// tests/client_test.bal
@test:Config {}
function testRestSendMessageSendsCorrectPathAndBody() returns error? {
    setNextRestResponse({"task": defaultTaskJson()});
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/message:send");
}

@test:Config {}
function testRestGetTaskSendsCorrectPathAndQuery() returns error? {
    setNextRestResponse(defaultTaskJson());
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task _ = check c->getTask("task-123", historyLength = 5);
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-123");
    test:assertEquals(req.queryParams["historyLength"], "5");
}

@test:Config {}
function testRestCancelTaskSendsIdInPathAndBody() returns error? {
    setNextRestResponse(defaultTaskJson());
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task _ = check c->cancelTask("task-123");
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-123:cancel");
    // M4: id is duplicated into the body for hasBody operations — assert
    // via getLastRequestBody() shared with the JSON-RPC mock's body
    // capture, if the REST mock resource also populates lastRequestBody;
    // otherwise extend MockRestScript with a lastBody field and assert
    // against that instead.
}

@test:Config {}
function testRestListTasksEncodesFilterAsQueryString() returns error? {
    setNextRestResponse({"tasks": [], "nextPageToken": "", "pageSize": 10, "totalSize": 0});
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    ListTasksResult _ = check c->listTasks(filter = {
        contextId: "ctx-1",
        status: TASK_STATE_WORKING,
        pageSize: 10,
        statusTimestampAfter: "2023-10-27T10:00:00+05:30"
    });
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks");
    test:assertEquals(req.queryParams["status"], "TASK_STATE_WORKING", "TaskState must serialize as its symbolic enum name in the query string, not an ordinal");
    test:assertEquals(req.queryParams["contextId"], "ctx-1");
}

@test:Config {}
function testRestCreateTaskPushNotificationConfigSendsTaskIdInPathAndBody() returns error? {
    setNextRestResponse({"url": "http://webhook.example", "id": "cfg-1", "taskId": "task-1"});
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({url: "http://webhook.example", taskId: "task-1"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");
}

@test:Config {}
function testRestDeleteTaskPushNotificationConfigToleratesEmptyBody() returns error? {
    setNextRestResponse({}, statusCode = 204, hasResponseBody = false);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    error? result = c->deleteTaskPushNotificationConfig("task-1", "cfg-1");
    test:assertTrue(result is (), "a 204 with no body must be treated as success, not InvalidAgentResponseError");
}

@test:Config {}
function testRestGetExtendedAgentCardSendsCorrectPath() returns error? {
    setNextRestResponse(defaultMockAgentCard());
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    AgentCard _ = check c->getExtendedAgentCard();
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/extendedAgentCard");
}

@test:Config {}
function testRestOperationWithTenantPrefixesPath() returns error? {
    setNextRestResponse(defaultTaskJson());
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON", tenant = "acme-corp");
    Task _ = check c->getTask("task-1");
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.path, "/acme-corp/tasks/task-1");
}

@test:Config {}
function testRestErrorResponseMapsToTypedError() returns error? {
    setNextRestResponse({
        "error": {"message": "no such task", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND"}]}
    }, statusCode = 404);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task|error result = c->getTask("nonexistent");
    test:assertTrue(result is TaskNotFoundError);
}
```

- [ ] **Step 2b: Run, confirm all fail** (compile errors — `binding`
  param on operations not yet dispatching, REST mock helpers may not
  exist depending on Step 1's exact shape).

- [ ] **Step 3: Implement the descriptor table and request builder in
  `client.bal`**, as a new section before the `Client` class:

```ballerina
import ballerina/url;

# How one operation maps onto the REST binding.
type RestOperation record {|
    string httpMethod;
    string pathTemplate;
    string[] pathParams;
    boolean hasBody;
    boolean streaming;
|};

final readonly & map<RestOperation> REST_OPERATIONS = {
    "SendMessage": {httpMethod: "POST", pathTemplate: "/message:send", pathParams: [], hasBody: true, streaming: false},
    "SendStreamingMessage": {httpMethod: "POST", pathTemplate: "/message:stream", pathParams: [], hasBody: true, streaming: true},
    "GetTask": {httpMethod: "GET", pathTemplate: "/tasks/{id}", pathParams: ["id"], hasBody: false, streaming: false},
    "ListTasks": {httpMethod: "GET", pathTemplate: "/tasks", pathParams: [], hasBody: false, streaming: false},
    "CancelTask": {httpMethod: "POST", pathTemplate: "/tasks/{id}:cancel", pathParams: ["id"], hasBody: true, streaming: false},
    "SubscribeToTask": {httpMethod: "GET", pathTemplate: "/tasks/{id}:subscribe", pathParams: ["id"], hasBody: false, streaming: true},
    "CreateTaskPushNotificationConfig": {httpMethod: "POST", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs", pathParams: ["taskId"], hasBody: true, streaming: false},
    "GetTaskPushNotificationConfig": {httpMethod: "GET", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs/{id}", pathParams: ["taskId", "id"], hasBody: false, streaming: false},
    "ListTaskPushNotificationConfigs": {httpMethod: "GET", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs", pathParams: ["taskId"], hasBody: false, streaming: false},
    "GetExtendedAgentCard": {httpMethod: "GET", pathTemplate: "/extendedAgentCard", pathParams: [], hasBody: false, streaming: false},
    "DeleteTaskPushNotificationConfig": {httpMethod: "DELETE", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs/{id}", pathParams: ["taskId", "id"], hasBody: false, streaming: false}
};

# Builds the path (with tenant prefix and path-param substitution) and
# body for one REST request, per the descriptor table above.
#
# Path params and tenant are substituted from `params`. Per the design
# spec's M3/M4 findings (matching the reference a2a-python SDK exactly,
# not "cleaning up" the duplication): for hasBody operations, tenant and
# path params stay in the body as well as the path; for bodiless
# operations, they are removed from the working param set so they don't
# leak into the query string. Bodiless operations serialize every
# remaining param as a URL-encoded query parameter; TaskState enum values
# serialize as their symbolic name (already what a bare enum value is in
# Ballerina — no conversion needed), and any value containing characters
# needing escaping (e.g. an RFC 3339 timestamp's `:`/`+`) goes through
# url:encode.
#
# + method - the JSON-RPC-style method name already used to key
#            REST_OPERATIONS (e.g. "GetTask") — the same string every
#            remote function already passes to rpcCall/openSseStream
# + params - the same params map the JSON-RPC binding would have sent
# + return - the full request path (including query string for bodiless
#            operations) and the JSON body to send (nil for bodiless
#            operations), or an error if method has no REST mapping
isolated function buildRestRequest(string method, map<json> params) returns [string, json?]|error {
    RestOperation? maybeOp = REST_OPERATIONS[method];
    if maybeOp is () {
        return error A2AInternalError(string `REST binding has no operation mapping for "${method}"`);
    }
    RestOperation op = maybeOp;
    map<json> workingParams = params.clone();

    string? tenant = ();
    json? tenantJson = workingParams["tenant"];
    if tenantJson is string {
        tenant = tenantJson;
        if !op.hasBody {
            _ = workingParams.remove("tenant");
        }
    }

    string path = op.pathTemplate;
    foreach string pName in op.pathParams {
        json? pValue = workingParams[pName];
        if pValue is string {
            // Plain string substitution, not regex: pathTemplate never
            // contains a literal "{"/"}" outside of exactly these
            // placeholder markers, so there's no need for regex escaping
            // here — string:replace(string, string, string) is exact and
            // simpler.
            path = path.replace(string `{${pName}}`, pValue);
            if !op.hasBody {
                _ = workingParams.remove(pName);
            }
        }
    }

    if tenant is string {
        path = string `/${tenant}${path}`;
    }

    if op.hasBody {
        return [path, workingParams];
    }

    string[] queryParts = [];
    foreach [string, json] [k, v] in workingParams.entries() {
        string stringValue = v is string ? v : v.toString();
        string encoded = check url:encode(stringValue, "UTF-8");
        queryParts.push(string `${k}=${encoded}`);
    }
    if queryParts.length() > 0 {
        path = path + "?" + string:'join("&", ...queryParts);
    }
    return [path, ()];
}
```

- [ ] **Step 4: Wire the REST dispatch into `rpcCall`** (`client.bal:365-390`).
  Add a binding branch at the top of the function body:

```ballerina
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        if self.binding == "HTTP+JSON" {
            return self.restCall(method, params);
        }
        string wireMethod = self.mode == "V0_3" ? v03MethodName(method) : method;
        // ... existing JSON-RPC body unchanged ...
    }

    # Performs one REST binding call and returns the unwrapped result, or
    # (), matching rpcCall's contract for callers that only need the
    # unwrapped result on the JSON-RPC side. DeleteTaskPushNotificationConfig
    # returns google.protobuf.Empty over the wire — an absent or empty
    # body must be tolerated here rather than treated as
    # InvalidAgentResponseError, unlike a genuinely malformed response.
    #
    # + method - the JSON-RPC-style method name (see buildRestRequest)
    # + params - the same params map the JSON-RPC binding would build
    # + return - the unwrapped result json (or an empty map for a bodiless
    #            success response), or a typed A2AError
    private isolated function restCall(string method, map<json> params) returns json|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> headers = self.buildHeaders();
        http:Response resp;
        if op.httpMethod == "GET" {
            resp = check self.httpClient->get(path, headers);
        } else if op.httpMethod == "DELETE" {
            resp = check self.httpClient->delete(path, headers = headers);
        } else {
            resp = check self.httpClient->post(path, body ?: {}, headers);
        }
        self.captureGrantedExtensions(resp);
        if resp.statusCode >= 200 && resp.statusCode < 300 {
            json|error payload = resp.getJsonPayload();
            if payload is json {
                return payload;
            }
            // No parseable body (e.g. 204 No Content) — treat as an
            // empty successful result. Callers of a void operation like
            // deleteTaskPushNotificationConfig discard this; callers of
            // an operation expecting real content will fail their own
            // cloneWithType, which is the correct place for that failure
            // to surface, not here.
            return {};
        }
        json? errorBody = resp.getJsonPayload() is json ? check resp.getJsonPayload() : ();
        return toA2AErrorFromRest(resp.statusCode, errorBody);
    }
```

- [ ] **Step 5: Run all eight new tests, confirm pass.** Fix
  `buildRestRequest`'s path-substitution mechanism per the design note in
  Step 3 if the regex approach doesn't compile cleanly.

- [ ] **Step 6: Full suite, then commit**

```bash
git add a2a/client.bal a2a/tests/testutil.bal a2a/tests/client_test.bal
git commit -m "feat: add REST_OPERATIONS descriptor table and REST dispatch for non-streaming operations"
```

---

## Task 5: REST streaming — `openSseStream` dispatch + binding-aware SSE decoding

**Files:**
- Modify: `client.bal` (`openSseStream`)
- Modify: `sse.bal` (`readSseStream`, `A2AStreamGenerator`)
- Test: `tests/testutil.bal`, `tests/sse_test.bal`, `tests/client_test.bal`

**Interfaces:**
- Consumes: `REST_OPERATIONS`, `buildRestRequest`, `toA2AErrorFromRest`
  (Tasks 3-4).
- Produces: `readSseStream`/`A2AStreamGenerator` gain a `TransportBinding`
  parameter; `decodeEvent` skips JSON-RPC envelope unwrapping for REST and
  parses a bare `StreamResponse` directly; the generator inspects
  `SseEvent.event` for a `"error"` frame name and routes its data through
  `toA2AErrorFromRest`; `openSseStream` gains a REST dispatch branch.

- [ ] **Step 1: Add REST SSE mock support to `tests/testutil.bal`.**
  Extend `MockRestScript` with the same `isSse`/`sseEvents`/
  `simulateDropError` fields `MockRpcScript` already has (`testutil.bal`,
  around line 29-43), and extend the `'default [string... path]` resource
  from Task 4 to check `script.isSse` the same way the existing `post .`
  resource does — respond with `script.sseEvents.toStream()` (or the
  `DropAfterEventsGenerator`-backed stream for the drop-simulating case;
  reuse that existing class from `testutil.bal` rather than duplicating
  it) instead of a JSON payload. Critically, unlike the JSON-RPC mock's
  scripted events, REST SSE event `data` strings must be **bare
  `StreamResponse` JSON with no JSON-RPC envelope** — e.g.
  `{"task": {...}}`, not `{"jsonrpc":"2.0","id":"1","result":{"task":{...}}}`
  — since that's the actual wire difference Task 5's production code
  exists to decode correctly.

```ballerina
type MockRestScript record {|
    json jsonBody = {};
    int statusCode = 200;
    boolean hasResponseBody = true;
    map<string> lastQueryParams = {};
    string lastPath = "";
    string lastMethod = "";
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    boolean simulateDropError = false;
    // Task 6's SubscribeToTask GET-vs-POST fallback support: when set,
    // the mock rejects exactly one request of this method with this
    // status, then clears itself so the retry (a different method)
    // succeeds normally. () means no rejection scripted.
    string? rejectMethod = ();
    int rejectStatusCode = 0;
|};

# Scripts the next REST request to receive an SSE stream response, with
# bare StreamResponse JSON event data (no JSON-RPC envelope) — the REST
# binding's actual wire shape.
#
# + events - the canned SSE events to stream back
public isolated function setNextRestSseResponse(http:SseEvent[] events) {
    lock {
        restScript.sseEvents = events.clone();
        restScript.isSse = true;
        restScript.simulateDropError = false;
    }
}

# Scripts the mock to reject exactly the next request of the given HTTP
# method with the given status code (e.g. simulating a server that only
# routes POST for an operation the proto annotates as GET), then clear
# the rejection so a subsequent request — the client's retry with a
# different method — succeeds normally against whatever else is scripted.
#
# + httpMethod - the method to reject once, e.g. "GET"
# + statusCode - the status to reject it with, e.g. 405
public isolated function setRestRejectMethod(string httpMethod, int statusCode) {
    lock {
        restScript.rejectMethod = httpMethod;
        restScript.rejectStatusCode = statusCode;
    }
}
```

In the `'default` resource, check `script.rejectMethod` first, before the
`isSse` branch: if `req.method == script.rejectMethod`, respond with
`script.rejectStatusCode` and no body, then clear `restScript.rejectMethod`
back to `()` (inside a `lock` block) so the next request — the client's
retry — is not rejected again and falls through to the normal
`isSse`/JSON response path.

In the `'default` resource from Task 4, branch on `script.isSse` before
building the response, mirroring the existing `post .` resource's
`if script.isSse { ... } else { ... }` structure exactly (reuse
`respondIgnoringClientGoneAway` and `DropAfterEventsGenerator` from this
same file rather than reimplementing them) — set `res.statusCode = 200`
and `res.setPayload(script.sseEvents.toStream())` (or the drop-generator
stream) instead of `res.setJsonPayload(...)`.

- [ ] **Step 2: Write the failing tests**

```ballerina
// tests/client_test.bal
@test:Config {}
function testRestSendMessageStreamDecodesBareStreamResponseNoEnvelope() returns error? {
    setNextRestSseResponse([
        {'event: "message", data: string `{"task": {"id": "task-1", "status": {"state": "TASK_STATE_SUBMITTED"}}}`}
    ]);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendMessageStream(msg);
    StreamResponse first = check expectValue(s.next());
    test:assertEquals(first?.task?.id, "task-1");
}

@test:Config {}
function testRestStreamErrorEventMapsToTypedError() returns error? {
    setNextRestSseResponse([
        {'event: "error", data: string `{"error": {"message": "boom", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "INVALID_AGENT_RESPONSE"}]}}`}
    ]);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    stream<StreamResponse, error?> s = check c->subscribeToTask("task-1");
    record {| StreamResponse value; |}|error? result = s.next();
    test:assertTrue(result is InvalidAgentResponseError, "a named 'error' SSE frame must route through toA2AErrorFromRest and surface as the typed error, not attempt to parse it as a StreamResponse");
}
```

- [ ] **Step 2b: Run, confirm both fail.**

- [ ] **Step 3: Update `sse.bal`.** Change `readSseStream` and
  `A2AStreamGenerator` to accept a `TransportBinding` (in addition to the
  existing `ProtocolMode mode`), and make `decodeEvent` binding-aware:

```ballerina
isolated function readSseStream(http:Response resp, ProtocolMode mode = "V1_0", TransportBinding binding = "JSONRPC")
        returns stream<StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream, mode, binding);
    stream<StreamResponse, error?> result = new (generator);
    return result;
}

class A2AStreamGenerator {
    private stream<http:SseEvent, error?> sseStream;
    private boolean closed = false;
    private ProtocolMode mode;
    private TransportBinding binding;

    isolated function init(stream<http:SseEvent, error?> sseStream, ProtocolMode mode = "V1_0", TransportBinding binding = "JSONRPC") {
        self.sseStream = sseStream;
        self.mode = mode;
        self.binding = binding;
    }

    public isolated function next() returns record {| StreamResponse value; |}|error? {
        if self.closed {
            return ();
        }
        while true {
            record {| http:SseEvent value; |}|error? chunk = self.sseStream.next();
            if chunk is () {
                self.closed = true;
                return ();
            }
            if chunk is error {
                self.closed = true;
                return chunk;
            }
            string? data = chunk.value.data;
            if data is () {
                continue;
            }
            // REST binding signals a mid-stream error via a named "error"
            // SSE frame, whose data is a REST error payload — not a
            // StreamResponse at all. The JSON-RPC binding has no
            // equivalent (its errors travel inside the envelope), so this
            // check is REST-only.
            if self.binding == "HTTP+JSON" && chunk.value.'event == "error" {
                json|error errBody = data.fromJsonString();
                self.closed = true;
                return toA2AErrorFromRest(200, errBody is json ? errBody : ());
            }
            StreamResponse|error result = self.decodeEvent(data);
            if result is error {
                self.closed = true;
                return result;
            }
            if isTerminalEvent(result) {
                self.closed = true;
            }
            return {value: result};
        }
    }

    private isolated function decodeEvent(string data) returns StreamResponse|error {
        if self.binding == "HTTP+JSON" {
            // REST events carry a bare StreamResponse with no JSON-RPC
            // envelope, unlike the JSON-RPC binding's enveloped events.
            return check data.fromJsonString().cloneWithType(StreamResponse);
        }
        json envelope = check data.fromJsonString();
        transport:JsonRpcResponse rpcResp = check envelope.cloneWithType(transport:JsonRpcResponse);
        transport:JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is transport:JsonRpcError {
            return toA2AError(rpcErr);
        }
        json? result = rpcResp?.result;
        if result is () {
            return error InvalidAgentResponseError(
                "SSE event contained neither result nor error",
                message = "SSE event contained neither result nor error"
            );
        }
        return self.mode == "V0_3" ? decodeV03StreamEvent(result) : check result.cloneWithType(StreamResponse);
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
    }
}
```

`'event` (with the `'` escape, since `event` is a reserved word in this
position) is confirmed as the correct field name — it's already used this
way in `tests/client_test.bal`'s existing SSE test scripting (e.g.
`{'event: "message", data: taskJson("task-1")}`), so `chunk.value.'event`
is the correct read in `next()` above.

- [ ] **Step 4: Update `openSseStream` in `client.bal`** (`client.bal:473-513`)
  to dispatch to REST when `self.binding == "HTTP+JSON"`:

```ballerina
    private isolated function openSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        if self.binding == "HTTP+JSON" {
            return self.openRestSseStream(method, params);
        }
        // ... existing JSON-RPC body unchanged ...
    }

    # Opens a REST binding SSE stream for a streaming operation
    # (SendStreamingMessage or SubscribeToTask).
    #
    # + method - the JSON-RPC-style method name (see buildRestRequest)
    # + params - the same params map the JSON-RPC binding would build
    # + return - a stream of StreamResponse values, or a typed A2AError
    private isolated function openRestSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> headers = self.buildHeaders();
        headers["Accept"] = "text/event-stream";
        http:Response resp = op.httpMethod == "GET"
            ? check self.httpClient->get(path, headers)
            : check self.httpClient->post(path, body ?: {}, headers);
        self.captureGrantedExtensions(resp);
        if !resp.getContentType().startsWith("text/event-stream") {
            json|error errBody = resp.getJsonPayload();
            return toA2AErrorFromRest(resp.statusCode, errBody is json ? errBody : ());
        }
        return readSseStream(resp, self.mode, self.binding);
    }
```

Also update the two existing call sites of `readSseStream` in the
JSON-RPC branch of `openSseStream` (unchanged behaviorally, just need the
new third argument added, defaulting to `"JSONRPC"` so nothing there
actually changes): confirm the existing call becomes
`readSseStream(resp, self.mode, self.binding)` rather than
`readSseStream(resp, self.mode)`, since `self.binding` is `"JSONRPC"` in
that branch anyway.

- [ ] **Step 5: Run both new tests, confirm pass.**

- [ ] **Step 6: Full suite, then commit**

```bash
git add a2a/client.bal a2a/sse.bal a2a/tests/testutil.bal a2a/tests/client_test.bal
git commit -m "feat: add REST binding SSE streaming with bare StreamResponse decoding and error-event mapping"
```

---

## Task 6: `SubscribeToTask` GET-with-POST-fallback

**Files:**
- Modify: `client.bal` (`openRestSseStream`, or wherever `SubscribeToTask`
  specifically needs special handling)
- Test: `tests/testutil.bal`, `tests/client_test.bal`

**Interfaces:**
- Consumes: `openRestSseStream` (Task 5).
- Produces: a single, `SubscribeToTask`-scoped retry: if the REST GET to
  `/tasks/{id}:subscribe` returns `404`, `405`, or `501`, retry exactly
  once with `POST` to the same path.

- [ ] **Step 1: Write the failing tests**

```ballerina
// tests/client_test.bal
@test:Config {}
function testRestSubscribeToTaskRetriesWithPostOn405() returns error? {
    // Script the mock to reject GET with 405 for this one operation, then
    // accept POST — assert the client retries and succeeds, not that it
    // surfaces the 405 as an error.
    setNextRestSseResponse([
        {'event: "message", data: string `{"statusUpdate": {"taskId": "task-1", "contextId": "ctx-1", "status": {"state": "TASK_STATE_WORKING"}}}`}
    ]);
    setRestRejectMethod("GET", 405);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    stream<StreamResponse, error?> s = check c->subscribeToTask("task-1");
    StreamResponse first = check expectValue(s.next());
    test:assertEquals(first?.statusUpdate?.taskId, "task-1");
}

@test:Config {}
function testRestFallbackDoesNotFireForOtherOperations() returns error? {
    // A 405 on any operation OTHER than SubscribeToTask must surface as
    // a normal error, not trigger a retry — the fallback is scoped to
    // exactly this one operation.
    setNextRestResponse({}, statusCode = 405);
    Client c = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task|error result = c->getTask("task-1");
    test:assertTrue(result is error, "a 405 on GetTask must surface as an error, not silently retry with a different verb");
}
```

- [ ] **Step 2: Run, confirm the first fails** (no retry logic exists
  yet) and the second passes already (no accidental over-broad retry).

- [ ] **Step 3: Implement the scoped retry in `openRestSseStream`**
  (Task 5's function), replacing the direct GET call for
  `SubscribeToTask` specifically:

```ballerina
    private isolated function openRestSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> headers = self.buildHeaders();
        headers["Accept"] = "text/event-stream";
        http:Response resp;
        if op.httpMethod == "GET" {
            resp = check self.httpClient->get(path, headers);
            // SubscribeToTask's proto annotation says GET, but a
            // non-reference server that hand-rolled its REST routes
            // following the reference *client* (which sends POST) might
            // only have registered POST. Scoped to exactly this one
            // operation — retrying broadly for every operation would
            // mask genuine method-not-allowed errors elsewhere.
            if method == "SubscribeToTask" && (resp.statusCode == 404 || resp.statusCode == 405 || resp.statusCode == 501) {
                resp = check self.httpClient->post(path, body ?: {}, headers);
            }
        } else {
            resp = check self.httpClient->post(path, body ?: {}, headers);
        }
        self.captureGrantedExtensions(resp);
        if !resp.getContentType().startsWith("text/event-stream") {
            json|error errBody = resp.getJsonPayload();
            return toA2AErrorFromRest(resp.statusCode, errBody is json ? errBody : ());
        }
        return readSseStream(resp, self.mode, self.binding);
    }
```

- [ ] **Step 4: Run both tests, confirm pass.**

- [ ] **Step 5: Full suite, then commit**

```bash
git add a2a/client.bal a2a/tests/testutil.bal a2a/tests/client_test.bal
git commit -m "feat: add scoped GET-to-POST fallback for SubscribeToTask over REST"
```

---

## Task 7: Close the M1 pre-existing gap — `Part.raw` byte[] round-trip test

**Files:**
- Modify: `tests/types_test.bal`

**Interfaces:** none new — pure test addition, closing a gap the design
spec flagged as pre-existing and not REST-specific, but worth closing
"while REST is being built" per the spec's own recommendation.

- [ ] **Step 1: Write and run in one pass** (this exercises existing
  `Part`/`toJson`/`cloneWithType` behavior; if it fails, that's a genuine
  bug the spec flagged as merely "assumed correct, never asserted" — fix
  `Part`'s handling in `types.bal` using the failure output to scope the
  fix, don't just adjust the test):

```ballerina
@test:Config {}
function testPartRawBytesRoundTripThroughBase64() returns error? {
    byte[] originalBytes = "hello world, some bytes".toBytes();
    Part original = {raw: originalBytes, mediaType: "application/octet-stream"};
    json encoded = original.toJson();
    // Confirm the wire representation really is a base64 string, not a
    // JSON array of byte values — this is the specific thing the design
    // spec flagged as assumed-but-never-asserted.
    map<json> encodedMap = check encoded.ensureType();
    json? rawField = encodedMap["raw"];
    test:assertTrue(rawField is string, "Part.raw must serialize as a base64 string on the wire, matching the proto's documented JSON encoding for bytes fields");
    Part decoded = check encoded.cloneWithType(Part);
    test:assertEquals(decoded.raw, originalBytes);
}
```

Run: `bal test --tests testPartRawBytesRoundTripThroughBase64`
Expected: PASS immediately (coverage, not new behavior) — if it fails,
investigate and fix `Part`'s byte-array handling in `types.bal` before
continuing.

- [ ] **Step 2: Full suite, then commit**

```bash
git add a2a/tests/types_test.bal
git commit -m "test: assert Part.raw round-trips through base64, closing the M1 pre-existing gap"
```

---

## Task 8: Equivalence tests — same scenario, JSON-RPC and REST, identical results

**Files:**
- Modify: `tests/client_test.bal`

**Interfaces:** none new — the strongest available check that the
binding is truly invisible to callers.

- [ ] **Step 1: Write and run** (should pass immediately if Tasks 1-6 are
  correct; a failure here means something in the REST path produces a
  value shape or error type that differs from the JSON-RPC binding for
  the same logical scenario):

```ballerina
@test:Config {}
function testJsonRpcAndRestProduceIdenticalGetTaskResult() returns error? {
    json taskBody = defaultTaskJson();

    setNextJsonResponse({"jsonrpc": "2.0", "id": "1", "result": taskBody});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task jsonRpcResult = check jsonRpcClient->getTask("task-x");

    setNextRestResponse(taskBody);
    Client restClient = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task restResult = check restClient->getTask("task-x");

    test:assertEquals(jsonRpcResult, restResult, "the same logical task must decode to an identical Task value regardless of which binding fetched it");
}

@test:Config {}
function testJsonRpcAndRestProduceIdenticalErrorTypeAndCode() returns error? {
    setNextJsonResponse({"jsonrpc": "2.0", "id": "1", "error": {"code": -32002, "message": "cannot cancel"}});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task|error jsonRpcResult = jsonRpcClient->cancelTask("task-x");

    setNextRestResponse({
        "error": {"message": "cannot cancel", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE"}]}
    }, statusCode = 400);
    Client restClient = check new (getServerBaseUrl(), binding = "HTTP+JSON");
    Task|error restResult = restClient->cancelTask("task-x");

    test:assertTrue(jsonRpcResult is TaskNotCancelableError);
    test:assertTrue(restResult is TaskNotCancelableError);
    test:assertEquals((<error>jsonRpcResult).detail().code, (<error>restResult).detail().code,
            "detail.code must be identical across bindings so a caller switching Client from JSON-RPC to REST sees no difference");
}
```

- [ ] **Step 2: Full suite, then commit**

```bash
git add a2a/tests/client_test.bal
git commit -m "test: add cross-binding equivalence tests proving REST and JSON-RPC are interchangeable to callers"
```

---

## Task 9: Interop-repo findings note (separate repo, light touch)

**Files:**
- Modify (in the sibling `a2a-interop-tests` repo, not this one):
  `FINDINGS.md` or a new `servers/<agent>/findings.md` entry, per that
  repo's existing convention.

**Interfaces:** none — documentation only, and explicitly optional if the
implementer doesn't have easy access to re-check the reference agents.

- [ ] **Step 1: Check each of the three reference agents' AgentCards**
  (`helloworld`, `adk_currency_agent`, the langgraph agent — see that
  repo's `servers/<agent>/setup.md` for how to run each one) for an
  `HTTP+JSON` entry in `supportedInterfaces`. This can be done without
  running the agents if their AgentCard JSON is already captured
  somewhere in that repo's findings docs from prior interop work; if not,
  running each briefly to fetch `/.well-known/agent-card.json` settles it
  quickly.

- [ ] **Step 2: Record the outcome.** If none advertise `HTTP+JSON` (the
  expected outcome per the design spec, which already flagged this gap),
  add one line to that repo's `FINDINGS.md` (or wherever this project's
  convention places such notes) recording that the REST binding is
  currently mock-verified only, with no real-server coverage — the same
  way the push-notification-config delete gap was recorded for the
  langgraph agent. If one of them *does* advertise `HTTP+JSON` unexpectedly,
  that's a genuinely interesting finding worth its own short write-up
  (and potentially a real interop test, which would be valuable follow-up
  work beyond this plan's scope).

- [ ] **Step 3: Commit** (in the interop-tests repo, per that repo's own
  convention of one branch/PR per unit of work — this is a small enough
  change it may be fine to fold into this same PR's description as a
  note rather than requiring a separate branch; use judgment, or ask the
  human partner if genuinely unsure which repo/branch this belongs on).

---

## After this plan

Once all 9 tasks are complete and reviewed, the REST binding is
implementation-complete and mock-verified. `Client` can be constructed
with `binding = "HTTP+JSON"` against any conformant REST-serving agent,
with identical caller-visible behavior (return types, error types,
`detail.code` values) to the JSON-RPC binding. The one known, deliberately
scoped-small residual risk is `SubscribeToTask`'s GET-vs-POST divergence,
mitigated by Task 6's single-operation retry and flagged for real-server
confirmation whenever a REST-serving reference agent becomes available
(Task 9).

The gRPC transport binding (from
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md`) is
separate, substantially larger follow-up work — a new implementation plan
in the same style as this one, on its own branch, per the human partner's
explicit direction to keep REST and gRPC on separate branches/PRs.
