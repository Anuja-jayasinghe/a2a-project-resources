# REST (HTTP+JSON) transport binding — design

## Context

`ballerina/a2a`'s `Client` speaks exactly one of the A2A specification's
three standard transport bindings: JSON-RPC. The spec defines three —
`JSONRPC`, `GRPC`, and `HTTP+JSON` — and an agent advertises which it
serves via `AgentCard.supportedInterfaces[].protocolBinding`, an open
string whose officially supported values are exactly those three (proto
`AgentInterface.protocol_binding`, lines 336–355 of `a2a.proto`).

Today `primaryUrl` (`client.bal:180-191`) hard-filters that list for
`"JSONRPC"` and errors out if no such entry exists. A card advertising
only an `HTTP+JSON` interface — a perfectly conformant card — is
unreachable by this library. This design covers adding the `HTTP+JSON`
binding as a second, co-equal wire format.

`GRPC` is explicitly out of scope: it needs protobuf codegen and an
`http2`/grpc client stack rather than `http:Client`, which is a
materially different effort from "same JSON, different framing".

## Research performed for this design

Two unknowns were flagged during the plan's research phase as inferred
rather than confirmed. Both were resolved before this design was written;
the evidence is recorded here because the answer to the first one changes
the architecture.

### Open question 1 — is REST streaming actually SSE?

**Answer: yes, confirmed — but the event payload shape differs from the
JSON-RPC binding's, which is the load-bearing finding.**

The prose route was a dead end and is documented as such so nobody
re-walks it: the rendered spec page (`a2a-protocol.org/latest/specification/`)
and `docs/topics/custom-protocol-bindings.md` were both fetched. The
topic doc only states that "The A2A protocol ships with three standard
bindings (JSON-RPC, gRPC, and HTTP+JSON/REST)" and describes how to
define *custom* bindings; it documents none of the three standard ones.
The rendered spec page is truncated by fetching before reaching the
binding sections, and two attempts to fetch deeper (a section anchor, and
the raw `docs/specification.md`) returned summaries containing endpoint
paths (`POST /messages`, `GET /.well-known/a2a/agent-card:extended`) that
directly contradict the proto's own `google.api.http` annotations. Those
summaries were discarded as unreliable rather than used.

The question was instead settled against primary sources — the normative
`a2a.proto` and the reference `a2a-python` SDK's REST transport, which is
the executable expression of the binding:

- `a2a.proto` declares both streaming RPCs as server-streaming
  (`returns (stream StreamResponse)`) with plain HTTP annotations, so the
  streaming framing is not specified inline in the proto.
- `a2a-python`'s `src/a2a/client/transports/rest.py` routes both through
  `_send_stream_request` → `send_http_stream_request`
  (`src/a2a/client/transports/http_helpers.py`), which sets
  `headers.setdefault('Accept', 'text/event-stream')` and
  `Cache-Control: no-store`, checks the response for
  `'text/event-stream' not in response.headers.get('content-type', '')`,
  and otherwise iterates `parse_sse_stream(response)`.

So: SSE, `Accept: text/event-stream`, at the `:stream` and `:subscribe`
paths, exactly as the URL naming suggested.

**The consequential difference.** In the JSON-RPC binding each SSE
event's `data` is a full JSON-RPC response envelope, which
`A2AStreamGenerator.decodeEvent` (`sse.bal:78-95`) unwraps before typing
the `result` as a `StreamResponse`. In the REST binding each event's
`data` is a **bare `StreamResponse` object with no envelope** —
`rest.py` does `event: StreamResponse = Parse(sse_data, StreamResponse())`
directly on the SSE data string. `decodeEvent`'s envelope unwrapping is
therefore not reusable as-is for REST and must be made binding-aware.

Two further REST-streaming behaviours worth designing for, both from
`http_helpers.py`:

- **Named `error` events.** The reader dispatches on the SSE event
  *name*: `if event_name == 'error': sse_error_handler(data)`. The REST
  binding signals a mid-stream error with an `event: error` frame whose
  data is a REST error payload (see §Error mapping). The JSON-RPC binding
  has no equivalent — it carries errors inside the envelope's `error`
  member. `A2AStreamGenerator` currently ignores `SseEvent.event`
  entirely and reads only `.data`; for REST it must inspect the name.
