# Transport-Specific Clients + API-Surface Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `Client` class that branches on a `binding` field per call with one concrete client type per transport binding (`JsonRpcClient`, `RestClient`, `GrpcClient`) behind a shared `AgentClient` interface, plus a common `Client` that auto-detects the binding once at construction and delegates. In the same pass, reduce the pre-release public API surface to only what the A2A spec mandates or a consumer demonstrably needs.

**Architecture:** `AgentClient` declares the eleven spec §9.4 client operations. Three concrete classes implement it, each owning exactly one transport's marshaling and carrying no `binding` field. `Client` implements it too, holding a private `AgentClient delegate` chosen at construction from the resolved Agent Card. Per-binding marshaling stays in shared internal helper functions — only the public class boundary multiplies, from one to four.

**Tech Stack:** Ballerina (`isolated client object` types, `isolated client class`, `*T` inclusion, `http:Client`, `grpc`, `ballerina/test`).

**Design spec:** `a2a/docs/superpowers/specs/2026-08-11-transport-specific-clients-design.md` — read this once at the start; it has the full rationale for every removal, demotion, and architectural decision below.

## Global Constraints

- The eleven remote-function signatures do not change. `AgentClient` declares exactly what today's `Client` exposes.
- No spec-facing type in `types.bal` changes shape. This plan changes visibility and client structure only.
- Every removal in PR 2 must be accompanied by its GitHub issue from PR 1 already being filed — the issue is the record of why, and it is filed first.
- Demoting a symbol means deleting the `public` modifier only. Never move, rename, or reimplement a symbol in the same commit that demotes it — those are separate commits.
- Ballerina's `tests/` directory is part of the same module, so demotion never requires a test change. If a test breaks on a demotion, something else is wrong; stop and investigate rather than re-publicizing.
- Per `a2a/CLAUDE.md`: one type or one method per commit, no batching; every commit message cites the design-doc section it implements; `bal build && bal test` green before any unit is considered done.
- Per repo `CLAUDE.md`: commit immediately as each change is made. Never push, open a PR, or merge without an explicit per-step instruction. No Claude/Anthropic attribution anywhere.
- Each PR below is its own branch off the previous one. Do not start a PR's branch until the previous PR's work is committed.

---

### PR 1: Design docs and follow-up issues

**Files:**
- Create: `a2a/docs/superpowers/specs/2026-08-11-transport-specific-clients-design.md`
- Create: `a2a/docs/superpowers/plans/2026-08-11-transport-specific-clients.md`
- Modify: `a2a/docs/A2A_Technical_Design.md`, `a2a/README.md`

- [ ] **Step 1: Write the design and plan docs** (this file and its spec).
- [ ] **Step 2: Update `A2A_Technical_Design.md`** — it is the module's stated source of truth, so its architecture section must describe the four-type split, and its feature list must drop signature verification and auto-auth before the code does.
- [ ] **Step 3: Update `README.md`** — remove the `verifyAgentCardSignature` feature bullet (README.md:81) and any auto-auth/`credentials` mention.
- [ ] **Step 4: File three GitHub issues** on `Anuja-jayasinghe/a2a-ballerina`. **Requires explicit user go-ahead — this is an outward-facing write.** Each records what existed, why it was pulled, and what would justify its return:
  - AgentCard signature verification (spec §8.4.3): procedure mandated, no API defined, no reference implementation, removed impl lacked RFC 8785 JCS canonicalization.
  - Auto-auth wiring from AgentCard security schemes: covered API-key-in-header and HTTP Basic/Bearer; OAuth2/OIDC/mTLS out of scope by design.
  - ETag-aware AgentCard caching: `resolveAgentCardCached`/`CachedAgentCard` conditional GET.

---

### PR 2: Remove non-spec public functions

Each bullet is its own commit. Order matters: delete producers before the error types they produce.

