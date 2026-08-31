# Public API provenance

Every public symbol in `ballerina/a2a`, classified by where it comes from:
the A2A specification, a convention borrowed from a reference SDK, or an
invention of this library. For anything in the last two categories, the
justification for carrying it.

This exists because the honest question about any SDK is *"why is this
here?"* — and for a pre-release library the answer needs to be written
down, since public surface cannot be withdrawn after release without
breaking callers.

**Sources checked directly, not from memory:**

- A2A specification §7.3 (client authentication process), §8.3.2 (client
  protocol selection), §8.4.3 (signature verification), §9.4 (client
  operations), §14.2.2 (extension headers).
- Java SDK — `a2aproject/sdk`: `ClientBuilder`, `Client`, `ClientTransport`
  (SPI), `A2A.getAgentCard`, `A2AHeaders`.
- Python `a2a-sdk` — `a2a.client`: `client_factory.py`, `client.py`,
  `base_client.py`, `card_resolver.py`, and the package's `__all__`.

---

## Summary

| Category | Count |
|---|---|
| Spec-mandated | 52 |
| Reference-SDK convention (not in spec) | 3 |
| Invented here | 8 |
| **Total public symbols** | **63** |

---

## 1. Spec-mandated (52)

Carried because the protocol defines them. No further justification needed.

**Domain types — `types.bal` (36).** `Role`, `Part`, `Message`,
`AgentProvider`, `AgentExtension`, `AgentCapabilities`, `AgentSkill`,
`AgentInterface`, `AgentCard`, `TaskState`, `TaskStatus`, `Artifact`,
`Task`, `TaskStatusUpdateEvent`, `TaskArtifactUpdateEvent`,
`StreamResponse`, `SendMessageResult`, `AuthenticationInfo`,
`TaskPushNotificationConfig`, `SendMessageConfiguration`, `ListTasksFilter`,
`ListTasksResult`, `ListTaskPushNotificationConfigsResult`,
`AgentCardSignature`, plus the security-scheme set (`ApiKeySecurityScheme`,
`HttpAuthSecurityScheme`, `OAuth2SecurityScheme`,
`OpenIdConnectSecurityScheme`, `MutualTlsSecurityScheme`, `SecurityScheme`,
`SecurityRequirement`) and the four OAuth flow records with `OAuthFlows`.

The security types follow OpenAPI 3.0's Security Scheme Object, which the
spec adopts by reference rather than redefining.

**The eleven operations (§9.4)**, declared on `AgentClient` and implemented
by all four client types: `sendMessage`, `sendStreamingMessage`, `getTask`,
`cancelTask`, `subscribeToTask`, `listTasks`,
`createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`,
`listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig`,
`getExtendedAgentCard`.

**Error taxonomy — `errors.bal` (12 of 13).** `A2AErrorDetail`, `A2AError`,
and the nine subtypes mapping one-to-one onto the spec's JSON-RPC error
code table (§4.1): `TaskNotFoundError` (-32001) through
`VersionNotSupportedError` (-32009), plus `A2AInternalError` as the
catch-all for unrecognised codes.

The *codes* are the spec's. Modelling them as distinct Ballerina error
types rather than one error carrying a code is a language-idiom decision —
Ballerina has no exception inheritance, so a distinct-error hierarchy is
the idiomatic equivalent.

**Signature verification — `signature.bal` (3).** `verifyAgentCardSignature`,
`AgentCardKeyProvider`, `AgentCardSignatureError`. Spec §8.4.3 defines a
mandatory six-step canonicalize-and-verify procedure and §8.4.2 the JWS
protected-header shape it verifies against; this is that procedure,
implemented for the two algorithms `ballerina/crypto` supports (RS256,
ES256).

What's a language-idiom choice rather than spec text, same distinction as
the error taxonomy above: one aggregate `AgentCardSignatureError` rather
than per-failure-mode types, since §8.4.3 has no notion of a partially-valid
signature — a caller only ever needs "trusted" or "not." And
`AgentCardKeyProvider` not fetching a card's `jku` (JWK Set URL) itself —
§8.4.3 step 2 requires resolving one, but neither reference SDK's own
verifier does that either; both take a caller-supplied key-resolution
callback keyed by `kid`/`jku` instead, and this matches that shape.

`canonicalizeAgentCardBody` (the underlying JCS canonicalization,
callable on its own) is listed separately in §2 below — it has direct
reference-SDK precedent as an exported function, where the verify/error
types above don't.

---

## 2. Reference-SDK convention, not in the spec (3)

The spec is silent on these. Both reference SDKs do them, so a Ballerina
user coming from either finds what they expect.

### `resolveAgentCard`

The spec defines discovery as a fetch of `/.well-known/agent-card.json`
(§8.2). It does not define an SDK function for it.