- **Non-streaming rejection responses.** If the content type is not
  `text/event-stream`, the helper reads the whole body and yields it as a
  single chunk, i.e. a rejected streaming request can come back as a
  plain error body under any status. `openSseStream` (`client.bal:478-489`)
  already handles precisely this shape for JSON-RPC; the same guard is
  needed for REST, routed through the REST error parser instead.

### Open question 2 — do REST camelCase field names match `types.bal` 1:1?

**Answer: the *names* match essentially 1:1; the *shapes* do not.** A
side-by-side pass was done for all 11 operations against the proto
messages and `types.bal`. Every mismatch found is listed below, smallest
to largest, including pre-existing ones that are not REST's fault.

The naming baseline holds: protojson lower-camelCases proto snake_case,
and every one of these already matches `types.bal` exactly —
`message_id`→`messageId`, `context_id`→`contextId`, `task_id`→`taskId`,
`reference_task_ids`→`referenceTaskIds`, `artifact_id`→`artifactId`,
`media_type`→`mediaType`, `status_update`→`statusUpdate`,
`artifact_update`→`artifactUpdate`, `next_page_token`→`nextPageToken`,
`page_size`→`pageSize`, `total_size`→`totalSize`,
`history_length`→`historyLength`, `accepted_output_modes`→
`acceptedOutputModes`, `return_immediately`→`returnImmediately`,
`task_push_notification_config`→`taskPushNotificationConfig`,
`status_timestamp_after`→`statusTimestampAfter`,
`include_artifacts`→`includeArtifacts`, `protocol_binding`→
`protocolBinding`, `protocol_version`→`protocolVersion`. Proto3 `oneof`
members are flattened by protojson (no wrapper object), which is why
`SendMessageResult`'s `{task}`/`{message}` and `StreamResponse`'s four
members are already the right shape. Enums serialize as their symbolic
names (`ROLE_USER`, `TASK_STATE_COMPLETED`), matching the `Role` and
`TaskState` enum members verbatim. `google.protobuf.Timestamp`
serializes as an RFC 3339 string, matching `TaskStatus.timestamp`'s
`string?`.

**M1 — `Part.raw` base64 (pre-existing, both bindings).** The proto
comments `bytes raw = 2` with "In JSON serialization, this is encoded as
a base64 string". `types.bal` declares `byte[]? raw?`. Ballerina's
`toJson()`/`cloneWithType` round-trip `byte[]` through base64, so this is
believed correct, but it is an *assumed* conversion this library has
never asserted in a test. Not REST-specific; worth a round-trip test
while REST is being built.

**M2 — `OAuthFlows` is missing `deviceCode` (pre-existing, both
bindings).** Proto `OAuthFlows` is a `oneof` of five members:
`authorization_code`, `client_credentials`, `implicit` (deprecated),
`password` (deprecated), and `device_code`. `types.bal`'s `OAuthFlows`
declares only the first four. Because `OAuthFlows` is an open record
(`json...;`), a card advertising a device-code flow does **not** lose the
member — it survives as an untyped `json` value, just without a typed
`DeviceCodeOAuthFlow` accessor. Unrelated to REST; noted because the pass
found it and the brief asked for every mismatch however small.

**M3 — `tenant` is duplicated between path and body on writes.** Every
request message carries a `tenant` field, *and* every operation has a
`/{tenant}/...` path variant. `a2a-python` resolves this asymmetrically:
for GET operations it deletes `tenant` from the query params after
putting it in the path (`if 'tenant' in params: del params['tenant']`),
but for POST operations it serializes the whole request via
`MessageToDict(request)` with `tenant` left in, so tenant travels in both
the path *and* the JSON body. This design follows the reference SDK
exactly rather than "cleaning it up", since servers are built against it.

**M4 — path-bound fields are duplicated into the body on writes, too.**
`CancelTask` has `post: "/tasks/{id=*}:cancel"` with `body: "*"`, so `id`
is in the path and also in the body. `CreateTaskPushNotificationConfig`
is worse: its request message *is* `TaskPushNotificationConfig`, bound at
`post: "/tasks/{task_id=*}/pushNotificationConfigs"` with `body: "*"`, so
`taskId` appears in the path and in the body. Again, matched to the
reference SDK rather than trimmed.

