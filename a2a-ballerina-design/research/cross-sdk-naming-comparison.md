# Cross-SDK naming and structure comparison

_2026-08-31 — from the 2026-08-31 A2A client review-planning meeting:
"do other real A2A SDK implementations keep the spec's method names and
primary parameters exactly as given, or rename/restructure them for
their own language's conventions?"_

Real evidence only — both reference SDKs inspected directly from their
actual installed artifacts, not from memory or their docs:

- **Python**: `a2a-sdk` 1.1.2, installed in
  `employee-concierge-demo/agents/digiops/.venv/lib/python3.12/site-packages/a2a/`
  (and `peopleoperations`'s venv, same version) — read the real
  `.py` source directly.
- **Java**: `a2a-java-sdk` 1.1.0.Final, in `~/.m2/repository/org/a2aproject/sdk/`
  — decompiled the real `.class` files with `javap -p` (no source jar
  available, only compiled classes).
- **Ballerina**: this library's own `ballerina/client.bal`.

## 1. Method naming: spec operation vs. each SDK's real method name

| Spec operation (§9.4) | Python `a2a.client.Client` | Java `org.a2aproject.sdk.client.Client` | Ballerina `a2a:Client` |
|---|---|---|---|
| `sendMessage` | `send_message` | `sendMessage` (3 overloads) | `sendMessage` |
| `sendStreamingMessage` | *(no separate method — see §2)* | *(no separate method — see §2)* | `sendStreamingMessage` |
| `getTask` | `get_task` | `getTask` | `getTask` |
| `cancelTask` | `cancel_task` | `cancelTask` | `cancelTask` |
| `subscribeToTask` | `subscribe` | `subscribeToTask` | `subscribeToTask` |
| `listTasks` | `list_tasks` | `listTasks` | `listTasks` |
| `createTaskPushNotificationConfig` | `create_task_push_notification_config` | `createTaskPushNotificationConfiguration` | `createTaskPushNotificationConfig` |
| `getTaskPushNotificationConfig` | `get_task_push_notification_config` | `getTaskPushNotificationConfiguration` | `getTaskPushNotificationConfig` |
| `listTaskPushNotificationConfigs` | `list_task_push_notification_configs` | `listTaskPushNotificationConfigurations` | `listTaskPushNotificationConfigs` |
| `deleteTaskPushNotificationConfig` | `delete_task_push_notification_config` | `deleteTaskPushNotificationConfigurations` | `deleteTaskPushNotificationConfig` |
| `getExtendedAgentCard` | `get_extended_agent_card` | `getExtendedAgentCard` | `getExtendedAgentCard` |

**Findings:**

- **Python**: mechanically converts every name to `snake_case` (expected —
  that's just PEP 8), with one real exception beyond casing:
  `subscribeToTask` → `subscribe`, dropping "ToTask" entirely. The
  request *type* keeps the full name (`SubscribeToTaskRequest`) — only
  the method itself was shortened.
- **Java**: keeps every method name in the spec's exact camelCase, with
  one real exception: all four push-notification-config methods get
  "Config" expanded to "Configuration"
  (`createTaskPushNotificationConfiguration`, etc.) — consistently, not
  a one-off typo.
- **Ballerina**: keeps every one of the 11 method names byte-for-byte
  identical to the spec. No renames, no shortening, no expansion.

## 2. Streaming: a separate method, or folded into the plain send?

Both reference SDKs **do not** expose `sendStreamingMessage` as its own
method on their main client-facing type — a real, deliberate
architectural choice, not a naming quirk:

- **Python**: `Client.send_message` returns `AsyncIterator[StreamResponse]`
  unconditionally. Its docstring: *"This will automatically use the
  streaming or non-streaming approach as supported by the server and the
  client config."* The spec's send/sendStreaming distinction still
  exists one layer down, on the `ClientTransport` interface
  (`send_message` vs. `send_message_streaming` in
  `a2a/client/transports/tenant_decorator.py`) — it's collapsed only at
  the ergonomic, caller-facing layer.
- **Java**: three `sendMessage` overloads exist (differing by which
  event-callback/push-config shape you pass), but none is named
  `sendStreamingMessage` — streaming vs. non-streaming is which overload
  you call and whether you pass event consumers, not a separate method
  name.
- **Ballerina**: keeps `sendMessage` and `sendStreamingMessage` as two
  distinct, separately-named methods, matching the spec's own two
  distinct operation names exactly. This is a real, structural
  divergence from both reference SDKs, not just a naming one.

## 3. Parameter shape: one request object vs. named parameters

This is the largest real structural difference found, and it's
consistent across every method in each SDK — not case-by-case.

- **Python**: every method takes exactly one parameter, `request: <SomeRequestType>`
  (e.g. `SendMessageRequest`, `GetTaskRequest`), plus a keyword-only
  `context: ClientCallContext | None`. All per-call configuration —
  including `tenant` — lives as a field *inside* that one request
  object, not as separate method parameters.
- **Java**: a hybrid. Most methods take the primary domain object or a
  dedicated `*Params` type as the first argument (`Message`,
  `TaskQueryParams`, `CancelTaskParams`, ...), then separate trailing
  arguments for callbacks/error-handlers, and always a trailing
  `ClientCallContext` — closer to "named parameters" than Python's single
  wrapper, but still funnels most of what would be named parameters
  through one params object rather than exposing each individually.
  `tenant` lives as a field on that `*Params` object (confirmed via
  `javap` on `MessageSendParams`/`TaskQueryParams` — both have a private
  `tenant` field and a `tenant()` accessor), same as Python.
- **Ballerina**: every method exposes its real primary parameters
  directly and individually (`sendMessage(Message message,
  SendMessageConfiguration? config, string? tenant, map<json>? metadata)`)
  — no wrapper request object at all. `tenant` is its own named,
  optional parameter, not a field nested inside something else.

Neither reference SDK's shape is "more correct" per the spec — the spec
defines JSON-RPC/REST/gRPC wire request shapes, not a target-language
call signature. Both are real, deliberate per-language ergonomic
choices, and Ballerina's is a third, different one.

## 4. Tenant handling: three different precedence chains

The spec (§7.x) says: *"tenant — Optional. Opaque routing identifier.
Must match the tenant value from the selected AgentInterface in the
Agent Card when that field is set."* All three SDKs implement the
card-auto-supply part. Where they differ is what else feeds into it:

- **Python** — 2 real layers, confirmed in
  `a2a/client/transports/tenant_decorator.py` +
  `a2a/client/client_factory.py:354-356`:
  1. Per-call: caller sets `request.tenant` explicitly before the call.
  2. Falls back to `selected_interface.tenant` — the `TenantTransportDecorator`
     is constructed with exactly that value
     (`TenantTransportDecorator(transport, selected_interface.tenant)`),
     and `_resolve_tenant` does `return tenant or self._tenant`.
  No separate "explicit tenant supplied by the calling application at
  client-construction time, independent of the card" layer exists —
  the only non-per-call source is the card itself.
- **Java** — effectively 1 layer, as far as `a2a-java-sdk-client` and
  `a2a-java-sdk-client-transport-spi` go: `tenant` is a field on the
  `*Params` request objects (confirmed via `javap`), but no
  `ClientBuilder`/`Client`/`ClientCallContext` method or field wiring a
  default tenant was found anywhere in either jar (`ClientCallContext`
  only carries a generic `state` map and `headers` map — no tenant).
  Every request apparently needs its tenant set explicitly by the
  caller; no fallback mechanism found in the client module.
- **Ballerina** — 3 layers, confirmed in `rest_client.bal`/
  `jsonrpc_client.bal`/`grpc_client.bal` (identical in all three):
  1. Per-call `tenant` parameter — wins if given.
  2. Explicit `tenant` passed to the client constructor — wins if given.
  3. Auto-supplied from the AgentCard's selected `AgentInterface`
     (`iface?.tenant`) — the spec-mandated fallback.
  Layer 2 is a real affordance neither reference SDK offers in quite
  the same shape: a friendly constructor parameter for a
  caller-supplied default, distinct from both the per-call override and
  the card's own value. Python's nearest equivalent requires the caller
  to set the field on every request object by hand; Java has no
  fallback at all in the modules inspected.

## Not yet checked

- Whether Java's higher-level `a2a-java-sdk-reference-*` modules (rather
  than the SPI/client modules inspected here) add their own
  default-tenant convenience on top of what's in `a2a-java-sdk-client`.
- gRPC-specific naming in either reference SDK (only the general
  client-facing API surface was checked here, not transport-specific
  code).
