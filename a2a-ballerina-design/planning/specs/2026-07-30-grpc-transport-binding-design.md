# gRPC transport binding — design

## Context

The A2A specification defines three standard transport bindings —
`JSONRPC`, `GRPC`, and `HTTP+JSON` — and an agent advertises which it
serves via `AgentCard.supportedInterfaces[].protocolBinding`. This
library's `Client` speaks only `JSONRPC` today.
`docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md`
(Task 8) covers `HTTP+JSON`. This document covers the third and last one,
`GRPC`, and is deliberately written to sit *on top of* the Task 8 design
rather than beside it: binding selection, the `A2AError` hierarchy, and
the "one `Client`, invisible binding" principle are all inherited
unchanged. Where this design diverges from Task 8, it says so and says
why.

`GRPC` was explicitly deferred out of Task 8 with the note that it "needs
protobuf codegen and an `http2`/grpc client stack rather than
`http:Client`, which is a materially different effort from 'same JSON,
different framing'." That assessment turned out to be correct, and the
empirical work below quantifies it: gRPC is not a reframing of the same
JSON, it is a second type system that has to be marshalled to and from
`types.bal`.

Server/listener support remains out of scope, consistent with every
other spec in this directory.

## Research performed for this design

### Step 1 — the codegen experiment (run, not reasoned about)

Everything in this section was produced by actually running the
toolchain, in a scratch directory outside this repository. Nothing here
is inferred from documentation.

**Environment.** Ballerina `2201.13.4` (Swan Lake Update 13),
`bal grpc` tool version `1.0.0` (already installed; no
`bal tool pull grpc` was needed), `ballerina/grpc:1.14.7`,
`protoc 3.21.7` (downloaded automatically by the tool on first run).

**Proto provenance.** `specification/a2a.proto` fetched from
`a2aproject/A2A` via `gh api repos/a2aproject/A2A/contents/specification/a2a.proto --jq '.content' | base64 -d`
(the raw-bytes route, because a prior task in this plan found WebFetch
returns summarised rather than literal content for some sources). 812
lines. Blob SHA `2814f0f9a8a3db0fa1976dd4aece8ce38700a0bf`, last touched
by commit `cfc9d34bc41e368827eb6446d31f912e44f795c5` (2026-07-21).
`package lf.a2a.v1`, `service A2AService`, 11 rpcs.

#### Finding 1 (the load-bearing one) — server-streaming returns exactly the shape we already use

**`bal grpc` generates `stream<StreamResponse, grpc:Error?>` for both
server-streaming rpcs.** Verbatim, from the generated
`a2a_pb.bal`:

```ballerina
isolated remote function SendStreamingMessage(SendMessageRequest|ContextSendMessageRequest req)
        returns stream<StreamResponse, grpc:Error?>|grpc:Error {
    ...
    var payload = check self.grpcClient->executeServerStreaming("lf.a2a.v1.A2AService/SendStreamingMessage", message, headers);
    [stream<anydata, grpc:Error?>, map<string|string[]>] [result, _] = payload;
    StreamResponseStream outputStream = new StreamResponseStream(result);
    return new stream<StreamResponse, grpc:Error?>(outputStream);
}
```

`SubscribeToTask` is byte-for-byte the same modulo the request type and
method path. The generated `main` sample (`a2aservice_client.bal`) binds
both results to a `stream<StreamResponse, error?>` variable and calls
`.forEach` on it:

```ballerina
stream<StreamResponse, error?> sendStreamingMessageResponse = check ep->SendStreamingMessage(sendStreamingMessageRequest);
```

which is legal because `grpc:Error?` is a subtype of `error?`, so
`stream<T, grpc:Error?>` is assignable to `stream<T, error?>`.

**Consequence:** `sendMessageStream` and `subscribeToTask` keep their
current public return type `stream<StreamResponse, error?>` with **zero
signature change**. The only work is a per-element adapter (§Design
decision 4), because the *element type* is a different `StreamResponse`
(the generated one) from the library's. The stream *shape* — including
`close()` and error-termination semantics — carries over unchanged, and
so does everything built on it: `A2AStreamGenerator`'s terminal-state
close logic, and the reconnecting wrapper added for
`maxReconnectAttempts`.

This was the single open unknown the plan flagged. It is resolved, and
resolved favourably.

#### Finding 2 — the stub does not compile as generated

The generated package fails `bal build` on **two independent defects**.
Both were reproduced, and both have confirmed workarounds.

*Defect A — dangling dependent-descriptor constants.* `a2a.proto`
imports `google/api/annotations.proto`, `google/api/client.proto`, and
`google/api/field_behavior.proto` for its HTTP/method-signature
annotations. Those are not bundled with the tool, so the first run fails
outright:

```
google/api/client.proto: File not found.
google/api/field_behavior.proto: File not found.
```

Supplying them (fetched from `googleapis/googleapis`) got codegen to
succeed, but the emitted stub then contains:

```ballerina
public const map<string> A2A_DESCRIPTOR_MAP = {"google/api/client.proto": GOOGLE_API_CLIENT_DESC, "google/api/field_behavior.proto": GOOGLE_API_FIELD_BEHAVIOR_DESC};
```

— referencing two constants the tool never generated:

```
ERROR [a2a_pb.bal:(7:75,7:97)] undefined symbol 'GOOGLE_API_CLIENT_DESC'
ERROR [a2a_pb.bal:(7:134,7:164)] undefined symbol 'GOOGLE_API_FIELD_BEHAVIOR_DESC'
```

There was also an environment-level wrinkle worth recording so nobody
re-debugs it: `--proto-path` notwithstanding, protoc is ultimately
invoked with the *JVM temp directory* as a proto path for dependent
imports, so the `google/api/*.proto` files had to be physically placed
at `$TMPDIR/google/api/` before the dependent-descriptor pass would
resolve them.

*Defect B — `google.protobuf.Value` is not mapped.* `Part.data` is a
`google.protobuf.Value`. The tool emits a reference to a type it never
defines and never imports:

```
ERROR [a2a_pb.bal:(1010:5,1010:26)] unknown type 'google_protobuf_Value'
```

(`google.protobuf.Struct` *is* handled — it maps to `map<anydata>`.
`Value` is the gap.)

*Confirmed resolution.* Both defects were fixed and the result compiled
clean:

1. Vendor an **annotation-stripped** copy of `a2a.proto`: drop the three
   `google/api/*` imports and every `(google.api.http)`,
   `(google.api.method_signature)`, and `(google.api.field_behavior)`
   option. These are HTTP-transcoding and documentation annotations
   only — they contribute nothing to the gRPC wire format or to the
   generated Ballerina types. Stripping them removes Defect A entirely,
   including the `$TMPDIR` wrinkle: the vendored proto then imports only
   `google/protobuf/{empty,struct,timestamp}.proto`, which the tool does
   bundle.
2. Post-process the generated file, rewriting `google_protobuf_Value` to
   `anydata` (2 occurrences: the `Part.data` field declaration and the
   `setPart_Data` helper).

Verified to **compile clean** — and no more than that:

```
$ bal grpc --input vend/a2a.proto --proto-path vend --output out3
Successfully generated the Ballerina file.
$ bal build            # after the google_protobuf_Value -> anydata rewrite
Compiling source
        scratch/grpcstubtest2:0.1.0
Generating executable
        target\bin\grpcstubtest2.jar
```

Two mechanical steps, both deterministic, both scriptable. This is what
drives the codegen-workflow decision in §Design decision 1.

**What that result does *not* establish, and why it matters.** The above
is a compilation result. The wire behaviour of the rewritten field is
**not yet exercised.** The `google_protobuf_Value` → `anydata` rewrite
changes only the *Ballerina* field type; `A2A_DESCRIPTOR_MAP` still
declares `Part.data` as a `google.protobuf.Value` on the wire. At runtime
the protobuf marshaller is therefore handed a Ballerina type the
descriptor does not describe. `bal build` cannot detect that — only an
actual round trip of a `Part` carrying non-nil `data` can. The workaround
may serialize incorrectly, or panic, on the first such `Part`.

Every other `Part` variant (`text`, `raw`, `url`, plus `filename` /
`media_type` / `metadata`) is untouched by the rewrite and carries no
such risk. This is the single largest unvalidated assumption in this
design: it is recorded as Known limitation 3 and gated by a mandatory
test in §Testing that implementation must clear before building anything
on top of the stub.

