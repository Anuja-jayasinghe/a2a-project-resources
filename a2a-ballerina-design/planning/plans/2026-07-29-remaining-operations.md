# Remaining A2A Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 6 A2A spec operations `ballerina/a2a`'s `Client` is missing: `listTasks`, `createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`, `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig`, `getExtendedAgentCard`.

**Architecture:** Same patterns the existing 5 operations already establish — new remote functions on `Client` in `client.bal`, a small number of new types in `types.bal`, v0.3 wire translation in `compat_v03.bal` for the 5 operations with a known v0.3 equivalent, and a client-side `VersionNotSupportedError` short-circuit for `listTasks` (no v0.3 equivalent exists).

**Tech Stack:** Ballerina (`bal test`, `bal build`), the existing `testutil.bal` mock-server scripting pattern.

## Global Constraints

- Every existing public method signature and returned type is unchanged. This plan is purely additive.
- No new `A2AError` subtypes — `PushNotificationNotSupportedError`, `UnsupportedOperationError`, `ExtendedAgentCardNotConfiguredError`, `VersionNotSupportedError` already exist and cover every error path this plan needs.
- `deleteTaskPushNotificationConfig` returns `error?`, not `error` — success is `()`, matching the spec's empty-response idempotent-delete semantics.
- Full design context lives in `a2a/docs/superpowers/specs/2026-07-29-remaining-operations-design.md` — read it before starting if anything below is unclear on *why*, not just *what*.
- Exact v0.3 wire field names for `TaskPushNotificationConfig`/`ListTaskPushNotificationConfigsResult` are **not independently confirmed** against a real server (documented as a known, deliberate verification gap in the design spec — neither reference agent supports push notifications). The code below is a field-name-preserving best guess, consistent with every other `parseV03*`/`encodeV03*` function in this file. If an implementer finds evidence otherwise (e.g. checking the installed `a2a-sdk`'s `a2a/compat/v0_3/types.py`, the same source that resolved every prior v0.3 field-name question in this project), prefer that evidence and note the correction in the task report.

---

## Task 1: New types — `ListTasksFilter`, `ListTasksResult`, `ListTaskPushNotificationConfigsResult`

**Files:**
- Modify: `a2a/types.bal` (append after `SendMessageConfiguration`, the last type in the file)
- Test: Modify `a2a/tests/types_test.bal`

**Interfaces:**
- Produces: the three new types below, consumed by every later task.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/types_test.bal`:

```ballerina
@test:Config {}
function testListTasksFilterRoundTrip() returns error? {
    ListTasksFilter original = {
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        historyLength: 10,
        statusTimestampAfter: "2026-07-29T00:00:00Z",
        includeArtifacts: true
    };
    ListTasksFilter decoded = check original.toJson().cloneWithType(ListTasksFilter);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTasksFilterToleratesUnrecognizedField() returns error? {
    json payload = {futureField: "some value from a newer spec revision"};

    ListTasksFilter decoded = check payload.cloneWithType(ListTasksFilter);

    test:assertTrue(decoded?.contextId is (), "contextId should be nil, not defaulted");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testListTasksResultRoundTrip() returns error? {
    ListTasksResult original = {
        tasks: [
            {id: "task-1", status: {state: TASK_STATE_COMPLETED}}
        ],
        nextPageToken: "cursor-def",
        pageSize: 20,
        totalSize: 1
    };
    ListTasksResult decoded = check original.toJson().cloneWithType(ListTasksResult);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTaskPushNotificationConfigsResultRoundTrip() returns error? {
    ListTaskPushNotificationConfigsResult original = {
        configs: [
            {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
        ],
        nextPageToken: "cursor-ghi"
    };
    ListTaskPushNotificationConfigsResult decoded = check original.toJson().cloneWithType(ListTaskPushNotificationConfigsResult);

    test:assertEquals(decoded, original);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testListTasksFilterRoundTrip` (from `a2a-ballerina/a2a`)
Expected: FAIL — compile error, the three types don't exist yet.

- [ ] **Step 3: Add the types**

Append to `a2a/types.bal`, after `SendMessageConfiguration`:

```ballerina
# Filter and pagination parameters for a listTasks call.
public type ListTasksFilter record {|
    # Restrict to tasks in this context
    string? contextId?;
    # Restrict to tasks in this lifecycle state
    TaskState? status?;
    # Maximum results per page
    int? pageSize?;
    # Opaque cursor from a previous ListTasksResult.nextPageToken
    string? pageToken?;
    # Same semantics as getTask's historyLength
    int? historyLength?;
    # ISO 8601 — only tasks whose status changed after this timestamp
    string? statusTimestampAfter?;
    # Whether to include each task's artifacts in the response
    boolean? includeArtifacts?;
    json...;
|};

# Paginated result of a listTasks call.
public type ListTasksResult record {|
    Task[] tasks;
    # Opaque cursor for the next page; empty when there are no more results
    string nextPageToken;
    # Echoes the effective page size used
    int pageSize;
    # Total matching tasks across all pages
    int totalSize;
    json...;
|};

# Paginated result of a listTaskPushNotificationConfigs call.
public type ListTaskPushNotificationConfigsResult record {|
    TaskPushNotificationConfig[] configs;
    string nextPageToken;
    json...;
|};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testListTasksFilterRoundTrip,testListTasksFilterToleratesUnrecognizedField,testListTasksResultRoundTrip,testListTaskPushNotificationConfigsResultRoundTrip`
Expected: PASS

- [ ] **Step 5: Run the full suite to confirm nothing else broke**

Run: `bal test` (from `a2a-ballerina/a2a`)
Expected: all tests passing, 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/types.bal a2a/tests/types_test.bal
git commit -m "feat: add ListTasksFilter, ListTasksResult, ListTaskPushNotificationConfigsResult types"
```

---

## Task 2: v0.3 compat functions for `TaskPushNotificationConfig` and its list result

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: `TaskPushNotificationConfig`, `AuthenticationInfo`, `ListTaskPushNotificationConfigsResult` (Task 1 / pre-existing `types.bal`).
- Produces: `parseV03TaskPushNotificationConfig`, `encodeV03TaskPushNotificationConfig`, `parseV03ListTaskPushNotificationConfigsResult` — used by Task 5/6.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testParseV03TaskPushNotificationConfig() returns error? {
    TaskPushNotificationConfig config = check parseV03TaskPushNotificationConfig({
        "url": "https://client.example.com/webhooks/a2a",
        "id": "webhook-1",
        "taskId": "task-1",
        "token": "correlation-token",
        "authentication": {"scheme": "Bearer", "credentials": "eyJhbGciOiJIUzI1NiIs..."},
        "tenant": "acme-corp"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(config?.id, "webhook-1");
    test:assertEquals(config?.taskId, "task-1");
    test:assertEquals(config?.token, "correlation-token");
    AuthenticationInfo? auth = config?.authentication;
    test:assertTrue(auth is AuthenticationInfo, "authentication should be parsed, not dropped");
    test:assertEquals((<AuthenticationInfo>auth).scheme, "Bearer");
    test:assertEquals(config?.tenant, "acme-corp");
}

@test:Config {}
function testParseV03TaskPushNotificationConfigOmitsUnsetOptionalFields() returns error? {
    TaskPushNotificationConfig config = check parseV03TaskPushNotificationConfig({
        "url": "https://client.example.com/webhooks/a2a"
    });

    test:assertTrue(config?.id is (), "id should be nil when absent on the wire");
    test:assertTrue(config?.taskId is (), "taskId should be nil when absent on the wire");
    test:assertTrue(config?.authentication is (), "authentication should be nil when absent on the wire");
}

@test:Config {}
function testEncodeV03TaskPushNotificationConfig() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://client.example.com/webhooks/a2a",
        id: "webhook-1",
        taskId: "task-1",
        token: "correlation-token",
        authentication: {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."},
        tenant: "acme-corp"
    };

    json encoded = encodeV03TaskPushNotificationConfig(original);
    map<json> m = check encoded.ensureType();

    test:assertEquals(m["url"], "https://client.example.com/webhooks/a2a");
    test:assertEquals(m["id"], "webhook-1");
    test:assertEquals(m["taskId"], "task-1");
    test:assertEquals(m["token"], "correlation-token");
    map<json> auth = check m["authentication"].ensureType();
    test:assertEquals(auth["scheme"], "Bearer");
    test:assertEquals(m["tenant"], "acme-corp");
}

@test:Config {}
function testEncodeV03TaskPushNotificationConfigOmitsUnsetOptionalFields() returns error? {
    TaskPushNotificationConfig original = {url: "https://client.example.com/webhooks/a2a"};

    json encoded = encodeV03TaskPushNotificationConfig(original);
    map<json> m = check encoded.ensureType();

    test:assertFalse(m.hasKey("id"), "id should be absent when unset");
    test:assertFalse(m.hasKey("taskId"), "taskId should be absent when unset");
    test:assertFalse(m.hasKey("authentication"), "authentication should be absent when unset");
}

# Round-trip: encoding then parsing a TaskPushNotificationConfig must
# reproduce it exactly, the same guard the Message encode/decode pair
# already has.
#
# + return - an error if any step other than the assertion itself fails
@test:Config {}
function testTaskPushNotificationConfigRoundTripsThroughEncodeAndParse() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://client.example.com/webhooks/a2a",
        id: "webhook-1",
        taskId: "task-1",
        token: "correlation-token",
        authentication: {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."},
        tenant: "acme-corp"
    };

    json encoded = encodeV03TaskPushNotificationConfig(original);
    TaskPushNotificationConfig decoded = check parseV03TaskPushNotificationConfig(encoded);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testParseV03ListTaskPushNotificationConfigsResult() returns error? {
    ListTaskPushNotificationConfigsResult result = check parseV03ListTaskPushNotificationConfigsResult({
        "configs": [
            {"url": "https://client.example.com/webhooks/a2a", "id": "webhook-1"}
        ],
        "nextPageToken": "cursor-ghi"
    });

    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.configs[0].url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(result.nextPageToken, "cursor-ghi");
}

@test:Config {}
function testParseV03ListTaskPushNotificationConfigsResultDefaultsNextPageTokenWhenAbsent() returns error? {
    ListTaskPushNotificationConfigsResult result = check parseV03ListTaskPushNotificationConfigsResult({
        "configs": []
    });

    test:assertEquals(result.configs.length(), 0);
    test:assertEquals(result.nextPageToken, "");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testParseV03TaskPushNotificationConfig`
Expected: FAIL — compile error, functions don't exist.

- [ ] **Step 3: Write the implementation**

Append to `a2a/compat_v03.bal`:

```ballerina
# Converts a v0.3 TaskPushNotificationConfig into the v1.0 shape. Field
# names are assumed identical between versions (no v0.3 payload for this
# type has been observed against a real server — neither reference agent
# tested in this project supports push notifications — so this follows
# the same "field names carry over unless documented otherwise" pattern
# every other parse function in this file already relies on).
#
# + configJson - the raw v0.3 TaskPushNotificationConfig JSON
# + return - the equivalent v1.0 TaskPushNotificationConfig, or an error if malformed
isolated function parseV03TaskPushNotificationConfig(json configJson) returns TaskPushNotificationConfig|error {
    map<json> m = check configJson.ensureType();
    map<json> v1Shape = {
        url: check m["url"].ensureType()
    };
    if m.hasKey("id") {
        v1Shape["id"] = m["id"];
    }
    if m.hasKey("taskId") {
        v1Shape["taskId"] = m["taskId"];
    }
    if m.hasKey("token") {
        v1Shape["token"] = m["token"];
    }
    if m.hasKey("authentication") {
        v1Shape["authentication"] = m["authentication"];
    }
    if m.hasKey("tenant") {
        v1Shape["tenant"] = m["tenant"];
    }
    return check v1Shape.cloneWithType(TaskPushNotificationConfig);
}

# Mirror image of parseV03TaskPushNotificationConfig. Returns map<json>
# rather than the bare json most other encodeV03* functions return,
# because this one is used as the ENTIRE outbound params map (the spec's
# request IS a TaskPushNotificationConfig, no wrapper) rather than
# nested under a key the way encodeV03Message is under "message" —
# callers need an assignable map<json>, not a widened json value.
#
# + config - the outbound TaskPushNotificationConfig, in v1.0 shape
# + return - the equivalent v0.3 TaskPushNotificationConfig JSON
isolated function encodeV03TaskPushNotificationConfig(TaskPushNotificationConfig config) returns map<json> {
    map<json> result = {url: config.url};
    string? id = config?.id;
    string? taskId = config?.taskId;
    string? token = config?.token;
    AuthenticationInfo? authentication = config?.authentication;
    string? tenant = config?.tenant;
    if id is string {
        result["id"] = id;
    }
    if taskId is string {
        result["taskId"] = taskId;
    }
    if token is string {
        result["token"] = token;
    }
    if authentication is AuthenticationInfo {
        result["authentication"] = authentication.toJson();
    }
    if tenant is string {
        result["tenant"] = tenant;
    }
    return result;
}

# + resultJson - the raw v0.3 ListTaskPushNotificationConfigs result JSON
# + return - the equivalent v1.0 ListTaskPushNotificationConfigsResult, or an error if malformed
isolated function parseV03ListTaskPushNotificationConfigsResult(json resultJson) returns ListTaskPushNotificationConfigsResult|error {
    map<json> m = check resultJson.ensureType();
    json[] rawConfigs = check m["configs"].ensureType();
    TaskPushNotificationConfig[] configs = [];
    foreach json c in rawConfigs {
        configs.push(check parseV03TaskPushNotificationConfig(c));
    }
    string nextPageToken = m.hasKey("nextPageToken") ? check m["nextPageToken"].ensureType() : "";
    return {configs, nextPageToken};
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testParseV03TaskPushNotificationConfig,testParseV03TaskPushNotificationConfigOmitsUnsetOptionalFields,testEncodeV03TaskPushNotificationConfig,testEncodeV03TaskPushNotificationConfigOmitsUnsetOptionalFields,testTaskPushNotificationConfigRoundTripsThroughEncodeAndParse,testParseV03ListTaskPushNotificationConfigsResult,testParseV03ListTaskPushNotificationConfigsResultDefaultsNextPageTokenWhenAbsent`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: add v0.3 compat functions for TaskPushNotificationConfig"
```

---

## Task 3: v0.3 method-name table extension

**Files:**
- Modify: `a2a/compat_v03.bal`
- Test: Modify `a2a/tests/compat_v03_test.bal`

**Interfaces:**
- Consumes: none new.
- Produces: `v03MethodName` now also translates the 5 new v1.0 method names — used by Task 4-7's `rpcCall` calls (which already call `v03MethodName` unconditionally in V0_3 mode, per Task 7 of the original v0.3 compat plan — no `client.bal` change needed for this table extension itself).

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/compat_v03_test.bal`:

```ballerina
@test:Config {}
function testV03MethodNameTranslatesRemainingOperations() returns error? {
    test:assertEquals(v03MethodName("CreateTaskPushNotificationConfig"), "tasks/pushNotificationConfig/set");
    test:assertEquals(v03MethodName("GetTaskPushNotificationConfig"), "tasks/pushNotificationConfig/get");
    test:assertEquals(v03MethodName("ListTaskPushNotificationConfigs"), "tasks/pushNotificationConfig/list");
    test:assertEquals(v03MethodName("DeleteTaskPushNotificationConfig"), "tasks/pushNotificationConfig/delete");
    test:assertEquals(v03MethodName("GetExtendedAgentCard"), "agent/getAuthenticatedExtendedCard");
}

# ListTasks has no v0.3 equivalent at all (confirmed "(NEW)" in the v0.3
# to v1.0 migration table) — v03MethodName's fallthrough passes it
# through unchanged rather than mapping it to something invented. This
# doesn't matter in practice since listTasks() short-circuits with a
# client-side error before ever calling rpcCall in V0_3 mode (Task 4),
# but pins down the fallthrough behavior explicitly.
@test:Config {}
function testV03MethodNamePassesThroughListTasksUnchanged() returns error? {
    test:assertEquals(v03MethodName("ListTasks"), "ListTasks");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testV03MethodNameTranslatesRemainingOperations`
Expected: FAIL — the 5 new method names aren't in the `match` yet, so they fall through to the `_ =>` case and return unchanged, not translated.

- [ ] **Step 3: Extend the match statement**

In `a2a/compat_v03.bal`, add 5 new cases to `v03MethodName`'s `match` statement, immediately before the `_ =>` fallthrough case:

```ballerina
        "CreateTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/set";
        }
        "GetTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/get";
        }
        "ListTaskPushNotificationConfigs" => {
            return "tasks/pushNotificationConfig/list";
        }
        "DeleteTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/delete";
        }
        "GetExtendedAgentCard" => {
            return "agent/getAuthenticatedExtendedCard";
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testV03MethodNameTranslatesRemainingOperations,testV03MethodNamePassesThroughListTasksUnchanged`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bal test`
Expected: all tests passing, 0 failing (confirms the pre-existing 5 method-name tests from the original v0.3 work are untouched).

- [ ] **Step 6: Commit**

```bash
git add a2a/compat_v03.bal a2a/tests/compat_v03_test.bal
git commit -m "feat: extend v03MethodName for the 5 remaining v0.3-mapped operations"
```

---

## Task 4: `listTasks`

**Files:**
- Modify: `a2a/client.bal` (add a new remote function, after `subscribeToTask` — the last method in the `Client` class)
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `ListTasksFilter`, `ListTasksResult` (Task 1); `self.mode`, `self.rpcCall`, `self.tenant` (pre-existing `Client` internals).
- Produces: `Client.listTasks(...)`.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/client_test.bal`:

```ballerina
@test:Config {}
function testListTasksHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            tasks: [{id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}],
            nextPageToken: "cursor-abc",
            pageSize: 20,
            totalSize: 1
        }
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult result = check c->listTasks();

    test:assertEquals(result.tasks.length(), 1);
    test:assertEquals(result.tasks[0].id, "task-1");
    test:assertEquals(result.nextPageToken, "cursor-abc");
    test:assertEquals(result.totalSize, 1);
}

# Confirms filter fields actually reach the wire — checks the mock's
# received request body, the same pattern testTenantPropagatesOnEveryMethod
# already uses via getLastRequestBody().
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testListTasksSendsFilterFieldsOnWire() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0}
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult _ = check c->listTasks({
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        includeArtifacts: true
    });

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.contextId, "ctx-1");
    test:assertEquals(check params.status, "TASK_STATE_COMPLETED");
    test:assertEquals(check params.pageSize, 20);
    test:assertEquals(check params.pageToken, "cursor-abc");
    test:assertEquals(check params.includeArtifacts, true);
}

@test:Config {}
function testListTasksOmitsUnsetFilterFields() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0}
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult _ = check c->listTasks();

    json params = check getLastRequestBody().params;
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("contextId"), "contextId should be absent when no filter is passed");
    test:assertFalse(paramsMap.hasKey("pageSize"), "pageSize should be absent when no filter is passed");
}