**M5 — bodiless operations (the six GETs and the DELETE) move fields from
a body into the query string.**
This is the largest reconciliation item and has no JSON-RPC analogue.
`GetTask`, `ListTasks`, `SubscribeToTask`, `GetTaskPushNotificationConfig`,
`ListTaskPushNotificationConfigs`, `GetExtendedAgentCard`, and
`DeleteTaskPushNotificationConfig` carry no body at all; every non-path field
becomes a query parameter. The field *names* are unchanged (still
camelCase), so this is a shape change, not a rename — but it means
`ListTasksFilter`'s seven fields must be URL-encoded rather than
JSON-encoded, and two of them need explicit attention:

- `status` is a `TaskState` enum → the symbolic name string
  (`TASK_STATE_WORKING`), not an ordinal.
- `statusTimestampAfter` is a `Timestamp` → the same RFC 3339 string
  `types.bal` already stores, but it contains `:` and `+` characters and
  must be percent-encoded.

**M6 — `DeleteTaskPushNotificationConfig` returns `google.protobuf.Empty`.**
Over REST this is an empty or `{}` body, potentially with `204 No
Content`. The current implementation does
`json _ = check self.rpcCall(...)` (`client.bal:870`), which requires a
parseable JSON result. The REST path must tolerate an absent body rather
than treating it as a malformed response.

**M7 — `GetTask`/`CancelTask` return a bare `Task`, not a wrapper.**
Consistent with what `cloneWithType(Task)` already does with the
JSON-RPC `result` member, so no change — recorded only to confirm it was
checked.

**Conclusion:** no field *renaming* layer is needed for REST. There is no
REST analogue of `compat_v03.bal`'s `encodeV03*`/`parseV03*` functions,
because the v1.0 JSON-RPC `params`/`result` bodies and the v1.0 REST
bodies are the *same* JSON objects — REST only redistributes those fields
across path, query, and body. That is the single most important finding
for scoping the implementation.

## Operation → HTTP mapping

Confirmed against `specification/a2a.proto` in `a2aproject/A2A`, service
`A2AService`, reading the `google.api.http` annotations directly. Each
operation's `additional_bindings` supplies the tenant-scoped variant,
which is uniformly the unscoped path prefixed with `/{tenant}`.

| Op | HTTP | Path | Tenant-scoped variant |
|---|---|---|---|
| SendMessage | POST | `/message:send` | `/{tenant}/message:send` |
| SendStreamingMessage | POST | `/message:stream` | `/{tenant}/message:stream` |
| GetTask | GET | `/tasks/{id}` | `/{tenant}/tasks/{id}` |
| ListTasks | GET | `/tasks` | `/{tenant}/tasks` |
| CancelTask | POST | `/tasks/{id}:cancel` | `/{tenant}/tasks/{id}:cancel` |
| SubscribeToTask | GET | `/tasks/{id}:subscribe` | `/{tenant}/tasks/{id}:subscribe` |
| CreateTaskPushNotificationConfig | POST | `/tasks/{task_id}/pushNotificationConfigs` | `/{tenant}/tasks/{task_id}/pushNotificationConfigs` |
| GetTaskPushNotificationConfig | GET | `/tasks/{task_id}/pushNotificationConfigs/{id}` | `/{tenant}/tasks/{task_id}/pushNotificationConfigs/{id}` |
| ListTaskPushNotificationConfigs | GET | `/tasks/{task_id}/pushNotificationConfigs` | `/{tenant}/tasks/{task_id}/pushNotificationConfigs` |
| GetExtendedAgentCard | GET | `/extendedAgentCard` | `/{tenant}/extendedAgentCard` |
| DeleteTaskPushNotificationConfig | DELETE | `/tasks/{task_id}/pushNotificationConfigs/{id}` | `/{tenant}/tasks/{task_id}/pushNotificationConfigs/{id}` |

Every POST uses `body: "*"` — the whole request message as the JSON body.
The DELETE has **no `body` member** in its annotation at all (only
`delete:` plus `additional_bindings`), so it carries no body; its request
message consists entirely of path fields. This distinction feeds
`REST_OPERATIONS`'s `hasBody` flag below, which in turn decides whether
path params are retained in the body or dropped — `hasBody` must be
`false` for the DELETE.

### `SubscribeToTask`'s verb: proto says GET, reference client sends POST

The proto annotates `SubscribeToTask` as **GET**
(`get: "/tasks/{id=*}:subscribe"`, and the tenant variant likewise). The
reference `a2a-python` *client* sends **POST**:

```python
async for event in self._send_stream_request(
    'POST',
    f'/tasks/{request.id}:subscribe',
    request.tenant,
    context=context,
):
```