> **Update (2026-08-02) — this section's diagnosis was incomplete; see
> Known limitation 3 for the resolved account.** The gate test was written
> and did fail at runtime. The cause was *not* the `anydata` rewrite
> handing the marshaller an undescribed type. It was that
> `initStub(self, A2A_DESC)` supplies no dependency descriptor map, so
> `google/protobuf/struct.proto` never resolved and `google.protobuf.Value`
> became a protobuf *placeholder* descriptor that `ballerina/grpc`'s
> `StandardDescriptorBuilder` has no message-name entry for — whereas
> `google.protobuf.Struct` does have one, which is precisely why
> `metadata`/`params`/`header` worked and `data` did not. Supplying the
> struct.proto descriptor fixes it; `anydata` turns out to be the correct
> Ballerina type for a `Value` all along. Known limitation 3 has the full
> analysis.

#### Finding 3 — ~22 generated type names collide with `types.bal`

The stub declares `Task`, `Message`, `Part`, `Artifact`, `TaskStatus`,
`AgentCard`, `AgentInterface`, `AgentCapabilities`, `AgentSkill`,
`AgentProvider`, `AgentExtension`, `AgentCardSignature`,
`StreamResponse`, `TaskStatusUpdateEvent`, `TaskArtifactUpdateEvent`,
`TaskPushNotificationConfig`, `AuthenticationInfo`,
`SendMessageConfiguration`, `SecurityScheme`, `SecurityRequirement`,
`OAuthFlows`, and the enums `Role` and `TaskState` — **all** public,
**all** already defined in `a2a/types.bal`. (The generated request
messages — `GetTaskRequest`, `CancelTaskRequest`, and so on — do *not*
collide; they have no `types.bal` counterpart. The collisions are
concentrated in the domain types, which is exactly the set the
conversion layer touches.) The stub therefore cannot be dropped into the
root module; it must live in its own submodule. See §Design decision 1.

#### Finding 4 — generated records are structurally incompatible with `types.bal`

This is what settles the `encodeGrpc*`/`decodeGrpc*` question
(§Design decision 5). Six categories of mismatch, all read directly off
the generated file:

**(a) snake_case, not camelCase.** `message_id`, `context_id`,
`task_id`, `media_type`, `reference_task_ids`, `artifact_id`,
`status_update`, `artifact_update`, `next_page_token`, `page_size`,
`total_size`, `history_length`, `accepted_output_modes`,
`return_immediately`, `task_push_notification_config`,
`status_timestamp_after`, `include_artifacts`, `protocol_binding`,
`protocol_version`, `last_chunk`, `input_modes`, `output_modes`,
`security_requirements`, `security_schemes`, `supported_interfaces`,
`default_input_modes`, `default_output_modes`, `documentation_url`,
`icon_url`, `extended_agent_card`, `push_notifications`, `bearer_format`,
`open_id_connect_url`, `oauth2_metadata_url`, `authorization_url`,
`token_url`, `refresh_url`, `pkce_required`, `device_authorization_url`,
`authorization_code`, `client_credentials`, `device_code`.

This is the exact opposite of the REST finding. Task 8 concluded that
REST needs **no** renaming layer because protojson lower-camelCases
proto field names, which already match `types.bal` 1:1. The generated
gRPC records skip protojson entirely and keep the proto's own
snake_case, so a renaming layer is mandatory here.

**(b) closed records with no rest field.** Every generated record is
`record {| ... |}` with no `json...;`. `types.bal`'s records are all
open, deliberately, so a newer-spec field survives a round trip. The
generated types drop unknown fields on the floor by construction (this
is inherent to protobuf, not a codegen choice) — noted as a real, if
unavoidable, capability difference between the bindings.

**(c) presence is encoded as a sentinel default, not as nil.** Proto3
non-`optional` scalars and messages generate as required Ballerina
fields with defaults: `string context_id = ""`, `TaskStatus status = {}`,
`Message message = {}`, `Artifact[] artifacts = []`. `types.bal` models
the same fields as `string? contextId?`. A decode step must normalise
`""` → `()` for the string cases and must *not* fabricate a nested
`Message`/`TaskStatus` from an all-defaults value. Only proto3
`optional` fields generate as Ballerina optional fields
(`int history_length?`, `int page_size?`, `boolean include_artifacts?`,
`boolean streaming?`, `string documentation_url?`).

**(d) `map<K,V>` becomes an array of key/value records.** Confirmed:

```ballerina
public type AgentCard record {|
    ...
    record {|string key; SecurityScheme value;|}[] security_schemes = [];
|};
public type SecurityRequirement record {|
    record {|string key; StringList value;|}[] schemes = [];
|};
public type AuthorizationCodeOAuthFlow record {|
    ...
    record {|string key; string value;|}[] scopes = [];
|};
```

`types.bal` models all three as real maps (`map<SecurityScheme>`,
`map<string[]>` semantics, `map<string> scopes`). Every one needs an
explicit array↔map conversion. `google.protobuf.Struct` fields
(`metadata`, `params`, `header`) fare better — they map to
`map<anydata>`, close to `map<json>?`, but `anydata` is wider than
`json` and still needs a guarded conversion.

**(e) `google.protobuf.Timestamp` becomes `time:Utc`.**
`TaskStatus.timestamp` generates as `time:Utc timestamp = [0, 0.0d]` — a
`[int, decimal]` tuple. `types.bal` stores `string? timestamp?` (RFC
3339). Conversion via `time:utcToString`/`time:utcFromString`, with the
`[0, 0.0d]` default treated as "absent" rather than as the Unix epoch.
Same for `ListTasksRequest.status_timestamp_after`.

**(f) the two things that *do* line up.** The enums are identical —
generated `Role` is `ROLE_UNSPECIFIED, ROLE_USER, ROLE_AGENT` and
generated `TaskState` is `TASK_STATE_UNSPECIFIED …
TASK_STATE_AUTH_REQUIRED`, matching `types.bal`'s members verbatim, so
enums pass through by name. And the `oneof` wrappers land where the plan
predicted:

```ballerina
public type SendMessageResponse record {| Task task?; Message message?; |};
public type StreamResponse record {|
    Task task?; Message message?;
    TaskStatusUpdateEvent status_update?; TaskArtifactUpdateEvent artifact_update?;
|};
```

The plan's carried-forward claim that these are "the same shape as the
JSON-RPC result union `client.bal` already parses" is **confirmed at the
union level** — same four members, same mutual exclusivity, generated as
optional fields exactly like `types.bal`'s `StreamResponse` and
`SendMessageResult`. It is **not** true at the field level: the members
are named `status_update`/`artifact_update` rather than
`statusUpdate`/`artifactUpdate`, and their payload records carry every
mismatch in (a)–(e). So the existing `Task`/`Message`/
`TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent` types are reusable as
the *destination* of a conversion — which is the reuse that matters, and
is why the public API doesn't change — but not as the direct decode
target.

#### Finding 5 — `ballerina/grpc` exposes no status details / trailing metadata

Read directly from `ballerina/grpc:1.14.7`'s `grpc_errors.bal`: every
error type is `distinct Error` where `public type Error distinct error`
— a plain error with **no detail record**. Grepping the whole module for
`trailer`, `Trailer`, `ErrorInfo`, and `errorDetail` returns nothing.

The module does map gRPC status codes onto 16 distinct Ballerina error
types (`CancelledError`, `UnKnownError`, `InvalidArgumentError`,
`DeadlineExceededError`, `NotFoundError`, `AlreadyExistsError`,
`PermissionDeniedError`, `UnauthenticatedError`,
`ResourceExhaustedError`, `FailedPreconditionError`, `AbortedError`,
`OutOfRangeError`, `UnimplementedError`, `InternalError`,
`UnavailableError`, `DataLossError`), so status-code granularity is
available. The module declares four further `Error` subtypes
(`ResiliencyError`, `StreamClosedError`, `DataMismatchError`,
`ClientAuthError`) but these are client-side conditions, not status-code
mappings. What is *not* available is the
`google.rpc.ErrorInfo.reason` string that Task 8 relies on to
disambiguate errors sharing a status. This is the one place where the
gRPC binding is strictly less faithful than the other two, and
§Design decision 6 deals with it head-on rather than papering over it.

