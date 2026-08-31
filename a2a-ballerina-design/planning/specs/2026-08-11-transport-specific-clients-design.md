# Transport-specific clients + pre-release API-surface reduction — design

## Context

Two changes land together here, both before this library has shipped
externally, both motivated by the same constraint: **once a symbol is
public in a released package, removing it is a breaking change.**
Publicizing later is additive and cheap; privatizing later is not. So
anything that is neither mandated by the A2A specification nor
precedented in the reference SDKs — and that has no proven consumer
need — comes out now.

### Change 1 — the client architecture

Two client architectures were drafted side by side in the proposal repo
(`a2a-interop-tests/docs/proposals/`) specifically so they could be
weighed against each other:

- `a2a_support_for_ballerina.md` — one `Client` class carrying a
  `binding` field, with per-call dispatch. This is what is implemented
  today: `rpcCall` (client.bal:722) and `openEventStream`
  (client.bal:1041) branch on `self.binding` and fan out to
  `restCall`/`grpcCall` or an inline JSON-RPC path.
- `a2a_support_for_ballerina_v2.md` — one concrete client type per
  transport binding, each with no internal branching, unified behind a
  shared interface type, plus a common auto-detecting client that
  delegates.

**The v2 architecture is chosen.** The losing variant is dropped.

The deciding argument is that per-call branching on a field that cannot
change after construction is dispatch in the wrong place. Which
transport a client speaks is fixed the moment it is constructed — it is
a property of the instance, not of the call — so the type system should
carry it. Under v2, `JsonRpcClient` *is* the JSON-RPC client; there is no
`if self.binding == "GRPC"` left to evaluate on every one of the eleven
operations, and no reachable-but-wrong branch to test.

The cost is three public class boundaries instead of one. That cost is
bounded deliberately: **only the class boundary multiplies, not the
marshaling code.** Each concrete client keeps calling the same internal
helpers that exist today (`restCall`, `buildRestRequest`, `grpcCall`,
`dispatchGrpcContextCall`, `encodeGrpcRequest`/`decodeGrpcResponse`,
`openGrpcStream`, `openRestSseStream`, `readSseStream`). Nothing is
tripled.

### Change 2 — API-surface reduction

A pre-release audit of every public symbol in this module classified
each as spec-mandated, borrowed-from-a-reference-SDK convention, or
invented here. The invented-here set was then tested against a single
question: *is there a consumer who needs this, today?* Where the answer
was no, the symbol comes out.

Everything removed for lack of spec or reference-SDK precedent gets a
GitHub issue recording what was built and what would justify bringing it
back, so no design work is lost.

## Removals

### `verifyAgentCardSignature` (signature.bal)

Spec §8.4.3 states that a client verifying an Agent Card signature MUST
follow its six-step canonicalize-and-verify sequence, and SHOULD verify
at least one signature before trusting a card. It stops there: it defines
no API, and neither reference SDK (Python `a2a-sdk`, Java) ships an
equivalent helper.

More decisively, the implementation being removed did not actually
satisfy the procedure it was written for. Its own doc comment
(signature.bal:58-77) records the gap: it performs no RFC 8785 JCS
canonicalization, so it only verifies signatures computed over
Ballerina's `toJsonString()` output. Against any signer that
canonicalizes correctly — that is, any spec-conformant signer — it would
fail. Shipping it would advertise a capability the library does not have.

Removing it also removes `SignatureVerificationError` and
`UnsupportedSignatureAlgorithmError`, which have no other producer.

`AgentCardSignature` and `AgentCard.signatures` **stay** — the spec
defines those shapes, and parsing a card must not lose them just because
this library cannot yet verify them.

### `buildAuthFromCard` / `ResolvedAuth` (auth.bal), and `credentials`

The spec defines `securitySchemes` and `securityRequirements` as an
Agent Card *data model*. It does not define a client-side API that turns
a card plus a credential bag into wired-up transport auth. That mapping
is this library's invention; the reference SDKs accept auth
configuration directly on their client builders instead.

