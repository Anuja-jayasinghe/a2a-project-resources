# A2A v0.3 Client Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ballerina/a2a`'s `Client` talk to A2A protocol v0.3 servers (like `adk_currency_agent`) by auto-detecting the dialect from the resolved `AgentCard` and translating v0.3 wire shapes into the exact same `Task`/`Message`/`Role`/`TaskState`/`StreamResponse` types it already returns for v1.0 servers.

**Architecture:** One new file, `compat_v03.bal`, at the `a2a` package root holds all v0.3 detection/translation logic as plain functions (no submodule — see rationale in the design spec). `Client` gains a private `ProtocolMode` field, set once at construction from an optional new `AgentCard? agentCard` parameter on `Client.init` (omitted = today's exact v1.0-only behavior, zero change for existing callers), and threaded through `rpcCall`, `openSseStream`, and the SSE generator.

**Tech Stack:** Ballerina (`bal test`, `bal build`), existing `testutil.bal` mock-server scripting pattern.

## Global Constraints

- Every existing public method signature and returned type is unchanged. A caller never sees or branches on protocol mode.
- Every new parameter (`Client.init`'s `agentCard`, `readSseStream`'s `mode`, `A2AStreamGenerator.init`'s `mode`) has a default value so every existing call site keeps compiling unchanged.
- No new `A2AError` subtypes — confirmed in the design spec that v0.3 and v1.0 share the same error code table for -32001 through -32007, and -32008/-32009 are v1.0-only additions a v0.3 server can never emit.
- Full design context lives in `a2a/docs/superpowers/specs/2026-07-28-v03-client-compat-design.md` — read it before starting if anything below is unclear on *why*, not just *what*.

---

## Task 1: `AgentCard.protocolVersion` field

**Files:**
- Modify: `a2a/types.bal:127-162` (the `AgentCard` type)
- Test: `a2a/tests/types_test.bal`

**Interfaces:**
- Produces: `AgentCard.protocolVersion` — `string?`, optional field.

- [ ] **Step 1: Write the failing tests**

Add to `a2a/tests/types_test.bal`, near the existing `AgentCard` round-trip tests (search for `testAgentCardCompositeRoundTrip`):

```ballerina
@test:Config {}
function testAgentCardRoundTripWithProtocolVersion() returns error? {
    AgentCard original = {
        name: "Legacy Agent",
        description: "A v0.3-style agent",
        version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };

    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded.protocolVersion, "0.3.0");
}

@test:Config {}
function testAgentCardToleratesMissingProtocolVersion() returns error? {
    json payload = {
        name: "v1.0 Agent",
        description: "A v1.0 agent that omits the legacy field",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: []
    };

    AgentCard decoded = check payload.cloneWithType(AgentCard);

    test:assertTrue(decoded?.protocolVersion is (), "protocolVersion should be nil, not defaulted, when the server never sent it");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testAgentCardRoundTripWithProtocolVersion` (from `a2a-ballerina/a2a`)
Expected: FAIL — compile error, `protocolVersion` is not a field of `AgentCard`.

- [ ] **Step 3: Add the field**

In `a2a/types.bal`, inside the `AgentCard` type (right after the `version` field, before `url`):

```ballerina
    # Agent's own version, not the protocol version
    string version;
    # Legacy top-level protocol version field, from before v1.0 moved this
    # into each AgentInterface.protocolVersion. A card with no
    # supportedInterfaces (see url below) is a legacy card; this field
    # helps detectProtocolMode (compat_v03.bal) confirm which dialect it
    # declares. v1.0-native cards omit this and set
    # supportedInterfaces[0].protocolVersion instead.
    string? protocolVersion?;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testAgentCardRoundTripWithProtocolVersion,testAgentCardToleratesMissingProtocolVersion`
Expected: PASS

- [ ] **Step 5: Run the full suite to confirm nothing else broke**

Run: `bal test` (from `a2a-ballerina/a2a`)
Expected: all `a2a` module tests pass (78 passing — 76 today + the 2 new ones), `a2a.transport` unaffected.

- [ ] **Step 6: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: add AgentCard.protocolVersion legacy field"
```

---

## Task 2: `ProtocolMode` + `detectProtocolMode`

**Files:**
- Create: `a2a/compat_v03.bal`
- Test: Create `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `AgentCard` (`types.bal`).
- Produces: `public type ProtocolMode "V1_0"|"V0_3";` and `isolated function detectProtocolMode(AgentCard card) returns ProtocolMode` — both used by every later task in this plan.

- [ ] **Step 1: Write the failing tests**

Create `a2a/tests/compat_v03_test.bal`:

```ballerina
import ballerina/test;

@test:Config {}
function testDetectProtocolModeFromSupportedInterfaces() returns error? {
    AgentCard v1Card = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://x", protocolBinding: "JSONRPC", protocolVersion: "1.0"}],
        skills: []
    };
    test:assertEquals(detectProtocolMode(v1Card), "V1_0");

    AgentCard v03InterfaceCard = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://x", protocolBinding: "JSONRPC", protocolVersion: "0.3.0"}],
        skills: []
    };
    test:assertEquals(detectProtocolMode(v03InterfaceCard), "V0_3");
}

@test:Config {}
function testDetectProtocolModeFromLegacyTopLevelField() returns error? {
    AgentCard legacyV03Card = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    test:assertEquals(detectProtocolMode(legacyV03Card), "V0_3");
}

@test:Config {}
function testDetectProtocolModeDefaultsLegacyCardWithNoProtocolVersionToV03() returns error? {
    // No supportedInterfaces AND no top-level protocolVersion: the currency
    // agent's exact shape isn't quite this (it does set protocolVersion),
    // but a legacy card that omits it entirely still lacks the one thing
    // that marks it v1.0-native (supportedInterfaces), so it defaults to
    // V0_3 rather than assuming v1.0.
    AgentCard bareLegacyCard = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        skills: []
    };
    test:assertEquals(detectProtocolMode(bareLegacyCard), "V0_3");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testDetectProtocolModeFromSupportedInterfaces`
Expected: FAIL — compile error, `detectProtocolMode`/`ProtocolMode` don't exist.

- [ ] **Step 3: Write the implementation**

Create `a2a/compat_v03.bal`:

```ballerina
// A2A protocol v0.3 compatibility layer.
//
// Lives in the root module, not modules/, for the same reason sse.bal and
// errors.bal do: a submodule under modules/ cannot import the root a2a
// module without a cyclic dependency, and this file needs to construct
// Task/Message/Role/TaskState/StreamResponse values directly. See
// docs/superpowers/specs/2026-07-28-v03-client-compat-design.md for the
// full design and the evidence behind every mapping below.

# Which A2A wire dialect a Client speaks to a given server.
public type ProtocolMode "V1_0"|"V0_3";

# Detects which wire dialect to use, from a resolved AgentCard.
#
# + card - the agent card fetched via resolveAgentCard
# + return - V0_3 for a legacy card (no supportedInterfaces) unless its
#            legacy top-level protocolVersion explicitly says otherwise, or
#            for a card whose first supportedInterfaces entry declares a
#            "0.x" protocolVersion; V1_0 otherwise
public isolated function detectProtocolMode(AgentCard card) returns ProtocolMode {
    if card.supportedInterfaces.length() > 0 {
        string? v = card.supportedInterfaces[0].protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    string? v = card?.protocolVersion;
    return (v is string && !v.startsWith("0.")) ? "V1_0" : "V0_3";
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testDetectProtocolModeFromSupportedInterfaces,testDetectProtocolModeFromLegacyTopLevelField,testDetectProtocolModeDefaultsLegacyCardWithNoProtocolVersionToV03`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add ProtocolMode and detectProtocolMode"
```

---

## Task 3: Method name, `Role`, and `TaskState` translation tables

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `Role`, `TaskState` (`types.bal`).
- Produces: `isolated function v03MethodName(string v1Method) returns string`, `isolated function mapV03Role(string role) returns Role|error`, `isolated function mapV03State(string state) returns TaskState|error` — all used by Task 5/7/8/9.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testV03MethodNameTranslation() returns error? {
    test:assertEquals(v03MethodName("SendMessage"), "message/send");
    test:assertEquals(v03MethodName("SendStreamingMessage"), "message/stream");
    test:assertEquals(v03MethodName("GetTask"), "tasks/get");
    test:assertEquals(v03MethodName("CancelTask"), "tasks/cancel");
    test:assertEquals(v03MethodName("SubscribeToTask"), "tasks/resubscribe");
}

@test:Config {}
function testMapV03Role() returns error? {
    test:assertEquals(check mapV03Role("user"), ROLE_USER);
    test:assertEquals(check mapV03Role("agent"), ROLE_AGENT);

    Role|error result = mapV03Role("nonsense");
    test:assertTrue(result is error, "an unrecognized v0.3 role should surface as an error, not silently default");
}

@test:Config {}
function testMapV03State() returns error? {
    test:assertEquals(check mapV03State("submitted"), TASK_STATE_SUBMITTED);
    test:assertEquals(check mapV03State("working"), TASK_STATE_WORKING);
    test:assertEquals(check mapV03State("completed"), TASK_STATE_COMPLETED);
    test:assertEquals(check mapV03State("failed"), TASK_STATE_FAILED);
    test:assertEquals(check mapV03State("canceled"), TASK_STATE_CANCELED);
    test:assertEquals(check mapV03State("rejected"), TASK_STATE_REJECTED);
    test:assertEquals(check mapV03State("input-required"), TASK_STATE_INPUT_REQUIRED);
    test:assertEquals(check mapV03State("auth-required"), TASK_STATE_AUTH_REQUIRED);

    TaskState|error result = mapV03State("nonsense");
    test:assertTrue(result is error, "an unrecognized v0.3 state should surface as an error, not silently default");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testV03MethodNameTranslation`
Expected: FAIL — compile error, functions don't exist.

- [ ] **Step 3: Write the implementation**

Append to `a2a/compat_v03.bal`:

```ballerina
# Translates a v1.0 PascalCase JSON-RPC method name to its v0.3 equivalent.
#
# + v1Method - the method name this client already builds for v1.0
# + return - the v0.3 wire method name
isolated function v03MethodName(string v1Method) returns string {
    match v1Method {
        "SendMessage" => {
            return "message/send";
        }
        "SendStreamingMessage" => {
            return "message/stream";
        }
        "GetTask" => {
            return "tasks/get";
        }
        "CancelTask" => {
            return "tasks/cancel";
        }
        "SubscribeToTask" => {
            return "tasks/resubscribe";
        }
        _ => {
            return v1Method;
        }
    }
}

# + role - the v0.3 wire role string ("user"/"agent")
# + return - the equivalent v1.0 Role, or an error if unrecognized
isolated function mapV03Role(string role) returns Role|error {
    match role {
        "user" => {
            return ROLE_USER;
        }
        "agent" => {
            return ROLE_AGENT;
        }
        _ => {
            return error(string `Unrecognized v0.3 role: ${role}`);
        }
    }
}

# + state - the v0.3 wire state string (e.g. "completed", "input-required")
# + return - the equivalent v1.0 TaskState, or an error if unrecognized
isolated function mapV03State(string state) returns TaskState|error {
    match state {
        "submitted" => {
            return TASK_STATE_SUBMITTED;
        }
        "working" => {
            return TASK_STATE_WORKING;
        }
        "completed" => {
            return TASK_STATE_COMPLETED;
        }
        "failed" => {
            return TASK_STATE_FAILED;
        }
        "canceled" => {
            return TASK_STATE_CANCELED;
        }
        "rejected" => {
            return TASK_STATE_REJECTED;
        }
        "input-required" => {
            return TASK_STATE_INPUT_REQUIRED;
        }
        "auth-required" => {
            return TASK_STATE_AUTH_REQUIRED;
        }
        _ => {
            return error(string `Unrecognized v0.3 task state: ${state}`);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testV03MethodNameTranslation,testMapV03Role,testMapV03State`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add v0.3 method name, Role, and TaskState translation"
```

---

## Task 4: `parseV03Part`

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `Part` (`types.bal`).
- Produces: `isolated function parseV03Part(json partJson) returns Part|error` — used by Task 5.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testParseV03PartText() returns error? {
    Part part = check parseV03Part({"kind": "text", "text": "hello"});
    test:assertEquals(part?.text, "hello");
}

@test:Config {}
function testParseV03PartFileWithUri() returns error? {
    Part part = check parseV03Part({
        "kind": "file",
        "file": {"uri": "https://example.com/report.pdf", "mime_type": "application/pdf", "name": "report.pdf"}
    });
    test:assertEquals(part?.url, "https://example.com/report.pdf");
    test:assertEquals(part?.mediaType, "application/pdf");
    test:assertEquals(part?.filename, "report.pdf");
}

@test:Config {}
function testParseV03PartFileWithBytes() returns error? {
    // "aGVsbG8=" base64-decodes to "hello"
    Part part = check parseV03Part({
        "kind": "file",
        "file": {"bytes": "aGVsbG8=", "mime_type": "text/plain"}
    });
    byte[]? raw = part?.raw;
    test:assertTrue(raw is byte[], "file-with-bytes should decode into Part.raw");
    test:assertEquals(string:fromBytes(<byte[]>raw), "hello");
}

@test:Config {}
function testParseV03PartData() returns error? {
    Part part = check parseV03Part({"kind": "data", "data": {"amount": 100, "currency": "USD"}});
    json? data = part?.data;
    test:assertEquals(data, {"amount": 100, "currency": "USD"});
}

@test:Config {}
function testParseV03PartRejectsUnrecognizedKind() returns error? {
    Part|error result = parseV03Part({"kind": "video", "url": "x"});
    test:assertTrue(result is error, "an unrecognized v0.3 Part kind should surface as an error");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testParseV03PartText`
Expected: FAIL — compile error, `parseV03Part` doesn't exist.

- [ ] **Step 3: Write the implementation**

Append to `a2a/compat_v03.bal` (needs `import ballerina/lang.'string as strings;` only if used elsewhere — not needed here, `mediaType`/`filename` extraction uses plain map indexing):

```ballerina
# Converts a v0.3 Part (kind-discriminated: text/file/data) into the v1.0
# Part shape (field-presence discriminated). File variants nest bytes/uri
# one level deeper in v0.3 (under a "file" object) than v1.0's flat
# raw/url fields; byte-array decoding is left to Ballerina's own
# cloneWithType, which already understands base64-encoded byte[] fields,
# rather than hand-decoding here.
#
# + partJson - the raw v0.3 Part JSON
# + return - the equivalent v1.0 Part, or an error if malformed/unrecognized
isolated function parseV03Part(json partJson) returns Part|error {
    map<json> m = check partJson.ensureType();
    string kind = check m["kind"].ensureType();
    map<json> v1Shape = {};
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    match kind {
        "text" => {
            v1Shape["text"] = m["text"];
        }
        "data" => {
            v1Shape["data"] = m["data"];
        }
        "file" => {
            map<json> file = check m["file"].ensureType();
            if file.hasKey("bytes") {
                v1Shape["raw"] = file["bytes"];
            } else if file.hasKey("uri") {
                v1Shape["url"] = file["uri"];
            } else {
                return error("v0.3 FilePart.file has neither bytes nor uri");
            }
            if file.hasKey("name") {
                v1Shape["filename"] = file["name"];
            }
            if file.hasKey("mime_type") {
                v1Shape["mediaType"] = file["mime_type"];
            } else if file.hasKey("mimeType") {
                v1Shape["mediaType"] = file["mimeType"];
            }
        }
        _ => {
            return error(string `Unrecognized v0.3 Part kind: ${kind}`);
        }
    }

    return check v1Shape.cloneWithType(Part);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testParseV03PartText,testParseV03PartFileWithUri,testParseV03PartFileWithBytes,testParseV03PartData,testParseV03PartRejectsUnrecognizedKind`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add parseV03Part"
```

---

## Task 5: `parseV03Message`, `parseV03TaskStatus`, `parseV03Artifact`, `parseV03Task`

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `parseV03Part`, `mapV03Role`, `mapV03State` (Tasks 3-4); `Message`, `TaskStatus`, `Artifact`, `Task` (`types.bal`).
- Produces: `isolated function parseV03Message(json) returns Message|error`, `isolated function parseV03TaskStatus(json) returns TaskStatus|error`, `isolated function parseV03Artifact(json) returns Artifact|error`, `isolated function parseV03Task(json) returns Task|error` — all used by Task 6 and Task 8.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testParseV03Message() returns error? {
    Message msg = check parseV03Message({
        "messageId": "msg-1",
        "role": "user",
        "parts": [{"kind": "text", "text": "Convert 100 USD to EUR"}],
        "contextId": "ctx-1",
        "kind": "message"
    });
    test:assertEquals(msg.messageId, "msg-1");
    test:assertEquals(msg.role, ROLE_USER);
    test:assertEquals(msg.parts.length(), 1);
    test:assertEquals(msg.parts[0]?.text, "Convert 100 USD to EUR");
    test:assertEquals(msg?.contextId, "ctx-1");
}

@test:Config {}
function testParseV03TaskStatus() returns error? {
    TaskStatus status = check parseV03TaskStatus({
        "state": "completed",
        "timestamp": "2026-07-28T03:18:13.954298+00:00",
        "message": {
            "messageId": "msg-2", "role": "agent",
            "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}],
            "kind": "message"
        }
    });
    test:assertEquals(status.state, TASK_STATE_COMPLETED);
    test:assertEquals(status?.timestamp, "2026-07-28T03:18:13.954298+00:00");
    Message? statusMessage = status?.message;
    test:assertTrue(statusMessage is Message, "TaskStatus.message should be parsed, not dropped");
    test:assertEquals((<Message>statusMessage).role, ROLE_AGENT);
}

@test:Config {}
function testParseV03Artifact() returns error? {
    Artifact artifact = check parseV03Artifact({
        "artifactId": "art-1",
        "name": "conversion_result",
        "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}]
    });
    test:assertEquals(artifact.artifactId, "art-1");
    test:assertEquals(artifact?.name, "conversion_result");
    test:assertEquals(artifact.parts[0]?.text, "100 USD is equal to 87.80 EUR.");
}

# Full round-trip against the actual raw response recorded in
# a2a-interop-tests/servers/adk_currency_agent/findings.md, minus the
# outer JSON-RPC envelope (that's rpcCall's job, not parseV03Task's).
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testParseV03TaskFromRealCurrencyAgentResponse() returns error? {
    Task task = check parseV03Task({
        "artifacts": [
            {"artifactId": "d9d3ff03-bf6c-4c68-ac46-b56a3088349c", "name": "conversion_result",
             "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}]}
        ],
        "contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684",
        "history": [
            {"contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684", "kind": "message",
             "messageId": "probe-msg-2", "parts": [{"kind": "text", "text": "Convert 100 USD to EUR"}],
             "role": "user", "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"}
        ],
        "id": "6ea25505-6764-4b29-9932-0227e2cf7e3e",
        "kind": "task",
        "status": {
            "message": {"contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684", "kind": "message",
                        "messageId": "e754dd1e-61b7-4968-a36f-7c4ea0ec14fa",
                        "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}],
                        "role": "agent", "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"},
            "state": "completed",
            "timestamp": "2026-07-28T03:18:13.954298+00:00"
        }
    });

    test:assertEquals(task.id, "6ea25505-6764-4b29-9932-0227e2cf7e3e");
    test:assertEquals(task?.contextId, "1b4188cb-0bc7-48ea-a3e6-177fa50f1684");
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(task.history.length(), 1);
    test:assertEquals(task.history[0].role, ROLE_USER);
    test:assertEquals(task.artifacts.length(), 1);
    test:assertEquals(task.artifacts[0].parts[0]?.text, "100 USD is equal to 87.80 EUR.");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testParseV03Message`
Expected: FAIL — compile error, functions don't exist.

- [ ] **Step 3: Write the implementation**

Append to `a2a/compat_v03.bal`:

```ballerina
# + msgJson - the raw v0.3 Message JSON
# + return - the equivalent v1.0 Message, or an error if malformed
isolated function parseV03Message(json msgJson) returns Message|error {
    map<json> m = check msgJson.ensureType();
    string role = check m["role"].ensureType();
    Role mappedRole = check mapV03Role(role);

    json[] rawParts = check m["parts"].ensureType();
    Part[] parts = [];
    foreach json p in rawParts {
        parts.push(check parseV03Part(p));
    }

    map<json> v1Shape = {
        messageId: check m["messageId"].ensureType(),
        role: mappedRole.toJson(),
        parts: parts.toJson()
    };
    if m.hasKey("contextId") {
        v1Shape["contextId"] = m["contextId"];
    }
    if m.hasKey("taskId") {
        v1Shape["taskId"] = m["taskId"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    return check v1Shape.cloneWithType(Message);
}

# + statusJson - the raw v0.3 TaskStatus JSON
# + return - the equivalent v1.0 TaskStatus, or an error if malformed
isolated function parseV03TaskStatus(json statusJson) returns TaskStatus|error {
    map<json> m = check statusJson.ensureType();
    TaskState state = check mapV03State(check m["state"].ensureType());

    map<json> v1Shape = {state: state.toJson()};
    if m.hasKey("message") {
        Message msg = check parseV03Message(m["message"]);
        v1Shape["message"] = msg.toJson();
    }
    if m.hasKey("timestamp") {
        v1Shape["timestamp"] = m["timestamp"];
    }

    return check v1Shape.cloneWithType(TaskStatus);
}

# + artifactJson - the raw v0.3 Artifact JSON
# + return - the equivalent v1.0 Artifact, or an error if malformed
isolated function parseV03Artifact(json artifactJson) returns Artifact|error {
    map<json> m = check artifactJson.ensureType();

    json[] rawParts = check m["parts"].ensureType();
    Part[] parts = [];
    foreach json p in rawParts {
        parts.push(check parseV03Part(p));
    }

    map<json> v1Shape = {
        artifactId: check m["artifactId"].ensureType(),
        parts: parts.toJson()
    };
    if m.hasKey("name") {
        v1Shape["name"] = m["name"];
    }
    if m.hasKey("description") {
        v1Shape["description"] = m["description"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    return check v1Shape.cloneWithType(Artifact);
}

# + taskJson - the raw v0.3 Task JSON (unwrapped — see decodeV03SendResult)
# + return - the equivalent v1.0 Task, or an error if malformed
isolated function parseV03Task(json taskJson) returns Task|error {
    map<json> m = check taskJson.ensureType();
    TaskStatus status = check parseV03TaskStatus(m["status"]);

    map<json> v1Shape = {
        id: check m["id"].ensureType(),
        status: status.toJson()
    };
    if m.hasKey("contextId") {
        v1Shape["contextId"] = m["contextId"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }
    if m.hasKey("history") {
        json[] rawHistory = check m["history"].ensureType();
        Message[] history = [];
        foreach json hm in rawHistory {
            history.push(check parseV03Message(hm));
        }
        v1Shape["history"] = history.toJson();
    }
    if m.hasKey("artifacts") {
        json[] rawArtifacts = check m["artifacts"].ensureType();
        Artifact[] artifacts = [];
        foreach json am in rawArtifacts {
            artifacts.push(check parseV03Artifact(am));
        }
        v1Shape["artifacts"] = artifacts.toJson();
    }

    return check v1Shape.cloneWithType(Task);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testParseV03Message,testParseV03TaskStatus,testParseV03Artifact,testParseV03TaskFromRealCurrencyAgentResponse`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add parseV03Message/TaskStatus/Artifact/Task"
```

---

## Task 6: `decodeV03SendResult` and `decodeV03StreamEvent`

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `parseV03Task`, `parseV03Message`, `parseV03TaskStatus`, `parseV03Artifact` (Task 5).
- Produces: `isolated function decodeV03SendResult(json result) returns Task|Message|error`, `isolated function decodeV03StreamEvent(json result) returns StreamResponse|error` — used by Task 8 (`sendMessage`) and Task 9 (`sse.bal`) respectively.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testDecodeV03SendResultTask() returns error? {
    Task|Message result = check decodeV03SendResult({
        "id": "task-1", "kind": "task",
        "status": {"state": "completed"}
    });
    test:assertTrue(result is Task, "kind:task should decode as a Task");
}

@test:Config {}
function testDecodeV03SendResultMessage() returns error? {
    Task|Message result = check decodeV03SendResult({
        "messageId": "msg-1", "kind": "message", "role": "agent",
        "parts": [{"kind": "text", "text": "hi"}]
    });
    test:assertTrue(result is Message, "kind:message should decode as a Message");
}

@test:Config {}
function testDecodeV03SendResultRejectsUnrecognizedKind() returns error? {
    Task|Message|error result = decodeV03SendResult({"kind": "artifact-update"});
    test:assertTrue(result is error, "an unrecognized top-level kind should surface as an error");
}

@test:Config {}
function testDecodeV03StreamEventStatusUpdate() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "status-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "status": {"state": "working"},
        "final": false
    });
    TaskStatusUpdateEvent? update = event?.statusUpdate;
    test:assertTrue(update is TaskStatusUpdateEvent, "status-update should decode into StreamResponse.statusUpdate");
    test:assertEquals((<TaskStatusUpdateEvent>update).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testDecodeV03StreamEventArtifactUpdate() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "artifact-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "artifact": {"artifactId": "art-1", "parts": [{"kind": "text", "text": "partial"}]},
        "lastChunk": true
    });
    TaskArtifactUpdateEvent? update = event?.artifactUpdate;
    test:assertTrue(update is TaskArtifactUpdateEvent, "artifact-update should decode into StreamResponse.artifactUpdate");
    test:assertEquals((<TaskArtifactUpdateEvent>update).lastChunk, true);
}

# Confirms the client ignores v0.3's redundant "final" field entirely and
# derives terminal-ness solely from the translated TaskState, matching the
# reference SDK's own v0.3->v1.0 conversion behavior (see design spec).
# final:true here is deliberately paired with a non-terminal state
# ("working") to prove it has no effect on the decoded event.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testDecodeV03StreamEventIgnoresFinalField() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "status-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "status": {"state": "working"},
        "final": true
    });
    TaskStatusUpdateEvent update = <TaskStatusUpdateEvent>event?.statusUpdate;
    test:assertEquals(update.status.state, TASK_STATE_WORKING, "final:true on a non-terminal state must not change the decoded TaskState");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testDecodeV03SendResultTask`
Expected: FAIL — compile error, functions don't exist.

- [ ] **Step 3: Write the implementation**

Append to `a2a/compat_v03.bal`:

```ballerina
# Decodes a v0.3 sendMessage/message-send result, which is unwrapped and
# kind-tagged (unlike v1.0's {"task":...}/{"message":...} wrapper).
#
# + result - the raw JSON-RPC result field
# + return - the equivalent Task or Message, or an error
isolated function decodeV03SendResult(json result) returns Task|Message|error {
    map<json> m = check result.ensureType();
    string kind = check m["kind"].ensureType();
    match kind {
        "task" => {
            return parseV03Task(result);
        }
        "message" => {
            return parseV03Message(result);
        }
        _ => {
            return error(string `Unrecognized v0.3 sendMessage result kind: ${kind}`);
        }
    }
}

# Decodes one v0.3 stream event (kind-discriminated) into the same
# StreamResponse shape v1.0 streams already produce.
#
# + result - the raw JSON-RPC result field for one SSE event
# + return - the equivalent StreamResponse, or an error
isolated function decodeV03StreamEvent(json result) returns StreamResponse|error {
    map<json> m = check result.ensureType();
    string kind = check m["kind"].ensureType();

    match kind {
        "task" => {
            Task t = check parseV03Task(result);
            return {task: t};
        }
        "message" => {
            Message msg = check parseV03Message(result);
            return {message: msg};
        }
        "status-update" => {
            TaskStatus status = check parseV03TaskStatus(m["status"]);
            map<json> v1Shape = {
                taskId: check m["taskId"].ensureType(),
                contextId: check m["contextId"].ensureType(),
                status: status.toJson()
            };
            if m.hasKey("metadata") {
                v1Shape["metadata"] = m["metadata"];
            }
            // "final" (v0.3-only) is deliberately not copied across — see
            // the design spec's evidence that it's pure derived redundancy
            // and testDecodeV03StreamEventIgnoresFinalField above.
            TaskStatusUpdateEvent event = check v1Shape.cloneWithType(TaskStatusUpdateEvent);
            return {statusUpdate: event};
        }
        "artifact-update" => {
            Artifact artifact = check parseV03Artifact(m["artifact"]);
            map<json> v1Shape = {
                taskId: check m["taskId"].ensureType(),
                contextId: check m["contextId"].ensureType(),
                artifact: artifact.toJson()
            };
            if m.hasKey("append") {
                v1Shape["append"] = m["append"];
            }
            if m.hasKey("lastChunk") {
                v1Shape["lastChunk"] = m["lastChunk"];
            }
            if m.hasKey("metadata") {
                v1Shape["metadata"] = m["metadata"];
            }
            TaskArtifactUpdateEvent event = check v1Shape.cloneWithType(TaskArtifactUpdateEvent);
            return {artifactUpdate: event};
        }
        _ => {
            return error(string `Unrecognized v0.3 stream event kind: ${kind}`);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testDecodeV03SendResultTask,testDecodeV03SendResultMessage,testDecodeV03SendResultRejectsUnrecognizedKind,testDecodeV03StreamEventStatusUpdate,testDecodeV03StreamEventArtifactUpdate,testDecodeV03StreamEventIgnoresFinalField`
Expected: PASS

- [ ] **Step 5: Run the full unit test file to confirm nothing else broke**

Run: `bal test --tests-file a2a/tests/compat_v03_test.bal` — if that flag isn't available in this Ballerina version, just run `bal test` (full suite) instead.
Expected: all new `compat_v03_test.bal` tests pass alongside the existing suite.

- [ ] **Step 6: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add decodeV03SendResult and decodeV03StreamEvent"
```

---

## Task 7: `Client.init` gains `agentCard`, `rpcCall`/`buildHeaders` translate for v0.3

**Files:**
- Modify: `a2a/client.bal:54-128` (the `Client` class through `rpcCall`)
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `ProtocolMode`, `detectProtocolMode`, `v03MethodName` (Tasks 2-3).
- Produces: `Client.init`'s new `AgentCard? agentCard = ()` parameter; `Client`'s private `mode` field, consumed by Task 8 and Task 9.

- [ ] **Step 1: Write the failing test**

Add to `a2a/tests/client_test.bal`, near `testTenantPropagatesOnEveryMethod`:

```ballerina
# Confirms method-name translation actually happens on the wire, not just
# that decoding tolerates it — asserts what the mock server actually
# received via getLastRequestBody(), the same pattern
# testTenantPropagatesOnEveryMethod already uses.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03ModeTranslatesSendMessageMethodName() returns error? {
    // sendMessage's own response decoding doesn't branch on mode until
    // Task 8 — this test only proves the wire method name is translated,
    // so it deliberately scripts the ordinary v1.0-wrapped mock response
    // (which the client's current, still-unconditional
    // SendMessageResult.cloneWithType happily accepts regardless of what
    // method name was actually sent). Task 8 adds the response-shape
    // coverage for the v0.3 unwrapped case separately.
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    Client c = check new (getServerBaseUrl(), agentCard = legacyCard);

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "message/send");
}