## The 11 rpcs and their messages

Service `A2AService`, `package lf.a2a.v1`. Field names below are the
proto's own snake_case — which, per Finding 4(a), is also exactly what
the generated Ballerina records use, so this table doubles as the
generated-type reference.

| # | rpc | Request message | Response message |
|---|---|---|---|
| 1 | `SendMessage` | `SendMessageRequest` | `SendMessageResponse` |
| 2 | `SendStreamingMessage` | `SendMessageRequest` | `stream StreamResponse` |
| 3 | `GetTask` | `GetTaskRequest` | `Task` |
| 4 | `ListTasks` | `ListTasksRequest` | `ListTasksResponse` |
| 5 | `CancelTask` | `CancelTaskRequest` | `Task` |
| 6 | `SubscribeToTask` | `SubscribeToTaskRequest` | `stream StreamResponse` |
| 7 | `CreateTaskPushNotificationConfig` | `TaskPushNotificationConfig` | `TaskPushNotificationConfig` |
| 8 | `GetTaskPushNotificationConfig` | `GetTaskPushNotificationConfigRequest` | `TaskPushNotificationConfig` |
| 9 | `ListTaskPushNotificationConfigs` | `ListTaskPushNotificationConfigsRequest` | `ListTaskPushNotificationConfigsResponse` |
| 10 | `GetExtendedAgentCard` | `GetExtendedAgentCardRequest` | `AgentCard` |
| 11 | `DeleteTaskPushNotificationConfig` | `DeleteTaskPushNotificationConfigRequest` | `google.protobuf.Empty` |

Note #7: the create rpc's *request message is the resource itself*, not a
dedicated `Create…Request` — the same asymmetry Task 8 recorded for
REST (its M4).

### Request message fields

| Message | Fields (proto order) |
|---|---|
| `SendMessageRequest` | `tenant`, `message` (REQUIRED), `configuration`, `metadata` (Struct) |
| `GetTaskRequest` | `tenant`, `id` (REQUIRED), `optional history_length` |
| `ListTasksRequest` | `tenant`, `context_id`, `status` (TaskState), `optional page_size`, `page_token`, `optional history_length`, `status_timestamp_after` (Timestamp), `optional include_artifacts` |
| `CancelTaskRequest` | `tenant`, `id` (REQUIRED), `metadata` (Struct) |
| `SubscribeToTaskRequest` | `tenant`, `id` (REQUIRED) |
| `TaskPushNotificationConfig` (also the create request) | `tenant`, `id`, `task_id`, `url` (REQUIRED), `token`, `authentication` |
| `GetTaskPushNotificationConfigRequest` | `tenant`, `task_id` (REQUIRED), `id` (REQUIRED) |
| `ListTaskPushNotificationConfigsRequest` | `task_id` (REQUIRED, field 1), `page_size` (2), `page_token` (3), `tenant` (**field 4**) |
| `DeleteTaskPushNotificationConfigRequest` | `tenant`, `task_id` (REQUIRED), `id` (REQUIRED) |
| `GetExtendedAgentCardRequest` | `tenant` |

`ListTaskPushNotificationConfigsRequest` is the one message where
`tenant` is not field 1 — it was appended as field 4. Irrelevant to
Ballerina codegen (fields are named, not positional, in the generated
record) but recorded because it is the sort of thing that looks like a
transcription error later.

### Response message fields

| Message | Fields |
|---|---|
| `SendMessageResponse` | `oneof payload { Task task = 1; Message message = 2; }` |
| `StreamResponse` | `oneof payload { Task task = 1; Message message = 2; TaskStatusUpdateEvent status_update = 3; TaskArtifactUpdateEvent artifact_update = 4; }` |
| `ListTasksResponse` | `tasks` (repeated), `next_page_token`, `page_size`, `total_size` |
| `ListTaskPushNotificationConfigsResponse` | `configs` (repeated), `next_page_token` |
| `Task` | `id`, `context_id`, `status`, `artifacts` (repeated), `history` (repeated), `metadata` (Struct) |
| `TaskStatus` | `state` (TaskState), `message`, `timestamp` (Timestamp) |
| `Message` | `message_id`, `context_id`, `task_id`, `role` (Role), `parts` (repeated), `metadata` (Struct), `extensions` (repeated), `reference_task_ids` (repeated) |
| `Part` | `oneof content { text = 1; raw = 2 (bytes); url = 3; data = 4 (Value); }` plus non-oneof `metadata` (Struct, 5), `filename` (6), `media_type` (7) |
| `Artifact` | `artifact_id`, `name`, `description`, `parts` (repeated), `metadata` (Struct), `extensions` (repeated) |
| `TaskStatusUpdateEvent` | `task_id`, `context_id`, `status`, `metadata` (Struct) |
| `TaskArtifactUpdateEvent` | `task_id`, `context_id`, `artifact`, `append`, `last_chunk`, `metadata` (Struct) |
| `AuthenticationInfo` | `scheme`, `credentials` |
| `AgentCard` | `name`, `description`, `supported_interfaces` (repeated `AgentInterface`), `provider`, `version`, `capabilities`, `security_schemes` (map), `security_requirements` (repeated), `default_input_modes`, `default_output_modes`, `skills` (repeated), `signatures` (repeated), `optional documentation_url`, `optional icon_url` |
| `AgentInterface` | `url`, `protocol_binding`, `tenant`, `protocol_version` |

### Supporting message fields

These are the messages the conversion functions in §Design decision 5
depend on but that no rpc names directly. They are tabulated here for the
same reason as the rest: so an implementer never has to go back to the
proto.

| Message | Fields |
|---|---|
| `SendMessageConfiguration` | `accepted_output_modes` (repeated string, 1), `task_push_notification_config` (2), `optional history_length` (int32, 3), `return_immediately` (bool, 4) |
| `AgentCapabilities` | `optional streaming` (bool, 1), `optional push_notifications` (bool, 2), `extensions` (repeated `AgentExtension`, 3), `optional extended_agent_card` (bool, 4) |
| `AgentSkill` | `id` (REQUIRED), `name` (REQUIRED), `description` (REQUIRED), `tags` (repeated, REQUIRED), `examples` (repeated), `input_modes` (repeated), `output_modes` (repeated), `security_requirements` (repeated `SecurityRequirement`) |
| `AgentProvider` | `url` (REQUIRED), `organization` (REQUIRED) |
| `AgentExtension` | `uri`, `description`, `required` (bool), `params` (Struct) |
| `AgentCardSignature` | `protected` (REQUIRED), `signature` (REQUIRED), `header` (Struct) |
| `SecurityRequirement` | `schemes` — `map<string, StringList>` |
| `StringList` | `list` (repeated string) |

`AgentCapabilities` is worth a second look: all three booleans are proto3
`optional`, so they generate as Ballerina *optional* fields
(`boolean streaming?`), whereas `types.bal` declares them as required
with `= false` defaults. Decode must treat an absent field as `false`,
and encode must not emit `false` as an explicit presence signal — a
server distinguishing "not declared" from "declared false" would
otherwise see the wrong thing.

### The `SecurityScheme` oneof and its five arms

`decodeGrpcAgentCard` is called the largest single function in
§Design decision 5 precisely because of this subtree, so it is spelled
out in full.

```proto
message SecurityScheme {
  oneof scheme {
    APIKeySecurityScheme api_key_security_scheme = 1;
    HTTPAuthSecurityScheme http_auth_security_scheme = 2;
    OAuth2SecurityScheme oauth2_security_scheme = 3;
    OpenIdConnectSecurityScheme open_id_connect_security_scheme = 4;
    MutualTlsSecurityScheme mtls_security_scheme = 5;
  }
}
```

| Arm message | Fields |
|---|---|
| `APIKeySecurityScheme` | `description`, `location` (REQUIRED), `name` (REQUIRED) |
| `HTTPAuthSecurityScheme` | `description`, `scheme` (REQUIRED), `bearer_format` |
| `OAuth2SecurityScheme` | `description`, `flows` (`OAuthFlows`, REQUIRED), `oauth2_metadata_url` |
| `OpenIdConnectSecurityScheme` | `description`, `open_id_connect_url` (REQUIRED) |
| `MutualTlsSecurityScheme` | `description` |

`OAuthFlows` is itself a five-member oneof, two arms deprecated:

```proto
message OAuthFlows {
  oneof flow {
    AuthorizationCodeOAuthFlow authorization_code = 1;
    ClientCredentialsOAuthFlow client_credentials = 2;
    ImplicitOAuthFlow implicit = 3 [deprecated = true];
    PasswordOAuthFlow password = 4 [deprecated = true];
    DeviceCodeOAuthFlow device_code = 5;
  }
}
```

| Flow message | Fields |
|---|---|
| `AuthorizationCodeOAuthFlow` | `authorization_url` (REQUIRED), `token_url` (REQUIRED), `refresh_url`, `scopes` (`map<string,string>`, REQUIRED), `pkce_required` (bool) |
| `ClientCredentialsOAuthFlow` | `token_url` (REQUIRED), `refresh_url`, `scopes` (map, REQUIRED) |
| `ImplicitOAuthFlow` | `authorization_url`, `refresh_url`, `scopes` (map) |
| `PasswordOAuthFlow` | `token_url`, `refresh_url`, `scopes` (map) |
| `DeviceCodeOAuthFlow` | `device_authorization_url` (REQUIRED), `token_url` (REQUIRED), `refresh_url`, `scopes` (map, REQUIRED) |

Three things fall out of this subtree that the conversion layer must
handle and that are easy to miss:

- **Every `scopes` field is a proto map**, so it arrives as
  `record {|string key; string value;|}[]` (Finding 4d) and must be
  converted to `types.bal`'s `map<string> scopes`. Five occurrences.
- **`SecurityRequirement.schemes` is a map to `StringList`**, i.e. a
  key/value array whose values are themselves single-field wrapper
  records. Two unwrapping steps, not one.
- **`OAuthFlows.device_code` exists in the proto.** Task 8's M2 recorded
  that `types.bal`'s `OAuthFlows` declares only four of the five flows
  and that `device_code` survives on the JSON bindings as untyped `json`
  via the open record. That escape hatch **does not exist over gRPC** —
  the generated records are closed (Finding 4b), so a device-code flow is
  dropped outright. If M2 is fixed by adding a `DeviceCodeOAuthFlow` type
  to `types.bal`, this becomes a non-issue for all three bindings at
  once; until then it is a gRPC-specific data loss, not merely a missing
  typed accessor.

`Part`'s `raw` is `bytes` on the wire — genuinely binary under protobuf,
with no base64 step. Task 8's M1 (the untested base64 round-trip
assumption for REST/JSON-RPC) simply does not arise for gRPC; the
generated field is `byte[] raw?`, matching `types.bal`'s `byte[]? raw?`
directly. This is the one place the gRPC binding is *more* faithful than
the JSON ones.

## Design decision 1 — codegen workflow: vendored proto, checked-in stub, script-driven regeneration

**Decision: check in a vendored, annotation-stripped `a2a.proto` and the
generated stub, and regenerate via a documented script. Do not wire
codegen into `bal build`.**

Layout:

```
a2a/proto/a2a.proto            # vendored, annotation-stripped
a2a/proto/PROVENANCE.md        # upstream repo, path, blob SHA, commit SHA, date, strip rules
a2a/modules/grpcstub/a2a_pb.bal  # generated + post-processed; checked in
a2a/scripts/regen-grpc-stub.sh   # fetch -> strip -> bal grpc -> post-process -> diff
```

Regeneration command, exactly as verified:

```bash
bal grpc --input a2a/proto/a2a.proto \
         --proto-path a2a/proto \
         --output a2a/modules/grpcstub
# then: rewrite google_protobuf_Value -> anydata (2 occurrences)
```

`--mode client` is deliberately **omitted**. With `--mode client` the
tool additionally emits `a2aservice_client.bal`, a sample `main()` that
constructs a client against `http://localhost:9090` and calls every rpc
with `"ballerina"` placeholders. It was invaluable for Finding 1 and is
useless in the package. Without `--mode`, only the stub is generated —
and the stub is where `A2AServiceClient` lives anyway.

Why each part:

- **Why a vendored proto rather than fetching upstream at build time.**
  Builds must be reproducible and offline-capable, and the vendored copy
  is not byte-identical to upstream anyway (annotations stripped, per
  Finding 2). `PROVENANCE.md` carries the upstream blob and commit SHA
  so drift is detectable with one `gh api` call.
- **Why strip the annotations rather than vendor `google/api/*` too.**
  Vendoring the googleapis protos does not fix Defect A — codegen still
  emits references to `GOOGLE_API_CLIENT_DESC` /
  `GOOGLE_API_FIELD_BEHAVIOR_DESC` that it never defines, and the build
  still fails. Stripping was the only route that produced a compiling
  package. The annotations are HTTP-transcoding metadata with no effect
  on the gRPC wire format or the generated types; Task 8's design
  already captured the `(google.api.http)` content it needed, in its own
  operation→HTTP table, so nothing is lost by dropping them here.
- **Why check the stub in rather than generate it at build time.** This
  is the explicit call the brief asked for. A `[[tool.grpc]]`
  `Ballerina.toml` entry would re-run codegen on every `bal build` and
  regenerate the *broken* `google_protobuf_Value` reference every time,
  breaking the build unless the post-processing step also ran — which a
  declarative toml entry cannot express. Checking the stub in also keeps
  `bal build` hermetic: no protoc download, no network, no `$TMPDIR`
  dependency. The cost is that the stub must be regenerated by hand when
  the spec moves; the script plus `PROVENANCE.md` make that a
  three-minute, reviewable diff.
- **Why a submodule (`modules/grpcstub`) and not the root module.**
  Forced by Finding 3: ~22 name collisions with `types.bal`. The stub
  imports only `ballerina/{grpc, protobuf, protobuf.types.empty, time}`
  and never the root module, so there is no cyclic dependency — the same
  arrangement `modules/transport` already uses. The root module imports
  it as `ballerina/a2a.grpcstub` and refers to generated types as
  `grpcstub:Task`, `grpcstub:StreamResponse`, and so on, which also
  makes every conversion site self-documenting about which side of the
  boundary it is on.
- **Why the script also diffs.** So CI can run it and fail if the
  checked-in stub is stale relative to the vendored proto. That is a
  cheap guard against the one failure mode this arrangement introduces.

**The `google_protobuf_Value` post-processing step is a known
liability.** It is a `sed`-equivalent rewrite of tool output, and it will
silently stop applying if a future `bal grpc` fixes the bug and emits a
proper type. The script must therefore *assert* the rewrite matched
(exactly 2 occurrences) and fail loudly on 0, rather than proceeding.
Filing the `google.protobuf.Value` gap upstream against `bal grpc` is
worth doing regardless.

## Design decision 2 — binding selection: reuse Task 8's mechanism verbatim

**Decision: extend Task 8's `TransportBinding` union with `"GRPC"`. Add
no new selection mechanism.**

Task 8 settled on a defaulted `preferredBinding` parameter plus a
`selectInterface` function returning the whole matched `AgentInterface`.
That generalises to a third binding with a one-token change:

```ballerina
public type TransportBinding "JSONRPC"|"HTTP+JSON"|"GRPC";

public isolated function primaryUrl(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns string|error;

public isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns AgentInterface|error;

public isolated function detectProtocolModeForBinding(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns ProtocolMode;
```

Everything Task 8 argued for these applies unchanged and is not
re-argued here: the defaulted parameter keeps `primaryUrl` source- and
behaviour-compatible for existing callers; `selectInterface` exists
because a binding needs the matched interface's `tenant` and
`protocolVersion`, not just its URL; the legacy `card.url` fallback stays
`JSONRPC`-only (a pre-v1.0 bare `url` cannot be a gRPC endpoint);
`detectProtocolModeForBinding` exists because reading
`supportedInterfaces[0].protocolVersion` pairs one interface's version
with another's URL on a mixed card. Task 8's worked example of that bug
holds verbatim with `"GRPC"` substituted for `"HTTP+JSON"`.

`Client.init` gains the same defaulted `binding` parameter Task 8
specified — one parameter, three values, no second mechanism.

**gRPC-specific addition: the URL scheme.** A `GRPC` interface's `url` is
an `http://`/`https://` authority, and `grpc:Client` accepts exactly
that form (the generated sample uses `new ("http://localhost:9090")`),
so no rewriting is needed. If a card advertises a `grpc://` or
`grpcs://` scheme — non-normative but observed in the wild — `init`
normalises it to `http://`/`https://` rather than failing, since the
scheme carries no information `grpc:Client` doesn't already infer.