The implementation was also structurally partial by design: it automated
only API-key-in-header and HTTP Basic/Bearer, because those reduce to one
credential string. OAuth2, OpenID Connect, and mutual TLS were explicitly
out of scope (auth.bal:1-9) since they need a token-acquisition flow or a
client certificate. A public type whose shape is known to be inadequate
for three of the five scheme kinds it nominally covers is a poor
candidate for a v1 compatibility promise.

The `credentials` parameter on the constructor falls out with it — it had
no other consumer. Callers configure `clientConfig.auth` and `headers`
directly, exactly as they would with any other Ballerina client.

`AuthResolutionError` **stays**: `projectToGrpcClientConfig`
(auth.bal:134) remains as an internal adapter projecting a caller-supplied
`http:ClientConfiguration.auth` onto the structurally equivalent
`grpc:ClientConfiguration.auth`, and still reports failure through it.

### `resolveAgentCardCached` / `CachedAgentCard` (client.bal)

ETag-aware conditional GET of the Agent Card. Not in the spec, not in the
reference SDKs, and with no caller inside this library — only two tests
exercise it. A genuinely useful idea for a long-running client that
re-checks a card periodically, but an unproven one, and re-adding it
later is non-breaking.

`resolveAgentCard` stays: fetching `/.well-known/agent-card.json` is the
spec's discovery mechanism and the entry point for everything else.

### `detectProtocolMode` (compat_v03.bal)

A one-line delegate to `detectProtocolModeForBinding(card, "JSONRPC")`
with no caller outside its own tests. Redundant surface; the parameterized
form covers it, and defaults to `"JSONRPC"` anyway.

### `main()` (main.bal)

A leftover `io:println("Hello, World!")` scaffold from project
initialization. The file is deleted.

### `newClient` and the `serviceUrl` parameter (client.bal)

`newClient(AgentCard|string agent, ...)` exists as a separate factory only
because an earlier design assumed a constructor could not accept a union.
It can. The resolution logic moves into `init` directly and the factory is
deleted, leaving one construction entry point per client type.

`Client.init`'s `serviceUrl` parameter is an escape hatch: it is an
independent argument, never derived from `agentCard` even when a card is
also supplied, so a caller can point the client at a URL the card does not
declare. It is removed with no replacement.