@test:Config {}
function testV1ModeStillSendsPascalCaseMethodNameByDefault() returns error? {
    // No agentCard passed at all — confirms omitting the new parameter
    // preserves today's exact v1.0-only behavior.
    Client c = check new (getServerBaseUrl());

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "SendMessage");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testV03ModeTranslatesSendMessageMethodName`
Expected: FAIL — compile error, `Client.init` has no `agentCard` named parameter yet.

- [ ] **Step 3: Modify `Client`**

In `a2a/client.bal`, inside `public isolated client class Client { ... }`:

1. Add the field, alongside the existing `private final` fields:

```ballerina
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    private final ProtocolMode mode;
```

2. Update `init`'s signature and body:

```ballerina
    # + serviceUrl - Base URL of the remote agent's A2A endpoint
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling.
    # + headers - Default headers merged into every outbound request. Use
    #             for API key schemes requiring a custom header name.
    #             Bearer and OAuth2 auth belong in clientConfig.auth.
    # + tenant - Optional multi-tenant routing identifier. When the selected
    #            AgentInterface in the Agent Card declares a tenant value,
    #            that value must be supplied here so it is sent with every
    #            operation. Leave unset for single-tenant agents.
    # + agentCard - The card previously fetched via resolveAgentCard, if
    #               any. When given, its declared protocol version is used
    #               to auto-detect whether to speak v1.0 or v0.3 wire
    #               format to this server. Omitting it (the default)
    #               preserves today's v1.0-only behavior exactly.
    # + return - error if the underlying http:Client cannot be created
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            AgentCard? agentCard = ()) returns error? {
        self.httpClient = check new (serviceUrl, clientConfig);
        self.defaultHeaders = headers.cloneReadOnly();
        self.tenant = tenant;
        self.mode = agentCard is AgentCard ? detectProtocolMode(agentCard) : "V1_0";
    }
