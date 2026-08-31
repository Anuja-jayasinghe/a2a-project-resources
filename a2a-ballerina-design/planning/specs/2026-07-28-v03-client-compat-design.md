# A2A v0.3 client compatibility — design

## Context

Testing `ballerina/a2a`'s `Client` against the `adk_currency_agent` reference
agent (from `a2aproject/a2a-samples`, used to prepare for an upcoming demo)
surfaced a real interop blocker, not just another vendor quirk like the
`helloworld` server's non-conformances: this agent's `AgentCard` declares
`"protocolVersion": "0.3.0"`, and it genuinely only understands the older
A2A protocol v0.3 wire format. Confirmed empirically:

- Card discovery succeeds (the card has no `supportedInterfaces`, only a
  legacy top-level `url`, and `primaryUrl()`'s existing fallback already
  handles that case correctly).
- Every actual RPC call fails: sending `SendMessage` (our client's v1.0
  method name) gets back `{"error":{"code":-32601,"message":"Method not
  found"}}`. The same request with `message/send` (the v0.3 method name)
  succeeds and returns a real currency conversion.

`ballerina/a2a`'s `Client` currently only ever speaks v1.0 (PascalCase
JSON-RPC method names, wrapped `SendMessage` responses, `SCREAMING_SNAKE_CASE`
enum values). This design adds v0.3 compatibility so the client can talk to
either kind of server, with the version difference fully absorbed inside the
client — callers write identical code regardless of which protocol version
the remote agent speaks.

## Decisions made during brainstorming

- **Detection**: auto-detect from `AgentCard.protocolVersion` rather than an
  explicit caller-supplied flag or a fallback-on-error retry.
- **Scope**: all 5 operations (`sendMessage`, `sendMessageStream`, `getTask`,
  `cancelTask`, `subscribeToTask`), not just enough to unblock the demo's
  happy path.
- **Type mapping**: v0.3 responses are translated into the exact same
  `Task`/`Message`/`Role`/`TaskState`/`StreamResponse` types the client
  already returns for v1.0 servers — no parallel v0.3-flavored result types.
  Callers never branch on which protocol version they're talking to.
- **Card plumbing**: `Client.init` gains an optional `AgentCard? agentCard`
  parameter. Omitting it keeps today's exact v1.0-only behavior (fully
  backward compatible with every existing caller); passing the card the
  caller already got from `resolveAgentCard` triggers auto-detection.

## Spec grounding