# ListTasks has no v0.3 equivalent (confirmed "(NEW)" in the migration
# table) — a V0_3-mode Client must fail client-side with
# VersionNotSupportedError before making any network call, per §3.6.3's
# principle against silent automatic fallback.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testListTasksErrorsImmediatelyInV03Mode() returns error? {
    Client c = check v03Client();

    ListTasksResult|error result = c->listTasks();

    test:assertTrue(result is error, "listTasks should fail in V0_3 mode, not attempt a network call");
    test:assertTrue(result is VersionNotSupportedError, "should map specifically to VersionNotSupportedError, not a generic error");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testListTasksHappyPath`
Expected: FAIL — compile error, `listTasks` doesn't exist on `Client` yet.

- [ ] **Step 3: Add the method**

In `a2a/client.bal`, inside the `Client` class, after `subscribeToTask` (the last method):

```ballerina
    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # Has no equivalent in A2A protocol v0.3 (confirmed new in v1.0) — a
    # Client detected as V0_3 fails immediately with
    # VersionNotSupportedError rather than sending a request the server
    # can't possibly understand.
    #
    # + filter - Optional filter/pagination parameters
    # + tenant - Optional per-call tenant override
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error {
        if self.mode == "V0_3" {
            return error VersionNotSupportedError(
                "ListTasks has no equivalent in A2A protocol v0.3",
                message = "ListTasks has no equivalent in A2A protocol v0.3"
            );
        }

        map<json> params = {};
        if filter is ListTasksFilter {
            string? contextId = filter?.contextId;
            TaskState? status = filter?.status;
            int? pageSize = filter?.pageSize;
            string? pageToken = filter?.pageToken;
            int? historyLength = filter?.historyLength;
            string? statusTimestampAfter = filter?.statusTimestampAfter;
            boolean? includeArtifacts = filter?.includeArtifacts;
            if contextId is string {
                params["contextId"] = contextId;
            }
            if status is TaskState {
                params["status"] = status;
            }
            if pageSize is int {
                params["pageSize"] = pageSize;
            }
            if pageToken is string {
                params["pageToken"] = pageToken;
            }
            if historyLength is int {
                params["historyLength"] = historyLength;
            }
            if statusTimestampAfter is string {
                params["statusTimestampAfter"] = statusTimestampAfter;
            }
            if includeArtifacts is boolean {
                params["includeArtifacts"] = includeArtifacts;
            }
        }
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("ListTasks", params);
        return check result.cloneWithType(ListTasksResult);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testListTasksHappyPath,testListTasksSendsFilterFieldsOnWire,testListTasksOmitsUnsetFilterFields,testListTasksErrorsImmediatelyInV03Mode`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bal test`
Expected: all tests passing, 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: add Client.listTasks"
```

---

## Task 5: `createTaskPushNotificationConfig` and `getTaskPushNotificationConfig`

**Files:**
- Modify: `a2a/client.bal`
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `parseV03TaskPushNotificationConfig`, `encodeV03TaskPushNotificationConfig` (Task 2); the extended `v03MethodName` (Task 3).
- Produces: `Client.createTaskPushNotificationConfig(...)`, `Client.getTaskPushNotificationConfig(...)`.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/client_test.bal`:

```ballerina
@test:Config {}
function testCreateTaskPushNotificationConfigHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(config?.id, "webhook-1");
}

@test:Config {}
function testGetTaskPushNotificationConfigHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->getTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
    test:assertEquals(check params.id, "webhook-1");
}

@test:Config {}
function testCreateTaskPushNotificationConfigNotSupportedErrorMapping() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        'error: {code: -32003, message: "Push notifications not supported"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig|error result = c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertTrue(result is PushNotificationNotSupportedError, "code -32003 should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testV03CreateTaskPushNotificationConfigTranslatesMethodAndBody() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/set");
}

@test:Config {}
function testV03GetTaskPushNotificationConfigTranslatesMethod() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    TaskPushNotificationConfig config = check c->getTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/get");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testCreateTaskPushNotificationConfigHappyPath`
Expected: FAIL — compile error, the methods don't exist yet.

- [ ] **Step 3: Add the methods**

In `a2a/client.bal`, inside the `Client` class, after `listTasks` (Task 4):

```ballerina
    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or an error
    #            (PushNotificationNotSupportedError if capabilities.pushNotifications is false)
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = self.mode == "V0_3"
            ? encodeV03TaskPushNotificationConfig(config)
            : check config.toJson().ensureType();
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("CreateTaskPushNotificationConfig", params);
        return self.mode == "V0_3"
            ? check parseV03TaskPushNotificationConfig(result)
            : check result.cloneWithType(TaskPushNotificationConfig);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = {taskId, id};
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("GetTaskPushNotificationConfig", params);
        return self.mode == "V0_3"
            ? check parseV03TaskPushNotificationConfig(result)
            : check result.cloneWithType(TaskPushNotificationConfig);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testCreateTaskPushNotificationConfigHappyPath,testGetTaskPushNotificationConfigHappyPath,testCreateTaskPushNotificationConfigNotSupportedErrorMapping,testV03CreateTaskPushNotificationConfigTranslatesMethodAndBody,testV03GetTaskPushNotificationConfigTranslatesMethod`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bal test`
Expected: all tests passing, 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: add Client.createTaskPushNotificationConfig and getTaskPushNotificationConfig"
```

---

## Task 6: `listTaskPushNotificationConfigs` and `deleteTaskPushNotificationConfig`

**Files:**
- Modify: `a2a/client.bal`
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `parseV03ListTaskPushNotificationConfigsResult` (Task 2); `ListTaskPushNotificationConfigsResult` (Task 1).
- Produces: `Client.listTaskPushNotificationConfigs(...)`, `Client.deleteTaskPushNotificationConfig(...)`.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/client_test.bal`:

```ballerina
@test:Config {}
function testListTaskPushNotificationConfigsHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
            nextPageToken: "cursor-abc"
        }
    });

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResult result = check c->listTaskPushNotificationConfigs("task-1");

    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.configs[0].url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(result.nextPageToken, "cursor-abc");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
}