```

3. Update `buildHeaders`:

```ballerina
    # Builds the header map for an outbound request. The A2A-Version header
    # is mandatory on every request per specification section 3.6.1; an
    # agent receiving an empty value assumes protocol version 0.3, which
    # would silently downgrade the interaction. Sends "0.3" instead of
    # "1.0" when this Client was constructed for a v0.3 server, per the
    # spec's per-interface header-negotiation guidance.
    #
    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "Content-Type": "application/json",
            "A2A-Version": self.mode == "V0_3" ? "0.3" : "1.0"
        };
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        return headers;
    }
```

4. Update `rpcCall` to translate the method name:

```ballerina
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        string wireMethod = self.mode == "V0_3" ? v03MethodName(method) : method;
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: wireMethod,
            params: params
        };
        http:Response resp = check self.httpClient->post(
            "", req.toJson(), self.buildHeaders()
        );
        json body = check resp.getJsonPayload();
        transport:JsonRpcResponse rpcResp =
            check body.cloneWithType(transport:JsonRpcResponse);
        transport:JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is transport:JsonRpcError {
            return toA2AError(rpcErr);
        }
        json? result = rpcResp?.result;
        if result is () {
            return error InvalidAgentResponseError(
                "JSON-RPC response contained neither result nor error"
            );
        }
        return result;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testV03ModeTranslatesSendMessageMethodName,testV1ModeStillSendsPascalCaseMethodNameByDefault`
Expected: PASS — both tests use the ordinary v1.0-wrapped mock response (`sendMessage`'s decoding is still unconditional at this point in the plan; Task 8 is what makes it mode-aware), so only the outbound method name differs between them.

- [ ] **Step 5: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: Client auto-detects protocol mode, translates v0.3 method names"
```

