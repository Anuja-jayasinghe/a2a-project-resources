# Remaining A2A operations (ListTasks, push-notification-config CRUD, GetExtendedAgentCard) — design

## Context

A full audit of `ballerina/a2a`'s `Client` against the official A2A
specification (`https://a2a-protocol.org/latest/specification/`) found
that only 5 of the spec's 11 defined operations are implemented:
`sendMessage`, `sendMessageStream`, `getTask`, `cancelTask`,
`subscribeToTask`. This design covers the remaining 6:

- `ListTasks` — filtered/paginated task listing
- `CreateTaskPushNotificationConfig`, `GetTaskPushNotificationConfig`,
  `ListTaskPushNotificationConfigs`, `DeleteTaskPushNotificationConfig` —
  standalone push-notification webhook management (distinct from
  configuring one at send time via
  `SendMessageConfiguration.taskPushNotificationConfig`, which already
  exists)
- `GetExtendedAgentCard` — retrieves a fuller `AgentCard` after client
  authentication

This is the largest piece of the "full parity" gap identified in that
audit; the other two pieces (full `SecurityScheme` typing,
`A2A-Extensions` header support) are separate, independently-scoped
efforts.

## Decisions made during brainstorming

- **v0.3 support**: full — the 5 operations with a known v0.3 equivalent
  (all but `ListTasks`) get the same auto-translating wire support every
  existing operation already has, via the same opt-in `agentCard`
  mechanism. The spec is silent on per-operation scope for a client's
  compatibility layer (pure implementation discretion), but this keeps
  the client consistent rather than introducing an arbitrary split in
  what's supported per protocol version.
- **`ListTasks` on a v0.3 server**: client-side error immediately,
  without a network round trip. `ListTasks` has no v0.3 equivalent at all
  (confirmed "(NEW)" in the v0.3→v1.0 migration table). The spec doesn't
  define a dedicated "operation doesn't exist in this version" error, but
  §3.6.3 states tooling "should... avoid automatic fallback to older
  versions, to prevent silently losing functionality" — the closest
  applicable normative principle, and it favors failing loudly. Uses
  `VersionNotSupportedError` (already exists, code -32009), extending its
  spec-defined whole-interface scope to this specific per-operation case
  — documented as a deliberate extension, not a literal spec requirement.
- **Push-notification CRUD verification**: mock-only for this batch.
  Neither reference agent tested so far (`helloworld`,
  `adk_currency_agent`) declares `capabilities.pushNotifications: true`,
  so these 4 methods cannot be interop-tested against a real server the
  way every other operation in this client has been. Documented as a
  known, deliberate limitation — closing it needs a third reference agent
  that actually supports push notifications.
- **`GetExtendedAgentCard` verification**: real interop test planned.
  `helloworld`'s agent card showed `capabilities.extendedAgentCard: true`
  in earlier session output — worth confirming this operation is
  genuinely supported by that server, not just flagged.

## Spec grounding

Confirmed against the official spec (`§3.1.4`, `§3.1.7`–`§3.1.11`, JSON-RPC
binding `§9.4.4`, `§9.4.7`–`§9.4.8`) and the authoritative
`a2a.proto` (same methodology as the earlier v0.3 compat work — the proto
is the single normative source of truth the spec site renders from):

**`ListTasks`** — request fields, all flat (no `TaskFilter` wrapper type
exists), all optional except none required: `tenant`, `contextId`,
`status` (`TaskState`), `pageSize` (int), `pageToken` (string),
`historyLength` (int), `statusTimestampAfter` (timestamp), `includeArtifacts`
(boolean). Response: `tasks` (`Task[]`, required), `nextPageToken`
(string, required), `pageSize` (int, required), `totalSize` (int,
required).

**`CreateTaskPushNotificationConfig`** — request IS a
`TaskPushNotificationConfig` directly (no wrapper — the type already has
a `taskId` field, unset in `sendMessage` context, set here). Response:
`TaskPushNotificationConfig`.

**`GetTaskPushNotificationConfig`** — request: `tenant` (optional),
`taskId` (required), `id` (required). Response:
`TaskPushNotificationConfig`.

**`ListTaskPushNotificationConfigs`** — request: `taskId` (required),
`pageSize` (optional), `pageToken` (optional), `tenant` (optional).
Response: `configs` (`TaskPushNotificationConfig[]`), `nextPageToken`
(string).

**`DeleteTaskPushNotificationConfig`** — request: `tenant` (optional),
`taskId` (required), `id` (required). Response: empty. **Must be
idempotent** (§3.1.10) — deleting an already-deleted/nonexistent config
is not an error.

**`GetExtendedAgentCard`** — request: `tenant` (optional) only. Response:
full `AgentCard`. Requires client authentication via a scheme declared in
the *public* `AgentCard.securitySchemes` — handled transparently by the
existing `http:ClientConfiguration.auth` mechanism every other operation
already uses; no new auth wiring needed.