Confirmed against `https://a2a-protocol.org/latest/whats-new-v1/` and the
actual installed `a2a-sdk` Python package's `a2a/compat/v0_3/types.py`
(pydantic definitions — more authoritative than the doc's prose summary):

**Note on migration-guide reliability**: the same migration-guide page
repeats a streaming-event-shape claim (`taskStatusUpdate`/`taskArtifactUpdate`
keys, an `index` field) that this project already empirically disproved
against a real v1.0 server (see `a2a-interop-tests/servers/helloworld/
findings.md` — real shape is `statusUpdate`/`artifactUpdate`, no `index`).
This design trusts our own verified findings for the v1.0 side, not that
page, and treats the v0.3 side of the same page as needing the same
skepticism — hence cross-checking against the actual installed SDK source
below rather than relying on the guide's prose alone.

**Method names** (v0.3 → v1.0):

| v0.3 | v1.0 |
|---|---|
| `message/send` | `SendMessage` |
| `message/stream` | `SendStreamingMessage` |
| `tasks/get` | `GetTask` |
| `tasks/cancel` | `CancelTask` |
| `tasks/resubscribe` | `SubscribeToTask` |

**AgentCard**: v1.0 moved `protocolVersion` from the card's top level into
each `AgentInterface.protocolVersion` (already modeled in this codebase's
`AgentInterface` type) and moved `url` into `supportedInterfaces[0].url`
(already handled by `primaryUrl()`). A card with no `supportedInterfaces` is
a legacy (v0.3) card, which is the same signal `primaryUrl()` already relies
on for its own fallback.

**Role**: `"user"` → `ROLE_USER`, `"agent"` → `ROLE_AGENT`.

**TaskState** (8 states, confirmed against the spec page):

| v0.3 | v1.0 |
|---|---|
| `submitted` | `TASK_STATE_SUBMITTED` |
| `working` | `TASK_STATE_WORKING` |
| `completed` | `TASK_STATE_COMPLETED` |
| `failed` | `TASK_STATE_FAILED` |
| `canceled` | `TASK_STATE_CANCELED` |
| `rejected` | `TASK_STATE_REJECTED` |
| `input-required` | `TASK_STATE_INPUT_REQUIRED` |
| `auth-required` | `TASK_STATE_AUTH_REQUIRED` |

**Part** (confirmed against `a2a/compat/v0_3/types.py`'s `TextPart`,
`FilePart`, `FileWithBytes`, `FileWithUri`, `DataPart` classes): v0.3 uses a
`"kind"` discriminator instead of v1.0's field-presence discrimination.

| v0.3 wire shape | v1.0 `Part` fields |
|---|---|
| `{"kind":"text","text":"..."}` | `{text: "..."}` |
| `{"kind":"file","file":{"bytes":"...","mime_type"?,"name"?}}` | `{raw: <decoded bytes>, mediaType?, filename?}` |
| `{"kind":"file","file":{"uri":"...","mime_type"?,"name"?}}` | `{url: "...", mediaType?, filename?}` |
| `{"kind":"data","data":{...}}` | `{data: {...}}` |

**`sendMessage` response**: v0.3 is unwrapped — the JSON-RPC `result` *is*
the task or message directly, tagged `"kind":"task"`/`"kind":"message"` —
unlike v1.0's `{"task":{...}}`/`{"message":{...}}` wrapper
(`SendMessageResult`).

**Stream events** (confirmed against `a2a/compat/v0_3/types.py`'s
`TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent` classes): discriminated by
`"kind"`: `task`, `message`, `status-update`, `artifact-update`.

**`final` field — confirmed safe to drop, not assumed.** v0.3's
`TaskStatusUpdateEvent` carries a `final: bool` field with no v1.0
equivalent. Verified against the actual reference implementation's own
conversion code, `a2a/compat/v0_3/conversions.py`, both directions:

- `to_compat_task_status_update_event` (lines 395–418, the v1.0→v0.3
  direction) *derives* `final` purely from `status.state`:
  ```python
  final = status.state in (
      types_v03.TaskState.completed,
      types_v03.TaskState.canceled,
      types_v03.TaskState.failed,
      types_v03.TaskState.rejected,
  )
  ```
  — the exact same terminal-state set this client's own `isTerminalEvent()`
  (`sse.bal`) already checks.
- `to_core_task_status_update_event` (lines 381–392, the v0.3→v1.0
  direction — the same direction this design's `decodeV03StreamEvent` needs)
  **ignores `compat_event.final` entirely**, copying only `status` across.

So the reference implementation's own v0.3→v1.0 translation already treats
`final` as pure derived redundancy carrying no independent signal — dropping
it and re-deriving terminal-ness from the translated `TaskState` (as this
design already does) matches the reference SDK's own behavior exactly, not
just a convenient assumption. As defense against a non-conforming server
setting `final: true` inconsistently with `state` (e.g. `final: true` with
`state: working`), add a unit test asserting the client ignores `final` and
closes the stream only when the translated `state` is terminal — see
Testing below.

**Error code table — confirmed shared, not assumed.** Checked
`a2a/compat/v0_3/types.py` for every A2A-specific error class and its
literal `code`:

| Code | v0.3 class | v1.0 (`errors.bal`) |
|---|---|---|
| -32001 | `TaskNotFoundError` | `TaskNotFoundError` |
| -32002 | `TaskNotCancelableError` | `TaskNotCancelableError` |
| -32003 | `PushNotificationNotSupportedError` | `PushNotificationNotSupportedError` |
| -32004 | `UnsupportedOperationError` | `UnsupportedOperationError` |
| -32005 | `ContentTypeNotSupportedError` | `ContentTypeNotSupportedError` |
| -32006 | `InvalidAgentResponseError` | `InvalidAgentResponseError` |
| -32007 | `AuthenticatedExtendedCardNotConfiguredError` | `UnsupportedOperationError` (name differs, same code/semantics, no dedicated Ballerina type either version) |
| -32008 | *(does not exist in v0.3)* | `UnsupportedOperationError` (`ExtensionSupportRequiredError`, no dedicated type) |
| -32009 | *(does not exist in v0.3)* | `VersionNotSupportedError` |

Codes -32001 through -32007 are identical in meaning and numeric value
across both versions — confirmed by matching class names at matching
literal codes in the actual installed v0.3 types, not inferred. -32008
(`ExtensionSupportRequiredError`) and -32009 (`VersionNotSupportedError`)
are v1.0-only additions with no v0.3 equivalent at all (extension support
and per-interface version negotiation are v1.0 concepts) — a v0.3 server
can structurally never emit them. **Conclusion: `toA2AError` (`errors.bal`)
needs no changes for v0.3 support.** It already maps the full shared code
range correctly, and the two v1.0-only codes simply never get triggered by
a v0.3 peer, which is expected and harmless — no error-mapping code path
in this design does anything version-specific.

**Header negotiation**: the spec describes per-interface `A2A-Version`
header validation. Empirically this didn't gate the currency agent's
behavior either way, but sending `A2A-Version: 0.3` in v0.3 mode is the
spec-correct thing to do and costs nothing.

## Architecture

One new file, `compat_v03.bal`, at the `a2a` package root — not a separate
submodule. `sse.bal`'s existing header comment explains why: a submodule
under `modules/` can't import the root module without a cyclic dependency,
which is exactly why SSE decoding and `toA2AError` already live at the root
instead of in `modules/transport/`. The same constraint rules out a
`modules/a2a.compat` submodule here.

`Client` gains a private field, `ProtocolMode mode` (a
`"V1_0"|"V0_3"` string union), detected once at construction and threaded
through every private helper (`rpcCall`, `openSseStream`) and into the SSE
generator. Every public method signature and every returned type (`Task`,
`Message`, `Role`, `TaskState`, `StreamResponse`, ...) is unchanged — mode
is purely an internal detail a caller never sees or branches on.

## Components & data flow

**`AgentCard` type change** (`types.bal`): add one new optional field,
`string? protocolVersion?;`, documented as the pre-v1.0 legacy top-level
location, superseded by `supportedInterfaces[].protocolVersion`, kept only
for detecting legacy cards.

**Detection** (`compat_v03.bal`):

```
public type ProtocolMode "V1_0"|"V0_3";

isolated function detectProtocolMode(AgentCard card) returns ProtocolMode {
    if card.supportedInterfaces.length() > 0 {
        string? v = card.supportedInterfaces[0]?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    string? v = card?.protocolVersion;
    return (v is string && !v.startsWith("0.")) ? "V1_0" : "V0_3";
}
```

A card with `supportedInterfaces` set uses that interface's declared
version; a legacy card (no `supportedInterfaces` — the same signal
`primaryUrl()` already uses) defaults to `V0_3` unless its top-level
`protocolVersion` explicitly says otherwise.

**Client construction** (`client.bal`): `Client.init` gains
`AgentCard? agentCard = ()`. When given, `self.mode =
detectProtocolMode(agentCard)`; when omitted, `self.mode = "V1_0"` — today's
exact behavior, unchanged for every existing caller.

**Outbound method-name translation**: a lookup table,
`v03MethodName(string v1Method) returns string`, used by `rpcCall` and
`openSseStream` when `mode == "V0_3"` to substitute the wire method name
before building the JSON-RPC request. `buildHeaders()` sends
`A2A-Version: 0.3` instead of `1.0` in that mode.

**Inbound decoding** (`compat_v03.bal`), all converting straight into the
existing v1.0 types:

- `mapV03Role`, `mapV03State` — table lookups per the mappings above.
- `parseV03Part(json) returns Part|error` — dispatches on `"kind"`, maps
  `file`'s nested `bytes`/`uri` variants to `Part.raw`/`Part.url`.
- `parseV03Task`, `parseV03Message` — parse the unwrapped v0.3 shapes into
  the existing `Task`/`Message` records.
- `decodeV03SendResult(json) returns Task|Message|error` — reads the
  top-level `"kind"` to choose `parseV03Task` or `parseV03Message`; replaces
  `SendMessageResult.cloneWithType` for `sendMessage` in v0.3 mode.
- `decodeV03StreamEvent(json) returns StreamResponse|error` — same `"kind"`
  dispatch across `task`/`message`/`status-update`/`artifact-update`,
  producing the same `StreamResponse` type either mode returns.
- `decodeTaskResult(json) returns Task|error` — small shared helper used by
  `getTask`/`cancelTask`, branching between today's `cloneWithType(Task)`
  and `parseV03Task`.

**`sse.bal`**: `A2AStreamGenerator` gains the same `ProtocolMode`; its
`decodeEvent` branches between `cloneWithType(StreamResponse)` (v1.0) and
`decodeV03StreamEvent` (v0.3). `isTerminalEvent` needs no change — it runs
after translation, so it always sees v1.0-shaped `TaskState` values
regardless of which wire dialect produced the event.

**Outbound encoding** (`compat_v03.bal`) — added after the initial
implementation, once a real interop test against a live v0.3 server
(`adk_currency_agent`) revealed this half was never covered by the
original design: the sections above only addressed translating a v0.3
server's *responses* back into v1.0 types. Nothing addressed translating
the *caller's* v1.0-shaped `Message`/`SendMessageConfiguration` into v0.3
wire shape before sending it. Without this, `sendMessage`/
`sendMessageStream` would combine a correctly-translated method name with
a body a v0.3 server's schema likely rejects or misparses. The mirror
image of the inbound functions above, all converting v1.0 → v0.3:

- `encodeV03Role(Role) returns string|error` — exhaustive `match` mirroring
  `mapV03Role`; errors on `ROLE_UNSPECIFIED` rather than silently
  defaulting to `"user"`.
- `encodeV03Part(Part) returns json|error` — dispatches on which field is
  set (`text`/`raw`/`url`/`data`), tags the result with the matching
  `"kind"`; errors if none of the four are set rather than silently
  fabricating a `{"kind":"data","data":null}`.
- `encodeV03Message(Message) returns json|error` — tags the result
  `"kind":"message"`, includes `referenceTaskIds`/`extensions` only when
  non-empty (symmetric with how `parseV03Message` populates them).
- `encodeV03SendConfiguration(SendMessageConfiguration) returns json` —
  `returnImmediately` inverts to v0.3's `blocking` (opposite sense),
  `taskPushNotificationConfig` renames to `pushNotificationConfig`
  (dropping the v1.0-only `taskId` sub-field), `acceptedOutputModes`/
  `historyLength` pass through unchanged.

`sendMessage` and `sendMessageStream` call `encodeV03Message`/
`encodeV03SendConfiguration` when `self.mode == "V0_3"`, mirroring exactly
how the inbound decode functions are already gated. `getTask`/`cancelTask`/
`subscribeToTask`/`cancelTask`'s other params (`id`, `historyLength`,
`metadata`) are plain scalars/opaque values with identical field names in
both dialects, so they need no translation — confirmed during the final
whole-branch review, not assumed.

**`tenant` routing**: sent only in `V1_0` mode. It's a v1.0-only concept
(a per-`AgentInterface` value); v0.3 has no wire counterpart, so it's
omitted rather than sent as an unrecognized param a strict v0.3 server
might reject.

## Error handling

No new `A2AError` subtypes. `-32601 Method not found` already falls through
`toA2AError`'s default case to `A2AInternalError`, which is correct, generic
behavior whether it comes from a genuine version-detection miss or an
actually-unsupported method. `compat_v03.bal`'s parse functions return a
plain `error` on malformed/unrecognized JSON (an unknown `"kind"` value, a
state string outside the mapping table), surfacing the same way today's
`cloneWithType` failures already do.

## Raw evidence

The full raw request/response JSON from a successful `message/send` call
against the real running `adk_currency_agent` — matching the evidentiary
standard set by `servers/helloworld/findings.md` — is recorded in
`a2a-interop-tests/servers/adk_currency_agent/findings.md`, alongside the
`SendMessage` failure probe, the agent card's raw JSON, and the actual
`ballerina/a2a` client's observed behavior against this server (discovery
succeeds, `sendMessage` fails with `Method not found` → `A2AInternalError`).