**v0.3 + gRPC is rejected at construction**, exactly as Task 8 rejects
v0.3 + REST, and for a stronger reason: `compat_v03.bal` is entirely a
JSON-shape translation layer (`v03MethodName` maps to v0.3 JSON-RPC
method strings; `encodeV03Part`/`parseV03Task` reshape JSON), none of
which has any meaning over protobuf. Constructing a `Client` with
`binding = "GRPC"` against a card that
`detectProtocolModeForBinding(card, "GRPC")` resolves to `V0_3` returns
`VersionNotSupportedError` from `init`.

## Design decision 3 — one `Client`, dispatch at the existing transport seam

**Decision: keep the single `Client` type and dispatch inside
`rpcCall`/`openSseStream`, exactly as Task 8 does. The eleven public
method bodies change by zero lines. No `GrpcClient` type.**

This is the least obvious call in this document, because gRPC has a
genuinely different client stack (`grpc:Client`, not `http:Client`) and
a genuinely different type system, so a separate client type is more
tempting here than it was for REST. It is still the wrong answer, and
the reasoning is worth stating.

`rpcCall`'s contract today is `(string method, map<json> params) returns
json|error` — "given an operation name and its v1.0 params as JSON,
return the unwrapped v1.0 result as JSON, or a typed `A2AError`." That
contract is *binding-neutral by construction*: it names an operation and
speaks the library's own v1.0 JSON vocabulary, not a wire format. The
`GRPC` branch honours it as follows:

```
map<json> params
   -> encodeGrpcRequest(operation, params)   // typed grpcstub:*Request
   -> grpcstub:A2AServiceClient->{Operation}Context(req, metadata)
   -> decodeGrpcResponse(operation, response) // back to v1.0 json
```

The eleven public methods then apply their existing
`cloneWithType(Task)` / `cloneWithType(ListTasksResult)` / v0.3 branch
untouched. All protobuf knowledge is confined to one new file,
`grpc_binding.bal`, plus the `modules/grpcstub` submodule.

**Why the proto→json→typed round trip is acceptable.** It looks like one
hop too many, and it isn't: the conversion code has to exist either way
(Finding 4), and this arrangement is the only one that keeps the binding
invisible to callers *and* keeps the eleven method bodies at zero
changes. The alternative — dispatching at the top of each public method
into typed gRPC siblings — would produce a `mode × binding` branch in
eleven functions, duplicate the tenant-resolution and v0.3 logic three
ways, and abandon precisely the property Task 8 established. The extra
`json` hop costs one `cloneWithType` per call; the alternative costs
eleven duplicated method bodies.

**Two things this decision does force, both small:**

- `Client` gains a `private final grpcstub:A2AServiceClient? grpcStub`
  field alongside `httpClient`. `init` constructs whichever the selected
  binding needs. Making `httpClient` nilable too is not worth it — a
  `GRPC` client still needs an `http:Client` for `resolveAgentCard`,
  which is fetched over plain HTTPS from `/.well-known/` regardless of
  binding.
- `openSseStream` should be renamed. Task 8 already gave it a second,
  non-JSON-RPC caller; with gRPC it acquires a third that involves no
  SSE at all. `openEventStream` describes what it actually does — return
  a `stream<StreamResponse, error?>` for a streaming operation — and the
  rename is private-to-`Client`, so it costs nothing.

  **Cross-plan note:** Task 8's spec refers to `openSseStream` by its
  current name throughout, and correctly so — REST does still use SSE. To
  keep the two follow-up implementation plans from colliding, the rename
  lands with whichever binding ships **second**, and the plan that ships
  first leaves the name alone. Either order works; doing it twice, or
  doing it first and stranding the other spec's references, does not.

**Auth and headers cross the seam cleanly.** `grpc:ClientConfiguration`
has its own `auth` field of type
`grpc:ClientAuthConfig = CredentialsConfig|BearerTokenConfig|JwtIssuerConfig|OAuth2GrantConfig`
— structurally the same union `http:ClientAuthConfig` offers, and both
of the scheme types `buildAuthFromCard` automates (HTTP basic → the
credentials shape, HTTP bearer → the bearer shape) are present in it.
`ResolvedAuth` therefore needs a small adapter that projects its
`http:ClientConfiguration.auth` onto `grpc:ClientConfiguration.auth`
rather than a second resolution path. `ResolvedAuth.headers` (the API-key
case) becomes per-call gRPC metadata, which is why the design uses the
generated `*Context` methods rather than the plain ones — see
§Design decision 4.

## Design decision 4 — streaming and metadata: use the `*Context` methods

**Decision: call the generated `…Context` variants for every operation,
not the plain ones.**

Every rpc is generated twice: `SendMessage(req)` returning the bare
response, and `SendMessageContext(req)` returning
`{content, headers}`. The `Context` form is what makes gRPC metadata
reachable in both directions:

- **Outbound.** `buildHeaders()` already assembles `A2A-Version`
  (mandatory per spec §3.6.1), `A2A-Extensions`, and any caller-supplied
  defaults plus the API-key header from `ResolvedAuth`. Over gRPC these
  become request metadata, supplied via the generated
  `Context{Operation}Request` record's `headers` field. `Content-Type`
  is dropped from the map for this binding — gRPC sets its own.
- **Inbound.** `captureGrantedExtensions` reads `A2A-Extensions` off
  the response (spec §14.2.2 uses the same header name in both
  directions). Only the `Context` variants surface response headers, so
  without them the extension-negotiation feature added earlier in this
  plan would silently stop working on the gRPC binding.

**The streaming adapter.** `SendStreamingMessageContext` returns
`ContextStreamResponseStream {stream<StreamResponse, error?> content;
map<string|string[]> headers;}` — note the tool declares this record's
field as `stream<StreamResponse, error?>`, i.e. already the library's
exact public shape, modulo the element type being `grpcstub:StreamResponse`.

So the adapter is a single stream-object class that mirrors the existing
`A2AStreamGenerator`:

```ballerina
class GrpcStreamAdapter {
    private stream<grpcstub:StreamResponse, error?> upstream;
    private boolean closed = false;