@test:Config {}
function testListTaskPushNotificationConfigsSendsPaginationFieldsWhenSet() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {configs: [], nextPageToken: ""}
    });

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResult _ = check c->listTaskPushNotificationConfigs("task-1", pageSize = 10, pageToken = "cursor-abc");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.pageSize, 10);
    test:assertEquals(check params.pageToken, "cursor-abc");
}

@test:Config {}
function testDeleteTaskPushNotificationConfigHappyPathReturnsNil() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {}
    });

    Client c = check new (getServerBaseUrl());
    error? result = c->deleteTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertTrue(result is (), "a successful delete should return nil, not an error");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
    test:assertEquals(check params.id, "webhook-1");
}

@test:Config {}
function testV03ListTaskPushNotificationConfigsTranslatesMethodAndDecodesUnwrappedResult() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
            nextPageToken: "cursor-abc"
        }
    });

    ListTaskPushNotificationConfigsResult result = check c->listTaskPushNotificationConfigs("task-1");

    test:assertEquals(result.configs.length(), 1);
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/list");
}

@test:Config {}
function testV03DeleteTaskPushNotificationConfigTranslatesMethod() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {}
    });

    error? result = c->deleteTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertTrue(result is (), "a successful delete should return nil in v0.3 mode too");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/delete");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testListTaskPushNotificationConfigsHappyPath`