---

## Task 8: `sendMessage`, `getTask`, `cancelTask` decode v0.3 responses

**Files:**
- Modify: `a2a/client.bal` (`sendMessage:146-187`, `getTask:276-290`, `cancelTask:301-315`)
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `decodeV03SendResult`, `parseV03Task` (Tasks 5-6); `self.mode` (Task 7).
- Produces: none new — this closes out the unary-call half of the feature.

- [ ] **Step 1: Write the failing tests**

Add to `a2a/tests/client_test.bal`:

```ballerina
isolated function v03Client() returns Client|error {
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    return new (getServerBaseUrl(), agentCard = legacyCard);
}

@test:Config {}
function testV03SendMessageDecodesUnwrappedTaskResponse() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            id: "task-1", kind: "task",
            status: {state: "completed"},
            artifacts: [{artifactId: "art-1", parts: [{kind: "text", text: "100 USD is equal to 87.80 EUR."}]}]
        }
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert 100 USD to EUR"}]};
    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Task, "an unwrapped kind:task v0.3 result should decode as a Task");
    Task task = <Task>result;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(extractArtifactText(task.artifacts[0]), "100 USD is equal to 87.80 EUR.");
}

@test:Config {}
function testV03SendMessageDecodesUnwrappedMessageResponse() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            messageId: "reply-1", kind: "message", role: "agent",
            parts: [{kind: "text", text: "Sure, what currency?"}]
        }
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert some money"}]};
    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Message, "an unwrapped kind:message v0.3 result should decode as a Message");
    test:assertEquals((<Message>result).role, ROLE_AGENT);
}

@test:Config {}
function testV03GetTaskDecodesUnwrappedTask() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });

    Task task = check c->getTask("task-1");

    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testV03CancelTaskDecodesUnwrappedTask() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "canceled"}}
    });

    Task task = check c->cancelTask("task-1");

    test:assertEquals(task.status.state, TASK_STATE_CANCELED);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testV03SendMessageDecodesUnwrappedTaskResponse`