**Files:**
- Delete: `a2a/signature.bal`, `a2a/main.bal`, `a2a/tests/signature_test.bal`, `a2a/tests/auth_test.bal`
- Modify: `a2a/auth.bal`, `a2a/errors.bal`, `a2a/client.bal`, `a2a/types.bal`, `a2a/compat_v03.bal`, `a2a/tests/client_test.bal`, `a2a/tests/compat_v03_test.bal`

- [ ] **Step 1: Delete `signature.bal` and `tests/signature_test.bal`.** Removes `verifyAgentCardSignature` and the file-private `decodeBase64Url`/`encodeBase64Url`.
- [ ] **Step 2: Delete `SignatureVerificationError` and `UnsupportedSignatureAlgorithmError`** from `errors.bal` (lines 57, 64 and their doc comments). Confirm no remaining producer.
- [ ] **Step 3: Drop the `verifyAgentCardSignature` cross-references** in `types.bal` doc comments (lines 354, 688). `AgentCardSignature` and `AgentCard.signatures` themselves stay — the spec defines them.
- [ ] **Step 4: Delete `buildAuthFromCard` and `ResolvedAuth`** from `auth.bal`. Keep `projectToGrpcClientConfig` and its use of `AuthResolutionError`. Update the file header comment, which currently describes only the removed function.
- [ ] **Step 5: Delete the `credentials` parameter** from `Client.init` and its call site at client.bal:608-618. Remove `credentials` from `newClient`'s pass-through too (it is deleted wholesale in PR 4, but must compile until then).
- [ ] **Step 6: Delete `tests/auth_test.bal`.** First check whether it holds any `projectToGrpcClientConfig` coverage; if so, relocate those tests to `tests/grpc_binding_test.bal` in this same commit rather than losing them.
- [ ] **Step 7: Delete `resolveAgentCardCached` and `CachedAgentCard`** from `client.bal` (lines 166-177, and the `CachedAgentCard` record). Simplify the shared `fetchAgentCardWithCaching` helper (client.bal:87-116) down to what `resolveAgentCard` alone needs — the ETag/304 branch has no other caller. Delete the two tests at `tests/client_test.bal:1788,1806`.
- [ ] **Step 8: Delete `detectProtocolMode`** from `compat_v03.bal` (lines 49-58). Rewrite its six test call sites in `tests/compat_v03_test.bal` (lines 12, 20, 31, 46, 59, 829) to call `detectProtocolModeForBinding(card)`, which defaults to `"JSONRPC"` and is behaviorally identical. Fix the stale `detectProtocolMode` doc reference at `types.bal:323`.
- [ ] **Step 9: Delete `main.bal`.** Confirm `bal build` now produces a library rather than `target/bin/a2a.jar` — an executable artifact from a library package is the symptom this removes.
- [ ] **Step 10: `bal build && bal test` green.**

---

### PR 3: Demote internal helpers to non-public

Mechanical and independent of everything else. One commit per symbol; delete the `public` modifier and nothing else.

**Files:** `a2a/types.bal`, `a2a/compat_v03.bal`, `a2a/client.bal`

- [ ] **Step 1:** `encodeRawBytesForWire` (types.bal:151).
- [ ] **Step 2:** `decodeRawBytesFromWire` (types.bal:194).
- [ ] **Step 3:** `parseSecuritySchemes` (types.bal:864).
- [ ] **Step 4:** `parseSecurityRequirements` (types.bal:893).
- [ ] **Step 5:** `parseAgentCardSignatures` (types.bal:912).
- [ ] **Step 6:** `detectProtocolModeForBinding` (compat_v03.bal:30).
- [ ] **Step 7:** `ProtocolMode` (compat_v03.bal:13) — verify first that it appears in no public signature; after Step 6 and PR 2 Step 8 it should appear only in private fields and internal parameters.
- [ ] **Step 8:** `primaryUrl` (client.bal:272).
- [ ] **Step 9:** `selectInterface` (client.bal:242).
- [ ] **Step 10:** Confirm `resolveAgentCard` is the only public free function left in the module. `bal build && bal test` green.

---

### PR 4: Constructor merge — `init(AgentCard|string)`

