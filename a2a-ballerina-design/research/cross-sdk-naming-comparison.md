# Cross-SDK naming and structure comparison

_2026-08-31 — from the 2026-08-31 A2A client review-planning meeting:
"do other real A2A SDK implementations keep the spec's method names and
primary parameters exactly as given, or rename/restructure them for
their own language's conventions?" Deepened same day with real GitHub
issue/PR history and the actual spec text, on top of the first pass's
source-code-only comparison._

Real evidence only, every claim cited:

- **Python**: `a2a-sdk` 1.1.2, installed in
  `employee-concierge-demo/agents/digiops/.venv/lib/python3.12/site-packages/a2a/`
  — read directly, plus real issues/PRs from `a2aproject/a2a-python`.
- **Java**: `a2a-java-sdk` 1.1.0.Final, in `~/.m2/repository/org/a2aproject/sdk/`
  — decompiled with `javap -p` (no source jar available), plus real
  PRs from `a2aproject/a2a-java`.
- **Go**: `a2aproject/a2a-go`, `main` branch — fetched and read directly
  (added this pass; not in the first).
- **The spec itself**: `a2aproject/A2A`'s `docs/specification.md`,
  fetched directly.
- **Ballerina**: this library's own `ballerina/client.bal`/`types.bal`.

## 1. Method naming: spec operation vs. each SDK's real method name

| Spec operation (§9.4) | Python `a2a.client.Client` | Java `org.a2aproject.sdk.client.Client` | Go `a2aclient.Client` | Ballerina `a2a:Client` |
|---|---|---|---|---|
| `sendMessage` | `send_message` | `sendMessage` (3 overloads) | `SendMessage` | `sendMessage` |
| `sendStreamingMessage` | *(folded into `send_message` — §2)* | *(folded into `sendMessage` overloads — §2)* | `SendStreamingMessage` (kept separate) | `sendStreamingMessage` |
| `getTask` | `get_task` | `getTask` | `GetTask` | `getTask` |
| `cancelTask` | `cancel_task` | `cancelTask` | `CancelTask` | `cancelTask` |
| `subscribeToTask` | `subscribe` (shortened) | `subscribeToTask` | `SubscribeToTask` | `subscribeToTask` |
| `listTasks` | `list_tasks` | `listTasks` | `ListTasks` | `listTasks` |
| `createTaskPushNotificationConfig` | `create_task_push_notification_config` | `createTaskPushNotificationConfiguration` | `CreateTaskPushConfig` (drops "Notification") | `createTaskPushNotificationConfig` |
| `getTaskPushNotificationConfig` | `get_task_push_notification_config` | `getTaskPushNotificationConfiguration` | `GetTaskPushConfig` | `getTaskPushNotificationConfig` |
| `listTaskPushNotificationConfigs` | `list_task_push_notification_configs` | `listTaskPushNotificationConfigurations` | `ListTaskPushConfigs` | `listTaskPushNotificationConfigs` |
| `deleteTaskPushNotificationConfig` | `delete_task_push_notification_config` | `deleteTaskPushNotificationConfigurations` | `DeleteTaskPushConfig` | `deleteTaskPushNotificationConfig` |
| `getExtendedAgentCard` | `get_extended_agent_card` | `getExtendedAgentCard` | `GetExtendedAgentCard` | `getExtendedAgentCard` |

**Updated findings, now with real sourced rationale, not just observation:**

- **Ballerina** is the only one of the four that renames nothing at all
  — every method name is byte-for-byte identical to the spec.