## Testing

- **Unit tests** (`tests/`, mock-based): extend `testutil.bal`'s scripting
  to script v0.3-shaped mock responses (unwrapped, lowercase enums, `"kind"`
  discriminators), and construct `Client` with a synthetic `AgentCard`
  forcing `V0_3` mode via both detection paths (`supportedInterfaces`
  present vs. legacy top-level `protocolVersion`). Cover all 5 operations,
  the full stream-event dispatch table, and `detectProtocolMode` directly.
  - **`AgentCard.protocolVersion` round-trip + tolerance**: the new field
    is serialized and deserialized correctly when present, and absent when
    unset (matching the existing round-trip/tolerance pattern every other
    `AgentCard` field already has in `types_test.bal`); an unrecognized
    extra field alongside it is still tolerated (open-record tolerance,
    same as every other type).
  - **`final`-field regression**: script a v0.3 stream event with
    `"final": true` on a *non-terminal* state (e.g. `"working"`) and assert
    the client does not close the stream — proving `final` is ignored and
    terminal-ness is derived solely from the translated `TaskState`, per
    the confirmed reference-SDK behavior above, not merely assumed safe.
- **Interop test** (separate `a2a-interop-tests` repo, matching the existing
  `servers/helloworld` pattern): `servers/adk_currency_agent/` (already
  added — `setup.md` with the `uv sync` / `GOOGLE_API_KEY` / `uv run
  currency_agent` steps, and `findings.md` with the full raw evidence), plus
  new interop tests exercising `sendMessage`/`sendMessageStream` end-to-end
  against the real running agent — this is what actually proves the
  compat layer works, beyond mocks.