Expected: FAIL — `sendMessage`'s unconditional `SendMessageResult.cloneWithType` rejects the unwrapped v0.3 shape.

- [ ] **Step 3: Modify `client.bal`**

In `sendMessage`, replace the block starting at `json result = check self.rpcCall("SendMessage", params);` through the end of the function:

```ballerina
        json result = check self.rpcCall("SendMessage", params);

        if self.mode == "V0_3" {
            return check decodeV03SendResult(result);
        }

        // The wire response wraps the payload — {"task": {...}} or
        // {"message": {...}} — rather than returning either one flat.
        SendMessageResult wrapped = check result.cloneWithType(SendMessageResult);
        Task? maybeTask = wrapped?.task;
        Message? maybeMessage = wrapped?.message;

        // A conforming server can't produce this — task/message form a real
        // protobuf oneof upstream, which makes both being set structurally
        // impossible in a well-formed response. But SendMessageResult is a
        // plain open record on our side, not an actual oneof, so nothing
        // stops a non-conforming server from sending both. Rather than
        // silently preferring one, treat it as the malformed response it is.
        if maybeTask is Task && maybeMessage is Message {
            return error InvalidAgentResponseError(
                "Response contained both a task and a message"
            );
        }
        if maybeTask is Task {
            return maybeTask;
        }
        if maybeMessage is Message {
            return maybeMessage;
        }
        return error InvalidAgentResponseError(
            "Response contained neither a task nor a message"
        );
    }
```