Lands on today's single `Client`, before the transport split, so PR 8 stays small.

**Files:** `a2a/client.bal`, `a2a/tests/client_test.bal`

**Interfaces:**
- Produces: the `init(AgentCard|string agent, ...)` shape that all four client types adopt in PRs 5-8.

- [ ] **Step 1: Write the failing tests.** Adapt the six existing `newClient*` tests (`tests/client_test.bal:287-344`) to construct via `new Client(...)` instead: construction from a URL, from an `AgentCard`, tenant auto-wired from the card's matched interface, explicit tenant overriding the card's, error when the card has no matching interface, error on an unreachable URL.
- [ ] **Step 2: Move `newClient`'s resolution logic into `Client.init`.** `init` takes `AgentCard|string agent` as its first parameter. If `agent` is a `string`, call `resolveAgentCard`; then derive the URL via `primaryUrl(card, binding)` and the tenant via `selectInterface(card, binding)`, an explicit `tenant` argument winning. Reuse the existing functions — do not reimplement.
- [ ] **Step 3: Delete the `serviceUrl` parameter.** The URL is now always derived from the resolved card. Update the two internal uses (client.bal:619 `http:Client` construction, client.bal:640 gRPC stub construction) to read the derived URL. Fix the stale `serviceUrl` mention in `auth.bal`'s error text (auth.bal:77).
- [ ] **Step 4: Delete `newClient`** and its doc block (client.bal:290-355).
- [ ] **Step 5: Delete the independent `agentCard` parameter** from `init` — the card is now always the resolved one, never an independent argument.
- [ ] **Step 6: Rewrite the ~38 positional call sites** in `tests/client_test.bal` that pass a URL first (`check new (getServerBaseUrl(), ...)`). Most need no change if the URL stays first positionally; the ones passing `agentCard` as a named or positional argument do. Tests that relied on `serviceUrl` pointing somewhere the card does not declare must instead construct an `AgentCard` whose `supportedInterfaces` points there.
- [ ] **Step 7: `bal build && bal test` green.**

---

### PR 5: `AgentClient` interface + `JsonRpcClient`

`Client` is untouched this PR — `JsonRpcClient` lands standalone and fully tested, which keeps the diff reviewable and avoids a half-migrated `Client`.

**Files:**
- Create: `a2a/jsonrpc_client.bal`, `a2a/tests/jsonrpc_client_test.bal`
- Modify: `a2a/client.bal`

**Interfaces:**
- Produces: `AgentClient` (consumed by PRs 6, 7, 8), `JsonRpcClient` (consumed by PR 8).

- [ ] **Step 1: Declare `AgentClient`** in `client.bal` as a `public type AgentClient isolated client object { ... }` with the eleven remote-function signatures copied verbatim from today's `Client`. No implementation yet.
- [ ] **Step 2: Write the failing `JsonRpcClient` construction tests** — from a URL, from a card, tenant auto-wiring, no-matching-interface error.
- [ ] **Step 3: Implement `JsonRpcClient.init`** in `jsonrpc_client.bal`, following the PR 4 shape minus the `binding` parameter (the binding is fixed to `"JSONRPC"` by the type).
- [ ] **Step 4: Implement the eleven remote functions**, one per commit, moving the inline JSON-RPC path out of today's `rpcCall` (client.bal:722-753) and `openEventStream` (client.bal:1041-1087) fallthrough branches. Write each function's test before its implementation.
- [ ] **Step 5: Declare `*AgentClient`** on the class and let the compiler verify the implementation is complete.
- [ ] **Step 6: `bal build && bal test` green.**

---

### PR 6: `RestClient`

**Files:**
- Create: `a2a/rest_client.bal`, `a2a/tests/rest_client_test.bal`

- [ ] **Step 1:** Same construction tests as PR 5, for `RestClient`, binding fixed to `"HTTP+JSON"`.
- [ ] **Step 2:** Implement `RestClient.init`.
- [ ] **Step 3:** Move `restCall` (client.bal:766-794), `buildRestRequest`, and `openRestSseStream` (client.bal:1134-1160) into `rest_client.bal` as the class's marshaling. They stay internal functions; the class calls them.
- [ ] **Step 4:** Implement the eleven remote functions, one per commit, test first.
- [ ] **Step 5:** Declare `*AgentClient`; `bal build && bal test` green.