Expected: FAIL — compile error, the methods don't exist yet.

- [ ] **Step 3: Add the methods**

In `a2a/client.bal`, inside the `Client` class, after `getTaskPushNotificationConfig` (Task 5):

```ballerina
    # Lists all push-notification webhook configs registered for a task.
    #
    # + taskId - The task to list configs for
    # + pageSize - Maximum results per page
    # + pageToken - Opaque cursor from a previous result's nextPageToken
    # + tenant - Optional per-call tenant override
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        map<json> params = {taskId};
        if pageSize is int {
            params["pageSize"] = pageSize;
        }
        if pageToken is string {
            params["pageToken"] = pageToken;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("ListTaskPushNotificationConfigs", params);
        return self.mode == "V0_3"
            ? check parseV03ListTaskPushNotificationConfigsResult(result)
            : check result.cloneWithType(ListTaskPushNotificationConfigsResult);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10 — deleting an already-deleted or
    # nonexistent config is not an error.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier
    # + tenant - Optional per-call tenant override
    # + return - nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        map<json> params = {taskId, id};
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json _ = check self.rpcCall("DeleteTaskPushNotificationConfig", params);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testListTaskPushNotificationConfigsHappyPath,testListTaskPushNotificationConfigsSendsPaginationFieldsWhenSet,testDeleteTaskPushNotificationConfigHappyPathReturnsNil,testV03ListTaskPushNotificationConfigsTranslatesMethodAndDecodesUnwrappedResult,testV03DeleteTaskPushNotificationConfigTranslatesMethod`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bal test`
Expected: all tests passing, 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: add Client.listTaskPushNotificationConfigs and deleteTaskPushNotificationConfig"
```