In `getTask`, replace `return check result.cloneWithType(Task);` with:

```ballerina
        return self.mode == "V0_3" ? check parseV03Task(result) : check result.cloneWithType(Task);
```

Do the same in `cancelTask`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testV03SendMessageDecodesUnwrappedTaskResponse,testV03SendMessageDecodesUnwrappedMessageResponse,testV03GetTaskDecodesUnwrappedTask,testV03CancelTaskDecodesUnwrappedTask`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bal test` (from `a2a-ballerina/a2a`)
Expected: all tests pass, including every test added in Task 7.

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: sendMessage/getTask/cancelTask decode v0.3 responses"
```

---

## Task 9: Streaming — `openSseStream`, `sse.bal`, and the `final`-field regression test

**Files:**
- Modify: `a2a/client.bal` (`openSseStream:195-233`, `sendMessageStream:249-262`, `subscribeToTask:331-340`)
- Modify: `a2a/sse.bal`
- Test: Modify `a2a/tests/client_test.bal`, `a2a/tests/sse_test.bal`

**Interfaces:**
- Consumes: `decodeV03StreamEvent` (Task 6); `self.mode` (Task 7); `isolated function v03Client() returns Client|error` (Task 8, in `a2a/tests/client_test.bal`).
- Produces: `readSseStream(http:Response resp, ProtocolMode mode = "V1_0")`, `A2AStreamGenerator.init`'s new `mode` parameter — both default to `"V1_0"` so `testReadSseStreamOverRealHttpResponse` and every `newGenerator(...)` call in `sse_test.bal` keep compiling unchanged.

- [ ] **Step 1: Write the failing tests**

In `a2a/tests/sse_test.bal`, update the `newGenerator` helper to accept an optional mode (default preserves every existing call site):

```ballerina
isolated function newGenerator((http:SseEvent|error)[] events, ProtocolMode mode = "V1_0") returns A2AStreamGenerator {
    stream<http:SseEvent, error?> sseStream = new (new TestSseSource(events));
    return new A2AStreamGenerator(sseStream, mode);
}
```

Then append new tests:

```ballerina
@test:Config {}
function testA2AStreamGeneratorDecodesV03StatusUpdate() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ], "V0_3");

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? third = generator.next();
    test:assertTrue(third is (), "stream should close after the v0.3 terminal status, same as v1.0");
}