---

### PR 7: `GrpcClient`

**Files:**
- Create: `a2a/grpc_client.bal`, `a2a/tests/grpc_client_test.bal`

`grpc_binding.bal` and `grpc_stream.bal` are unchanged — this file is the new client-class home, not a duplicate of them.

- [ ] **Step 1:** Construction tests for `GrpcClient`, binding fixed to `"GRPC"`. Note the existing `normalizeGrpcSchemeUrl` handling (client.bal:640) must carry over.
- [ ] **Step 2:** Implement `GrpcClient.init`, including the `grpcstub:A2AServiceClient` stub construction and `projectToGrpcClientConfig` call.
- [ ] **Step 3:** Move `grpcCall` (client.bal:805-814), `dispatchGrpcContextCall` (client.bal:835-920), and `openGrpcStream` (client.bal:1104-1126) into `grpc_client.bal`.
- [ ] **Step 4:** Implement the eleven remote functions, one per commit, test first. Reuse the existing gRPC mock service (`tests/grpcmock_service.bal`, `tests/grpcmock_scripting.bal`) — do not build a new one.
- [ ] **Step 5:** Declare `*AgentClient`; `bal build && bal test` green.

---

### PR 8: `Client` becomes the delegator

**Files:** `a2a/client.bal`, `a2a/tests/client_test.bal`

- [ ] **Step 1: Write the failing delegation tests** — a `Client` built from a card whose preferred binding is `GRPC` must delegate to a `GrpcClient`, and so on for each binding; and the already-resolved card must not be fetched a second time when constructing the delegate.
- [ ] **Step 2: Replace `Client`'s fields** with a single `private final AgentClient delegate`, dropping `httpClient`, `binding`, `grpcStub`, `mode`, and the rest — they now live in the concrete clients.
- [ ] **Step 3: Rewrite `Client.init`** to resolve the card, read its preferred binding (the `binding` parameter still overrides), construct the matching concrete client **with the already-resolved card**, and store it.
- [ ] **Step 4: Rewrite the eleven remote functions** as one-line delegations, one per commit.
- [ ] **Step 5: Delete the dead dispatchers** — `rpcCall`, `openEventStream`, and any now-unreferenced helper left behind in `client.bal`.
- [ ] **Step 6: Declare `*AgentClient`** on `Client`; `bal build && bal test` green.

---

### PR 9: Whole-client test overhaul and final surface check

**Files:** `a2a/tests/client_test.bal`, and a final sweep across both repos.

- [ ] **Step 1: Add whole-client integration coverage** — for each of the three bindings: `Client` auto-detects it from a card, and at least one operation round-trips through the delegation. Reuse the existing test-server fixtures (`tests/testutil.bal`, `tests/grpcmock_service.bal`); do not invent new ones.
- [ ] **Step 2: Add direct-construction coverage** — each concrete client works when constructed directly, bypassing `Client` entirely.
- [ ] **Step 3: Confirm all eleven operations round-trip** on at least the JSON-RPC binding end to end. Cross-binding parity is already covered by the per-class tests from PRs 5-7.
- [ ] **Step 4: Final grep** across `a2a-ballerina` and `a2a-interop-tests` for `serviceUrl`, `newClient`, `verifyAgentCardSignature`, `buildAuthFromCard`, `resolveAgentCardCached`, and `detectProtocolMode`. Expect zero hits outside historical `docs/superpowers/plans/*.md`, which are left as a historical record and not rewritten.
- [ ] **Step 5: Final public-surface check** — `resolveAgentCard` is the only public free function; the public types are the `types.bal` spec set, `TransportBinding`, the `A2AError` hierarchy, and the four client types.
- [ ] **Step 6: `bal build && bal test` green.**