- **Round-trip property tests** (`compat_v03_test.bal`):
  `parseV03Message(check encodeV03Message(m)) == m`, over both a Message
  exercising every Part variant and every optional field, and a minimal
  Message with none of them set. The cheapest ongoing guard against the
  encode and decode halves of this file drifting apart from each other as
  either changes independently in the future — added after the final
  review recommended it, not part of the original plan.

## Known limitations

Two wire-shape assumptions in the outbound encoding functions remain
unverified against a live v0.3 server, because no recorded interop finding
exercises these specific fields:

- **`TaskPushNotificationConfig`'s shape under the renamed
  `pushNotificationConfig` field.** `encodeV03SendConfiguration` assumes
  `url`/`id`/`token`/`authentication` forward unchanged and `taskId` is
  dropped, based only on that field's own doc comment ("Leave unset in a
  sendMessage request") — no observed v0.3 payload for it exists anywhere
  in this repo or `a2a-interop-tests`, since neither reference agent
  tested so far declares `capabilities.pushNotifications: true`.
- **`Message.referenceTaskIds`/`extensions` and `Artifact.extensions`
  field names.** Assumed identical to v1.0 by extrapolation from the
  pattern this whole file already relies on for `contextId`/`taskId`/
  `metadata` (field names carry over unless a discriminator/enum/nesting
  difference is specifically documented) — neither the `helloworld` nor
  `adk_currency_agent` findings exercise these two fields either way.

Both are reasonable, low-risk extrapolations consistent with how the rest
of this file already treats untested field-name symmetry, confirmed as
such during the final whole-branch review — not a new departure from the
file's established pattern. Closing them for real requires a reference
agent that actually uses push notifications or cross-task references,
which neither `helloworld` nor `adk_currency_agent` do.