# Confirms end-to-end (not just decodeV03StreamEvent in isolation) that
# final:true on a non-terminal v0.3 state does not close the stream —
# terminal-ness must come only from the translated TaskState.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testA2AStreamGeneratorIgnoresV03FinalFieldOnNonTerminalState() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"},"final":true}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ], "V0_3");

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    // If final:true had closed the stream despite the non-terminal state,
    // this would return () instead of the second event.
    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED);
}
```

Add to `a2a/tests/client_test.bal`:

```ballerina
@test:Config {}
function testV03SendMessageStreamDecodesStatusAndArtifactUpdates() returns error? {
    Client c = check v03Client();
    setNextSseResponse([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"artifact-update","taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"kind":"text","text":"100 USD is equal to 87.80 EUR."}]}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ]);

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert 100 USD to EUR"}]};
    stream<StreamResponse, error?> events = check c->sendMessageStream(msg);

    StreamResponse first = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(events.next());
    test:assertEquals(extractArtifactText((<TaskArtifactUpdateEvent>second?.artifactUpdate).artifact), "100 USD is equal to 87.80 EUR.");

    StreamResponse third = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>third?.statusUpdate).status.state, TASK_STATE_COMPLETED);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testA2AStreamGeneratorDecodesV03StatusUpdate`
Expected: FAIL — compile error, `A2AStreamGenerator.init`/`readSseStream` don't accept a `mode` parameter yet.

- [ ] **Step 3: Modify `sse.bal`**

```ballerina
# + resp - the HTTP response opened with `Accept: text/event-stream`
# + mode - which wire dialect to decode events as; defaults to V1_0,
#          preserving every existing caller's behavior unchanged
# + return - a stream of decoded StreamResponse values
isolated function readSseStream(http:Response resp, ProtocolMode mode = "V1_0")
        returns stream<StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream, mode);
    stream<StreamResponse, error?> result = new (generator);
    return result;
}

# Iterates a raw SSE event stream, decoding each event's JSON-RPC envelope
# into a StreamResponse. Stops once a terminal task status is reached; per
# design §8.1, a TaskArtifactUpdateEvent never closes the stream, and
# interrupted states (INPUT_REQUIRED, AUTH_REQUIRED) also do not close it.
class A2AStreamGenerator {
    private stream<http:SseEvent, error?> sseStream;
    private boolean closed = false;
    private ProtocolMode mode;