    public isolated function next() returns record {|StreamResponse value;|}|error? { ... }
    public isolated function close() returns error? { ... }
}
```

`next()` pulls one `grpcstub:StreamResponse`, runs it through
`decodeGrpcStreamResponse`, and applies the *same* `isTerminalEvent`
check `sse.bal` already uses, so terminal-state close semantics are
identical across all three bindings. Because the result is still a
`stream<StreamResponse, error?>`, the reconnecting wrapper behind
`maxReconnectAttempts` composes over it with no changes — it only ever
saw a stream and a `subscribeToTask` callback, both of which still hold.

`decodeEvent`'s JSON-RPC-envelope unwrapping — which Task 8 has to make
binding-aware for REST — is simply not on this path. gRPC has no
envelope, and `grpcstub:StreamResponse` arrives already framed and
typed. The gRPC binding is the *simplest* of the three at the stream
layer and the most involved at the type layer.

**Mid-stream errors** surface as a `grpc:Error` from
`upstream.next()`, which `GrpcStreamAdapter` runs through
`toA2AErrorFromGrpc` before returning — the exact analogue of Task 8
routing an `event: error` SSE frame through `toA2AErrorFromRest`.

## Design decision 5 — dedicated `encodeGrpc*`/`decodeGrpc*` conversion functions

**Decision: yes, dedicated conversion functions, mirroring
`compat_v03.bal`'s `encodeV03*`/`parseV03*` pattern. The generated types
cannot be used directly, and `cloneWithType` cannot bridge them.**

Finding 4 makes this unambiguous, and it is worth being explicit that
this is the *opposite* of Task 8's conclusion. Task 8 found REST needs no
conversion layer at all, because v1.0 REST bodies and v1.0 JSON-RPC
`params`/`result` bodies are literally the same JSON objects. gRPC is
the other extreme: field names differ (snake_case), map fields are
key/value arrays, timestamps are `time:Utc` tuples, absence is a
sentinel default rather than nil, and the records are closed. No amount
of `cloneWithType` bridges that — it would fail on the very first
`context_id`/`contextId` mismatch, and would silently mis-handle
`""`-as-absent even where names happened to align.

The precedent is exact. `compat_v03.bal` already solves a
same-concepts/different-encoding problem with paired, hand-written,
per-type functions (`parseV03Part`/`encodeV03Part`,
`parseV03Message`/`encodeV03Message`, `parseV03Task`,
`parseV03TaskStatus`, `parseV03Artifact`,
`parseV03TaskPushNotificationConfig`/`encodeV03TaskPushNotificationConfig`,
`decodeV03SendResult`, `decodeV03StreamEvent`), each small, each
individually testable, none relying on structural coincidence. The gRPC
layer gets the same treatment in a new `grpc_binding.bal`:

| Direction | Functions |
|---|---|
| encode (library → `grpcstub:`) | `encodeGrpcPart`, `encodeGrpcMessage`, `encodeGrpcSendConfiguration`, `encodeGrpcPushConfig`, plus one `encodeGrpc{Operation}Request` per rpc |
| decode (`grpcstub:` → library) | `decodeGrpcPart`, `decodeGrpcMessage`, `decodeGrpcTaskStatus`, `decodeGrpcArtifact`, `decodeGrpcTask`, `decodeGrpcStatusUpdate`, `decodeGrpcArtifactUpdate`, `decodeGrpcSendResult`, `decodeGrpcStreamResponse`, `decodeGrpcPushConfig`, `decodeGrpcListTasksResult`, `decodeGrpcListPushConfigsResult`, `decodeGrpcAgentCard` |
| shared helpers | `grpcKvToMap` / `mapToGrpcKv` (Finding 4d), `grpcTimestampToString` / `stringToGrpcTimestamp` (4e), `grpcStructToJson` / `jsonToGrpcStruct`, `emptyToNil` (4c) |

Five cross-cutting rules the helpers exist to enforce consistently:

1. **`""` decodes to `()`,** for every non-`optional` proto string that
   `types.bal` models as `string?`. Encoding does the reverse — `()`
   becomes `""`, which is what the proto wire format omits anyway.
2. **All-default nested messages decode to `()`.** A
   `TaskStatus.message` of `{}` means "no message", not "an empty
   message"; likewise `Task.status` on a partially-populated response.
3. **`time:Utc [0, 0.0d]` decodes to `()`,** not to
   `"1970-01-01T00:00:00Z"`. This is the highest-risk silent-corruption
   case in the whole layer and deserves its own test.
4. **Enums pass through by name** (Finding 4f) — the one place
   conversion is a genuine no-op, and worth a test asserting it stays
   that way if either enum gains a member.
5. **`Part.data` crosses a `json` ↔ `anydata` boundary, and the
   narrowing direction can fail.** This is the arm the
   `google_protobuf_Value` workaround touches, and it is the riskiest
   conversion in the layer, so its rule is stated separately from the
   rest.

   `types.bal` declares `json? data?` (`types.bal:22`); the rewritten
   stub declares `anydata data?`. The two directions are not symmetric:

   - **Encode (`json` → `anydata`) is total and lossless.** `json` is a
     strict subtype of `anydata`, so `encodeGrpcPart` assigns directly,
     with no check and no possibility of failure.
   - **Decode (`anydata` → `json`) is partial.** `anydata` admits values
     `json` does not — `xml`, `table`, `byte[]`, tuples, `decimal` in
     positions `json` disallows, and records that aren't
     `map<json>`-shaped. `decodeGrpcPart` must therefore attempt
     `value:cloneWithType(json)` (or equivalent) rather than cast, and
     **must not** silently coerce.

   **What happens when the narrowing fails.** `decodeGrpcPart` returns
   an `InvalidAgentResponseError` (code -32006) naming the offending
   part index and the actual runtime type. Rationale: a `data` value the
   library cannot represent as `json` *is* an agent response this client
   cannot honour, which is precisely what -32006 already means on the
   other two bindings — so no new error type, and callers handle it
   identically regardless of binding. The rejected alternatives were
   dropping `data` silently (turns a protocol error into missing user
   content) and stringifying it (fabricates a value the agent never
   sent).

   **How likely is the failure in practice?** A well-behaved server
   sends a `google.protobuf.Value`, whose value space is exactly JSON's
   — so on the happy path the narrowing always succeeds. The rule exists
   because the workaround has removed the type system's guarantee that
   this is what actually arrives: with the field typed `anydata`, nothing
   in the stub constrains what the marshaller can hand back. Which is the
   same reason Known limitation 3 exists, viewed from the conversion
   layer rather than the wire.

`decodeGrpcAgentCard` is the largest single function, because
`AgentCard.security_schemes` is a key/value array of a five-member
`oneof` (`SecurityScheme`), each arm of which has its own field
renaming, and `security_requirements` nests a second key/value array of
`StringList`. It is also the one that matters least in practice —
`GetExtendedAgentCard` is the only rpc that returns an `AgentCard`, and
the *primary* card is still fetched as JSON from `/.well-known/`
regardless of binding, so `parseAgentCardBody`'s tolerant handling stays
the main path.

One capability difference to accept explicitly: because the generated
records are closed (Finding 4b), a field from a newer spec version
survives a JSON-RPC or REST round trip via `types.bal`'s open records but
is dropped on the gRPC binding. That is inherent to protobuf, not a
design choice, but it should be documented in the client's user-facing
docs rather than discovered.

## Design decision 6 — error mapping, and its unavoidable fidelity loss

**Decision: map `grpc:Error` subtypes onto the existing `A2AError`
hierarchy by status code, synthesizing the JSON-RPC `code` where the
mapping is unambiguous. Where a status covers several A2A errors and no
`reason` is recoverable, map to the most probable member and preserve
the server's status message. No new error types.**

Task 8 established the normative mapping table (from `a2a-python`'s
`A2A_ERROR_MAPPING`), including its gRPC-status column. Reproduced here
with the Ballerina error type each status arrives as:

| A2A error | gRPC status | `ballerina/grpc` type | JSON-RPC code |
|---|---|---|---|
| TaskNotFoundError | NOT_FOUND | `grpc:NotFoundError` | -32001 |
| TaskNotCancelableError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32002 |
| PushNotificationNotSupportedError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32003 |
| UnsupportedOperationError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32004 |
| ContentTypeNotSupportedError | INVALID_ARGUMENT | `grpc:InvalidArgumentError` | -32005 |
| InvalidAgentResponseError | INTERNAL | `grpc:InternalError` | -32006 |
| ExtendedAgentCardNotConfiguredError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32007 |
| ExtensionSupportRequiredError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32008 |
| VersionNotSupportedError | FAILED_PRECONDITION | `grpc:FailedPreconditionError` | -32009 |
| *(InvalidParamsError)* | INVALID_ARGUMENT | `grpc:InvalidArgumentError` | -32602 |
| *(InvalidRequestError)* | INVALID_ARGUMENT | `grpc:InvalidArgumentError` | -32600 |
| *(MethodNotFoundError)* | NOT_FOUND | `grpc:NotFoundError` | -32601 |
| *(InternalError)* | INTERNAL | `grpc:InternalError` | -32603 |

**The problem, stated plainly.** Five distinct A2A errors share
FAILED_PRECONDITION and three share INVALID_ARGUMENT. Task 8 resolves
exactly this collision for REST by reading
`google.rpc.ErrorInfo.reason` out of the error body. Per Finding 5,
`ballerina/grpc:1.14.7` gives us **no access to status details or
trailing metadata** — `grpc:Error` is a bare `distinct error` with no
detail record. The disambiguator Task 8 depends on is unreachable from
this library.

**What this design does instead:**

```ballerina
# Maps a gRPC transport error onto the same A2AError hierarchy the
# JSON-RPC and REST bindings map onto. Status-code granularity only —
# see the fidelity note in the gRPC binding design doc.
isolated function toA2AErrorFromGrpc(grpc:Error err) returns A2AError;
```

Resolution order:

1. `grpc:NotFoundError` → `TaskNotFoundError` (code -32001). Safe: the
   only other NOT_FOUND member is `MethodNotFoundError`, which
   `toA2AError` already folds into `A2AInternalError` anyway, and which a
   correctly-generated client cannot provoke — the method path is
   compiled in.
2. `grpc:InvalidArgumentError` → `A2AInternalError` with code -32602
   (`INVALID_PARAMS`). Deliberately *not* `ContentTypeNotSupportedError`:
   invalid-params is by far the likelier cause, and -32602 is a code
   `toA2AError` already folds into `A2AInternalError`, so this arm is
   consistent with existing JSON-RPC behaviour rather than inventing a
   guess.
3. `grpc:FailedPreconditionError` → `UnsupportedOperationError`
   (code -32004). This is the one genuinely lossy arm.
   `UnsupportedOperationError` is chosen as the widest and most
   defensible of the five: it is the error a server returns for
   "this operation isn't available here," which subsumes the practical
   meaning of the push-notification and extended-card variants, and it
   is the least misleading thing to tell a caller who cannot be told the
   truth.
4. `grpc:InternalError`, `grpc:DataLossError`, `grpc:UnKnownError`,
   `grpc:AbortedError` → `A2AInternalError` (code -32603).
5. Everything else (`Unavailable`, `DeadlineExceeded`, `Cancelled`,
   `Unauthenticated`, `PermissionDenied`, `ResourceExhausted`,
   `Unimplemented`, `AlreadyExists`, `OutOfRange`) → `A2AInternalError`
   with the message preserved. These are transport-level conditions with
   no A2A error equivalent; inventing one would be worse than passing
   the gRPC message through.

Every arm sets `A2AErrorDetail.message` from the `grpc:Error`'s own
message, so the server's status description — which usually *does* say
"task is not cancelable" in words — reaches the caller even when the
type cannot.

**This limitation must be documented user-facing, not buried.** A caller
who writes `if e is TaskNotCancelableError` against a JSON-RPC client and
then switches that client to `binding = "GRPC"` will find the branch
never taken. That is a real behavioural difference between bindings, and
it is the one place this design fails the "binding is invisible to
callers" principle that Task 8 and this document otherwise hold to.

**Two ways out, both out of scope here, both worth recording.** (a) Ask
`ballerina/grpc` upstream to expose status details / trailing metadata on
`grpc:Error`; the moment it does, `toA2AErrorFromGrpc` gains a
`reason`-first resolution step identical to `toA2AErrorFromRest`'s and
the loss disappears. (b) Split `A2AError`'s FAILED_PRECONDITION members
by inspecting the status *message* text against known server phrasings —
rejected, because it would be matching on prose that no specification
constrains, and a wrong match is worse than an honest widening.

## Files touched

- `a2a/proto/a2a.proto` — new; vendored, annotation-stripped.
- `a2a/proto/PROVENANCE.md` — new; upstream SHAs, date, strip rules.
- `a2a/scripts/regen-grpc-stub.sh` — new; fetch → strip → `bal grpc` →
  post-process → assert-and-diff.
- `a2a/modules/grpcstub/a2a_pb.bal` — new; generated + post-processed,
  checked in. Not hand-edited beyond the scripted rewrite.
- `a2a/grpc_binding.bal` — new; all `encodeGrpc*`/`decodeGrpc*`
  functions, the shared helpers, and `GrpcStreamAdapter`.
- `a2a/client.bal` — `TransportBinding` gains `"GRPC"`; `Client` gains a
  `grpcStub` field and the gRPC arm of `init` (including URL-scheme
  normalisation and the v0.3+gRPC rejection); `rpcCall` and
  `openSseStream`→`openEventStream` gain the gRPC dispatch;
  `buildHeaders` grows a binding-aware `Content-Type` omission.
- `a2a/errors.bal` — new `toA2AErrorFromGrpc`.
- `a2a/auth.bal` — small adapter projecting `ResolvedAuth`'s
  `http:ClientConfiguration.auth` onto `grpc:ClientConfiguration.auth`.
- `a2a/compat_v03.bal` — no change beyond Task 8's already-specified
  `detectProtocolModeForBinding`, which is binding-count-agnostic.
- `a2a/types.bal` — no changes.
- `a2a/Ballerina.toml` — no `[[tool.grpc]]` entry, deliberately
  (§Design decision 1).
- `a2a/tests/` — see below.

## Testing

- **`Part.data` wire round-trip — mandatory, and a gate on the whole
  `google_protobuf_Value` workaround.** This test must be written and
  passing *before* any other gRPC work proceeds, because everything else
  in this design assumes the rewritten stub marshals correctly and
  nothing so far has demonstrated that (Finding 2, Known limitation 3).
  Against a real gRPC server or a Ballerina gRPC listener built from the
  same stub, send a `Part` whose `data` holds each of: a JSON object, a
  JSON array, a string, a number, a boolean, and `null`; assert each
  survives the round trip byte-equal. A `Part` with `data` unset must
  also round-trip, to confirm the rewrite didn't make the field
  accidentally mandatory. If this test cannot be made to pass, the
  `anydata` rewrite is not a viable workaround and the codegen strategy
  in §Design decision 1 must be revisited — most likely by hand-writing
  a `Value` type into the stub rather than erasing it to `anydata`.
  Note this is the one test in this list that a pure unit-level mock
  **cannot** satisfy: the defect is in marshalling against the embedded
  descriptor, so the protobuf codec has to actually run.
- **`Part.data` narrowing-failure test** — feed `decodeGrpcPart` an
  `anydata` value outside `json`'s value space and assert it returns
  `InvalidAgentResponseError` with the part index named, rather than
  dropping the field or stringifying it (§Design decision 5, rule 5).
- **Conversion round-trip tests** — the highest-value block by a wide
  margin, and the cheapest, since they need no server at all. For each
  paired `encodeGrpc*`/`decodeGrpc*`: build a fully-populated
  `types.bal` value, encode, decode, assert deep equality. Then rules 1–3
  from §Design decision 5 get dedicated negative tests: `""`→`()`,
  all-default nested message→`()`, `time:Utc [0, 0.0d]`→`()` (not the
  epoch); plus key/value-array↔map for `securitySchemes`,
  `securityRequirements`, and all five OAuth flows' `scopes` (Finding 4d,
  not one of the five numbered cross-cutting rules). Rule 4 (enums pass
  through by name) is covered by the enum-parity test below, not here.
  (Rule 5, `Part.data`, is covered by the two dedicated tests above.)
- **Enum-parity test** — assert every `Role` and `TaskState` member in
  `types.bal` has an identically-named member in `grpcstub`, so the
  pass-through-by-name assumption fails loudly if either drifts.
- **Binding-selection tests** — extend Task 8's set with `GRPC`-only
  cards, mixed cards with varied ordering, the `grpc://` scheme
  normalisation, and the v0.3+gRPC construction rejection.