The reasoning is a security argument, not an ergonomic one. Resolving a
card exists to establish where it is safe to send requests and
credentials. A parameter that overrides the resolved destination
reintroduces exactly the redirection surface that resolving the card was
meant to close — and neither reference SDK exposes an equivalent. Code
that needs to dial elsewhere (including this library's own tests)
constructs an `AgentCard` whose declared interfaces already point where it
needs to go.

Adding a narrower, deliberately-scoped override later is not a breaking
change. It would need its own justification.

## Demotions to non-public

These are implementation details that were marked `public` without a
consumer needing them. In Ballerina the `tests/` directory is part of the
same module, so demoting costs nothing — existing tests keep compiling.

| Symbol | Source | Callers |
|---|---|---|
| `encodeRawBytesForWire` | types.bal | client.bal, grpc_binding.bal |
| `decodeRawBytesFromWire` | types.bal | client.bal, sse.bal, grpc_binding.bal |
| `parseSecuritySchemes` | types.bal | client.bal |
| `parseSecurityRequirements` | types.bal | client.bal |
| `parseAgentCardSignatures` | types.bal | client.bal |
| `detectProtocolModeForBinding` | compat_v03.bal | client.bal |
| `primaryUrl` | client.bal | the four `init`s |
| `selectInterface` | client.bal | `primaryUrl`, the four `init`s |
| `ProtocolMode` | compat_v03.bal | private fields, internal params |

The first five are wire-marshaling and card-parsing guts — base64
encoding of `Part.raw`, and lenient per-entry parsing of a card's
security and signature arrays. No consumer calls these.

`selectInterface` is the one genuine judgment call: it implements the
spec's own §8.3.2 client protocol-selection algorithm, which is a
legitimate thing to expose. It is demoted anyway, because once the four
client types exist, a consumer has no reason to run selection by hand —
construction does it. If that turns out to be wrong, publicizing it again
is additive.

`ProtocolMode` follows mechanically: with `detectProtocolMode` deleted and
`detectProtocolModeForBinding` demoted, it appears in no public signature.

`TransportBinding` **stays public** — `Client.init`'s `binding` parameter
is typed with it.

## Submodules held back at the package boundary

`modules/grpcstub` and `modules/transport` are implementation detail, but
their symbols cannot simply drop `public`: Ballerina requires `public` for
cross-module access within a package, so the root module using them forces
them public.

`grpcstub` is the acute case. It is protoc-generated, and it re-declares
its own `Task`, `Message`, `AgentCard`, `Part`, `SecurityScheme` and
friends — same names as the root module's spec types, structurally
different shapes (protobuf field naming versus JSON camelCase). A consumer
importing it directly would end up holding an incompatible `Task` next to
`a2a:Task`. Worse, the shapes are whatever `protoc-gen-ballerina` emits, so
regeneration could change them without anyone deciding to.

The fix is at the package boundary rather than the symbol level:

```toml
[[package.modules]]
name = "a2a.grpcstub"
export = false
```

Verified against a scratch consumer package built on a locally-published
bala: `import ballerina/a2a.grpcstub` fails with `cannot resolve module
'ballerina/a2a.grpcstub:0.2.0 is not exported'`, while `import
ballerina/a2a` resolves normally. Intra-package use is unaffected, and the
setting survives stub regeneration because it lives in `Ballerina.toml`
rather than the generated file.

This also makes true a claim `a2a/CLAUDE.md` had been making without
enforcement — that `modules/transport/` is "internal and unexported".

## Resulting public surface

- Every spec-facing type in `types.bal` (36), unchanged.
- The `A2AError` hierarchy in `errors.bal` (13), minus the two signature
  errors.
- `resolveAgentCard` — the module's **only** public free function.
- `AgentClient`, `Client`, `JsonRpcClient`, `RestClient`, `GrpcClient`.

Nothing from `a2a.grpcstub` or `a2a.transport`.

`TransportBinding` is **not** public either, which was not the original
plan. Once `Client` took its binding from the card rather than a
parameter, the name stopped appearing in any public signature — the same
mechanical consequence that made `ProtocolMode` internal. A caller selects
a binding by choosing `JsonRpcClient`, `RestClient`, or `GrpcClient`, never
by naming one, so there is nothing left for the type to be used for.

## Target architecture

```ballerina
public type AgentClient isolated client object {
    // the eleven spec §9.4 client operations; signatures unchanged
    // from today's Client
};

public isolated client class JsonRpcClient { *AgentClient; ... }
public isolated client class RestClient    { *AgentClient; ... }
public isolated client class GrpcClient    { *AgentClient; ... }

public isolated client class Client {
    *AgentClient;
    private final AgentClient delegate;
}
```

`AgentClient` is what makes the split cost-free for callers: code that
does not care which binding it speaks is written against `AgentClient`
and works identically whether it holds the auto-detecting `Client` or a
concrete one.

### Transport selection

Spec §8.3.2 is explicit that the card, not the client, decides:

> Parse `supportedInterfaces` if present, and select the first supported
> transport. […] Prefer earlier entries in the ordered list when multiple
> options are supported.

and of the array itself:

> `supportedInterfaces` **SHOULD** declare all supported protocol
> combinations in preference order. […] The first entry represents the
> preferred interface.

Two consequences, both of which this library previously got wrong.

**Within a binding, the earliest entry wins.** `selectInterface` used to
rank candidates by `protocolVersion`, taking a 1.0 entry over a 0.3 entry
even when the card listed the 0.3 one first. The rationale — that card
ordering shouldn't silently downgrade the protocol version — is real, but
the spec makes ordering the server's decision, and the reference Java SDK
agrees, keeping only the first entry per binding
(`ClientBuilder.getServerInterfacesMap` uses `putIfAbsent`, commented "If
there are multiple interfaces with the same protocol binding, only the
first is considered"). The version ranking is removed.

**The binding itself comes from the card.** Today `Client.init` takes
`binding = "JSONRPC"` and never consults the card's ordering, so a
GRPC-only agent is unreachable via `new (url)` despite being perfectly
valid — construction fails with "AgentCard has no JSONRPC entry". That is
not auto-detection; it is a fixed client preference.

The common `Client` instead walks `supportedInterfaces` in card order and
constructs the concrete client for the first binding this library
supports. It takes **no `binding` parameter at all**: expressing a client
preference is what the three concrete types are for. A caller who wants
gRPC writes `new GrpcClient(url)`; a caller with no opinion writes
`new Client(url)` and gets the server's preference. This is the same split
the Java SDK expresses through its `useClientPreference` flag, but carried
by the type system instead of a boolean.

### Construction

`Client` takes no `binding`; the three concrete clients omit it because
the type already says which transport it speaks:

```ballerina
public isolated function init(
        AgentCard|string agent,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        int maxReconnectAttempts = 0) returns error?;
```

The signature is identical for all four types — `Client` has no extra
parameter, because binding selection is the card's job and client
preference is expressed by choosing a concrete type.

Rules, identical across all four:

1. If `agent` is a `string`, resolve it with `resolveAgentCard` first.
   There is no fetch-free path — the card is what determines protocol
   version, service URL, and tenant.
2. Derive the URL with `primaryUrl`/`selectInterface` against the resolved
   card and this client's binding.
3. Read `tenant` from the matched `AgentInterface` unless the caller
   passed one explicitly; an explicit `tenant` wins.
4. Fix the protocol mode (1.0 vs 0.3) once, via
   `detectProtocolModeForBinding`.

`Client` additionally reads the card's preferred binding, constructs the
matching concrete client with the **already-resolved card** so it is not
fetched twice, and stores it as `delegate`. Every one of its remote
functions is then a one-line delegation. Selection happens once, at
construction.

A directly-constructed concrete client resolves the card itself, since
there is no common client upstream to have done it. Either way, the rest
of construction is identical.

### File layout

`client.bal` is roughly 1900 lines today. Splitting it keeps each
concrete client reviewable on its own and matches the module's existing
one-concern-per-file convention (`grpc_binding.bal`, `grpc_stream.bal`,
`sse.bal`):

- `client.bal` — `resolveAgentCard`, `selectInterface`/`primaryUrl`, the
  `AgentClient` interface, the `Client` delegator, and helpers genuinely
  shared across all three transports.
- `jsonrpc_client.bal` — `JsonRpcClient` and the plain JSON-RPC POST/SSE
  path that is currently the inline fallthrough in `rpcCall` and
  `openEventStream`.
- `rest_client.bal` — `RestClient`, `restCall`, `buildRestRequest`,
  `openRestSseStream`.
- `grpc_client.bal` — `GrpcClient`, `grpcCall`, `dispatchGrpcContextCall`,
  `encodeGrpcRequest`/`decodeGrpcResponse`, `openGrpcStream`.
  `grpc_binding.bal` and `grpc_stream.bal` are unchanged.

Deleted: `signature.bal`, `main.bal`, `tests/signature_test.bal`,
`tests/auth_test.bal` (relocating any `projectToGrpcClientConfig`
coverage it holds).

## What is explicitly unchanged

- Every public spec-facing type in `types.bal`.
- `resolveAgentCard` behavior, including legacy pre-1.0 card
  normalization (synthesizing `supportedInterfaces` from `url` /
  `preferredTransport` / `additionalInterfaces`).
- `selectInterface` selection logic — highest declared protocol version
  wins, not first matching entry — only its visibility changes.
- The 0.3 compatibility layer and the rule that protocol version is fixed
  at construction.
- The `A2AError` taxonomy and all three transports' mappings onto it
  (JSON-RPC codes directly, REST via `google.rpc.ErrorInfo.reason`, gRPC
  by status code).
- All per-binding marshaling internals.

## Follow-up issues

One per removed capability, each recording what existed, why it was
pulled, and what would justify its return:

- [#12](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues/12) —
  AgentCard signature verification (spec §8.4.3). Revisit when a reference
  implementation or a JCS-capable verification path exists.
- [#13](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues/13) —
  Auto-auth wiring from AgentCard security schemes. Records the
  reserved-header collision check and the first-colon-only Basic split as
  worth preserving if it returns.
- [#14](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues/14) —
  ETag-aware AgentCard caching.