    isolated function init(stream<http:SseEvent, error?> sseStream, ProtocolMode mode = "V1_0") {
        self.sseStream = sseStream;
        self.mode = mode;
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
                // Comment / keep-alive frame — no payload, pull the next one
                continue;
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

`isTerminalEvent` (below the class, unchanged from today) needs no modification — it runs after `decodeEvent` has already translated a v0.3 event into a v1.0-shaped `StreamResponse`, so it always sees a v1.0 `TaskState` regardless of which dialect produced the event:

```ballerina
isolated function isTerminalEvent(StreamResponse event) returns boolean {
    TaskStatusUpdateEvent? statusUpdate = event?.statusUpdate;
    if statusUpdate is () {
        return false;
    }
    TaskState state = statusUpdate.status.state;
    return state == TASK_STATE_COMPLETED
        || state == TASK_STATE_FAILED
        || state == TASK_STATE_CANCELED
        || state == TASK_STATE_REJECTED;
}
```

- [ ] **Step 4: Modify `client.bal`**

In `openSseStream`, translate the method name and thread `self.mode` through to `readSseStream`:

```ballerina
    private isolated function openSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        string wireMethod = self.mode == "V0_3" ? v03MethodName(method) : method;
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: wireMethod,
            params: params
        };
        map<string> headers = self.buildHeaders();
        headers["Accept"] = "text/event-stream";
        http:Response resp = check self.httpClient->post(
            "", req.toJson(), headers
        );
        if resp.statusCode != 200 {
            return error A2AInternalError(
                string `Stream request failed with HTTP ${resp.statusCode}`,
                code = resp.statusCode
            );
        }

        if !resp.getContentType().startsWith("text/event-stream") {
            json body = check resp.getJsonPayload();
            transport:JsonRpcResponse rpcResp =
                check body.cloneWithType(transport:JsonRpcResponse);
            transport:JsonRpcError? rpcErr = rpcResp?.'error;
            if rpcErr is transport:JsonRpcError {
                return toA2AError(rpcErr);
            }
            return error InvalidAgentResponseError(
                "Stream request returned a non-streaming response with neither a JSON-RPC error nor an SSE stream"
            );
        }

        return readSseStream(resp, self.mode);
    }
```

`sendMessageStream` and `subscribeToTask` call `self.openSseStream(...)` already and need no changes themselves — the mode threading happens entirely inside `openSseStream`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bal test --tests testA2AStreamGeneratorDecodesV03StatusUpdate,testA2AStreamGeneratorIgnoresV03FinalFieldOnNonTerminalState,testV03SendMessageStreamDecodesStatusAndArtifactUpdates`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `bal test` (from `a2a-ballerina/a2a`)
Expected: all tests pass — this is the full feature's unit-level completion gate.

- [ ] **Step 7: Commit**

```bash
git add a2a/client.bal a2a/sse.bal a2a/tests/client_test.bal a2a/tests/sse_test.bal
git commit -m "feat: sendMessageStream/subscribeToTask decode v0.3 SSE events"
```

---

## Task 10: Real interop test against `adk_currency_agent`

**Files (in the separate `a2a-interop-tests` repo, not `a2a-ballerina`):**
- Modify: `tests/Ballerina.toml` (bump the `ballerina/a2a` local dependency after re-packing)
- Create: `tests/currency_agent_interop_test.bal`
- Modify: `servers/adk_currency_agent/findings.md` (already exists — add a note once this is confirmed)

**Interfaces:**
- Consumes: the full `feature/a2a-v03-compat` branch of `ballerina/a2a`, packed and pushed to the local Ballerina repository.

This task proves the compat layer works against the real agent, not just mocks — the actual point of building it.

- [ ] **Step 1: Re-pack and push `ballerina/a2a`**

From `a2a-ballerina/a2a` (on `feature/a2a-v03-compat`, after Task 9 is committed):

```bash
bal pack
bal push --repository=local
```

Expected: `Successfully pushed target\bala\ballerina-a2a-any-0.1.0.bala to 'local' repository.`

- [ ] **Step 2: Write the interop test**

Create `tests/currency_agent_interop_test.bal` in `a2a-interop-tests`:

```ballerina
// Real interop tests against the adk_currency_agent reference server —
// see servers/adk_currency_agent/setup.md to start it, and findings.md
// for why this needs v0.3 client support at all. Same no-op-unless-
// configured pattern as interop_test.bal: set
// A2A_CURRENCY_AGENT_URL=http://localhost:10999 to run for real.

import ballerina/a2a;
import ballerina/io;
import ballerina/os;
import ballerina/test;

isolated function isCurrencyAgentConfigured() returns boolean {
    return os:getEnv("A2A_CURRENCY_AGENT_URL") != "";
}

isolated function logCurrencyAgentSkip(string testName) {
    io:println(string `SKIPPED (A2A_CURRENCY_AGENT_URL not set): ${testName}`);
}

@test:Config {groups: ["interop"]}
function testCurrencyAgentSendMessage() returns error? {
    if !isCurrencyAgentConfigured() {
        logCurrencyAgentSkip("testCurrencyAgentSendMessage");
        return;
    }

    string baseUrl = os:getEnv("A2A_CURRENCY_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, agentCard = card);

    a2a:Message msg = {
        messageId: "currency-interop-send-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Convert 100 USD to EUR"}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the currency agent replies with a Task");
    a2a:Task task = <a2a:Task>result;
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
}

@test:Config {groups: ["interop"]}
function testCurrencyAgentSendMessageStream() returns error? {
    if !isCurrencyAgentConfigured() {
        logCurrencyAgentSkip("testCurrencyAgentSendMessageStream");
        return;
    }

    string baseUrl = os:getEnv("A2A_CURRENCY_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, agentCard = card, {timeout: 30});

    a2a:Message msg = {
        messageId: "currency-interop-stream-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Convert 50 GBP to JPY"}]
    };

    stream<a2a:StreamResponse, error?> events = check c->sendMessageStream(msg);

    boolean sawCompletion = false;
    record {| a2a:StreamResponse value; |}|error? next = events.next();
    while next is record {| a2a:StreamResponse value; |} {
        a2a:TaskStatusUpdateEvent? statusUpdate = next.value?.statusUpdate;
        if statusUpdate is a2a:TaskStatusUpdateEvent && statusUpdate.status.state == a2a:TASK_STATE_COMPLETED {
            sawCompletion = true;
        }
        next = events.next();
    }
    if next is error {
        test:assertFail("stream ended with an error: " + next.message());
    }

    test:assertTrue(sawCompletion, "stream should deliver a COMPLETED status update before closing");
}
```

- [ ] **Step 3: Start the real agent and run the test**

Follow `servers/adk_currency_agent/setup.md` to start it (`GOOGLE_API_KEY` required), then:

```bash
export A2A_CURRENCY_AGENT_URL=http://localhost:10999
bal test --groups interop
```

Expected: `testCurrencyAgentSendMessage` and `testCurrencyAgentSendMessageStream` both pass, alongside the existing `helloworld` interop tests (unaffected — they don't set `A2A_CURRENCY_AGENT_URL`, so they run against `A2A_TEST_SERVER_URL` as before).

- [ ] **Step 4: Update `findings.md`**

Add a short closing section to `servers/adk_currency_agent/findings.md`:

```markdown
## 6. Resolved

`ballerina/a2a`'s Client now auto-detects this agent's v0.3 dialect from
its AgentCard and translates transparently — confirmed via
`tests/currency_agent_interop_test.bal` (`testCurrencyAgentSendMessage`,
`testCurrencyAgentSendMessageStream`), both passing against the real
running agent. See `a2a-ballerina`'s
`a2a/docs/superpowers/specs/2026-07-28-v03-client-compat-design.md` for
the implementation.
```

- [ ] **Step 5: Commit (in `a2a-interop-tests`, on its own branch)**

```bash
git checkout -b feature/currency-agent-v03-interop
git add tests/currency_agent_interop_test.bal servers/adk_currency_agent/findings.md
git commit -m "test: add real interop tests against adk_currency_agent"
git push -u origin feature/currency-agent-v03-interop
gh pr create --title "test: add real interop tests against adk_currency_agent" --body "Confirms ballerina/a2a's new v0.3 client compatibility (a2a-ballerina feature/a2a-v03-compat) against the real running currency agent, not just mocks. Requires that branch's ballerina/a2a to be packed and pushed to the local repository first (see setup.md)."
```

Do not merge — hold for review, same as every other batch. Do not merge `a2a-ballerina`'s `feature/a2a-v03-compat` either; open its own PR at this point, referencing this interop-test confirmation.