The reference *server*, however, accepts **both**. From
`a2aproject/a2a-python`, `src/a2a/server/routes/rest_routes.py:80-81`:

```python
('/tasks/{id}:subscribe', 'GET'): dispatcher.on_subscribe_to_task,
('/tasks/{id}:subscribe', 'POST'): dispatcher.on_subscribe_to_task,
```

So the client/proto divergence is real but **largely inert in practice**:
against the reference server — which is what most REST-serving A2A agents
are built on — GET works fine, and the two verbs dispatch to the same
handler.

**Decision: send GET, matching the proto.** GET is the normative
annotation, and the reference server routes it, so this is correct
against both the specification and the dominant implementation.

**Fallback, deliberately scoped small.** A non-reference server that
hand-rolls its routes might register only POST, following the reference
client rather than the proto. For that case only, a `404`, `405`, or
`501` response to a `SubscribeToTask` GET triggers exactly one retry with
POST. The trigger covers all three statuses rather than just `405`
because a router that never registered the GET route is as likely to
return `404` (no route matched) or `501` as a properly-formed `405`
(route exists, wrong verb). The retry is scoped to this one operation and
is not generalised.

This is a **low-likelihood** interop risk, not a high one — the earlier
framing of it as the most likely failure source was based on reading only
the reference client and has been corrected. It is still worth confirming
against a real REST-serving agent, since a mock cannot settle it (a mock
implements whatever the client sends).

## Request/response body shape per operation

Bodies below are the v1.0 JSON shapes. `⟨path⟩` marks a field that also
appears in the URL path (see M3/M4 — it is sent in both places).

- **SendMessage** — body `{tenant⟨path⟩?, message, configuration?,
  metadata?}`; response `{task}` xor `{message}` (`SendMessageResult`).
- **SendStreamingMessage** — identical body; response is an SSE stream of
  bare `StreamResponse` objects.
- **GetTask** — query `historyLength?`; response bare `Task`.
- **ListTasks** — query `contextId?, status?, pageSize?, pageToken?,
  historyLength?, statusTimestampAfter?, includeArtifacts?`; response
  `{tasks, nextPageToken, pageSize, totalSize}` (`ListTasksResult`).
- **CancelTask** — body `{tenant⟨path⟩?, id⟨path⟩, metadata?}`; response
  bare `Task`.
- **SubscribeToTask** — no body; response is an SSE stream of bare
  `StreamResponse` objects.
- **CreateTaskPushNotificationConfig** — body is a whole
  `TaskPushNotificationConfig` `{tenant⟨path⟩?, id?, taskId⟨path⟩?, url,
  token?, authentication?}`; response `TaskPushNotificationConfig`.
- **GetTaskPushNotificationConfig** — no body, no query beyond path;
  response `TaskPushNotificationConfig`.
- **ListTaskPushNotificationConfigs** — query `pageSize?, pageToken?`;
  response `{configs, nextPageToken}`.
- **DeleteTaskPushNotificationConfig** — no body; response empty (M6).
- **GetExtendedAgentCard** — no body; response bare `AgentCard`, parsed
  through the existing `parseAgentCardBody` so the tolerant
  securitySchemes/securityRequirements/signatures handling is preserved.

Note `TaskPushNotificationConfig` is **flat** in v1.0 (proto lines
470–487: `tenant, id, task_id, url, token, authentication`) — there is no
nested `pushNotificationConfig` wrapper. `types.bal` already models it
flat, so it is reused verbatim as both request and response body.

## Design decision 1 — how the client selects the REST binding

**Decision: add a defaulted `preferredBinding` parameter to `primaryUrl`,
and add a new `selectInterface` function that returns the whole matched
`AgentInterface`.**

```ballerina
# The transport bindings this library can speak.
public type TransportBinding "JSONRPC"|"HTTP+JSON";

public isolated function primaryUrl(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns string|error;

# Returns the whole matched interface, not just its url — callers need
# `tenant` and `protocolVersion` from the same entry they resolved the
# url from.
public isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns AgentInterface|error;
```

Rationale, and why not the alternatives:

- **Why a defaulted parameter, not new binding-specific functions
  (`restUrl`, `jsonRpcUrl`).** `primaryUrl` is already public API with
  existing callers, including the demo. A defaulted parameter is source-
  compatible — every existing call keeps resolving `JSONRPC` with byte-
  identical behaviour, including the legacy `card.url` fallback. Binding-
  specific functions would instead multiply one-per-binding (a third
  arrives with `GRPC`) while duplicating the identical scan-and-fallback
  body each time, and would leave `primaryUrl` as a permanently
  misleading name for "the JSON-RPC one".
- **Why also `selectInterface`.** REST needs more than a URL. The tenant
  a client must echo on every request is defined per-interface
  (`AgentInterface.tenant`, and the proto states clients MUST include it
  when set), and so is `protocolVersion`. Returning only a string forces
  callers to re-scan the card and risks pairing one interface's URL with
  another's tenant or version. `primaryUrl` becomes a thin wrapper over
  `selectInterface` so there is one scan implementation, not two.
- **Legacy `card.url` fallback stays `JSONRPC`-only.** A pre-v1.0 card's
  bare `url` field predates `HTTP+JSON` entirely, so falling back to it
  for a REST request would point the client at a JSON-RPC endpoint.
  `selectInterface(card, "HTTP+JSON")` errors rather than falling back.
- **`Client.init` gains a matching `binding` parameter**, defaulted to
  `"JSONRPC"`, so existing construction is unchanged. Deliberately *not*
  auto-detected from the card: silently choosing a binding based on card
  ordering would make the wire format depend on server-side list order.

### `protocolVersion` must be read from the selected interface

`detectProtocolMode` (`compat_v03.bal`) currently reads `protocolVersion`
off `supportedInterfaces[0]` unconditionally:

```ballerina
if card.supportedInterfaces.length() > 0 {
    string? v = card.supportedInterfaces[0]?.protocolVersion;
    return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
}
```

Index 0 is not necessarily the entry `selectInterface` returned, and with
a second binding in play that becomes a live bug rather than a
theoretical one. Consider a conformant card:

```json
"supportedInterfaces": [
  {"protocolBinding": "JSONRPC",   "url": "...", "protocolVersion": "0.3"},
  {"protocolBinding": "HTTP+JSON", "url": "...", "protocolVersion": "1.0"}
]
```

A REST client selects entry 1 (v1.0), but `detectProtocolMode` reads
entry 0 and resolves `V0_3` — which, combined with the v0.3+REST
rejection rule below, would reject a perfectly valid REST client at
construction.

**Decision: `protocolVersion` is read from the interface `selectInterface`
actually returned, never from index 0.** `detectProtocolMode` gains a
binding-aware overload rather than being changed in place, so every
existing single-binding caller keeps identical behaviour:

```ballerina
# Resolves the wire dialect for the interface matching `preferredBinding`,
# rather than assuming supportedInterfaces[0]. Falls back to the existing
# index-0/legacy behaviour when the card declares no matching interface.
public isolated function detectProtocolModeForBinding(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns ProtocolMode;
```

The existing one-arg `detectProtocolMode` stays, delegating with
`"JSONRPC"`. For a single-binding card this preserves its current
semantics exactly. It is **not** identical behaviour for every present
caller, though: for a multi-interface card where the `JSONRPC` interface
isn't at `supportedInterfaces[0]` — the same mixed-interface-card shape
worked through a few paragraphs above — the new binding-aware lookup now
selects the actual `JSONRPC` entry's `protocolVersion` instead of
whatever happens to sit at index 0. That is a deliberate, correct
behaviour change (it fixes exactly the index-0 misread this section
exists to address), not a regression, but it is a real divergence from
today's index-0 reading for that specific case, not "identical."

**Where the v0.3+REST check lives.** `Client.init` already accepts an
optional `agentCard` and derives `self.mode` from it
(`self.mode = agentCard is AgentCard ? detectProtocolMode(agentCard) : "V1_0"`),
so `init` *does* see a card when one is supplied and the check belongs
there — inside `init`, not pushed onto callers. With the new `binding`
parameter, that line becomes:

```ballerina
self.mode = agentCard is AgentCard
    ? detectProtocolModeForBinding(agentCard, binding)
    : "V1_0";
if self.mode == "V0_3" && binding == "HTTP+JSON" {
    return error VersionNotSupportedError(...);
}
```

No new `init` parameter beyond `binding` is needed. When no card is
supplied, `mode` defaults to `V1_0` exactly as today, so REST is
permitted and the check is a no-op — matching the existing convention
that omitting the card means "assume v1.0".