---

## Task 7: `getExtendedAgentCard`

**Files:**
- Modify: `a2a/client.bal`
- Test: Modify `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `AgentCard` (pre-existing `types.bal` — no new parse function needed; `AgentCard.cloneWithType` already handles both protocol versions' shapes since they differ only in which optional fields are populated, not enum values or wrapping, per how `resolveAgentCard` already works).
- Produces: `Client.getExtendedAgentCard(...)`.

- [ ] **Step 1: Write the failing tests**

Append to `a2a/tests/client_test.bal`:

```ballerina
@test:Config {}
function testGetExtendedAgentCardHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            name: "Mock Weather Agent (extended)",
            description: "A scripted mock agent used by Client tests",
            version: "1.0.0",
            capabilities: {extendedAgentCard: true},
            skills: [{id: "weather-lookup", name: "Weather Lookup", description: "Reports current weather for a city"}]
        }
    });

    Client c = check new (getServerBaseUrl());
    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Mock Weather Agent (extended)");
}

@test:Config {}
function testGetExtendedAgentCardNotConfiguredErrorMapping() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        'error: {code: -32007, message: "Extended agent card not configured"}
    });

    Client c = check new (getServerBaseUrl());
    AgentCard|error result = c->getExtendedAgentCard();

    test:assertTrue(result is ExtendedAgentCardNotConfiguredError, "code -32007 should map to ExtendedAgentCardNotConfiguredError");
}