- **Python** snake_cases everything (expected — PEP 8), plus one real
  content change: `subscribeToTask` → `subscribe`. Could not find a
  dedicated rename PR for this specific shortening — it appears to have
  been introduced directly in the big v1.0 rewrite,
  [PR #572](https://github.com/a2aproject/a2a-python/pull/572)
  ("refactor!: upgrade SDK to A2A 1.0 specs"), which doesn't call it out
  individually in its own description.
- **Java** has two distinct, separately-motivated naming changes on the
  push-notification-config methods, confirmed via real PRs, not one:
  1. Method names expanded `Config` → `Configuration` (confirmed via
     `javap` bytecode — real, but no dedicated PR found explaining this
     specific choice).
  2. The *result type* `ListTaskPushNotificationConfig` was separately
     pluralized to `ListTaskPushNotificationConfigs...` for consistency —
     [PR #724](https://github.com/a2aproject/a2a-java/pull/724), fixing
     [issue #704](https://github.com/a2aproject/a2a-java/issues/704).
  3. A third, deeper pass renamed several *field* names to align with
     `a2a.proto` directly (not just the method/type names):
     `pushNotificationConfig`→`config`, and — a genuinely easy detail to
     get backwards — `DeleteTaskPushNotificationConfigParams`/
     `GetTaskPushNotificationConfigParams` had their `id`/
     `pushNotificationConfigId` fields renamed to `taskId`/`id`
     respectively, while `ListTaskPushNotificationConfigParams` renamed
     `taskId` to `id` — [PR #647](https://github.com/a2aproject/a2a-java/pull/647),
     fixing [issue #634](https://github.com/a2aproject/a2a-java/issues/634).
- **Go** (new this pass) takes push-notification naming further than
  either: it drops "Notification" entirely (`GetTaskPushConfig`, not
  `GetTaskPushNotificationConfig`) — a third distinct naming variant
  beyond Python's snake_case-only and Java's Config→Configuration
  expansion.

## 2. Streaming: a separate method, or folded into the plain send?

Revised finding — this is **not** a universal pattern across reference
SDKs, as the first pass's 2-SDK sample suggested:

- **Python**: `Client.send_message` returns `AsyncIterator[StreamResponse]`
  unconditionally — no separate `send_streaming_message` on the
  caller-facing `Client` (it still exists one layer down, on
  `ClientTransport`).
- **Java**: three `sendMessage` overloads, none named
  `sendStreamingMessage` — which overload/callback shape you use decides
  streaming vs. not.
- **Go**: keeps `SendStreamingMessage` as its own, separately-named
  method, alongside `SendMessage` — matching the spec's own two
  distinct operation names, and matching Ballerina's choice exactly.

So Ballerina's separate `sendMessage`/`sendStreamingMessage` methods
aren't an outlier invented by this library — they match a real
precedent (Go), just not the majority (2 of 3 checked reference SDKs
collapse it).

## 3. Parameter shape: one request object vs. named parameters — and *why*

The first pass documented the shape difference (Python: single
`request` object; Java: hybrid domain-object-plus-params; Ballerina:
fully named parameters) but not *why* Python/Java converge on a request
wrapper. Found the real reason:
[a2a-python issue #767](https://github.com/a2aproject/a2a-python/issues/767)
("feat: add GetExtendedAgentCardRequest as input parameter to
GetExtendedAgentCard method") states it directly:

> [Spec](https://a2a-protocol.org/latest/specification/#103-service-definition)
> defines `rpc GetExtendedAgentCard(GetExtendedAgentCardRequest) returns
> (AgentCard)`. Currently `GetExtendedAgentCard` does not take
> `GetExtendedAgentCardRequest` as input parameter.

The A2A spec's gRPC service definition (`a2a.proto`) declares every RPC
as taking exactly **one** input message and returning exactly **one**
output message — standard protobuf/gRPC convention. Python's
one-`request`-object-per-call shape is a direct, literal mirror of that
gRPC service signature; this issue is a real, tracked case of the SDK
being brought back into alignment with it after drifting. Java's hybrid
shape sits partway between the two: it also carries dedicated request
objects, but exposes primary domain values as separate leading
arguments rather than nesting everything.

Ballerina's fully-named-parameter shape is therefore a **deliberate
departure from the gRPC service signature**, not an oversight — a real,
informed design choice to prioritize idiomatic Ballerina function calls
over a literal 1:1 mirror of the protobuf RPC shape.

## 4. Tenant handling: four different real mechanisms, not three

The first pass covered Python (2 layers) and Java (1, no fallback
found). Adding Go this pass reveals genuinely more architectural
variety than "how many fallback layers":

- **Python** — per-call `request.tenant`, falling back to
  `selected_interface.tenant` via a `TenantTransportDecorator`
  (`a2a/client/transports/tenant_decorator.py`), wired at construction
  in `client_factory.py:354-356`. Confirmed the origin:
  [PR #758](https://github.com/a2aproject/a2a-python/pull/758) ("feat:
  handle tenant in Client"), fixing
  [issue #672](https://github.com/a2aproject/a2a-python/issues/672).
  That issue explicitly cites
  [a2a-go PR #237](https://github.com/a2aproject/a2a-go/pull/237) as
  implementation inspiration — real evidence of cross-SDK design
  borrowing, not independent invention.
- **Java** — no fallback mechanism found in `a2a-java-sdk-client`/
  `a2a-java-sdk-client-transport-spi`; `tenant` is a field on the
  `*Params` request objects (confirmed via `javap` on
  `MessageSendParams`/`TaskQueryParams`) that the caller must set
  explicitly every time.
- **Go** — a fourth, distinct pattern: idiomatic Go `context.Context`
  propagation. `a2a/tenant.go` defines `AttachTenant(ctx, tenant)` and
  `TenantFrom(ctx)`; the client has a `DisableTenantPropagation` config
  flag (default false) controlling whether it automatically pulls the
  tenant out of the call's `context.Context` and attaches it to the
  outgoing request. Neither a per-call parameter nor a
  constructor-supplied default — the tenant rides along on Go's own
  request-scoped context mechanism instead.
- **Ballerina** — 3 layers (per-call → explicit constructor tenant →
  AgentCard-interface auto-supply), confirmed identically in
  `rest_client.bal`/`jsonrpc_client.bal`/`grpc_client.bal`. The explicit
  constructor-level override, independent of both the per-call value and
  the card's own value, still isn't matched by any of the three
  reference SDKs checked.

### Where tenant itself comes from (bonus finding)

Multi-tenancy is relatively new to the spec.
[a2a-python issue #672](https://github.com/a2aproject/a2a-python/issues/672)
links to the actual spec-level PR that added it:
[a2aproject/A2A PR #1195](https://github.com/a2aproject/A2A/pull/1195)
("feat(spec): Natively Support Multi-tenancy on gRPC through an
additional scope field on the request"). The real motivating reason,
from [a2aproject/A2A issue #1273](https://github.com/a2aproject/A2A/issues/1273):

> The `tenant` field was introduced to accommodate protocol-specific
> requirements, particularly gRPC's URL structure limitations.

REST can path-prefix a tenant into the URL naturally
(`/{tenant}/message:send`); gRPC's URL/path structure can't, so `tenant`
exists as an explicit field specifically to give gRPC parity with what
REST gets for free from its URL shape. That issue is still open at
time of writing and documents real, ongoing ambiguity about whether an
Agent Card should list multiple `AgentInterface` entries per tenant at
all — worth re-checking before this library's tenant handling is
considered finished.

## 5. `blocking` → `returnImmediately`: a spec-level rename, confirmed matching our own field

Not part of the original naming question, but found while digging
through Java's history and directly relevant to this library's own
`SendMessageConfiguration.returnImmediately` field:
[a2a-java PR #722](https://github.com/a2aproject/a2a-java/pull/722)
("fix!: Rename `blocking` to `returnImmediately` in
SendMessageConfiguration") states this was **upstream spec/proto
churn**, not a Java-specific choice — *"Sync a2a.proto with upstream"* —
with inverted semantics: `blocking=true` (wait) became
`returnImmediately=false`, and the **default behavior changed**:
`false` now means "wait for completion" instead of "return
immediately."

Checked our own `types.bal:343-348` against this: `returnImmediately`
defaults to `false`, with the doc comment *"False (default) blocks
until the task reaches a terminal or interrupted state; true returns as
soon as the task is created"* — an exact match to the real spec
semantics Java's PR describes, not just a name coincidence.

## 6. What the spec itself actually mandates about naming

Fetched `docs/specification.md` directly from `a2aproject/A2A` (`main`
branch) rather than assuming. Two real, current, normative rules:

- **§5.5, JSON Field Naming Convention**: *"All JSON serializations of
  the A2A protocol data model **MUST** use **camelCase** naming for
  field names."*
- **§9.1, JSON-RPC Protocol Binding**: *"**Method Naming:** PascalCase
  method names matching gRPC conventions (e.g., `SendMessage`,
  `GetTask`)."*

Both rules govern the **wire format only** — the literal JSON keys and
the literal JSON-RPC `"method"` string sent over the network. The spec
says **nothing** about what a client library's own language-level
method or function should be called. Every divergence documented above
(Python's snake_case + `subscribe` shortening, Java's `Configuration`
expansion, Go's dropped "Notification") is therefore a legitimate,
spec-compliant SDK-author choice, not a deviation from anything the
spec actually requires — confirms this library's decision to keep
spec-exact names is *a* valid choice, not *the only* valid one.

This also explains something noted in an earlier dump-folder writeup,
[`ballerina-jsondata-name-annotation.md`](https://github.com/Anuja-jayasinghe/wso2-internship-notes/blob/master/dump/ballerina-jsondata-name-annotation.md)
— that writeup's finding that the client's PascalCase
method-name strings (`"SendMessage"`, `"GetTask"` in
`rest_client.bal`'s `REST_OPERATIONS`) were correctly left as-is rather
than converted, since they're literal wire values, not record fields.
§9.1 above is the actual normative source for why those strings must
stay PascalCase.

### The spec has renamed itself before, too

Appendix A.2 of `specification.md` documents the spec's own historical
renames, kept as legacy anchors for backward-compatible links:
`SendMessageSuccessResponse` → `SendMessageResponse` ("Unified success
response naming"), `GetAuthenticatedExtendedCardRequest` →
`GetExtendedAgentCardRequest` ("Removed 'Authenticated' from naming").
Naming evolution is normal at every layer of this ecosystem, not just
in SDKs reacting to a fixed spec.

## Updated summary table

| | Python | Java | Go | Ballerina |
|---|---|---|---|---|
| Method names vs. spec | snake_case + 1 shortening | camelCase + Config→Configuration expansion | PascalCase + Notification dropped | Identical |
| `sendStreamingMessage` kept separate? | No | No | **Yes** | Yes |
| Request shape | Single wrapper object (mirrors gRPC 1:1) | Hybrid | Not checked this pass | Named parameters |
| Tenant fallback layers | 2 (decorator) | 0-1 (no fallback found) | Context-propagation (opt-out) | 3 |

## Not yet checked

- `a2a-js`, `a2a-dotnet`, `a2a-rs` — not examined this pass either;
  scope was Python/Java (deepened) + Go (added).
- Go's request/parameter shape wasn't compared in the same depth as
  Python/Java (only method naming and tenant handling).
- Whether Java's higher-level `a2a-java-sdk-reference-*` modules add
  their own default-tenant convenience on top of what's in
  `a2a-java-sdk-client` (still not checked).
- The still-open status of `a2aproject/A2A#1273` (multi-tenancy Agent
  Card ambiguity) — worth a follow-up check before treating this
  library's tenant handling as spec-final.