**Capability gating** (server-side, already-existing client error types
apply): all 4 push-notification methods → `PushNotificationNotSupportedError`
if `capabilities.pushNotifications` is false. `GetExtendedAgentCard` →
`UnsupportedOperationError` if unsupported, or
`ExtendedAgentCardNotConfiguredError` if the capability is on but no
extended card is actually configured (both types already exist in
`errors.bal`, added during the earlier spec-compliance quick-win batch).

**v0.3 method-name mapping** (from the migration guide's table,
cross-checked against the same authoritative proto used throughout this
project's v0.3 work):

| v1.0 | v0.3 |
|---|---|
| `ListTasks` | *(none — v1.0-only)* |
| `CreateTaskPushNotificationConfig` | `tasks/pushNotificationConfig/set` |
| `GetTaskPushNotificationConfig` | `tasks/pushNotificationConfig/get` |
| `ListTaskPushNotificationConfigs` | `tasks/pushNotificationConfig/list` |
| `DeleteTaskPushNotificationConfig` | `tasks/pushNotificationConfig/delete` |
| `GetExtendedAgentCard` | `agent/getAuthenticatedExtendedCard` |

Exact v0.3 wire *field* names for `TaskPushNotificationConfig`'s v0.3
shape are not independently re-confirmed at design time — per this
project's established methodology, verify against the actual installed
`a2a-sdk` Python package's `a2a/compat/v0_3/types.py` during
implementation (the same source that resolved every prior v0.3 field-name
question in this project), rather than guessing from spec prose alone.

## Architecture

Six new `Client` remote functions in `client.bal`, following the exact
patterns the existing 5 operations already establish — no new
architectural concepts. Two new response-only types in `types.bal`
(`ListTasksResult`, `ListTaskPushNotificationConfigsResult`) plus one new
request-filter type (`ListTasksFilter`, mirroring `SendMessageConfiguration`'s
style since it has many optional fields). `TaskPushNotificationConfig`
(already exists) is reused directly as both request and response body for
the 3 CRUD methods that need it — no new wrapper type, matching the
spec's own "request IS the object" shape.

`compat_v03.bal` gains: a v0.3 method-name table extension (5 new
entries), and `parseV03*`/`encodeV03*` pairs for
`TaskPushNotificationConfig` and the two list-result types, mirroring the
existing `parseV03Task`/`encodeV03Message`-style functions exactly.

## Components & data flow

**New types** (`types.bal`):

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

**New `Client` methods** (`client.bal`), each following the existing
`rpcCall` + mode-branch pattern exactly (method-name translation via
`v03MethodName`, response decode via `cloneWithType` for V1_0 or the
matching `parseV03*` for V0_3):

```ballerina
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

isolated remote function createTaskPushNotificationConfig(
        TaskPushNotificationConfig config,
        string? tenant = ()) returns TaskPushNotificationConfig|error {
    map<json> params = self.mode == "V0_3"
        ? check encodeV03TaskPushNotificationConfig(config)
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
    // Empty success response per spec -- nothing to decode.
}

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

`compat_v03.bal` gains `parseV03TaskPushNotificationConfig`,
`encodeV03TaskPushNotificationConfig`, and
`parseV03ListTaskPushNotificationConfigsResult`, mirroring the existing
`parseV03Task`/`encodeV03Message` pattern — build/consume an intermediate
JSON map, `cloneWithType` at the boundary, exact v0.3 field names
confirmed against the installed `a2a-sdk` source during implementation
per the Spec Grounding section above.

## Error handling

No new `A2AError` subtypes. `PushNotificationNotSupportedError` and
`UnsupportedOperationError`/`ExtendedAgentCardNotConfiguredError` (all
already exist) cover every server-side rejection path for these 6
operations. `listTasks`'s client-side `VersionNotSupportedError`
short-circuit in `V0_3` mode is the only new error-flow, and it never
reaches the network.

## Testing

- **Unit tests** (mock-based, `tests/`): all 6 operations, both `V1_0`
  and `V0_3` wire shapes (except `listTasks`, `V0_3`-only case being the
  client-side error itself, not a wire round-trip) — following the
  existing `testutil.bal` scripting conventions exactly. Cover: happy
  path per operation, pagination fields present/absent for `listTasks`
  and `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig`
  returning `()` on success, and the capability-gating error paths
  (scripted JSON-RPC error responses mapping to the existing error
  types).
- **Interop test** (`a2a-interop-tests`, real server): attempt
  `getExtendedAgentCard` against the real running `helloworld` server,
  given its card previously showed `extendedAgentCard: true` — confirm
  whether it's genuinely supported or just flagged, and document
  whichever is true in `servers/helloworld/findings.md`.
- **Known, deliberate verification gap**: the 4 push-notification CRUD
  methods and `listTasks` cannot be interop-tested against either current
  reference agent (`helloworld`, `adk_currency_agent`) — neither declares
  `pushNotifications: true`, and neither is confirmed to support
  `listTasks`. This mirrors the two wire-shape assumptions already
  documented as known limitations in the v0.3 compat design spec; closing
  it requires a third reference agent that actually exercises these
  features.