- **Streaming tests** — `GrpcStreamAdapter` over a mock upstream stream:
  per-element conversion, terminal-state close matching the other
  bindings, a mid-stream `grpc:Error` surfacing as a typed `A2AError`,
  and composition with the `maxReconnectAttempts` wrapper.
- **Error-mapping tests** — one per arm of `toA2AErrorFromGrpc`,
  asserting both type and synthesized `detail.code`. Plus an explicit
  test *documenting the known loss*: a `grpc:FailedPreconditionError`
  produces `UnsupportedOperationError`, and a comment pointing at
  §Design decision 6 so the next reader doesn't "fix" it.
- **Codegen-freshness check** — CI runs `regen-grpc-stub.sh` and fails
  if the regenerated stub differs from the checked-in one, or if the
  `google_protobuf_Value` rewrite matches anything other than exactly 2
  occurrences.
- **Equivalence tests** — run one scripted scenario against a JSON-RPC
  mock and a gRPC mock and assert identical returned values. Note that
  the error half of Task 8's equivalence test **cannot** pass for gRPC
  by design (§Design decision 6); the equivalence assertion covers
  success paths and `NOT_FOUND` only, and that narrowing should be
  explicit in the test, not silent.
- **Interop verification, and its gap** — as with REST, none of this
  project's reference agents (`helloworld`, `adk_currency_agent`, the
  langgraph agent) is known to advertise a `GRPC` interface.
  Implementation should re-check each agent's card first; if none does,
  record the gap in the interop repo's findings the same way the
  push-notification CRUD gap was recorded. Two things a mock genuinely
  cannot settle and a real server can: whether A2A servers populate
  `google.rpc.ErrorInfo` in their status details at all (which decides
  how much §Design decision 6's limitation actually costs in practice),
  and whether `A2A-Version` / `A2A-Extensions` are honoured as gRPC
  metadata by real implementations.

## Known limitations

1. **Error-type fidelity is lower than the other two bindings**, because
   `ballerina/grpc` exposes no status details. Five A2A errors collapse
   into `UnsupportedOperationError`, three into `A2AInternalError`.
   §Design decision 6.
2. **Unknown fields are dropped**, because protobuf-generated records are
   closed. `types.bal`'s open records preserve them on JSON-RPC and REST.
3. **`Part.data` over gRPC — RESOLVED (2026-08-02), with one residual
   fidelity note.** This limitation originally read "unvalidated, and the
   workaround may not work at all." The mandatory gate test
   (`a2a/tests/grpc_wire_test.bal`) was then written and it **did** fail,
   exactly as feared, on every `Part` carrying non-nil `data`:

   ```
   error {ballerina/grpc:1}InternalError ("gRPC Client Connector Error :INTERNAL:
   Failed to frame message: Cannot invoke
   "com.google.protobuf.Descriptors$FileDescriptor.findMessageTypeByName(String)"
   because "fileDescriptor" is null")
   ```

   **What the root cause actually was.** Not the `anydata` rewrite, and not
   a missing Ballerina type. `ballerina/grpc`'s
   `ServiceDefinition.getFileDescriptor()` resolves the root
   FileDescriptorProto's `dependency` entries **only** from the descriptor
   map passed to `grpc:Client.initStub`, then calls
   `FileDescriptor.buildFrom(proto, deps, /*allowUnknownDependencies=*/true)`.
   `bal grpc` emits `initStub(self, A2A_DESC)` with **no** map, so
   `google/protobuf/struct.proto` was never resolved and every
   `google.protobuf.*` type in a2a.proto degraded to a protobuf
   *placeholder* descriptor (file name `<Type>.placeholder.proto`). At
   (de)serialization time `grpc.Message.getDescriptor()` detects a
   placeholder and re-resolves it by message name through
   `StandardDescriptorBuilder.getFileDescriptorFromMessageName()`. That
   table covers `google.protobuf.{Any,Empty,Timestamp,Duration,Struct}`
   plus the nine wrappers — but **not** `Value`, `ListValue`, or
   `NullValue`. Hence the exact asymmetry Finding 2 observed and could not
   explain: `Struct`-typed fields (`metadata`, `params`, `header`) were
   rescued by that table and worked; `Value`-typed `Part.data` got a null
   FileDescriptor and NPE'd.

   This also corrects Finding 2's framing. The `bal grpc` codegen gap is
   real but is only a *compile-time* nuisance; the *runtime* failure was a
   descriptor-wiring gap, and the two are independent.

   **The fix.** `a2a/modules/grpcstub/wellknown_desc.bal` (new,
   hand-maintained, not generated) defines `GOOGLE_PROTOBUF_STRUCT_DESC` —
   the hex-encoded FileDescriptorProto for `google/protobuf/struct.proto`,
   which is where `Value`/`ListValue`/`NullValue` are declared — and
   `A2A_DESCRIPTOR_MAP` keyed by that dependency's file name. The
   regeneration script now rewrites `initStub(self, A2A_DESC)` to
   `initStub(self, A2A_DESC, A2A_DESCRIPTOR_MAP)`. struct.proto then
   resolves for real, `Value` is never a placeholder, and the runtime's
   **already-existing** `google.protobuf.Value` ⇄ `anydata` machinery
   becomes reachable — see `grpc.Message`'s
   `GOOGLE_PROTOBUF_VALUE_STRUCT_VALUE` / `GOOGLE_PROTOBUF_VALUE_LIST_VALUE`
   / `GOOGLE_PROTOBUF_LISTVALUE_VALUES` branches, which were present and
   correct all along. No hand-written `Value` type was needed, no fork of
   `ballerina/grpc`, and no change to the vendored proto.

   Only `google/protobuf/struct.proto` is added to the map.
   `empty.proto` and `timestamp.proto` are also a2a.proto dependencies but
   *are* covered by `StandardDescriptorBuilder`, so their placeholders
   resolve correctly and adding them would change working behaviour for no
   benefit.

   **This also retires the `anydata` rewrite's "erasure" characterisation.**
   With the descriptor resolved, `anydata` is the *correct* Ballerina
   representation of a `google.protobuf.Value`, identical to how the tool
   already represents the `Value`s inside a `Struct`'s `map<anydata>`. The
   rewrite is still needed (the tool still emits an undefined
   `google_protobuf_Value`) and is still asserted at exactly 2 occurrences,
   so Known limitation 4 stands unchanged.

   **Residual fidelity note — integers widen to floats.**
   `google.protobuf.Value`'s `kind` oneof has exactly one numeric arm,
   `double number_value`. A Ballerina `int` inside `Part.data` therefore
   comes back as a `float` of equal value (`1` → `1.0`). This is the
   well-known type's own definition, not a defect in this binding and not
   fixable in any protobuf implementation of any language — but it *is* a
   real cross-binding difference, since JSON-RPC and HTTP+JSON preserve
   the int/float distinction. It is pinned by
   `testPartDataIntegersWidenToFloatOverGrpc` so that it cannot change
   silently, and §Design decision 5's rule 5 should be read with it in
   mind: `decodeGrpcPart`'s `anydata` → `json` narrowing will see floats
   where the caller sent ints.

   **Verified.** All seven gate cases in `a2a/tests/grpc_wire_test.bal`
   pass — JSON object, JSON array, string, number, boolean, null, and the
   unset case — against the real mock gRPC service on `localhost:19198`,
   with the real protobuf codec running in both directions. No test case
   was weakened or removed; the object/array cases' *expectations* were
   corrected for the documented int→float widening, and an eighth test was
   added to pin that widening explicitly.

   One thing this does **not** establish: `Part.data` set to an explicit
   JSON `null` and `Part.data` left unset are indistinguishable on the
   Ballerina side (both surface as `()`), so `testPartDataRoundTripNull`
   and `testPartUnsetDataRoundTrips` assert the same observable outcome.
   That is inherent to representing `Value` as `anydata` and matches
   proto3 semantics (`NULL_VALUE = 0` is not emitted on the wire anyway).
4. **The post-generation rewrite is tool-version-sensitive.** It is a
   textual rewrite of tool output and will silently stop applying if a
   future `bal grpc` emits a proper type. Guarded by an
   exactly-2-occurrences assertion in the regeneration script, and worth
   an upstream bug report.
5. **`OAuthFlows.device_code` is dropped over gRPC.** Task 8's M2 noted
   `types.bal`'s `OAuthFlows` omits the device-code flow but that it
   survives as untyped `json` on the JSON bindings via the open record.
   Closed generated records remove that escape hatch, so on gRPC the flow
   is lost outright. Fixed for all three bindings at once by adding a
   `DeviceCodeOAuthFlow` type to `types.bal`.
6. **The vendored proto is not byte-identical to upstream** (annotations
   stripped), so drift detection is by recorded SHA rather than by
   direct diff.
7. **v0.3 over gRPC is unsupported**, by construction.
8. **Adding the gRPC binding downgrades this package's resolved `http`
   version**, and that downgrade can propagate to consumers. `a2a`'s
   `Ballerina.toml` pins `http` to `2.14.13` (down from the `2.16.6` it
   resolved to before this branch) because `ballerina/grpc:1.14.7` bundles
   its own `http-native-2.14.12.jar` for shared native logging
   infrastructure, and a separately-resolved `http` whose native ABI has
   drifted too far from that bundled jar crashes `grpc:Listener`
   construction with `java.lang.IllegalAccessError` on
   `HttpLogManager.<init>` (confirmed with `http:2.16.6`; see
   ballerina-platform/ballerina-library#2496). The full rationale and the
   exact pin are recorded as a comment directly above the `[[dependency]]`
   entry in `a2a/Ballerina.toml`, which is the source of truth. This repo
   has no CHANGELOG/release-notes file to duplicate the notice into (none
   exists on `main` as of this writing), so this Known limitations entry is
   the second, more discoverable place this fact lives: a consuming
   project that also pins `http` above `2.14.13` and separately depends on
   `ballerina/grpc` may see the same crash, or may see its own `http`
   silently resolved down to this floor with no warning from `bal build`.