@test:Config {}
function testV03GetExtendedAgentCardTranslatesMethodName() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            name: "Legacy Agent (extended)",
            description: "x",
            version: "1.0.0",
            capabilities: {extendedAgentCard: true},
            skills: []
        }
    });

    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Legacy Agent (extended)");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "agent/getAuthenticatedExtendedCard");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bal test --tests testGetExtendedAgentCardHappyPath`
Expected: FAIL — compile error, the method doesn't exist yet.

- [ ] **Step 3: Add the method**

In `a2a/client.bal`, inside the `Client` class, after `deleteTaskPushNotificationConfig` (Task 6) — this is now the last method in the class:

```ballerina
    # Retrieves the agent's extended AgentCard, available after client
    # authentication (via the same http:ClientConfiguration.auth every
    # other operation already uses — no separate auth wiring needed).
    #
    # Requires capabilities.extendedAgentCard to be true; otherwise the
    # agent returns UnsupportedOperationError, or
    # ExtendedAgentCardNotConfiguredError if the capability is on but no
    # extended card is actually configured.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        map<json> params = {};
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("GetExtendedAgentCard", params);
        return check result.cloneWithType(AgentCard);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bal test --tests testGetExtendedAgentCardHappyPath,testGetExtendedAgentCardNotConfiguredErrorMapping,testV03GetExtendedAgentCardTranslatesMethodName`