Both reference SDKs expose one:

- Java: `A2A.getAgentCard(String agentUrl)` — static, four overloads
- Python: `A2ACardResolver.get_agent_card()`

Carried because discovery is separable from calling: a caller frequently
wants to inspect a card (capabilities, skills, security requirements)
before deciding whether to construct a client at all. Passing a URL
straight to a constructor covers the common path; this covers the rest.

### Server-preference transport selection, with client preference as an opt-out

Spec §8.3.2 says a client should *"select the first supported transport"*,
preferring *"earlier entries in the ordered list"*. What it does **not**
define is how a caller overrides that.

Both reference SDKs make the override explicit and default it off:

- Java: `ClientConfig.isUseClientPreference()`, default `false`
- Python: `use_client_preference: bool = False`, documented
  *"Recommended to use server preferences in most situations"*

This library draws the same distinction, but through the type system rather
than a boolean: `Client` honours the card's ordering, and constructing
`JsonRpcClient`/`RestClient`/`GrpcClient` directly expresses a client
preference. The *semantics* are borrowed; the *mechanism* is ours (see §3).

### `canonicalizeAgentCardBody`

Spec §8.4.1 defines the canonicalization *procedure* signing and
verification both must follow; it does not require an SDK to expose it as
a callable function on its own, separate from the verify/sign operations
that use it internally.

Both reference SDKs export one anyway:

- a2a-js: `canonicalizeAgentCard(agentCard)`
- Python `a2a-sdk`: the equivalent in its own signing utilities

Carried for the same reason they carry it: a caller writing their own
signing tooling, or debugging why a signature doesn't verify, needs to be
able to reproduce exactly what gets signed, not just call a verify
function that hides it.

---

## 3. Invented here (8)

Nothing in the spec or either reference SDK. Each is here for a stated
reason, and each is additive — removable only before release, which is why
they are listed.

### `AgentClient` (interface type)

**Closest precedent, not an equivalent.** Java has `ClientTransport`, an
SPI interface with per-transport implementations, but it is internal
plumbing behind a single public `Client`. Python exposes `Client` and
`BaseClient` and no transport interface at all.

Ours is a *public* interface implemented by all four client types, so
binding-agnostic code can be written against one type:

```ballerina
a2a:AgentClient agent = check new a2a:Client(url);
```

**Why:** the type split (below) is only free for callers if there is a type
that unifies the four. Without it, every function taking a client would
have to name a concrete class and lose the ability to accept another.

**Stability decision:** documented on the type itself as implemented by
this library only, not a stable extension point for external
implementors — the one real forward-compatibility trap identified while
surveying what other A2A SDKs expose that this one doesn't (per-call
context/timeout, an interceptor seam - see the design plan). None of
those are spec-backed or TCK-tested, so none were added speculatively;
but `AgentClient` being public and syntactically implementable means
adding a parameter to its 11 methods later would break anyone who *did*
implement it. Stating the boundary explicitly, rather than adding an
unproven parameter now, keeps that door open without adding surface
nobody has asked for yet.

### `JsonRpcClient`, `RestClient`, `GrpcClient` (public per-transport types)

**This is the significant divergence from both reference SDKs.** Neither
exposes per-transport client classes:

- Java has `JSONRPCTransportProvider`, `RestTransportProvider`,
  `GrpcTransportProvider` — but behind the `ClientTransport` SPI, selected
  by `ClientBuilder`, never constructed directly by a caller.
- Python's `__all__` is `AuthInterceptor`, `BaseClient`, `Client`,
  `ClientCallContext`, `ClientCallInterceptor`, `ClientConfig`,
  `ClientEvent`, `ClientFactory` — no transport classes.

**Why here:** the concept exists in both SDKs; only its visibility differs.
Making it public is what lets client preference be expressed by choosing a
type instead of by a boolean flag — replacing Java's `useClientPreference`
and Python's `use_client_preference` with something the compiler checks.
It also removes per-call binding dispatch entirely: `JsonRpcClient` *is*
the JSON-RPC client, so there is no `if binding == …` to evaluate on every
operation and no reachable-but-wrong branch to test.

**The cost, stated plainly:** three more public types than either reference
SDK, and a caller reading their docs will not find them. If per-transport
types prove to be surface nobody wants, they are the most likely candidate
for withdrawal — which is precisely why the decision is recorded here.

### `maxReconnectAttempts` (automatic SSE/stream reconnection)

**Neither reference SDK does this.** Verified by search: Java's "reconnect"
references are docstrings telling the caller to invoke `subscribeToTask`
again; Python's is a comment on `TaskResubscriptionRequest` in its legacy
module. Both leave reconnection to the caller.

The spec defines `subscribeToTask` as the mechanism for resuming (§3.1.6,
noting the first event is always the task's current state, which is what
makes resumption lossless) — but says nothing about a client doing it
automatically.