An earlier draft of this design asserted that `Client` "is constructed
from a URL, not a card"; that is wrong — `init` has taken an optional
`agentCard` since the v0.3 compat work. The statement is corrected here
because it was the premise for pushing the version check outside `init`.

## Design decision 2 — branch inside `Client`, not a separate client type

**Decision: extend the existing `Client` with a `binding` field and
branch at a transport seam, not in each method body. No separate
`RestClient` type.**

The justification comes from what the method bodies actually contain.
Reading all eleven remote functions, each is structured identically:
build a `map<json>` of params, apply the `V0_3`/`V1_0` encode branch,
resolve the effective tenant, call one of exactly two private helpers
(`rpcCall` or `openSseStream`), then apply the `V0_3`/`V1_0` decode
branch. Everything except those two helper calls is binding-independent
— param assembly, tenant resolution, and response typing are the same
JSON either way, which is precisely what open question 2 established.

So the binding branch belongs *inside* `rpcCall`/`openSseStream`, and the
eleven method bodies change by zero lines. Concretely:

- `rpcCall(string method, map<json> params)` keeps its signature and
  gains an internal dispatch: `JSONRPC` behaves exactly as today; for
  `HTTP+JSON` it looks the operation up in a descriptor table and issues
  the corresponding request. Its contract — "return the unwrapped result
  json or an `A2AError`" — is already binding-neutral, which is why the
  seam works.
- `openSseStream` likewise, plus passing the binding down to
  `readSseStream` so `decodeEvent` knows whether to unwrap a JSON-RPC
  envelope.

This is *not* the same shape as the `V1_0`/`V0_3` split, and the
difference is the point. `mode` is threaded into method bodies because
v0.3 genuinely changes field names and payload shapes, which only the
method knows how to encode. `binding` changes only framing — where fields
sit in an HTTP request — which only the transport knows. Putting
`binding` in the method bodies too would produce a four-way
`mode × binding` cartesian branch in eleven functions; keeping it at the
transport seam keeps them orthogonal.

A separate `RestClient` type was rejected: it would duplicate all eleven
public method signatures plus their doc comments, the reconnect wiring,
`buildHeaders`, `captureGrantedExtensions`, and the whole v0.3 layer, and
would force callers to choose a *type* at compile time for something the
agent card decides at runtime. Callers holding a `Client` should not care
which binding it negotiated — that is the same principle driving the
error mapping below.

The needed additions are one descriptor table and one new private helper:

```ballerina
# How one operation maps onto the REST binding.
type RestOperation record {|
    string method;                 # "GET" | "POST" | "DELETE"
    string pathTemplate;           # e.g. "/tasks/{id}:cancel"
    string[] pathParams;           # params consumed by pathTemplate
    boolean hasBody;               # true only where the annotation has body: "*"
    boolean streaming;             # response is text/event-stream
|};

final readonly & map<RestOperation> REST_OPERATIONS = { /* 11 entries */ };
```

`hasBody` is `true` for exactly the four POST operations
(`SendMessage`, `SendStreamingMessage`, `CancelTask`,
`CreateTaskPushNotificationConfig`) — the only ones whose annotation
carries `body: "*"`. It is `false` for the six GETs **and for the
DELETE**, whose annotation has no `body` member at all.