Expected: PASS

- [ ] **Step 5: Run the full suite — this is the full feature's unit-level completion gate**

Run: `bal test` (from `a2a-ballerina/a2a`)
Expected: all tests passing, 0 failing.

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/tests/client_test.bal
git commit -m "feat: add Client.getExtendedAgentCard"
```

---

## Task 8: Real interop test for `getExtendedAgentCard` against `helloworld`

**Files (in the separate `a2a-interop-tests` repo, not `a2a-ballerina`):**
- Modify: `tests/interop_test.bal` (add one new test to the existing file — this operation belongs with the other `helloworld` interop tests, not a new file)
- Modify: `servers/helloworld/findings.md` (record the result either way)

**Interfaces:**
- Consumes: the full `feature/a2a-remaining-operations` branch of `ballerina/a2a`, packed and pushed to the local Ballerina package repository.

This task determines, empirically, whether `helloworld`'s previously-observed `capabilities.extendedAgentCard: true` means `getExtendedAgentCard` is genuinely supported — the only one of these 6 new operations with a real reference agent to test against.

- [ ] **Step 1: Re-pack and push `ballerina/a2a`**

From `a2a-ballerina/a2a` (on `feature/a2a-remaining-operations`, after Task 7 is committed):

```bash
bal pack
bal push --repository=local
```

Expected: `Successfully pushed target\bala\ballerina-a2a-any-0.1.0.bala to 'local' repository.`

- [ ] **Step 2: Write the test**

Add to `tests/interop_test.bal` in `a2a-interop-tests` (follow the file's existing pattern exactly — it already has `isRealServerConfigured()`/`logSkip()` helpers and a `groups: ["interop"]` tag on every test in this file):

```ballerina
# Determines empirically whether helloworld's capabilities.extendedAgentCard
# flag (observed true in earlier interop work) means getExtendedAgentCard
# is genuinely implemented, or just declared. See findings.md for the
# result either way — this is exploratory verification, not a test with a
# single predetermined correct outcome.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testInteropGetExtendedAgentCard() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropGetExtendedAgentCard");
        return;
    }

    Client c = check new (getServerBaseUrl());

    AgentCard|error result = c->getExtendedAgentCard();

    if result is error {
        io:println("  [getExtendedAgentCard] not supported by this server: ", result.message());
        return;
    }

    AgentCard card = result;
    io:println("  [getExtendedAgentCard] supported — name: ", card.name);
    test:assertTrue(card.name.length() > 0, "an extended card, if returned, should at least have a name");
}
```

- [ ] **Step 3: Start `helloworld` and run the test**

Follow `servers/helloworld/setup.md` to start it, then:

```bash
A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --groups interop
```

Expected: the test passes either way (it's written to tolerate either outcome and report which one occurred via `io:println`) — read the console output to see whether `helloworld` actually supports the operation or returned an error.

- [ ] **Step 4: Update `findings.md` with whichever result actually occurred**

Add a section to `servers/helloworld/findings.md` reporting the actual observed outcome from Step 3 — either "genuinely supports GetExtendedAgentCard, returned card named X" or "declares capabilities.extendedAgentCard: true but GetExtendedAgentCard returns error: Y" (a non-conformance finding, matching this file's existing pattern of documenting real, observed non-conformances). Do not guess at the content before running Step 3 — write this section from the actual console output.

- [ ] **Step 5: Commit (in `a2a-interop-tests`, on its own branch)**

```bash
git checkout -b test/getExtendedAgentCard-interop
git add tests/interop_test.bal servers/helloworld/findings.md
git commit -m "test: add real interop test for getExtendedAgentCard against helloworld"
git push -u origin test/getExtendedAgentCard-interop
gh pr create --title "test: add real interop test for getExtendedAgentCard against helloworld" --body "Confirms (or disproves) whether helloworld's capabilities.extendedAgentCard:true means getExtendedAgentCard (from a2a-ballerina's feature/a2a-remaining-operations) is genuinely supported. Requires that branch's ballerina/a2a to be packed and pushed to the local repository first (see setup.md)."
```

Do not merge — hold for review, same as every other batch. Do not merge `a2a-ballerina`'s `feature/a2a-remaining-operations` either; open its own PR at this point, referencing this interop-test confirmation and noting explicitly that the 4 push-notification CRUD methods and `listTasks` remain unverified against any real server (documented limitation, not an oversight).