**Why here:** opt-in and default `0`, which preserves exactly the
manual-reconnect behaviour both reference SDKs have. When enabled, the
client resubscribes on a dropped (non-terminal) stream up to the configured
count. The attempt budget is deliberately shared across the whole reconnect
chain rather than reset per reconnect — otherwise a persistently failing
agent would retry without bound.

### `requestedExtensions` (constructor parameter)

Sending the header is spec. Making the set a per-client construction
parameter rather than a per-call argument is this library's shape — Python
takes `extensions` per call.

**Why here:** in practice the extension set a client wants is a property of
the client, not of each message. Per-call remains available implicitly, in
that a caller wanting different sets can construct different clients.
Narrower than Python's per-call form; the difference is worth knowing.

### `fetchAgentCardBody`, `parseAgentCardBody`

Neither reference SDK exposes a raw, unparsed card body as a separate
public step — Python's `A2ACardResolver.get_agent_card()` and Java's
`A2A.getAgentCard()` both fetch and parse in one call, returning only the
typed card.

**Why here:** `verifyAgentCardSignature` (§1) has to canonicalize the
response exactly as received, not a parsed `AgentCard` record — a record
carries every field's declared default whether or not the signer
included it on the wire, which would inject content into the canonical
payload the signer never actually signed and guarantee verification
failure. `fetchAgentCardBody` is the raw fetch step split out on its own
so a caller can verify first, then parse the same body afterward without
a second network round trip; `resolveAgentCard` itself is unchanged
(still fetch-then-parse in one call) and delegates to both internally.
`parseAgentCardBody` was already the internal parsing step; it only
needed making `public` for the "parse afterward" half of that flow to be
possible for a caller.

### `resolveAgentCardCached`, `CachedAgentCard`

**Neither reference SDK does this** — Java's client performs no caching
at all; Python's card resolver fetches fresh every time too. Spec §8.6.2
does say clients "SHOULD cache Agent Cards locally to reduce network
requests," but leaves the mechanism undefined; ETag/If-None-Match
conditional GET is this library's own choice of ordinary HTTP caching to
satisfy that SHOULD, not something either reference SDK models.

**Why here:** opt-in and additive, mirroring `maxReconnectAttempts`
above — `resolveAgentCard` is completely unchanged (always fetches
fresh) and unaffected by whether a caller ever reaches for this function
at all. A caller who wants the SHOULD honored calls this one instead;
everyone else pays nothing for its existence.

---

## 4. Deliberately absent

Built, then removed before release for lack of spec definition or SDK
precedent. Each has a tracking issue recording what existed and what would
justify bringing it back. (Two former entries here — `verifyAgentCardSignature`
and `resolveAgentCardCached`/`CachedAgentCard` — have since been revived
with fixes for the reasons they were originally pulled; see §1 and §3.)

| Removed | Issue | Reason |
|---|---|---|
| `buildAuthFromCard` / `ResolvedAuth` / `credentials` | [#13](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues/13) | spec §7.3 puts credential *acquisition* explicitly out-of-band, and transmission/refresh is already handled natively (`http:ClientConfiguration.auth`, `ballerina/oauth2`'s own token cache) — nothing was actually missing once traced through; both SDKs take auth on the builder anyway, and the implementation covered only 2 of 5 scheme kinds by design |
| `lastGrantedExtensions()` | [#33](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues/33) | reading back granted extensions has no spec definition and no SDK precedent — both reference SDKs treat `A2A-Extensions` as request-side only; flagged as the likeliest withdrawal candidate when it was added, which is exactly what happened |

Also removed, without issues, because nothing was lost: `newClient` (folded
into `init`), the `serviceUrl` escape hatch (a caller could dial a URL the
card never declared — the redirection surface that resolving a card exists
to close), `detectProtocolMode` (a one-line delegate), and a leftover
`main()` scaffold.

---

## 5. Internal by design

Not public, listed so the choice is visible rather than accidental:

`TransportBinding`, `ProtocolMode`, `selectInterface`, `primaryUrl`,
`detectProtocolModeForBinding`, `encodeRawBytesForWire`,
`decodeRawBytesFromWire`, `parseSecuritySchemes`,
`parseSecurityRequirements`, `parseAgentCardSignatures`, and every symbol in
`modules/grpcstub` and `modules/transport` (held back at the package
boundary with `export = false`).

`selectInterface` is the closest call: it implements the spec's own §8.3.2
algorithm, which is a defensible thing to expose. It is internal because
once construction performs selection, a consumer has no reason to run it by
hand. Publicizing it later is additive; the reverse is not.

`TransportBinding` became internal as a consequence rather than a decision:
once `Client` took its binding from the card instead of a parameter, the
type stopped appearing in any public signature.