Path params are substituted from `params` and — matching the reference
SDK (M3/M4) — left in the body for `hasBody` operations, but removed
entirely for the rest (they must not leak into the query string, which is
why the DELETE's `hasBody: false` matters). `tenant` is lifted out of
`params` into the path prefix when present.

**v0.3 + REST is rejected at construction.** `compat_v03.bal`'s method-
name table maps to v0.3 *JSON-RPC* method names, which have no meaning in
a REST path. Constructing a `Client` with `binding = "HTTP+JSON"` against
a card that `detectProtocolModeForBinding(card, "HTTP+JSON")` resolves to
`V0_3` returns `VersionNotSupportedError` from `init` (see §"`protocolVersion`
must be read from the selected interface" for why the binding-aware
overload is essential here — the index-0 reading would misfire on a
mixed-version card) — consistent with the existing
precedent of `listTasks` failing fast rather than sending a request the
server cannot understand.

## Design decision 3 — error mapping

**Decision: discriminate on the error payload's `reason` string, fall
back to the HTTP status code, and map onto the existing `A2AError`
subtypes with the equivalent JSON-RPC code synthesized into
`A2AErrorDetail.code`. No new error types.**

The critical finding is that **HTTP status alone is not sufficient**.
From `a2a-python`'s `src/a2a/utils/errors.py`, the normative
`A2A_ERROR_MAPPING` is:

| A2A error | HTTP | gRPC status | `reason` | existing JSON-RPC code |
|---|---|---|---|---|
| TaskNotFoundError | 404 | NOT_FOUND | `TASK_NOT_FOUND` | -32001 |
| TaskNotCancelableError | 400 | FAILED_PRECONDITION | `TASK_NOT_CANCELABLE` | -32002 |
| PushNotificationNotSupportedError | 400 | FAILED_PRECONDITION | `PUSH_NOTIFICATION_NOT_SUPPORTED` | -32003 |
| UnsupportedOperationError | 400 | FAILED_PRECONDITION | `UNSUPPORTED_OPERATION` | -32004 |
| ContentTypeNotSupportedError | 400 | INVALID_ARGUMENT | `CONTENT_TYPE_NOT_SUPPORTED` | -32005 |
| InvalidAgentResponseError | 500 | INTERNAL | `INVALID_AGENT_RESPONSE` | -32006 |
| ExtendedAgentCardNotConfiguredError | 400 | FAILED_PRECONDITION | `EXTENDED_AGENT_CARD_NOT_CONFIGURED` | -32007 |
| ExtensionSupportRequiredError | 400 | FAILED_PRECONDITION | `EXTENSION_SUPPORT_REQUIRED` | -32008 |
| VersionNotSupportedError | 400 | FAILED_PRECONDITION | `VERSION_NOT_SUPPORTED` | -32009 |
| *(InvalidParamsError)* | 400 | INVALID_ARGUMENT | `INVALID_PARAMS` | -32602 |
| *(InvalidRequestError)* | 400 | INVALID_ARGUMENT | `INVALID_REQUEST` | -32600 |
| *(MethodNotFoundError)* | 404 | NOT_FOUND | `METHOD_NOT_FOUND` | -32601 |
| *(InternalError)* | 500 | INTERNAL | `INTERNAL_ERROR` | -32603 |

Seven distinct A2A errors all return `400`, and two return `404`. Any
design keyed on status code alone would collapse
`TaskNotCancelableError`, `UnsupportedOperationError`, and
`VersionNotSupportedError` into one indistinguishable error — a
regression against the JSON-RPC binding, where they are separate types
today.

The discriminator is the `reason` field of a `google.rpc.ErrorInfo` entry
inside the error body. The payload shape, from `_parse_rest_error` in
`rest.py`, is:

```json
{
  "error": {
    "message": "...",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "TASK_NOT_CANCELABLE",
        "metadata": { }
      }
    ]
  }
}
```

The reference implementation scans `error.details` for the first entry
whose `@type` is `type.googleapis.com/google.rpc.ErrorInfo`, reads its
`reason`, maps that to an error class, uses `error.message` as the
message, and attaches `metadata` as the error's `data`.

**Implementation** — one new function in `errors.bal`, sitting beside the
existing `toA2AError` and returning the same types:

```ballerina
# Maps a REST binding error response onto the same A2AError hierarchy the
# JSON-RPC binding maps onto, so callers handle errors identically
# regardless of which binding their Client negotiated.
isolated function toA2AErrorFromRest(int statusCode, json? body) returns A2AError;
```

Resolution order:

1. If `body` yields an `ErrorInfo` `reason` in the table above, construct
   that subtype, with `message` from `error.message`, `data` from
   `ErrorInfo.metadata`, and **`code` set to the JSON-RPC code from the
   rightmost column**.
2. Otherwise fall back on status: `404` → `TaskNotFoundError` (-32001);
   `5xx` → `A2AInternalError` (-32603); anything else →
   `A2AInternalError` with `code` set to the raw HTTP status.

Step 1's `code` synthesis is what makes the binding invisible to callers.
`A2AErrorDetail.code` is documented as "originating JSON-RPC code,
preserved for diagnostics", and code already reads it — a caller
switching a `Client` from JSON-RPC to REST would otherwise see `code`
silently change from `-32002` to `400`. Populating it from the mapping
table keeps `is TaskNotCancelableError` *and* `detail.code == -32002`
both true on either binding.

The four parenthesised rows have no distinct type in `errors.bal` today —
`toA2AError`'s `_` arm already folds `-32600`/`-32601`/`-32602`/`-32603`
into `A2AInternalError` with the code preserved. `toA2AErrorFromRest`
does the same for their `reason` strings, so the two bindings stay
consistent. Adding those four as distinct types is a reasonable separate
change, but doing it here would alter JSON-RPC behaviour too and is out
of scope.

Streaming errors use the same function: an `event: error` SSE frame's
data is this same payload, passed to `toA2AErrorFromRest` with the
stream's HTTP status (200), so a mid-stream error surfaces as the same
typed error a unary call would produce.

## Files touched

- `a2a/client.bal` — `TransportBinding` type; `primaryUrl` gains a
  defaulted `preferredBinding`; new `selectInterface`; `Client` gains a
  `binding` field and `init` parameter plus the v0.3+REST rejection;
  `rpcCall` and `openSseStream` gain the binding dispatch; new
  `REST_OPERATIONS` descriptor table and REST request-building helper.
- `a2a/compat_v03.bal` — new `detectProtocolModeForBinding` overload;
  existing `detectProtocolMode` delegates to it with `"JSONRPC"`.
- `a2a/errors.bal` — new `toA2AErrorFromRest`, plus the reason→type and
  reason→JSON-RPC-code tables it maps through.
- `a2a/sse.bal` — `readSseStream`/`A2AStreamGenerator` take the binding;
  `decodeEvent` skips envelope unwrapping for REST; the generator begins
  inspecting `SseEvent.event` to detect `error` frames.
- `a2a/types.bal` — no changes required for REST itself (the shared v1.0
  types are reused verbatim). Optional, if the M1/M2 pre-existing gaps
  are addressed alongside: a `DeviceCodeOAuthFlow` type and its
  `OAuthFlows` member.
- `a2a/tests/` — new REST request-shape, binding-selection, streaming,
  error-mapping, and cross-binding equivalence tests (see §Testing).

## Testing

- **Unit tests** (mock-based, `tests/`, following `testutil.bal`
  conventions): for each of the 11 operations, assert the exact method,
  path, query string, and body the REST binding emits — including the
  tenant-prefixed path variants, and the path/body duplication of M3/M4,
  which are easy to "fix" by accident.
- **Binding-selection tests**: `selectInterface`/`primaryUrl` against
  cards with JSONRPC-only, HTTP+JSON-only, both (order varied), and
  legacy-`url`-only shapes; assert the legacy fallback stays
  JSONRPC-only, and that the tenant returned comes from the same entry as
  the url.
- **Streaming tests**: bare-`StreamResponse` SSE decoding (no envelope),
  an `event: error` frame mapping to a typed error, terminal-state close
  behaviour matching the JSON-RPC binding, and a non-`text/event-stream`
  rejection response routed through the REST error parser.
- **Error-mapping tests**: one per `reason` in the table, plus the
  status-only fallbacks, asserting both the error *type* and the
  synthesized `detail.code`. The three-way `400` disambiguation
  (`TASK_NOT_CANCELABLE` / `UNSUPPORTED_OPERATION` /
  `VERSION_NOT_SUPPORTED`) is the highest-value case here.
- **Equivalence tests**: the strongest available check that the binding
  is invisible to callers — run the same scripted scenario against a
  JSON-RPC mock and a REST mock and assert identical returned values and
  identical error types/codes.
- **Interop verification, and its current gap**: none of the reference
  agents used by this project so far (`helloworld`, `adk_currency_agent`,
  the langgraph agent) is known to advertise an `HTTP+JSON` interface.
  Until one does, this binding is mock-verified only — a strictly weaker
  position than the JSON-RPC binding, which has real-server coverage.
  Implementation should first re-check each reference agent's card for an
  `HTTP+JSON` entry, and if none exists, record the gap in the interop
  repo's findings the same way the push-notification CRUD gap was
  recorded. `SubscribeToTask`'s GET-vs-POST divergence is worth
  confirming here rather than by mock (a mock implements whatever the
  client sends), though the reference server accepting both verbs makes
  this a low-likelihood risk rather than a blocking one.
- **`SubscribeToTask` verb-fallback test**: a mock that rejects GET with
  `404`/`405`/`501` and accepts POST, asserting the single retry fires
  and that it does *not* fire for any other operation. Mock-only by
  nature — this path exists for hypothetical non-reference servers, so
  it cannot be exercised against the reference server, which routes GET.
