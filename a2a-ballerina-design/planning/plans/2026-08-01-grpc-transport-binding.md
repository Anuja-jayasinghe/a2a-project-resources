# gRPC Transport Binding + CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the gRPC transport binding designed in
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md`, so
`Client` can speak JSON-RPC, REST, or gRPC to a remote A2A agent, chosen at
construction time, with zero change to the 11 public remote-function
signatures. Then stand up CI for both this repo (`a2a-ballerina`) and the
downstream `a2a-interop-tests` repo, so every push/PR is built and tested
automatically instead of relying on manual `bal build`/`bal test` runs.

**Architecture:** Per the spec's Design decisions 1–6: a vendored,
annotation-stripped `a2a.proto` compiles to a checked-in stub in
`modules/grpcstub` (its own submodule — the generated types collide by name
with `types.bal`). A new `grpc_binding.bal` holds every `encodeGrpc*`/
`decodeGrpc*` conversion function plus `GrpcStreamAdapter`, mirroring how
`compat_v03.bal` already bridges the v0.3 dialect. The binding branch lives
entirely inside the two existing private transport helpers — `rpcCall` and
`openSseStream` (renamed `openEventStream`, per the spec's cross-plan note,
since REST shipped first and left the name alone) — exactly as the REST
binding did. No new client type, no changes to any of the 11 remote function
bodies.

**Tech Stack:** Ballerina 2201.13.4, `ballerina/grpc:1.14.7`, `bal grpc` tool
1.0.0, `protoc` 3.21.7 (auto-downloaded by the tool). GitHub Actions for
CI/CD in both repos.

## Global Constraints

- Every new unit/round-trip test needs no server at all — pure function
  tests on `encodeGrpc*`/`decodeGrpc*`. Streaming and binding-selection
  tests use a mock `grpc:Client`-facing service (`tests/grpcmock/`, built in
  Task 2) the same way `tests/testutil.bal`'s `mockListener` serves the
  JSON-RPC/REST tests — a second, gRPC-speaking mock, not a replacement.
- No existing public function signature changes without a default value
  that preserves current caller behavior exactly. `TransportBinding` gains
  a new union member (`"GRPC"`); `selectInterface`/`primaryUrl`/
  `Client.init` already take a defaulted `binding`/`preferredBinding`
  parameter from the REST work — extending its allowed values requires no
  signature change at all.
- Follow existing code style: `isolated` functions/classes throughout, doc
  comments with `# + param - description` / `# + return - description` on
  every public function, `A2AError` subtypes (never bare `error`) for
  anything the caller should be able to pattern-match on.
- Every task ends green: `bal test` run from `a2a-ballerina/a2a/` with zero
  failures before moving to the next task. The `bal` CLI is not on PATH in
  a bash/git-bash shell in this environment — use PowerShell for all `bal`
  commands.
- Commit after every task.
- The `google_protobuf_Value` → `anydata` post-processing rewrite
  (Design decision 1) must be scripted and must assert exactly 2
  occurrences before proceeding — a silent 0-occurrence match means the
  tool changed behavior and the rewrite step must fail loudly, not
  no-op.
- `Part.data`'s wire round-trip (Task 3) is a hard gate: per the spec, no
  other gRPC work should be built on top of the `anydata` rewrite until
  this test passes against the real generated+compiled stub. If it fails,
  stop and escalate — do not proceed to Task 4 with a workaround.
- `grpcstub:*` generated types are referenced with the `grpcstub:` prefix
  everywhere outside `modules/grpcstub` itself, never imported unqualified,
  so every conversion site stays self-documenting about which side of the
  boundary it's on (per Design decision 1's stated rationale).

---

## Task 1: Vendor the proto, provenance doc, and regeneration script; generate the checked-in client stub

**Files:**
- Create: `a2a/proto/a2a.proto` (vendored, annotation-stripped)
- Create: `a2a/proto/PROVENANCE.md`
- Create: `a2a/scripts/regen-grpc-stub.sh`
- Create: `a2a/modules/grpcstub/a2a_pb.bal` (generated + post-processed)
- Create: `a2a/modules/grpcstub/Module.md` (one-paragraph: generated code, do not hand-edit beyond the scripted rewrite)

**Interfaces:**
- Produces: the `grpcstub` submodule, importable from the root module as
  `import ballerina/a2a.grpcstub;`, exposing `grpcstub:A2AServiceClient`
  and every `grpcstub:*` request/response/domain type named in the design
  spec's field tables (§"The 11 rpcs and their messages" through
  §"The `SecurityScheme` oneof and its five arms").

- [ ] **Step 1: Fetch the upstream proto and record provenance**

Run (PowerShell):

```powershell
$content = gh api repos/a2aproject/A2A/contents/specification/a2a.proto --jq '.content'
[System.Convert]::FromBase64String($content) | Set-Content -Path a2a/proto/a2a.upstream.proto -Encoding Byte
gh api repos/a2aproject/A2A/contents/specification/a2a.proto --jq '{sha, path}'
gh api repos/a2aproject/A2A/commits?path=specification/a2a.proto --jq '.[0].sha'
```

Record the blob SHA, the last-touching commit SHA, and today's date.

- [ ] **Step 2: Write `a2a/proto/PROVENANCE.md`**

```markdown
# a2a.proto provenance

- Upstream repo: `a2aproject/A2A`
- Upstream path: `specification/a2a.proto`
- Blob SHA: `<paste from Step 1>`
- Last-touching commit SHA: `<paste from Step 1>`
- Fetched: `<today's date>`

## Strip rules applied to produce the vendored copy

The vendored `a2a.proto` in this directory is **not** byte-identical to the
upstream file. The following are removed, and only these:

1. The three imports `google/api/annotations.proto`,
   `google/api/client.proto`, `google/api/field_behavior.proto`.
2. Every `option (google.api.http) = { ... };` block on an rpc.
3. Every `[(google.api.method_signature) = "..."]` field/rpc annotation.
4. Every `[(google.api.field_behavior) = ...]` field annotation.

These are HTTP-transcoding and documentation annotations only — they
contribute nothing to the gRPC wire format or to the generated Ballerina
types (`bal grpc` does not read them for anything but the fields removed
above). Stripping them is required because `bal grpc` cannot resolve the
`google/api/*` imports without vendoring `googleapis/googleapis` as well,
and doing so does not actually fix codegen (see the design spec's Finding 2,
Defect A) — it still emits references to constants the tool never
generates.

## Regenerating

Run `a2a/scripts/regen-grpc-stub.sh` from the repo root. It re-derives the
stub from this vendored proto and fails (with a diff) if the checked-in
`a2a/modules/grpcstub/a2a_pb.bal` would change — review the diff, decide
whether it's expected (spec moved) or a regression, and re-run with
`--apply` to accept it.

If the upstream proto changes, re-run Step 1 above to refresh both this
file and `a2a.upstream.proto`, then manually re-apply the four strip rules
to produce a new vendored `a2a.proto`, then run the regen script.
```

- [ ] **Step 3: Produce the annotation-stripped vendored proto**

Fetch `a2a.upstream.proto` (Step 1's output) and manually apply the four
strip rules from `PROVENANCE.md` to produce `a2a/proto/a2a.proto`: delete
the three `import "google/api/...";` lines, and delete every
`option (google.api.http) = {...};`, `[(google.api.method_signature) = ...]`,
and `[(google.api.field_behavior) = ...]` occurrence (these are easiest to
strip with a small Python/PowerShell script that regex-matches balanced
`{...}` option blocks and bracketed field annotations — write one, run it,
then manually diff the result against upstream to confirm only those four
categories were removed and nothing else changed). Confirm the result still
declares `package lf.a2a.v1;` and `service A2AService` with all 11 rpcs.

- [ ] **Step 4: Write `a2a/scripts/regen-grpc-stub.sh`**

```bash
#!/usr/bin/env bash
# Regenerates a2a/modules/grpcstub/a2a_pb.bal from a2a/proto/a2a.proto and
# checks whether the result matches what's checked in. Run with --apply to
# overwrite the checked-in file instead of just diffing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$REPO_ROOT/proto"
STUB_DIR="$REPO_ROOT/modules/grpcstub"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

echo "Regenerating gRPC stub from $PROTO_DIR/a2a.proto ..."
bal grpc --input "$PROTO_DIR/a2a.proto" --proto-path "$PROTO_DIR" --output "$SCRATCH_DIR"

GENERATED_FILE="$SCRATCH_DIR/a2a_pb.bal"
if [ ! -f "$GENERATED_FILE" ]; then
    echo "ERROR: bal grpc did not produce a2a_pb.bal at the expected path" >&2
    exit 1
fi

echo "Post-processing: rewriting google_protobuf_Value -> anydata ..."
OCCURRENCES=$(grep -o "google_protobuf_Value" "$GENERATED_FILE" | wc -l | tr -d ' ')
if [ "$OCCURRENCES" -ne 2 ]; then
    echo "ERROR: expected exactly 2 occurrences of google_protobuf_Value, found $OCCURRENCES." >&2
    echo "The bal grpc tool's output shape has changed — do not proceed with this rewrite." >&2
    exit 1
fi
sed -i 's/google_protobuf_Value/anydata/g' "$GENERATED_FILE"

if [ "${1:-}" = "--apply" ]; then
    cp "$GENERATED_FILE" "$STUB_DIR/a2a_pb.bal"
    echo "Applied. $STUB_DIR/a2a_pb.bal updated."
    exit 0
fi

if ! diff -q "$GENERATED_FILE" "$STUB_DIR/a2a_pb.bal" >/dev/null 2>&1; then
    echo "DRIFT DETECTED: regenerated stub differs from checked-in a2a_pb.bal." >&2
    diff "$STUB_DIR/a2a_pb.bal" "$GENERATED_FILE" || true
    exit 1
fi

echo "OK: checked-in stub matches regeneration from a2a.proto."
```

Make it executable: `chmod +x a2a/scripts/regen-grpc-stub.sh`.

- [ ] **Step 5: Generate and check in the stub for the first time**

Run (PowerShell, since `bal` isn't on PATH in bash here):

```powershell
bal grpc --input a2a/proto/a2a.proto --proto-path a2a/proto --output a2a/modules/grpcstub
```

Then apply the same rewrite the script does — open
`a2a/modules/grpcstub/a2a_pb.bal`, confirm exactly 2 occurrences of
`google_protobuf_Value`, and replace both with `anydata`.

Add `a2a/modules/grpcstub/Module.md`:

```markdown
# grpcstub

Generated Ballerina gRPC client stub for the A2A protocol's `GRPC` binding,
produced from `a2a/proto/a2a.proto` by `a2a/scripts/regen-grpc-stub.sh`.

**Do not hand-edit this module beyond the scripted `google_protobuf_Value`
→ `anydata` rewrite the regeneration script already applies.** It lives in
its own submodule (not the root module) because its generated type names
collide with `types.bal`'s domain types — see the design spec's Finding 3.
```

- [ ] **Step 6: Confirm the stub compiles standalone**

Run: `bal build a2a` (PowerShell, from `a2a-ballerina/`)
Expected: PASS — the new `grpcstub` submodule compiles clean, and since
nothing in the root module imports it yet, the rest of the package is
unaffected.

- [ ] **Step 7: Commit**

```bash
git add a2a/proto/a2a.proto a2a/proto/PROVENANCE.md a2a/scripts/regen-grpc-stub.sh a2a/modules/grpcstub/
git commit -m "feat: vendor A2A proto and generate the gRPC client stub submodule"
```

---

## Task 2: A scriptable gRPC mock service for tests

**Files:**
- Create: `a2a/tests/grpcmock/service.bal` (implements `A2AService` against the generated service skeleton)
- Create: `a2a/tests/grpcmock/scripting.bal` (scriptable next-response state, mirroring `tests/testutil.bal`'s HTTP mock)
- Modify: `a2a/tests/testutil.bal` (export a `getGrpcMockPort()` helper alongside the existing `getServerBaseUrl()`)

**Interfaces:**
- Consumes: nothing from earlier tasks besides the compiled `grpcstub` module.
- Produces: a `grpc:Listener` on `localhost:19198` (distinct from the HTTP
  mock's `19199`) running a scripted `A2AService` implementation, plus
  test-only functions `setNextGrpcResponse(grpcstub:StreamResponse|grpcstub:SendMessageResponse|grpcstub:Task|... value)`,
  `setNextGrpcError(grpc:Error err)`, `getLastGrpcMetadata() returns map<string|string[]>`
  that every later gRPC test task reuses.

- [ ] **Step 1: Generate a service-mode skeleton into scratch, and copy the parts needed**

Run (PowerShell, scratch dir, not committed):

```powershell
bal grpc --input a2a/proto/a2a.proto --proto-path a2a/proto --output scratch/grpc_service_sample --mode service
```

Inspect `scratch/grpc_service_sample/a2a_pb.bal` (the service-mode stub —
same message/client types as Task 1's, plus the `A2AService` service-type
declaration and a sample `service.bal` showing the expected method
signatures for `remote function SendMessage(...)`,
`remote function SendStreamingMessage(...) returns stream<...>`, etc.). Do
not check the sample service in verbatim — write `a2a/tests/grpcmock/service.bal`
by hand, following the method signatures the sample demonstrates, wired to
the scripted response state from Step 2 below. Delete `scratch/` when done.

- [ ] **Step 2: Write the scriptable response state**

```ballerina
// a2a/tests/grpcmock/scripting.bal
//
// Scriptable state for the gRPC mock service, mirroring tests/testutil.bal's
// HTTP mock pattern: tests call setNextGrpcResponse/setNextGrpcError before
// invoking a Client against getGrpcMockUrl(), and the mock service consults
// this state to decide what to return.
import ballerina/lang.value;

isolated int grpcMockPort = 19198;

public isolated function getGrpcMockUrl() returns string {
    lock {
        return string `http://localhost:${grpcMockPort}`;
    }
}

// Tagged union of every response shape a mock rpc might need to return.
// anydata (not a concrete grpcstub type) so this module doesn't have to
// import grpcstub — it's populated with grpcstub:* values by the test that
// calls setNextGrpcResponse, and consumed with a runtime type check on the
// mock service side, which does import grpcstub.
isolated anydata? nextGrpcResponse = ();
isolated grpc:Error? nextGrpcError = ();
isolated map<string|string[]> lastGrpcMetadata = {};

public isolated function setNextGrpcResponse(anydata value) {
    lock {
        nextGrpcResponse = value.clone();
        nextGrpcError = ();
    }
}

public isolated function setNextGrpcError(grpc:Error err) {
    lock {
        nextGrpcError = err;
        nextGrpcResponse = ();
    }
}

public isolated function getLastGrpcMetadata() returns map<string|string[]> {
    lock {
        return lastGrpcMetadata.clone();
    }
}

isolated function takeNextGrpcResponse() returns anydata|error {
    lock {
        grpc:Error? err = nextGrpcError;
        if err is grpc:Error {
            return err;
        }
        anydata? resp = nextGrpcResponse;
        if resp is () {
            return error("grpcmock: no scripted response set for this call");
        }
        return resp.clone();
    }
}

isolated function recordGrpcMetadata(map<string|string[]> headers) {
    lock {
        lastGrpcMetadata = headers.clone();
    }
}

import ballerina/grpc;
```

(Reorder the trailing `import` to the top of the file per Ballerina
convention when actually writing it — shown last here only because it's
referenced by `grpc:Error`/`grpc:Error?` above.)

- [ ] **Step 3: Write the mock service, dispatching every rpc through the scripted state**

```ballerina
// a2a/tests/grpcmock/service.bal
import ballerina/a2a.grpcstub;
import ballerina/grpc;

listener grpc:Listener grpcMockListener = new (19198);

service "A2AService" on grpcMockListener {

    remote function SendMessage(grpcstub:SendMessageRequest req, map<string|string[]> headers)
            returns grpcstub:SendMessageResponse|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:SendMessageResponse);
    }

    remote function SendStreamingMessage(grpcstub:SendMessageRequest req, map<string|string[]> headers)
            returns stream<grpcstub:StreamResponse, error?>|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        grpcstub:StreamResponse[] events = check resp.ensureType();
        return events.toStream();
    }

    remote function GetTask(grpcstub:GetTaskRequest req, map<string|string[]> headers)
            returns grpcstub:Task|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:Task);
    }

    remote function ListTasks(grpcstub:ListTasksRequest req, map<string|string[]> headers)
            returns grpcstub:ListTasksResponse|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:ListTasksResponse);
    }

    remote function CancelTask(grpcstub:CancelTaskRequest req, map<string|string[]> headers)
            returns grpcstub:Task|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:Task);
    }

    remote function SubscribeToTask(grpcstub:SubscribeToTaskRequest req, map<string|string[]> headers)
            returns stream<grpcstub:StreamResponse, error?>|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        grpcstub:StreamResponse[] events = check resp.ensureType();
        return events.toStream();
    }

    remote function CreateTaskPushNotificationConfig(grpcstub:TaskPushNotificationConfig req, map<string|string[]> headers)
            returns grpcstub:TaskPushNotificationConfig|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:TaskPushNotificationConfig);
    }

    remote function GetTaskPushNotificationConfig(grpcstub:GetTaskPushNotificationConfigRequest req, map<string|string[]> headers)
            returns grpcstub:TaskPushNotificationConfig|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:TaskPushNotificationConfig);
    }

    remote function ListTaskPushNotificationConfigs(grpcstub:ListTaskPushNotificationConfigsRequest req, map<string|string[]> headers)
            returns grpcstub:ListTaskPushNotificationConfigsResponse|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:ListTaskPushNotificationConfigsResponse);
    }

    remote function DeleteTaskPushNotificationConfig(grpcstub:DeleteTaskPushNotificationConfigRequest req, map<string|string[]> headers)
            returns grpcstub:Empty|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:Empty);
    }

    remote function GetExtendedAgentCard(grpcstub:GetExtendedAgentCardRequest req, map<string|string[]> headers)
            returns grpcstub:AgentCard|error {
        recordGrpcMetadata(headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:AgentCard);
    }
}
```

(The exact remote-function parameter shape — whether headers arrive as a
second parameter or via a `grpc:Caller`/context object — must be confirmed
against the Step 1 generated sample and adjusted here to match; the sample
is authoritative over this sketch if they differ. `grpcstub:Empty` is the
generated Ballerina name for `google.protobuf.Empty` — confirm the exact
name against the generated stub and adjust if the tool names it
differently, e.g. `grpcstub:google_protobuf_Empty` or similar.)

- [ ] **Step 4: Confirm the mock compiles and starts**

Run: `bal build a2a` (PowerShell)
Expected: PASS. Then run a throwaway `bal test a2a --tests grpcmock` (or
equivalent) with one smoke test that constructs a raw `grpcstub:A2AServiceClient`
against `http://localhost:19198`, calls `SendMessage` after
`setNextGrpcResponse` primes a `grpcstub:SendMessageResponse`, and asserts
the value round-trips.

- [ ] **Step 5: Commit**

```bash
git add a2a/tests/grpcmock/ a2a/tests/testutil.bal
git commit -m "test: add scriptable gRPC mock service for gRPC binding tests"
```

---

## Task 3: Part.data wire round-trip test — mandatory gate

**Files:**
- Test: `a2a/tests/grpc_wire_test.bal`

**Interfaces:**
- Consumes: `grpcstub:A2AServiceClient`, `grpcstub:Part`, `grpcstub:Message`,
  `grpcstub:SendMessageRequest`, `grpcstub:SendMessageResponse` (Task 1);
  `getGrpcMockUrl`, `setNextGrpcResponse` (Task 2).
- Produces: nothing consumed by later tasks — this is a pure gate. If it
  fails, stop and revisit Design decision 1 before continuing (see Global
  Constraints).

- [ ] **Step 1: Write the six data-shape round-trip tests plus the unset case**

```ballerina
import ballerina/test;
import ballerina/a2a.grpcstub;

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonObject() returns error? {
    check assertPartDataRoundTrips({"key": "value", "nested": {"n": 1}});
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonArray() returns error? {
    check assertPartDataRoundTrips([1, 2, "three", true, null]);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripString() returns error? {
    check assertPartDataRoundTrips("plain string");
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripNumber() returns error? {
    check assertPartDataRoundTrips(42.5);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripBoolean() returns error? {
    check assertPartDataRoundTrips(false);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripNull() returns error? {
    check assertPartDataRoundTrips(null);
}

@test:Config {groups: ["grpc"]}
function testPartUnsetDataRoundTrips() returns error? {
    grpcstub:Part sentPart = {text: "hello, no data field"};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    grpcstub:Message? msg = echoed?.message;
    test:assertTrue(msg is grpcstub:Message, "expected a message back");
    grpcstub:Part[] parts = (<grpcstub:Message>msg).parts;
    test:assertEquals(parts.length(), 1);
    test:assertTrue(parts[0]?.data is (), "data must not be fabricated for a Part that never set it");
}

isolated function assertPartDataRoundTrips(anydata dataValue) returns error? {
    grpcstub:Part sentPart = {data: dataValue};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    grpcstub:Message? msg = echoed?.message;
    test:assertTrue(msg is grpcstub:Message, "expected a message back");
    grpcstub:Part[] parts = (<grpcstub:Message>msg).parts;
    test:assertEquals(parts.length(), 1);
    test:assertEquals(parts[0]?.data, dataValue, "Part.data did not round-trip byte-equal");
}

// Sends a single-Part Message through the real generated grpc:Client against
// the mock service (which echoes whatever it's asked to via
// setNextGrpcResponse — scripted here to echo the same Part back inside a
// Message), exercising the real protobuf marshaller both directions. This is
// the one test in the whole gRPC binding that a pure unit-level mock cannot
// satisfy, per the design spec: the defect under test is in marshalling
// against the embedded descriptor, so the codec has to actually run.
isolated function sendPartThroughGrpcMock(grpcstub:Part part) returns grpcstub:SendMessageResponse|error {
    grpcstub:A2AServiceClient grpcClient = check new (getGrpcMockUrl());
    grpcstub:Message echoMessage = {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [part]};
    grpcstub:SendMessageResponse scripted = {message: echoMessage};
    setNextGrpcResponse(scripted);
    grpcstub:SendMessageRequest req = {message: {message_id: "m1", role: grpcstub:ROLE_USER, parts: [part]}};
    return grpcClient->SendMessage(req);
}
```

(`grpcstub:ROLE_AGENT`/`grpcstub:ROLE_USER` and the exact snake_case field
names — `message_id` — must match whatever Task 1's generated stub actually
produced; adjust names here to match if the generator's naming convention
differs from the design spec's prediction in any field.)

- [ ] **Step 2: Run the tests**

Run: `bal test a2a --tests testPartDataRoundTrip,testPartUnsetDataRoundTrips` (PowerShell)
Expected: all PASS. **If any fails**, this is the hard gate from Global
Constraints — do not proceed to Task 4. Revisit whether the
`google_protobuf_Value` → `anydata` rewrite needs replacing with a
hand-written `Value` type (Design decision 1's stated fallback) before any
further gRPC work.

- [ ] **Step 3: Commit**

```bash
git add a2a/tests/grpc_wire_test.bal
git commit -m "test: gate gRPC work on Part.data wire round-trip through the real codec"
```

---

## Task 4: Enum-parity test

**Files:**
- Test: `a2a/tests/grpc_types_test.bal`

**Interfaces:**
- Consumes: `Role`, `TaskState` (`types.bal`); `grpcstub:Role`, `grpcstub:TaskState` (Task 1).

- [ ] **Step 1: Write the test**

```ballerina
import ballerina/test;
import ballerina/a2a.grpcstub;

@test:Config {groups: ["grpc"]}
function testRoleEnumParity() {
    string[] libraryMembers = ["ROLE_UNSPECIFIED", "ROLE_USER", "ROLE_AGENT"];
    foreach string m in libraryMembers {
        test:assertTrue(grpcRoleHasMember(m), string `grpcstub:Role missing member ${m} present in types.bal Role`);
    }
}

@test:Config {groups: ["grpc"]}
function testTaskStateEnumParity() {
    string[] libraryMembers = [
        "TASK_STATE_UNSPECIFIED", "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING",
        "TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
        "TASK_STATE_REJECTED", "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"
    ];
    foreach string m in libraryMembers {
        test:assertTrue(grpcTaskStateHasMember(m), string `grpcstub:TaskState missing member ${m} present in types.bal TaskState`);
    }
}

isolated function grpcRoleHasMember(string name) returns boolean {
    grpcstub:Role|error r = trap name.ensureType(grpcstub:Role);
    return r is grpcstub:Role;
}

isolated function grpcTaskStateHasMember(string name) returns boolean {
    grpcstub:TaskState|error s = trap name.ensureType(grpcstub:TaskState);
    return s is grpcstub:TaskState;
}
```

- [ ] **Step 2: Run and confirm PASS**

Run: `bal test a2a --tests testRoleEnumParity,testTaskStateEnumParity` (PowerShell)
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add a2a/tests/grpc_types_test.bal
git commit -m "test: assert Role/TaskState enum parity between types.bal and grpcstub"
```

---

## Task 5: `TransportBinding` gains `"GRPC"`; binding selection, scheme normalization, v0.3 rejection

**Files:**
- Modify: `a2a/client.bal:178` (`TransportBinding`)
- Modify: `a2a/compat_v03.bal:30` (`detectProtocolModeForBinding`)
- Test: `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: existing `selectInterface`, `primaryUrl`, `detectProtocolModeForBinding` (all already take a `TransportBinding` parameter from the REST work — only the union's member set changes).
- Produces: `TransportBinding` = `"JSONRPC"|"HTTP+JSON"|"GRPC"`; a new
  `normalizeGrpcSchemeUrl(string url) returns string` helper later tasks
  (Task 13) call from `Client.init`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testSelectInterfaceGrpcOnlyCard() returns error? {
    AgentCard card = {
        name: "grpc-agent", description: "d", version: "1.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://localhost:9090", protocolBinding: "GRPC", protocolVersion: "1.0"}],
        skills: []
    };
    AgentInterface iface = check selectInterface(card, "GRPC");
    test:assertEquals(iface.url, "http://localhost:9090");
}

@test:Config {groups: ["grpc"]}
function testSelectInterfaceMixedCardOrdering() returns error? {
    AgentCard card = {
        name: "mixed-agent", description: "d", version: "1.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:9090", protocolBinding: "GRPC", protocolVersion: "1.0"},
            {url: "http://localhost:8080", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "http://localhost:8081", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: []
    };
    test:assertEquals(check primaryUrl(card, "GRPC"), "http://localhost:9090");
    test:assertEquals(check primaryUrl(card, "JSONRPC"), "http://localhost:8080");
    test:assertEquals(check primaryUrl(card, "HTTP+JSON"), "http://localhost:8081");
}

@test:Config {groups: ["grpc"]}
function testGrpcSchemeNormalization() {
    test:assertEquals(normalizeGrpcSchemeUrl("grpc://localhost:9090"), "http://localhost:9090");
    test:assertEquals(normalizeGrpcSchemeUrl("grpcs://localhost:9090"), "https://localhost:9090");
    test:assertEquals(normalizeGrpcSchemeUrl("http://localhost:9090"), "http://localhost:9090");
    test:assertEquals(normalizeGrpcSchemeUrl("https://localhost:9090"), "https://localhost:9090");
}

@test:Config {groups: ["grpc"]}
function testClientInitRejectsV03PlusGrpc() returns error? {
    AgentCard card = {
        name: "legacy", description: "d", version: "1.0", protocolVersion: "0.3",
        capabilities: {},
        supportedInterfaces: [{url: "http://localhost:9090", protocolBinding: "GRPC"}],
        skills: []
    };
    Client|error result = new (getGrpcMockUrl(), agentCard = card, binding = "GRPC");
    test:assertTrue(result is VersionNotSupportedError, "expected VersionNotSupportedError for v0.3 + GRPC");
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bal test a2a --tests testSelectInterfaceGrpcOnlyCard,testSelectInterfaceMixedCardOrdering,testGrpcSchemeNormalization,testClientInitRejectsV03PlusGrpc` (PowerShell)
Expected: compile errors (`"GRPC"` not assignable to `TransportBinding`;
`normalizeGrpcSchemeUrl` undefined).

- [ ] **Step 3: Extend `TransportBinding` and add the scheme normalizer**

Edit `client.bal:178`:

```ballerina
# The A2A transport bindings this library can speak.
public type TransportBinding "JSONRPC"|"HTTP+JSON"|"GRPC";
```

`selectInterface` and `primaryUrl` need no code change — they already
compare `iface.protocolBinding == preferredBinding` generically. Add the
scheme normalizer near them:

```ballerina
# Normalizes a non-normative grpc://\grpcs:// scheme (observed in the wild
# on some AgentCards) to the http://\https:// form grpc:Client actually
# accepts. A conformant card's GRPC interface url is already http(s), in
# which case this is a no-op.
#
# + url - the GRPC interface's url, as published on the AgentCard
# + return - the url with any grpc/grpcs scheme rewritten to http/https
isolated function normalizeGrpcSchemeUrl(string url) returns string {
    if url.startsWith("grpcs://") {
        return "https://" + url.substring(8);
    }
    if url.startsWith("grpc://") {
        return "http://" + url.substring(7);
    }
    return url;
}
```

- [ ] **Step 4: Extend `detectProtocolModeForBinding`'s v0.3 rejection to include GRPC**

Read `compat_v03.bal:30` first to confirm its current body handles
`"HTTP+JSON"` how the REST task left it, then add the `"GRPC"` arm using
the exact same reasoning (`compat_v03.bal` is a JSON-shape translation
layer with no meaning over protobuf, matching the design spec's Design
decision 2). The `Client.init` rejection itself (returning
`VersionNotSupportedError`) is wired in Task 13, alongside the REST
binding's existing `binding == "HTTP+JSON"` check — this task only ensures
`detectProtocolModeForBinding` resolves `V0_3` correctly for a `GRPC`-only
card so Task 13's check has something correct to read.

- [ ] **Step 5: Run tests, expect PASS**

Run: `bal test a2a --tests testSelectInterfaceGrpcOnlyCard,testSelectInterfaceMixedCardOrdering,testGrpcSchemeNormalization` (PowerShell)
Expected: PASS. `testClientInitRejectsV03PlusGrpc` still fails/doesn't
compile — `Client.init` doesn't check `binding == "GRPC"` yet. That's
expected; it's finished in Task 13. Leave the test in place (skip it via
`@test:Config {groups: ["grpc"], enable: false}` with a comment pointing at
Task 13, or simply defer adding this one test until Task 13 — either is
fine, but do not leave a permanently-failing test in a green build).

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/compat_v03.bal a2a/tests/client_test.bal
git commit -m "feat: extend TransportBinding with GRPC, add grpc/grpcs scheme normalization"
```

---

## Task 6: Shared gRPC conversion helpers (`grpc_binding.bal`)

**Files:**
- Create: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Produces: `grpcKvToMap`, `mapToGrpcKv`, `grpcTimestampToString`,
  `stringToGrpcTimestamp`, `grpcStructToJson`, `jsonToGrpcStruct`,
  `emptyGrpcStringToNil`, `emptyGrpcTimestampToNil` — all `isolated
  function`s in the new `grpc_binding.bal`, used by every later task in
  this file.

- [ ] **Step 1: Write the failing tests**

```ballerina
import ballerina/test;
import ballerina/time;

@test:Config {groups: ["grpc"]}
function testGrpcKvToMapStringValues() {
    record {|string key; string value;|}[] kv = [{key: "a", value: "1"}, {key: "b", value: "2"}];
    map<string> result = grpcKvToMap(kv);
    test:assertEquals(result, {"a": "1", "b": "2"});
}

@test:Config {groups: ["grpc"]}
function testMapToGrpcKvStringValues() {
    map<string> m = {"a": "1", "b": "2"};
    record {|string key; string value;|}[] result = mapToGrpcKv(m);
    test:assertEquals(result.length(), 2);
    map<string> roundTripped = grpcKvToMap(result);
    test:assertEquals(roundTripped, m);
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringDefaultIsAbsent() {
    time:Utc zeroTimestamp = [0, 0.0d];
    test:assertEquals(grpcTimestampToString(zeroTimestamp), ());
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringRealValue() returns error? {
    time:Utc ts = check time:utcFromString("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00.000Z");
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampRoundTrips() returns error? {
    time:Utc ts = check stringToGrpcTimestamp("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00.000Z");
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampAbsentIsZero() returns error? {
    time:Utc ts = check stringToGrpcTimestamp(());
    test:assertEquals(ts, [0, 0.0d]);
}

@test:Config {groups: ["grpc"]}
function testEmptyGrpcStringToNil() {
    test:assertEquals(emptyGrpcStringToNil(""), ());
    test:assertEquals(emptyGrpcStringToNil("x"), "x");
}

@test:Config {groups: ["grpc"]}
function testGrpcStructRoundTrip() returns error? {
    map<json> original = {"a": 1, "b": "two", "c": {"nested": true}};
    map<anydata> struct = jsonToGrpcStruct(original);
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, original);
}

@test:Config {groups: ["grpc"]}
function testGrpcStructEmptyMapIsAbsent() returns error? {
    map<anydata> struct = {};
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, ());
}
```

- [ ] **Step 2: Run to verify they fail (undefined functions)**

Run: `bal test a2a --tests testGrpcKvToMapStringValues` (PowerShell)
Expected: compile error, functions undefined.

- [ ] **Step 3: Implement `grpc_binding.bal`'s shared helpers**

```ballerina
// Conversion layer between the generated grpcstub:* protobuf types and
// this library's own types.bal domain types. Mirrors compat_v03.bal's
// encodeV03*/parseV03* pattern for the same reason: the generated records
// are structurally incompatible with types.bal (snake_case fields, closed
// records, sentinel-default presence, map fields as key/value arrays,
// google.protobuf.Timestamp as a time:Utc tuple) — see the design spec's
// Finding 4 for the full enumeration. No amount of cloneWithType bridges
// that.
import ballerina/time;

# Converts a generated proto map field (a key/value record array, since
# protobuf maps generate that shape rather than a real Ballerina map — see
# design spec Finding 4d) into a real map<string>.
#
# + kv - the generated key/value array
# + return - an equivalent map<string>
isolated function grpcKvToMap(record {|string key; string value;|}[] kv) returns map<string> {
    map<string> result = {};
    foreach var entry in kv {
        result[entry.key] = entry.value;
    }
    return result;
}

# The reverse of grpcKvToMap: builds the key/value array shape a generated
# proto map field expects from a real map<string>.
#
# + m - the map to convert
# + return - the equivalent key/value array
isolated function mapToGrpcKv(map<string> m) returns record {|string key; string value;|}[] {
    record {|string key; string value;|}[] result = [];
    foreach [string, string] [k, v] in m.entries() {
        result.push({key: k, value: v});
    }
    return result;
}

# Converts a generated google.protobuf.Timestamp (time:Utc tuple) into an
# RFC 3339 string, per types.bal's string? timestamp field convention.
# The proto3 sentinel default [0, 0.0d] (Unix epoch) decodes to () rather
# than to "1970-01-01T00:00:00Z" — per design spec Design decision 5, rule
# 3, this is the highest-risk silent-corruption case in the whole layer: a
# TaskStatus.timestamp of [0, 0.0d] means "field not set", not "set to the
# epoch."
#
# + ts - the generated timestamp value
# + return - the RFC 3339 string, or () if ts is the proto3 zero-default
isolated function grpcTimestampToString(time:Utc ts) returns string? {
    if ts[0] == 0 && ts[1] == 0.0d {
        return ();
    }
    return time:utcToString(ts);
}

# The reverse of grpcTimestampToString: () encodes to the proto3
# zero-default [0, 0.0d], matching what an unset non-optional Timestamp
# field looks like on the wire.
#
# + s - the RFC 3339 string, or ()
# + return - the equivalent time:Utc tuple, or an error if s is a non-()
#            value that isn't valid RFC 3339
isolated function stringToGrpcTimestamp(string? s) returns time:Utc|error {
    if s is () {
        return [0, 0.0d];
    }
    return check time:utcFromString(s);
}

# Non-optional proto3 string fields default to "" when unset; types.bal
# models the same fields as string?. Per design spec Design decision 5,
# rule 1, "" always decodes to () for these fields — there is no way on
# the wire to distinguish "explicitly set to empty string" from "unset",
# so () is the only correct decoding.
#
# + s - the generated string field's value
# + return - s unchanged, or () if s is empty
isolated function emptyGrpcStringToNil(string s) returns string? {
    return s.length() == 0 ? () : s;
}

# Converts a generated google.protobuf.Struct field (map<anydata>, per
# design spec Finding 4d) into map<json>?, matching types.bal's metadata/
# params/header field convention. An empty struct decodes to () rather
# than {} — per Design decision 5 rule 2, an all-defaults nested message
# means "not set," and an empty Struct is exactly that case for this
# field type.
#
# + struct - the generated Struct field's value
# + return - the equivalent map<json>, or () if struct is empty, or an
#            error if a value inside it falls outside json's value space
isolated function grpcStructToJson(map<anydata> struct) returns map<json>?|error {
    if struct.length() == 0 {
        return ();
    }
    json|error asJson = struct.cloneWithType(json);
    if asJson is error {
        return error InvalidAgentResponseError(
            string `struct field could not be narrowed to json: ${asJson.message()}`,
            message = string `struct field could not be narrowed to json: ${asJson.message()}`
        );
    }
    map<json> result = check asJson.ensureType();
    return result;
}

# The reverse of grpcStructToJson: () or an empty map both encode to an
# empty map<anydata> (the proto3 wire representation of "no Struct set").
#
# + j - the map<json>? field's value
# + return - the equivalent map<anydata>
isolated function jsonToGrpcStruct(map<json>? j) returns map<anydata> {
    if j is () {
        return {};
    }
    return j;
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `bal test a2a --tests testGrpcKvToMapStringValues,testMapToGrpcKvStringValues,testGrpcTimestampToStringDefaultIsAbsent,testGrpcTimestampToStringRealValue,testStringToGrpcTimestampRoundTrips,testStringToGrpcTimestampAbsentIsZero,testEmptyGrpcStringToNil,testGrpcStructRoundTrip,testGrpcStructEmptyMapIsAbsent` (PowerShell)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add shared gRPC conversion helpers (kv-map, timestamp, struct, empty-string)"
```

---

## Task 7: `encodeGrpcPart`/`decodeGrpcPart`, including the base64⇄bytes asymmetry and the `Part.data` narrowing rule

**Files:**
- Modify: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Consumes: `grpcKvToMap`/`mapToGrpcKv`/`emptyGrpcStringToNil`/`grpcStructToJson`/`jsonToGrpcStruct` (Task 6).
- Produces: `encodeGrpcPart(Part p) returns grpcstub:Part|error`,
  `decodeGrpcPart(grpcstub:Part p, int partIndex) returns Part|error`.

**Important, non-obvious wrinkle this task must handle:** `rpcCall`'s
callers (the 11 remote functions) already call `encodeRawBytesForWire`
before params ever reach `rpcCall`/`encodeGrpcRequest` — that function
base64-encodes any `Part.raw` byte array into a string, because the
JSON-RPC and REST bindings need base64 on the wire. gRPC's `Part.raw` is
genuine `bytes` on the wire (no base64 — see the design spec's closing
note under §"The `SecurityScheme` oneof and its five arms": "this is the
one place the gRPC binding is *more* faithful than the JSON ones"). So
`encodeGrpcPart` receives a `Part` whose `raw` field, if the caller's JSON
went through the usual pre-`rpcCall` encoding, may already be a base64
**string** masquerading through `json`'s looseness — but since
`encodeGrpcPart` takes a typed `Part` (whose `raw` field is `byte[]?`, not
`string?`), this only actually bites at the `encodeGrpcRequest` layer
(Task 12), which builds a `Part` from raw `map<json>` params. This task's
`encodeGrpcPart` takes an already-typed `Part`, so it has a real
`byte[]?` to assign directly — no base64 involved at this layer. Task 12's
job is to make sure a typed `Part` reaches this function in the first
place (by decoding `params`'s pre-encoded json back into typed values
*before* calling `encodeGrpcPart`, not by re-encoding here). This task's
doc comment says so explicitly, so nobody "fixes" it later by adding a
redundant base64 step here.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testEncodeDecodePartTextRoundTrips() returns error? {
    Part original = {text: "hello", mediaType: "text/plain"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartRawBytesRoundTrips() returns error? {
    byte[] bytes = "raw bytes here".toBytes();
    Part original = {raw: bytes, filename: "f.bin", mediaType: "application/octet-stream"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    test:assertEquals(encoded.raw, bytes, "encodeGrpcPart must assign raw bytes directly, no base64");
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartUrlRoundTrips() returns error? {
    Part original = {url: "https://example.com/f.png", mediaType: "image/png"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartDataRoundTrips() returns error? {
    Part original = {data: {"k": "v", "n": 1}};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartMetadataRoundTrips() returns error? {
    Part original = {text: "with metadata", metadata: {"trace": "abc"}};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcPartDataNarrowingFailureReturnsTypedError() {
    // A value outside json's value space: a table, which anydata admits
    // but json does not.
    table<map<anydata>> notJson = table [{"x": 1}];
    grpcstub:Part malformed = {data: notJson};
    Part|error decoded = decodeGrpcPart(malformed, 3);
    test:assertTrue(decoded is InvalidAgentResponseError, "expected InvalidAgentResponseError for a data value outside json's value space");
    if decoded is InvalidAgentResponseError {
        string msg = decoded.message();
        test:assertTrue(msg.includes("3"), "error message should name the offending part index");
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bal test a2a --tests testEncodeDecodePartTextRoundTrips` (PowerShell)
Expected: compile error, `encodeGrpcPart`/`decodeGrpcPart` undefined.

- [ ] **Step 3: Implement, appending to `grpc_binding.bal`**

```ballerina
# Converts a typed Part into the generated grpcstub:Part shape.
#
# Callers must pass an already-typed Part (raw as byte[]?, not a base64
# string) — this function does not undo base64 encoding. That undoing, if
# needed, happens one layer up in encodeGrpcRequest (see its doc comment),
# not here, because this function's contract is "typed Part in, typed
# grpcstub:Part out," and base64 is a JSON-RPC/REST wire concern that
# never should have reached a typed Part value in the first place.
#
# + p - the Part to encode
# + return - the equivalent grpcstub:Part, or an error if p.data cannot be
#            widened (it always can: json is a strict subtype of anydata)
isolated function encodeGrpcPart(Part p) returns grpcstub:Part|error {
    grpcstub:Part result = {
        metadata: jsonToGrpcStruct(p?.metadata)
    };
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    json? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        // json is a strict subtype of anydata, so this widening is total
        // and lossless (design spec Design decision 5, rule 5).
        result.data = data;
    }
    string? filename = p?.filename;
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = p?.mediaType;
    if mediaType is string {
        result.media_type = mediaType;
    }
    return result;
}

# Converts a generated grpcstub:Part into a typed Part.
#
# + p - the generated Part to decode
# + partIndex - this part's index within its containing parts array, used
#               only to name the offending part in a narrowing-failure
#               error message
# + return - the equivalent typed Part, or InvalidAgentResponseError if
#            p.data (typed anydata on the wire, per the
#            google_protobuf_Value -> anydata workaround) holds a runtime
#            value json cannot represent — see design spec Design decision
#            5, rule 5, for why this is a real possible failure and not a
#            defensive check against something that can't happen
isolated function decodeGrpcPart(grpcstub:Part p, int partIndex) returns Part|error {
    Part result = {};
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    anydata? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        json|error narrowed = trap data.cloneWithType(json);
        if narrowed is error {
            return error InvalidAgentResponseError(
                string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                message = string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                code = -32006
            );
        }
        result.data = narrowed;
    }
    string? filename = p?.filename;
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = p?.media_type;
    if mediaType is string {
        result.mediaType = mediaType;
    }
    map<json>? metadata = check grpcStructToJson(p.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}
```

(`p.media_type`/`p.metadata` field-name spelling must match exactly what
Task 1's generated stub produced — confirm against `a2a_pb.bal` and adjust
if the generator capitalizes or spells anything differently than the
design spec's field table predicted.)

- [ ] **Step 4: Run tests, expect PASS**

Run: `bal test a2a --tests testEncodeDecodePartTextRoundTrips,testEncodeDecodePartRawBytesRoundTrips,testEncodeDecodePartUrlRoundTrips,testEncodeDecodePartDataRoundTrips,testEncodeDecodePartMetadataRoundTrips,testDecodeGrpcPartDataNarrowingFailureReturnsTypedError` (PowerShell)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add encodeGrpcPart/decodeGrpcPart with Part.data narrowing rule"
```

---

## Task 8: `encodeGrpcMessage`/`decodeGrpcMessage`, `encodeGrpcSendConfiguration`, `encodeGrpcPushConfig`/`decodeGrpcPushConfig`

**Files:**
- Modify: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Consumes: `encodeGrpcPart`/`decodeGrpcPart` (Task 7); `grpcKvToMap`/`mapToGrpcKv`/`emptyGrpcStringToNil`/`grpcStructToJson`/`jsonToGrpcStruct` (Task 6).
- Produces: `encodeGrpcMessage(Message m) returns grpcstub:Message|error`,
  `decodeGrpcMessage(grpcstub:Message m) returns Message|error`,
  `encodeGrpcSendConfiguration(SendMessageConfiguration c) returns grpcstub:SendMessageConfiguration|error`,
  `encodeGrpcPushConfig(TaskPushNotificationConfig c) returns grpcstub:TaskPushNotificationConfig|error`,
  `decodeGrpcPushConfig(grpcstub:TaskPushNotificationConfig c) returns TaskPushNotificationConfig|error`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testEncodeDecodeMessageRoundTrips() returns error? {
    Message original = {
        messageId: "m1", role: ROLE_USER,
        parts: [{text: "hi"}, {url: "https://example.com/x"}],
        contextId: "ctx1", taskId: "task1",
        referenceTaskIds: ["task0"], extensions: ["urn:ext:one"],
        metadata: {"k": "v"}
    };
    grpcstub:Message encoded = check encodeGrpcMessage(original);
    Message decoded = check decodeGrpcMessage(encoded);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodeMessageMinimalRoundTrips() returns error? {
    Message original = {messageId: "m2", role: ROLE_AGENT, parts: [{text: "hi"}]};
    grpcstub:Message encoded = check encodeGrpcMessage(original);
    Message decoded = check decodeGrpcMessage(encoded);
    test:assertEquals(decoded.messageId, original.messageId);
    test:assertEquals(decoded.role, original.role);
    test:assertEquals(decoded.parts, original.parts);
    test:assertEquals(decoded?.contextId, ());
    test:assertEquals(decoded?.taskId, ());
    test:assertEquals(decoded.referenceTaskIds, []);
    test:assertEquals(decoded.extensions, []);
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcSendConfiguration() returns error? {
    SendMessageConfiguration config = {
        acceptedOutputModes: ["text", "image/png"],
        historyLength: 5,
        returnImmediately: true,
        taskPushNotificationConfig: {url: "https://cb.example.com", taskId: "t1"}
    };
    grpcstub:SendMessageConfiguration encoded = check encodeGrpcSendConfiguration(config);
    test:assertEquals(encoded.accepted_output_modes, ["text", "image/png"]);
    test:assertEquals(encoded.history_length, 5);
    test:assertEquals(encoded.return_immediately, true);
    grpcstub:TaskPushNotificationConfig? cb = encoded?.task_push_notification_config;
    test:assertTrue(cb is grpcstub:TaskPushNotificationConfig);
    test:assertEquals((<grpcstub:TaskPushNotificationConfig>cb).url, "https://cb.example.com");
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePushConfigRoundTrips() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://cb.example.com", id: "cfg1", taskId: "task1",
        token: "tok", authentication: {scheme: "Bearer", credentials: "abc"},
        tenant: "tenant1"
    };
    grpcstub:TaskPushNotificationConfig encoded = check encodeGrpcPushConfig(original);
    TaskPushNotificationConfig decoded = check decodeGrpcPushConfig(encoded);
    test:assertEquals(decoded, original);
}
```

- [ ] **Step 2: Run to verify failure, then implement**

```ballerina
# + m - the Message to encode
# + return - the equivalent grpcstub:Message
isolated function encodeGrpcMessage(Message m) returns grpcstub:Message|error {
    grpcstub:Part[] parts = [];
    foreach Part p in m.parts {
        parts.push(check encodeGrpcPart(p));
    }
    grpcstub:Message result = {
        message_id: m.messageId,
        role: <grpcstub:Role>m.role,
        parts: parts,
        reference_task_ids: m.referenceTaskIds,
        extensions: m.extensions,
        metadata: jsonToGrpcStruct(m?.metadata)
    };
    string? contextId = m?.contextId;
    if contextId is string {
        result.context_id = contextId;
    }
    string? taskId = m?.taskId;
    if taskId is string {
        result.task_id = taskId;
    }
    return result;
}

# + m - the generated grpcstub:Message to decode
# + return - the equivalent typed Message
isolated function decodeGrpcMessage(grpcstub:Message m) returns Message|error {
    Part[] parts = [];
    foreach grpcstub:Part p in m.parts {
        parts.push(check decodeGrpcPart(p, parts.length()));
    }
    Message result = {
        messageId: m.message_id,
        role: <Role>m.role,
        parts: parts,
        referenceTaskIds: m.reference_task_ids,
        extensions: m.extensions
    };
    string? contextId = emptyGrpcStringToNil(m.context_id);
    if contextId is string {
        result.contextId = contextId;
    }
    string? taskId = emptyGrpcStringToNil(m.task_id);
    if taskId is string {
        result.taskId = taskId;
    }
    map<json>? metadata = check grpcStructToJson(m.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# + c - the SendMessageConfiguration to encode
# + return - the equivalent grpcstub:SendMessageConfiguration
isolated function encodeGrpcSendConfiguration(SendMessageConfiguration c) returns grpcstub:SendMessageConfiguration|error {
    grpcstub:SendMessageConfiguration result = {
        accepted_output_modes: c.acceptedOutputModes,
        return_immediately: c.returnImmediately
    };
    int? historyLength = c?.historyLength;
    if historyLength is int {
        result.history_length = historyLength;
    }
    TaskPushNotificationConfig? cb = c?.taskPushNotificationConfig;
    if cb is TaskPushNotificationConfig {
        result.task_push_notification_config = check encodeGrpcPushConfig(cb);
    }
    return result;
}

# + c - the TaskPushNotificationConfig to encode
# + return - the equivalent grpcstub:TaskPushNotificationConfig
isolated function encodeGrpcPushConfig(TaskPushNotificationConfig c) returns grpcstub:TaskPushNotificationConfig|error {
    grpcstub:TaskPushNotificationConfig result = {url: c.url};
    string? id = c?.id;
    if id is string {
        result.id = id;
    }
    string? taskId = c?.taskId;
    if taskId is string {
        result.task_id = taskId;
    }
    string? token = c?.token;
    if token is string {
        result.token = token;
    }
    AuthenticationInfo? auth = c?.authentication;
    if auth is AuthenticationInfo {
        grpcstub:AuthenticationInfo grpcAuth = {scheme: auth.scheme};
        string? credentials = auth?.credentials;
        if credentials is string {
            grpcAuth.credentials = credentials;
        }
        result.authentication = grpcAuth;
    }
    string? tenant = c?.tenant;
    if tenant is string {
        result.tenant = tenant;
    }
    return result;
}

# + c - the generated grpcstub:TaskPushNotificationConfig to decode
# + return - the equivalent typed TaskPushNotificationConfig
isolated function decodeGrpcPushConfig(grpcstub:TaskPushNotificationConfig c) returns TaskPushNotificationConfig|error {
    TaskPushNotificationConfig result = {url: c.url};
    string? id = emptyGrpcStringToNil(c.id);
    if id is string {
        result.id = id;
    }
    string? taskId = emptyGrpcStringToNil(c.task_id);
    if taskId is string {
        result.taskId = taskId;
    }
    string? token = emptyGrpcStringToNil(c.token);
    if token is string {
        result.token = token;
    }
    grpcstub:AuthenticationInfo? grpcAuth = c?.authentication;
    if grpcAuth is grpcstub:AuthenticationInfo {
        AuthenticationInfo auth = {scheme: grpcAuth.scheme};
        string? credentials = emptyGrpcStringToNil(grpcAuth.credentials);
        if credentials is string {
            auth.credentials = credentials;
        }
        result.authentication = auth;
    }
    string? tenant = emptyGrpcStringToNil(c.tenant);
    if tenant is string {
        result.tenant = tenant;
    }
    return result;
}
```

- [ ] **Step 3: Run tests, expect PASS**

Run: `bal test a2a --tests testEncodeDecodeMessageRoundTrips,testEncodeDecodeMessageMinimalRoundTrips,testEncodeGrpcSendConfiguration,testEncodeDecodePushConfigRoundTrips` (PowerShell)
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add encodeGrpcMessage/decodeGrpcMessage, send-config and push-config conversion"
```

---

## Task 9: Task/status/artifact/stream-response decode functions

**Files:**
- Modify: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Consumes: `decodeGrpcMessage` (Task 8), `decodeGrpcPart` (Task 7), `grpcTimestampToString`/`grpcStructToJson`/`emptyGrpcStringToNil` (Task 6).
- Produces: `decodeGrpcTaskStatus`, `decodeGrpcArtifact`, `decodeGrpcTask`,
  `decodeGrpcStatusUpdate`, `decodeGrpcArtifactUpdate`,
  `decodeGrpcSendResult`, `decodeGrpcStreamResponse` — all
  `grpcstub:X -> types.bal X|error`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testDecodeGrpcTaskStatusAllDefaultsIsNoMessage() returns error? {
    grpcstub:TaskStatus grpcStatus = {state: grpcstub:TASK_STATE_WORKING};
    TaskStatus status = check decodeGrpcTaskStatus(grpcStatus);
    test:assertEquals(status.state, TASK_STATE_WORKING);
    test:assertEquals(status?.message, (), "an all-defaults nested Message must decode to () per rule 2");
    test:assertEquals(status?.timestamp, ());
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcTaskStatusWithMessageAndTimestamp() returns error? {
    grpcstub:TaskStatus grpcStatus = {
        state: grpcstub:TASK_STATE_INPUT_REQUIRED,
        message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "need more info"}]},
        timestamp: check stringToGrpcTimestamp("2023-10-27T10:00:00Z")
    };
    TaskStatus status = check decodeGrpcTaskStatus(grpcStatus);
    test:assertEquals(status.state, TASK_STATE_INPUT_REQUIRED);
    test:assertTrue(status?.message is Message);
    test:assertEquals(status?.timestamp, "2023-10-27T10:00:00.000Z");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcArtifact() returns error? {
    grpcstub:Artifact grpcArtifact = {
        artifact_id: "a1", name: "result.txt", description: "the output",
        parts: [{text: "content"}], extensions: ["urn:ext:one"]
    };
    Artifact artifact = check decodeGrpcArtifact(grpcArtifact);
    test:assertEquals(artifact.artifactId, "a1");
    test:assertEquals(artifact?.name, "result.txt");
    test:assertEquals(artifact?.description, "the output");
    test:assertEquals(artifact.parts.length(), 1);
    test:assertEquals(artifact.extensions, ["urn:ext:one"]);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcTask() returns error? {
    grpcstub:Task grpcTask = {
        id: "t1", context_id: "ctx1",
        status: {state: grpcstub:TASK_STATE_WORKING},
        history: [{message_id: "m1", role: grpcstub:ROLE_USER, parts: [{text: "hi"}]}],
        artifacts: [{artifact_id: "a1", parts: [{text: "out"}]}]
    };
    Task task = check decodeGrpcTask(grpcTask);
    test:assertEquals(task.id, "t1");
    test:assertEquals(task?.contextId, "ctx1");
    test:assertEquals(task.status.state, TASK_STATE_WORKING);
    test:assertEquals(task.history.length(), 1);
    test:assertEquals(task.artifacts.length(), 1);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcStatusUpdate() returns error? {
    grpcstub:TaskStatusUpdateEvent grpcEvent = {
        task_id: "t1", context_id: "ctx1", status: {state: grpcstub:TASK_STATE_COMPLETED}
    };
    TaskStatusUpdateEvent event = check decodeGrpcStatusUpdate(grpcEvent);
    test:assertEquals(event.taskId, "t1");
    test:assertEquals(event.contextId, "ctx1");
    test:assertEquals(event.status.state, TASK_STATE_COMPLETED);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcArtifactUpdate() returns error? {
    grpcstub:TaskArtifactUpdateEvent grpcEvent = {
        task_id: "t1", context_id: "ctx1",
        artifact: {artifact_id: "a1", parts: [{text: "chunk"}]},
        append: true, last_chunk: false
    };
    TaskArtifactUpdateEvent event = check decodeGrpcArtifactUpdate(grpcEvent);
    test:assertEquals(event.taskId, "t1");
    test:assertEquals(event.artifact.artifactId, "a1");
    test:assertEquals(event.append, true);
    test:assertEquals(event.lastChunk, false);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultTask() returns error? {
    grpcstub:SendMessageResponse resp = {task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}};
    Task|Message result = check decodeGrpcSendResult(resp);
    test:assertTrue(result is Task);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultMessage() returns error? {
    grpcstub:SendMessageResponse resp = {message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "hi"}]}};
    Task|Message result = check decodeGrpcSendResult(resp);
    test:assertTrue(result is Message);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultNeitherIsInvalidAgentResponse() {
    grpcstub:SendMessageResponse resp = {};
    Task|Message|error result = decodeGrpcSendResult(resp);
    test:assertTrue(result is InvalidAgentResponseError);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcStreamResponseEachVariant() returns error? {
    StreamResponse r1 = check decodeGrpcStreamResponse({task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}});
    test:assertTrue(r1?.task is Task);
    StreamResponse r2 = check decodeGrpcStreamResponse({message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "hi"}]}});
    test:assertTrue(r2?.message is Message);
    StreamResponse r3 = check decodeGrpcStreamResponse({status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_WORKING}}});
    test:assertTrue(r3?.statusUpdate is TaskStatusUpdateEvent);
    StreamResponse r4 = check decodeGrpcStreamResponse({artifact_update: {task_id: "t1", context_id: "c1", artifact: {artifact_id: "a1", parts: [{text: "x"}]}}});
    test:assertTrue(r4?.artifactUpdate is TaskArtifactUpdateEvent);
}
```

- [ ] **Step 2: Implement, appending to `grpc_binding.bal`**

```ballerina
# + s - the generated grpcstub:TaskStatus to decode
# + return - the equivalent typed TaskStatus
isolated function decodeGrpcTaskStatus(grpcstub:TaskStatus s) returns TaskStatus|error {
    TaskStatus result = {state: <TaskState>s.state};
    grpcstub:Message? msg = s?.message;
    // An all-defaults nested Message ({message_id: "", role: ROLE_UNSPECIFIED,
    // parts: []}) means "no message," not "an empty message" — rule 2.
    if msg is grpcstub:Message && (msg.message_id.length() > 0 || msg.parts.length() > 0) {
        result.message = check decodeGrpcMessage(msg);
    }
    time:Utc? ts = s?.timestamp;
    if ts is time:Utc {
        string? tsString = grpcTimestampToString(ts);
        if tsString is string {
            result.timestamp = tsString;
        }
    }
    return result;
}

# + a - the generated grpcstub:Artifact to decode
# + return - the equivalent typed Artifact
isolated function decodeGrpcArtifact(grpcstub:Artifact a) returns Artifact|error {
    Part[] parts = [];
    foreach grpcstub:Part p in a.parts {
        parts.push(check decodeGrpcPart(p, parts.length()));
    }
    Artifact result = {artifactId: a.artifact_id, parts, extensions: a.extensions};
    string? name = emptyGrpcStringToNil(a.name);
    if name is string {
        result.name = name;
    }
    string? description = emptyGrpcStringToNil(a.description);
    if description is string {
        result.description = description;
    }
    map<json>? metadata = check grpcStructToJson(a.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# + t - the generated grpcstub:Task to decode
# + return - the equivalent typed Task
isolated function decodeGrpcTask(grpcstub:Task t) returns Task|error {
    Message[] history = [];
    foreach grpcstub:Message m in t.history {
        history.push(check decodeGrpcMessage(m));
    }
    Artifact[] artifacts = [];
    foreach grpcstub:Artifact a in t.artifacts {
        artifacts.push(check decodeGrpcArtifact(a));
    }
    Task result = {
        id: t.id,
        status: check decodeGrpcTaskStatus(t.status),
        history,
        artifacts
    };
    string? contextId = emptyGrpcStringToNil(t.context_id);
    if contextId is string {
        result.contextId = contextId;
    }
    map<json>? metadata = check grpcStructToJson(t.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# + e - the generated grpcstub:TaskStatusUpdateEvent to decode
# + return - the equivalent typed TaskStatusUpdateEvent
isolated function decodeGrpcStatusUpdate(grpcstub:TaskStatusUpdateEvent e) returns TaskStatusUpdateEvent|error {
    TaskStatusUpdateEvent result = {
        taskId: e.task_id,
        contextId: e.context_id,
        status: check decodeGrpcTaskStatus(e.status)
    };
    map<json>? metadata = check grpcStructToJson(e.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# + e - the generated grpcstub:TaskArtifactUpdateEvent to decode
# + return - the equivalent typed TaskArtifactUpdateEvent
isolated function decodeGrpcArtifactUpdate(grpcstub:TaskArtifactUpdateEvent e) returns TaskArtifactUpdateEvent|error {
    TaskArtifactUpdateEvent result = {
        taskId: e.task_id,
        contextId: e.context_id,
        artifact: check decodeGrpcArtifact(e.artifact),
        append: e.append,
        lastChunk: e.last_chunk
    };
    map<json>? metadata = check grpcStructToJson(e.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# + resp - the generated grpcstub:SendMessageResponse to decode
# + return - the Task or Message it wraps, or InvalidAgentResponseError if
#            neither is set — mirroring rpcCall's own JSON-RPC-side check
#            for the identical malformed-response shape
isolated function decodeGrpcSendResult(grpcstub:SendMessageResponse resp) returns Task|Message|error {
    grpcstub:Task? t = resp?.task;
    grpcstub:Message? m = resp?.message;
    if t is grpcstub:Task {
        return decodeGrpcTask(t);
    }
    if m is grpcstub:Message {
        return decodeGrpcMessage(m);
    }
    return error InvalidAgentResponseError(
        "gRPC SendMessageResponse contained neither a task nor a message",
        message = "gRPC SendMessageResponse contained neither a task nor a message"
    );
}

# + resp - the generated grpcstub:StreamResponse to decode
# + return - the equivalent typed StreamResponse, with exactly the one
#            field set that the oneof carried
isolated function decodeGrpcStreamResponse(grpcstub:StreamResponse resp) returns StreamResponse|error {
    grpcstub:Task? t = resp?.task;
    if t is grpcstub:Task {
        return {task: check decodeGrpcTask(t)};
    }
    grpcstub:Message? m = resp?.message;
    if m is grpcstub:Message {
        return {message: check decodeGrpcMessage(m)};
    }
    grpcstub:TaskStatusUpdateEvent? su = resp?.status_update;
    if su is grpcstub:TaskStatusUpdateEvent {
        return {statusUpdate: check decodeGrpcStatusUpdate(su)};
    }
    grpcstub:TaskArtifactUpdateEvent? au = resp?.artifact_update;
    if au is grpcstub:TaskArtifactUpdateEvent {
        return {artifactUpdate: check decodeGrpcArtifactUpdate(au)};
    }
    return error InvalidAgentResponseError(
        "gRPC StreamResponse contained none of task/message/status_update/artifact_update",
        message = "gRPC StreamResponse contained none of task/message/status_update/artifact_update"
    );
}
```

- [ ] **Step 3: Run tests, expect PASS**

Run: `bal test a2a --tests testDecodeGrpcTaskStatusAllDefaultsIsNoMessage,testDecodeGrpcTaskStatusWithMessageAndTimestamp,testDecodeGrpcArtifact,testDecodeGrpcTask,testDecodeGrpcStatusUpdate,testDecodeGrpcArtifactUpdate,testDecodeGrpcSendResultTask,testDecodeGrpcSendResultMessage,testDecodeGrpcSendResultNeitherIsInvalidAgentResponse,testDecodeGrpcStreamResponseEachVariant` (PowerShell)
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add Task/status/artifact/stream-response gRPC decode functions"
```

---

## Task 10: `decodeGrpcListTasksResult`/`decodeGrpcListPushConfigsResult`

**Files:**
- Modify: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Consumes: `decodeGrpcTask` (Task 9), `decodeGrpcPushConfig` (Task 8).
- Produces: `decodeGrpcListTasksResult(grpcstub:ListTasksResponse) returns ListTasksResult|error`,
  `decodeGrpcListPushConfigsResult(grpcstub:ListTaskPushNotificationConfigsResponse) returns ListTaskPushNotificationConfigsResult|error`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testDecodeGrpcListTasksResult() returns error? {
    grpcstub:ListTasksResponse resp = {
        tasks: [{id: "t1", status: {state: grpcstub:TASK_STATE_WORKING}}],
        next_page_token: "cursor1", page_size: 10, total_size: 1
    };
    ListTasksResult result = check decodeGrpcListTasksResult(resp);
    test:assertEquals(result.tasks.length(), 1);
    test:assertEquals(result.nextPageToken, "cursor1");
    test:assertEquals(result.pageSize, 10);
    test:assertEquals(result.totalSize, 1);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcListPushConfigsResult() returns error? {
    grpcstub:ListTaskPushNotificationConfigsResponse resp = {
        configs: [{url: "https://cb.example.com", task_id: "t1"}],
        next_page_token: "cursor2"
    };
    ListTaskPushNotificationConfigsResult result = check decodeGrpcListPushConfigsResult(resp);
    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.nextPageToken, "cursor2");
}
```

- [ ] **Step 2: Implement, appending to `grpc_binding.bal`**

```ballerina
# + resp - the generated grpcstub:ListTasksResponse to decode
# + return - the equivalent typed ListTasksResult
isolated function decodeGrpcListTasksResult(grpcstub:ListTasksResponse resp) returns ListTasksResult|error {
    Task[] tasks = [];
    foreach grpcstub:Task t in resp.tasks {
        tasks.push(check decodeGrpcTask(t));
    }
    return {
        tasks,
        nextPageToken: resp.next_page_token,
        pageSize: resp.page_size,
        totalSize: resp.total_size
    };
}

# + resp - the generated grpcstub:ListTaskPushNotificationConfigsResponse to decode
# + return - the equivalent typed ListTaskPushNotificationConfigsResult
isolated function decodeGrpcListPushConfigsResult(grpcstub:ListTaskPushNotificationConfigsResponse resp) returns ListTaskPushNotificationConfigsResult|error {
    TaskPushNotificationConfig[] configs = [];
    foreach grpcstub:TaskPushNotificationConfig c in resp.configs {
        configs.push(check decodeGrpcPushConfig(c));
    }
    return {configs, nextPageToken: resp.next_page_token};
}
```

- [ ] **Step 3: Run tests, expect PASS**

Run: `bal test a2a --tests testDecodeGrpcListTasksResult,testDecodeGrpcListPushConfigsResult` (PowerShell)
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add decodeGrpcListTasksResult/decodeGrpcListPushConfigsResult"
```

---

## Task 11: `decodeGrpcAgentCard` — the `SecurityScheme`/`OAuthFlows` oneofs

**Files:**
- Modify: `a2a/grpc_binding.bal`
- Test: `a2a/tests/grpc_binding_test.bal`

**Interfaces:**
- Consumes: `grpcKvToMap` (Task 6).
- Produces: `decodeGrpcAgentCard(grpcstub:AgentCard) returns AgentCard|error`
  (this pulls in every helper below it, all also defined in this task since
  none are needed elsewhere):
  `decodeGrpcSecurityScheme`, `decodeGrpcOAuthFlows`,
  `decodeGrpcSecurityRequirement`, `decodeGrpcAgentSkill`,
  `decodeGrpcAgentInterface`, `decodeGrpcAgentCapabilities`,
  `decodeGrpcAgentProvider`, `decodeGrpcAgentExtension`,
  `decodeGrpcAgentCardSignature`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardMinimal() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0",
        capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"],
        skills: []
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.name, "agent");
    test:assertEquals(card.capabilities.streaming, false);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardApiKeyScheme() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_schemes: [{key: "apiKeyAuth", value: {api_key_security_scheme: {location: "header", name: "X-API-Key"}}}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    SecurityScheme scheme = card.securitySchemes.get("apiKeyAuth");
    test:assertTrue(scheme is ApiKeySecurityScheme);
    if scheme is ApiKeySecurityScheme {
        test:assertEquals(scheme.'in, "header");
        test:assertEquals(scheme.name, "X-API-Key");
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardOAuth2AuthorizationCodeFlow() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_schemes: [{key: "oauth2", value: {oauth2_security_scheme: {
            flows: {authorization_code: {
                authorization_url: "https://auth.example.com/authorize",
                token_url: "https://auth.example.com/token",
                scopes: [{key: "read", value: "Read access"}, {key: "write", value: "Write access"}]
            }}
        }}}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    SecurityScheme scheme = card.securitySchemes.get("oauth2");
    test:assertTrue(scheme is OAuth2SecurityScheme);
    if scheme is OAuth2SecurityScheme {
        AuthorizationCodeOAuthFlow? flow = scheme.flows?.authorizationCode;
        test:assertTrue(flow is AuthorizationCodeOAuthFlow);
        if flow is AuthorizationCodeOAuthFlow {
            test:assertEquals(flow.scopes, {"read": "Read access", "write": "Write access"});
        }
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardSecurityRequirements() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_requirements: [{schemes: [{key: "apiKeyAuth", value: {list: []}}]}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.securityRequirements.length(), 1);
    test:assertEquals(card.securityRequirements[0], {"apiKeyAuth": []});
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardSkillsAndInterfaces() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"],
        skills: [{id: "s1", name: "Skill One", description: "does one thing", tags: ["tag1"]}],
        supported_interfaces: [{url: "http://localhost:9090", protocol_binding: "GRPC", protocol_version: "1.0"}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.skills.length(), 1);
    test:assertEquals(card.skills[0].id, "s1");
    test:assertEquals(card.supportedInterfaces.length(), 1);
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "GRPC");
}
```

- [ ] **Step 2: Implement, appending to `grpc_binding.bal`**

```ballerina
# + s - the generated grpcstub:SecurityScheme oneof to decode
# + return - the equivalent typed SecurityScheme, or an error if none of
#            the five oneof arms is set
isolated function decodeGrpcSecurityScheme(grpcstub:SecurityScheme s) returns SecurityScheme|error {
    grpcstub:APIKeySecurityScheme? apiKey = s?.api_key_security_scheme;
    if apiKey is grpcstub:APIKeySecurityScheme {
        ApiKeySecurityScheme result = {'in: <"query"|"header"|"cookie">apiKey.location, name: apiKey.name};
        string? description = emptyGrpcStringToNil(apiKey.description);
        if description is string {
            result.description = description;
        }
        return result;
    }
    grpcstub:HTTPAuthSecurityScheme? httpAuth = s?.http_auth_security_scheme;
    if httpAuth is grpcstub:HTTPAuthSecurityScheme {
        HttpAuthSecurityScheme result = {scheme: httpAuth.scheme};
        string? description = emptyGrpcStringToNil(httpAuth.description);
        if description is string {
            result.description = description;
        }
        string? bearerFormat = emptyGrpcStringToNil(httpAuth.bearer_format);
        if bearerFormat is string {
            result.bearerFormat = bearerFormat;
        }
        return result;
    }
    grpcstub:OAuth2SecurityScheme? oauth2 = s?.oauth2_security_scheme;
    if oauth2 is grpcstub:OAuth2SecurityScheme {
        OAuth2SecurityScheme result = {flows: check decodeGrpcOAuthFlows(oauth2.flows)};
        string? description = emptyGrpcStringToNil(oauth2.description);
        if description is string {
            result.description = description;
        }
        string? metadataUrl = emptyGrpcStringToNil(oauth2.oauth2_metadata_url);
        if metadataUrl is string {
            result.oauth2MetadataUrl = metadataUrl;
        }
        return result;
    }
    grpcstub:OpenIdConnectSecurityScheme? oidc = s?.open_id_connect_security_scheme;
    if oidc is grpcstub:OpenIdConnectSecurityScheme {
        OpenIdConnectSecurityScheme result = {openIdConnectUrl: oidc.open_id_connect_url};
        string? description = emptyGrpcStringToNil(oidc.description);
        if description is string {
            result.description = description;
        }
        return result;
    }
    grpcstub:MutualTlsSecurityScheme? mtls = s?.mtls_security_scheme;
    if mtls is grpcstub:MutualTlsSecurityScheme {
        MutualTlsSecurityScheme result = {};
        string? description = emptyGrpcStringToNil(mtls.description);
        if description is string {
            result.description = description;
        }
        return result;
    }
    return error InvalidAgentResponseError(
        "gRPC SecurityScheme had none of its five oneof arms set",
        message = "gRPC SecurityScheme had none of its five oneof arms set"
    );
}

# + f - the generated grpcstub:OAuthFlows oneof to decode. Per design spec
#       Known limitation 5, a device_code arm is dropped: types.bal's
#       OAuthFlows has no DeviceCodeOAuthFlow member, and (unlike the JSON
#       bindings' open records) the generated OAuthFlows record is closed,
#       so there is no escape-hatch field to preserve it in. Also, per the
#       proto's own [deprecated = true] annotations, `implicit` and
#       `password` are decoded for completeness even though upstream flags
#       them deprecated.
# + return - the equivalent typed OAuthFlows
isolated function decodeGrpcOAuthFlows(grpcstub:OAuthFlows f) returns OAuthFlows|error {
    OAuthFlows result = {};
    grpcstub:AuthorizationCodeOAuthFlow? authCode = f?.authorization_code;
    if authCode is grpcstub:AuthorizationCodeOAuthFlow {
        AuthorizationCodeOAuthFlow flow = {
            authorizationUrl: authCode.authorization_url,
            tokenUrl: authCode.token_url,
            scopes: grpcKvToMap(authCode.scopes)
        };
        string? refreshUrl = emptyGrpcStringToNil(authCode.refresh_url);
        if refreshUrl is string {
            flow.refreshUrl = refreshUrl;
        }
        result.authorizationCode = flow;
    }
    grpcstub:ClientCredentialsOAuthFlow? clientCreds = f?.client_credentials;
    if clientCreds is grpcstub:ClientCredentialsOAuthFlow {
        ClientCredentialsOAuthFlow flow = {tokenUrl: clientCreds.token_url, scopes: grpcKvToMap(clientCreds.scopes)};
        string? refreshUrl = emptyGrpcStringToNil(clientCreds.refresh_url);
        if refreshUrl is string {
            flow.refreshUrl = refreshUrl;
        }
        result.clientCredentials = flow;
    }
    grpcstub:ImplicitOAuthFlow? implicitFlow = f?.'implicit;
    if implicitFlow is grpcstub:ImplicitOAuthFlow {
        ImplicitOAuthFlow flow = {authorizationUrl: implicitFlow.authorization_url, scopes: grpcKvToMap(implicitFlow.scopes)};
        string? refreshUrl = emptyGrpcStringToNil(implicitFlow.refresh_url);
        if refreshUrl is string {
            flow.refreshUrl = refreshUrl;
        }
        result.'implicit = flow;
    }
    grpcstub:PasswordOAuthFlow? passwordFlow = f?.password;
    if passwordFlow is grpcstub:PasswordOAuthFlow {
        PasswordOAuthFlow flow = {tokenUrl: passwordFlow.token_url, scopes: grpcKvToMap(passwordFlow.scopes)};
        string? refreshUrl = emptyGrpcStringToNil(passwordFlow.refresh_url);
        if refreshUrl is string {
            flow.refreshUrl = refreshUrl;
        }
        result.password = flow;
    }
    // device_code (f?.device_code) is intentionally not read into result:
    // types.bal's OAuthFlows has no field to put it in. See doc comment.
    return result;
}

# + r - the generated grpcstub:SecurityRequirement to decode (a key/value
#       array of StringList, itself a single-field wrapper — two
#       unwrapping steps, not one, per design spec's note under the
#       SecurityScheme oneof section)
# + return - the equivalent typed SecurityRequirement (map<string[]>)
isolated function decodeGrpcSecurityRequirement(grpcstub:SecurityRequirement r) returns SecurityRequirement {
    map<string[]> result = {};
    foreach var entry in r.schemes {
        result[entry.key] = entry.value.list;
    }
    return result;
}

# + s - the generated grpcstub:AgentSkill to decode
# + return - the equivalent typed AgentSkill
isolated function decodeGrpcAgentSkill(grpcstub:AgentSkill s) returns AgentSkill {
    SecurityRequirement[] requirements = [];
    foreach grpcstub:SecurityRequirement r in s.security_requirements {
        requirements.push(decodeGrpcSecurityRequirement(r));
    }
    return {
        id: s.id, name: s.name, description: s.description,
        tags: s.tags, examples: s.examples,
        inputModes: s.input_modes, outputModes: s.output_modes,
        securityRequirements: requirements
    };
}

# + i - the generated grpcstub:AgentInterface to decode
# + return - the equivalent typed AgentInterface
isolated function decodeGrpcAgentInterface(grpcstub:AgentInterface i) returns AgentInterface {
    AgentInterface result = {url: i.url, protocolBinding: i.protocol_binding};
    string? tenant = emptyGrpcStringToNil(i.tenant);
    if tenant is string {
        result.tenant = tenant;
    }
    string? protocolVersion = emptyGrpcStringToNil(i.protocol_version);
    if protocolVersion is string {
        result.protocolVersion = protocolVersion;
    }
    return result;
}

# + c - the generated grpcstub:AgentCapabilities to decode. Every field is
#       proto3 optional (design spec §"Supporting message fields" note),
#       so an absent field decodes to types.bal's false default rather
#       than being (mis-)read as an explicit "declared false."
# + return - the equivalent typed AgentCapabilities
isolated function decodeGrpcAgentCapabilities(grpcstub:AgentCapabilities c) returns AgentCapabilities {
    AgentExtension[] extensions = [];
    foreach grpcstub:AgentExtension e in c.extensions {
        extensions.push(decodeGrpcAgentExtension(e));
    }
    return {
        streaming: c?.streaming ?: false,
        pushNotifications: c?.push_notifications ?: false,
        extendedAgentCard: c?.extended_agent_card ?: false,
        extensions
    };
}

# + p - the generated grpcstub:AgentProvider to decode
# + return - the equivalent typed AgentProvider
isolated function decodeGrpcAgentProvider(grpcstub:AgentProvider p) returns AgentProvider {
    return {organization: p.organization, url: p.url};
}

# + e - the generated grpcstub:AgentExtension to decode
# + return - the equivalent typed AgentExtension
isolated function decodeGrpcAgentExtension(grpcstub:AgentExtension e) returns AgentExtension {
    AgentExtension result = {uri: e.uri, required: e.required, params: check grpcStructToJson(e.params)};
    string? description = emptyGrpcStringToNil(e.description);
    if description is string {
        result.description = description;
    }
    return result;
}

# + s - the generated grpcstub:AgentCardSignature to decode
# + return - the equivalent typed AgentCardSignature
isolated function decodeGrpcAgentCardSignature(grpcstub:AgentCardSignature s) returns AgentCardSignature|error {
    AgentCardSignature result = {protected: s.protected, signature: s.signature};
    map<json>? header = check grpcStructToJson(s.header);
    if header is map<json> {
        result.header = header;
    }
    return result;
}

# The largest single conversion function in this file — AgentCard.security_schemes
# is a key/value array of a five-member oneof, each arm of which has its
# own field renaming, and security_requirements nests a second key/value
# array of StringList. Matters least in practice: GetExtendedAgentCard is
# the only rpc returning an AgentCard, and the primary card is still
# fetched as JSON from /.well-known/ regardless of binding.
#
# + c - the generated grpcstub:AgentCard to decode
# + return - the equivalent typed AgentCard
isolated function decodeGrpcAgentCard(grpcstub:AgentCard c) returns AgentCard|error {
    map<SecurityScheme> securitySchemes = {};
    foreach var entry in c.security_schemes {
        securitySchemes[entry.key] = check decodeGrpcSecurityScheme(entry.value);
    }
    SecurityRequirement[] securityRequirements = [];
    foreach grpcstub:SecurityRequirement r in c.security_requirements {
        securityRequirements.push(decodeGrpcSecurityRequirement(r));
    }
    AgentSkill[] skills = [];
    foreach grpcstub:AgentSkill s in c.skills {
        skills.push(decodeGrpcAgentSkill(s));
    }
    AgentInterface[] supportedInterfaces = [];
    foreach grpcstub:AgentInterface i in c.supported_interfaces {
        supportedInterfaces.push(decodeGrpcAgentInterface(i));
    }
    AgentCardSignature[] signatures = [];
    foreach grpcstub:AgentCardSignature s in c.signatures {
        signatures.push(check decodeGrpcAgentCardSignature(s));
    }
    AgentCard result = {
        name: c.name, description: c.description, version: c.version,
        capabilities: decodeGrpcAgentCapabilities(c.capabilities),
        securitySchemes, securityRequirements, skills, supportedInterfaces, signatures,
        defaultInputModes: c.default_input_modes,
        defaultOutputModes: c.default_output_modes
    };
    grpcstub:AgentProvider? provider = c?.provider;
    if provider is grpcstub:AgentProvider {
        result.provider = decodeGrpcAgentProvider(provider);
    }
    string? documentationUrl = emptyGrpcStringToNil(c?.documentation_url ?: "");
    if documentationUrl is string {
        result.documentationUrl = documentationUrl;
    }
    string? iconUrl = emptyGrpcStringToNil(c?.icon_url ?: "");
    if iconUrl is string {
        result.iconUrl = iconUrl;
    }
    return result;
}
```

- [ ] **Step 3: Run tests, expect PASS**

Run: `bal test a2a --tests testDecodeGrpcAgentCardMinimal,testDecodeGrpcAgentCardApiKeyScheme,testDecodeGrpcAgentCardOAuth2AuthorizationCodeFlow,testDecodeGrpcAgentCardSecurityRequirements,testDecodeGrpcAgentCardSkillsAndInterfaces` (PowerShell)
Expected: PASS. Adjust field spellings (`'implicit` reserved-word escaping,
exact optional-field accessor syntax for `documentation_url`/`icon_url` if
the generator marks them proto3 `optional` vs. plain string) against
whatever Task 1's actual generated stub declares.

- [ ] **Step 4: Commit**

```bash
git add a2a/grpc_binding.bal a2a/tests/grpc_binding_test.bal
git commit -m "feat: add decodeGrpcAgentCard and its SecurityScheme/OAuthFlows oneof decoders"
```

---

## Task 12: Per-operation `encodeGrpcRequest`/`decodeGrpcResponse` dispatch, and `toA2AErrorFromGrpc`

**Files:**
- Modify: `a2a/grpc_binding.bal` (`encodeGrpcRequest`/`decodeGrpcResponse`)
- Modify: `a2a/errors.bal` (`toA2AErrorFromGrpc`)
- Test: `a2a/tests/grpc_binding_test.bal`, `a2a/tests/errors_test.bal`

**Interfaces:**
- Consumes: every `encodeGrpc*`/`decodeGrpc*` function from Tasks 7–11.
- Produces: `encodeGrpcRequest(string operation, map<json> params) returns anydata|error`,
  `decodeGrpcResponse(string operation, anydata response) returns json|error`,
  `toA2AErrorFromGrpc(grpc:Error err) returns A2AError` — the three
  functions Task 13's `rpcCall` dispatch calls directly.

**The base64⇄bytes wrinkle, resolved here (see Task 7's note):**
`params` arrives at `encodeGrpcRequest` in the same post-`encodeRawBytesForWire`
shape every other binding receives it in — any `Part.raw` is a base64
`string` inside the `json`, not real bytes. `encodeGrpcRequest` must call
`decodeRawBytesFromWire(params)` **first**, before doing anything else,
which turns that base64 string back into the integer-array json shape,
then `cloneWithType`s the relevant sub-object into a typed `Part`/`Message`
(whose `raw` field is `byte[]?`) before handing it to `encodeGrpcPart`/
`encodeGrpcMessage`. This is the one place `decodeRawBytesFromWire` (an
existing, `decode`-named function) is legitimately called on the *encode*
path — it is undoing an *encode*-side transformation another layer applied
upstream, which is exactly what its existing doc comment says it does.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestGetTask() returns error? {
    map<json> params = {"id": "t1", "historyLength": 5, "tenant": "tenant1"};
    anydata req = check encodeGrpcRequest("GetTask", params);
    grpcstub:GetTaskRequest typed = check req.ensureType(grpcstub:GetTaskRequest);
    test:assertEquals(typed.id, "t1");
    test:assertEquals(typed?.history_length, 5);
    test:assertEquals(typed.tenant, "tenant1");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestSendMessageUndoesBase64() returns error? {
    byte[] rawBytes = "hello bytes".toBytes();
    json messageJson = encodeRawBytesForWire({
        messageId: "m1", role: "ROLE_USER",
        parts: [{raw: rawBytes.toJson()}]
    }.toJson());
    // messageJson now has parts[0].raw as a base64 string, matching what
    // sendMessage actually builds before calling rpcCall.
    map<json> params = {"message": messageJson};
    anydata req = check encodeGrpcRequest("SendMessage", params);
    grpcstub:SendMessageRequest typed = check req.ensureType(grpcstub:SendMessageRequest);
    grpcstub:Part firstPart = typed.message.parts[0];
    test:assertEquals(firstPart.raw, rawBytes, "encodeGrpcRequest must undo the base64 encoding applied upstream");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcResponseGetTask() returns error? {
    grpcstub:Task grpcTask = {id: "t1", status: {state: grpcstub:TASK_STATE_WORKING}};
    json result = check decodeGrpcResponse("GetTask", grpcTask);
    Task decoded = check (check decodeRawBytesFromWire(result)).cloneWithType(Task);
    test:assertEquals(decoded.id, "t1");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestUnknownOperationErrors() {
    anydata|error result = encodeGrpcRequest("NotARealOperation", {});
    test:assertTrue(result is A2AInternalError);
}
```

```ballerina
// errors_test.bal additions
@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcNotFound() {
    grpc:Error err = error grpc:NotFoundError("task not found");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is TaskNotFoundError);
    test:assertEquals(mapped.detail()?.code, -32001);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcInvalidArgument() {
    grpc:Error err = error grpc:InvalidArgumentError("bad params");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is A2AInternalError);
    test:assertEquals(mapped.detail()?.code, -32602);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcFailedPreconditionIsLossyByDesign() {
    // Documents the known loss from design spec Design decision 6: five
    // distinct A2A errors collapse into UnsupportedOperationError because
    // ballerina/grpc exposes no status details to disambiguate them. Do
    // not "fix" this without also fixing the upstream ballerina/grpc gap
    // that makes it necessary — see the design doc.
    grpc:Error err = error grpc:FailedPreconditionError("task is not cancelable");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is UnsupportedOperationError);
    test:assertEquals(mapped.detail()?.code, -32004);
    test:assertEquals(mapped.message(), "task is not cancelable");
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcInternalErrorFamily() {
    A2AError mapped1 = toA2AErrorFromGrpc(error grpc:InternalError("x"));
    test:assertTrue(mapped1 is A2AInternalError);
    A2AError mapped2 = toA2AErrorFromGrpc(error grpc:DataLossError("x"));
    test:assertTrue(mapped2 is A2AInternalError);
    A2AError mapped3 = toA2AErrorFromGrpc(error grpc:UnKnownError("x"));
    test:assertTrue(mapped3 is A2AInternalError);
    A2AError mapped4 = toA2AErrorFromGrpc(error grpc:AbortedError("x"));
    test:assertTrue(mapped4 is A2AInternalError);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcTransportOnlyStatusesFallThrough() {
    A2AError mapped = toA2AErrorFromGrpc(error grpc:UnavailableError("connection refused"));
    test:assertTrue(mapped is A2AInternalError);
    test:assertEquals(mapped.message(), "connection refused");
}
```

- [ ] **Step 2: Implement `encodeGrpcRequest`/`decodeGrpcResponse`, appending to `grpc_binding.bal`**

```ballerina
# Converts this library's v1.0 params map (the same shape rpcCall's
# JSON-RPC/REST branches already speak) into the typed grpcstub request
# message for one operation.
#
# params arrives with any Part.raw already base64-encoded by
# encodeRawBytesForWire, applied upstream by the calling remote function
# before rpcCall is ever reached (see sendMessage/sendMessageStream in
# client.bal). gRPC wants genuine bytes, not base64 — decodeRawBytesFromWire
# is called here to undo that encoding before any Part-bearing sub-object
# is cloned into a typed value, so encodeGrpcPart/encodeGrpcMessage always
# receive a real byte[]?, never a base64 string masquerading as one.
#
# + operation - the JSON-RPC-style operation name (e.g. "GetTask", the
#               same string rpcCall's other branches already key off)
# + params - the v1.0 params map, pre-base64-undone
# + return - the typed grpcstub request value for this operation, or
#            A2AInternalError if operation has no gRPC mapping
isolated function encodeGrpcRequest(string operation, map<json> params) returns anydata|error {
    map<json> undone = check decodeRawBytesFromWire(params);
    match operation {
        "SendMessage"|"SendStreamingMessage" => {
            Message message = check undone.get("message").cloneWithType(Message);
            grpcstub:SendMessageRequest req = {message: check encodeGrpcMessage(message)};
            json? configJson = undone["configuration"];
            if configJson is map<json> {
                SendMessageConfiguration config = check configJson.cloneWithType(SendMessageConfiguration);
                req.configuration = check encodeGrpcSendConfiguration(config);
            }
            json? metadataJson = undone["metadata"];
            if metadataJson is map<json> {
                req.metadata = jsonToGrpcStruct(metadataJson);
            }
            string? tenant = undone["tenant"] is string ? <string>undone["tenant"] : ();
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "GetTask" => {
            grpcstub:GetTaskRequest req = {id: check undone.get("id").ensureType(string)};
            json? historyLength = undone["historyLength"];
            if historyLength is int {
                req.history_length = historyLength;
            }
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "CancelTask" => {
            grpcstub:CancelTaskRequest req = {id: check undone.get("id").ensureType(string)};
            json? metadata = undone["metadata"];
            if metadata is map<json> {
                req.metadata = jsonToGrpcStruct(metadata);
            }
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "SubscribeToTask" => {
            grpcstub:SubscribeToTaskRequest req = {id: check undone.get("id").ensureType(string)};
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "ListTasks" => {
            grpcstub:ListTasksRequest req = {};
            json? contextId = undone["contextId"];
            if contextId is string {
                req.context_id = contextId;
            }
            json? status = undone["status"];
            if status is string {
                req.status = <grpcstub:TaskState>status;
            }
            json? pageSize = undone["pageSize"];
            if pageSize is int {
                req.page_size = pageSize;
            }
            json? pageToken = undone["pageToken"];
            if pageToken is string {
                req.page_token = pageToken;
            }
            json? historyLength = undone["historyLength"];
            if historyLength is int {
                req.history_length = historyLength;
            }
            json? statusTimestampAfter = undone["statusTimestampAfter"];
            if statusTimestampAfter is string {
                req.status_timestamp_after = check stringToGrpcTimestamp(statusTimestampAfter);
            }
            json? includeArtifacts = undone["includeArtifacts"];
            if includeArtifacts is boolean {
                req.include_artifacts = includeArtifacts;
            }
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "CreateTaskPushNotificationConfig" => {
            TaskPushNotificationConfig config = check undone.cloneWithType(TaskPushNotificationConfig);
            return check encodeGrpcPushConfig(config);
        }
        "GetTaskPushNotificationConfig" => {
            return {
                task_id: check undone.get("taskId").ensureType(string),
                id: check undone.get("id").ensureType(string),
                tenant: undone["tenant"] is string ? <string>undone["tenant"] : ""
            };
        }
        "ListTaskPushNotificationConfigs" => {
            grpcstub:ListTaskPushNotificationConfigsRequest req = {task_id: check undone.get("taskId").ensureType(string)};
            json? pageSize = undone["pageSize"];
            if pageSize is int {
                req.page_size = pageSize;
            }
            json? pageToken = undone["pageToken"];
            if pageToken is string {
                req.page_token = pageToken;
            }
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        "DeleteTaskPushNotificationConfig" => {
            return {
                task_id: check undone.get("taskId").ensureType(string),
                id: check undone.get("id").ensureType(string),
                tenant: undone["tenant"] is string ? <string>undone["tenant"] : ""
            };
        }
        "GetExtendedAgentCard" => {
            grpcstub:GetExtendedAgentCardRequest req = {};
            json? tenant = undone["tenant"];
            if tenant is string {
                req.tenant = tenant;
            }
            return req;
        }
        _ => {
            return error A2AInternalError(
                string `gRPC binding has no operation mapping for "${operation}"`,
                message = string `gRPC binding has no operation mapping for "${operation}"`
            );
        }
    }
}

# Converts a typed grpcstub response value for one operation back into the
# v1.0 json shape rpcCall's callers already expect (the same shape a
# JSON-RPC "result" field would have carried). Callers then apply
# decodeRawBytesFromWire (already a no-op on gRPC's byte[]-shaped raw
# fields, see design spec's closing bytes note) and cloneWithType exactly
# as they do for the other two bindings — no per-binding branching needed
# in the 11 remote function bodies.
#
# + operation - the JSON-RPC-style operation name
# + response - the typed grpcstub response value returned by the rpc call
# + return - the equivalent v1.0 json, or A2AInternalError if operation has
#            no gRPC mapping
isolated function decodeGrpcResponse(string operation, anydata response) returns json|error {
    match operation {
        "SendMessage" => {
            Task|Message result = check decodeGrpcSendResult(check response.ensureType(grpcstub:SendMessageResponse));
            return {task: result is Task ? result : (), message: result is Message ? result : ()}.toJson();
        }
        "GetTask"|"CancelTask" => {
            Task task = check decodeGrpcTask(check response.ensureType(grpcstub:Task));
            return task.toJson();
        }
        "ListTasks" => {
            ListTasksResult result = check decodeGrpcListTasksResult(check response.ensureType(grpcstub:ListTasksResponse));
            return result.toJson();
        }
        "CreateTaskPushNotificationConfig"|"GetTaskPushNotificationConfig" => {
            TaskPushNotificationConfig config = check decodeGrpcPushConfig(check response.ensureType(grpcstub:TaskPushNotificationConfig));
            return config.toJson();
        }
        "ListTaskPushNotificationConfigs" => {
            ListTaskPushNotificationConfigsResult result = check decodeGrpcListPushConfigsResult(check response.ensureType(grpcstub:ListTaskPushNotificationConfigsResponse));
            return result.toJson();
        }
        "DeleteTaskPushNotificationConfig" => {
            return {};
        }
        "GetExtendedAgentCard" => {
            AgentCard card = check decodeGrpcAgentCard(check response.ensureType(grpcstub:AgentCard));
            return card.toJson();
        }
        _ => {
            return error A2AInternalError(
                string `gRPC binding has no response mapping for "${operation}"`,
                message = string `gRPC binding has no response mapping for "${operation}"`
            );
        }
    }
}
```

(`SendStreamingMessage`/`SubscribeToTask` are intentionally absent from
`decodeGrpcResponse` — their per-element decoding goes through
`decodeGrpcStreamResponse` inside `GrpcStreamAdapter`, Task 14, not through
this unary-response function.)

- [ ] **Step 3: Implement `toA2AErrorFromGrpc`, appending to `errors.bal`**

```ballerina
import ballerina/grpc;

# Maps a gRPC transport error onto the same A2AError hierarchy the
# JSON-RPC and REST bindings map onto. Status-code granularity only —
# ballerina/grpc:1.14.7 exposes no status details or trailing metadata
# (grpc:Error is a bare `distinct error` with no detail record), so five
# A2A errors that all share FAILED_PRECONDITION cannot be disambiguated
# here the way toA2AErrorFromRest disambiguates via
# google.rpc.ErrorInfo.reason. See design spec Design decision 6 for the
# full resolution-order rationale and the two out-of-scope ways to close
# this gap later (ballerina/grpc exposing status details; matching on
# status-message text, rejected as unreliable).
#
# + err - the gRPC transport error received from a grpcstub client call
# + return - the corresponding typed A2AError
isolated function toA2AErrorFromGrpc(grpc:Error err) returns A2AError {
    string message = err.message();
    if err is grpc:NotFoundError {
        return error TaskNotFoundError(message, message = message, code = -32001);
    }
    if err is grpc:InvalidArgumentError {
        return error A2AInternalError(message, message = message, code = -32602);
    }
    if err is grpc:FailedPreconditionError {
        return error UnsupportedOperationError(message, message = message, code = -32004);
    }
    if err is grpc:InternalError || err is grpc:DataLossError
            || err is grpc:UnKnownError || err is grpc:AbortedError {
        return error A2AInternalError(message, message = message, code = -32603);
    }
    return error A2AInternalError(message, message = message);
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `bal test a2a --tests testEncodeGrpcRequestGetTask,testEncodeGrpcRequestSendMessageUndoesBase64,testDecodeGrpcResponseGetTask,testEncodeGrpcRequestUnknownOperationErrors,testToA2AErrorFromGrpcNotFound,testToA2AErrorFromGrpcInvalidArgument,testToA2AErrorFromGrpcFailedPreconditionIsLossyByDesign,testToA2AErrorFromGrpcInternalErrorFamily,testToA2AErrorFromGrpcTransportOnlyStatusesFallThrough` (PowerShell)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add a2a/grpc_binding.bal a2a/errors.bal a2a/tests/grpc_binding_test.bal a2a/tests/errors_test.bal
git commit -m "feat: add encodeGrpcRequest/decodeGrpcResponse dispatch and toA2AErrorFromGrpc"
```

---

## Task 13: Wire the `GRPC` branch into `Client.init`/`rpcCall`, plus the auth adapter

**Files:**
- Modify: `a2a/client.bal` (`Client` fields, `init`, `rpcCall`, `buildHeaders`)
- Modify: `a2a/auth.bal` (grpc auth projection)
- Test: `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `encodeGrpcRequest`/`decodeGrpcResponse`/`toA2AErrorFromGrpc` (Task 12); `normalizeGrpcSchemeUrl` (Task 5); `grpcstub:A2AServiceClient` (Task 1); `getGrpcMockUrl`/`setNextGrpcResponse` (Task 2).
- Produces: `Client` gains `private final grpcstub:A2AServiceClient? grpcStub`;
  `Client.init` constructs it when `binding == "GRPC"` and rejects v0.3+GRPC;
  `rpcCall` gains a `GRPC` branch analogous to the existing `HTTP+JSON`
  one; `buildHeaders` omits `Content-Type` for `GRPC`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testClientGrpcSendMessageUnary() returns error? {
    grpcstub:Task scriptedTask = {id: "t1", status: {state: grpcstub:TASK_STATE_COMPLETED}};
    setNextGrpcResponse(grpcstub:SendMessageResponse {task: scriptedTask});
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    Task|Message result = check grpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task);
    if result is Task {
        test:assertEquals(result.id, "t1");
    }
}

@test:Config {groups: ["grpc"]}
function testClientGrpcGetTaskMapsNotFoundError() returns error? {
    setNextGrpcError(error grpc:NotFoundError("no such task"));
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    Task|error result = grpcClient->getTask("missing");
    test:assertTrue(result is TaskNotFoundError);
}

@test:Config {groups: ["grpc"]}
function testClientGrpcSendsMandatoryA2AVersionHeader() returns error? {
    grpcstub:Task scriptedTask = {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}};
    setNextGrpcResponse(grpcstub:SendMessageResponse {task: scriptedTask});
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    Task|Message _ = check grpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    map<string|string[]> metadata = getLastGrpcMetadata();
    test:assertTrue(metadata.hasKey("A2A-Version"), "A2A-Version metadata must be present per spec section 3.6.1");
}
```

- [ ] **Step 2: Modify `client.bal`**

Add the field (near `private final http:Client httpClient;`):

```ballerina
    private final grpcstub:A2AServiceClient? grpcStub;
```

Import `grpcstub` and `grpc` at the top of `client.bal`:

```ballerina
import ballerina/a2a.grpcstub;
import ballerina/grpc;
```

In `init`, after the existing `HTTP+JSON` v0.3 rejection block, add the
`GRPC` construction and rejection:

```ballerina
        if self.mode == "V0_3" && binding == "GRPC" {
            return error VersionNotSupportedError(
                "A2A protocol v0.3 has no gRPC binding equivalent",
                message = "A2A protocol v0.3 has no gRPC binding equivalent"
            );
        }
        if binding == "GRPC" {
            grpc:ClientConfiguration grpcConfig = check projectToGrpcClientConfig(effectiveClientConfig);
            self.grpcStub = check new (normalizeGrpcSchemeUrl(serviceUrl), grpcConfig);
        } else {
            self.grpcStub = ();
        }
```

(Place this after `self.httpClient = check new (...)` so `self.httpClient`
is still always constructed — a `GRPC` client still needs it for
`resolveAgentCard`, per Design decision 3.)

Modify `buildHeaders` to omit `Content-Type` for `GRPC` (gRPC sets its own,
per Design decision 4):

```ballerina
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "A2A-Version": self.mode == "V0_3" ? "0.3" : "1.0"
        };
        if self.binding != "GRPC" {
            headers["Content-Type"] = "application/json";
        }
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }
```

Modify `rpcCall` to add the `GRPC` branch, alongside the existing
`HTTP+JSON` one:

```ballerina
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        if self.binding == "HTTP+JSON" {
            return self.restCall(method, params);
        }
        if self.binding == "GRPC" {
            return self.grpcCall(method, params);
        }
        // ... existing JSON-RPC body unchanged ...
    }

    # Performs one gRPC binding call and returns the unwrapped result,
    # matching rpcCall's contract. Uses the generated *Context method
    # variants exclusively (never the plain ones) so response metadata —
    # specifically A2A-Extensions — is reachable; see design spec Design
    # decision 4.
    #
    # + method - the JSON-RPC-style method name (see encodeGrpcRequest)
    # + params - the same params map the JSON-RPC binding would build
    # + return - the unwrapped result json, or a typed A2AError
    private isolated function grpcCall(string method, map<json> params) returns json|error {
        grpcstub:A2AServiceClient stub = <grpcstub:A2AServiceClient>self.grpcStub;
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        anydata|grpc:Error response = self.dispatchGrpcContextCall(stub, method, req, headers);
        if response is grpc:Error {
            return toA2AErrorFromGrpc(response);
        }
        return decodeGrpcResponse(method, response);
    }

    # Dispatches to the correct generated *Context method for one unary
    # operation. A single match here (rather than a match inline in
    # grpcCall) keeps grpcCall's own control flow readable and gives the
    # streaming adapter (Task 14) an obvious place alongside this to add
    # its own two streaming-operation cases without touching this one.
    #
    # + stub - the generated gRPC client stub
    # + method - the JSON-RPC-style method name
    # + req - the typed grpcstub request value from encodeGrpcRequest
    # + headers - outbound metadata (A2A-Version, A2A-Extensions, auth headers)
    # + return - the typed grpcstub response value, or a grpc:Error
    private isolated function dispatchGrpcContextCall(
            grpcstub:A2AServiceClient stub, string method, anydata req,
            map<string|string[]> headers) returns anydata|grpc:Error {
        match method {
            "SendMessage" => {
                var result = stub->SendMessageContext(<grpcstub:SendMessageRequest|grpcstub:ContextSendMessageRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "GetTask" => {
                var result = stub->GetTaskContext(<grpcstub:GetTaskRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "CancelTask" => {
                var result = stub->CancelTaskContext(<grpcstub:CancelTaskRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "ListTasks" => {
                var result = stub->ListTasksContext(<grpcstub:ListTasksRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "CreateTaskPushNotificationConfig" => {
                var result = stub->CreateTaskPushNotificationConfigContext(<grpcstub:TaskPushNotificationConfig>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "GetTaskPushNotificationConfig" => {
                var result = stub->GetTaskPushNotificationConfigContext(<grpcstub:GetTaskPushNotificationConfigRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "ListTaskPushNotificationConfigs" => {
                var result = stub->ListTaskPushNotificationConfigsContext(<grpcstub:ListTaskPushNotificationConfigsRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "DeleteTaskPushNotificationConfig" => {
                var result = stub->DeleteTaskPushNotificationConfigContext(<grpcstub:DeleteTaskPushNotificationConfigRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "GetExtendedAgentCard" => {
                var result = stub->GetExtendedAgentCardContext(<grpcstub:GetExtendedAgentCardRequest>req, headers);
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            _ => {
                return error grpc:InternalError(string `no gRPC dispatch for unary method "${method}"`);
            }
        }
    }

    # gRPC analogue of captureGrantedExtensions — reads A2A-Extensions off
    # response metadata instead of an http:Response header, per design
    # spec Design decision 4 (only the *Context method variants surface
    # response metadata at all).
    #
    # + headers - the response metadata from a *Context call
    private isolated function captureGrantedExtensionsFromGrpc(map<string|string[]> headers) {
        string|string[]? extHeader = headers["A2A-Extensions"];
        string[] granted = [];
        if extHeader is string && extHeader.length() > 0 {
            foreach string entry in re `,`.split(extHeader) {
                granted.push(entry.trim());
            }
        } else if extHeader is string[] {
            granted = extHeader;
        }
        lock {
            self.grantedExtensions = granted.clone();
        }
    }
```

(The exact generated `*Context` method names, and whether the request
parameter is a plain type or a union with a `Context*Request` wrapper type,
must be confirmed against Task 1's actual generated `a2a_pb.bal` — the
design spec's §Design decision 4 documents `SendMessageContext` returning
`{content, headers}` and names the pattern generically for the rest; adjust
this dispatch to match whatever the generator actually emits for each of
the other 8 unary operations.)

- [ ] **Step 3: Add the auth adapter in `auth.bal`**

```ballerina
import ballerina/grpc;

# Projects an http:ClientConfiguration.auth value (already resolved by
# buildAuthFromCard for the HTTP-basic and HTTP-bearer cases this library
# automates) onto the structurally equivalent grpc:ClientAuthConfig union.
# Per design spec Design decision 3, grpc:ClientConfiguration.auth is
# structurally the same union http:ClientConfiguration.auth offers for
# both scheme types buildAuthFromCard automates, so this is a projection,
# not a second resolution path — ResolvedAuth itself is unchanged.
#
# + clientConfig - the effective http:ClientConfiguration built by
#                  Client.init (from clientConfig param + any
#                  buildAuthFromCard resolution)
# + return - the equivalent grpc:ClientConfiguration, or an error if
#            clientConfig.auth is set to a shape this adapter doesn't
#            recognize (OAuth2/JWT auth configs, which buildAuthFromCard
#            never produces, so this can only happen if a caller sets
#            clientConfig.auth to something unsupported directly)
isolated function projectToGrpcClientConfig(http:ClientConfiguration clientConfig) returns grpc:ClientConfiguration|error {
    grpc:ClientConfiguration result = {};
    http:ClientAuthConfig? auth = clientConfig?.auth;
    if auth is http:CredentialsConfig {
        result.auth = {username: auth.username, password: auth.password};
    } else if auth is http:BearerTokenConfig {
        result.auth = {token: auth.token};
    } else if auth is () {
        // no auth configured — nothing to project
    } else {
        return error AuthResolutionError(
            "grpc binding only supports HTTP Basic/Bearer auth projected from http:ClientConfiguration.auth; the configured auth type is not automated for gRPC");
    }
    return result;
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `bal test a2a --tests testClientGrpcSendMessageUnary,testClientGrpcGetTaskMapsNotFoundError,testClientGrpcSendsMandatoryA2AVersionHeader,testClientInitRejectsV03PlusGrpc` (PowerShell)
Expected: PASS (this also finishes Task 5's deferred `testClientInitRejectsV03PlusGrpc`).

- [ ] **Step 5: Commit**

```bash
git add a2a/client.bal a2a/auth.bal a2a/tests/client_test.bal
git commit -m "feat: wire GRPC binding into Client.init and rpcCall's dispatch"
```

---

## Task 14: `GrpcStreamAdapter`, `openSseStream` → `openEventStream` rename, streaming wiring

**Files:**
- Modify: `a2a/client.bal` (`openSseStream` renamed to `openEventStream`, gains `GRPC` branch)
- Create: `a2a/grpc_stream.bal` (`GrpcStreamAdapter`)
- Test: `a2a/tests/grpc_stream_test.bal`, `a2a/tests/client_test.bal`

**Interfaces:**
- Consumes: `decodeGrpcStreamResponse` (Task 9), `toA2AErrorFromGrpc` (Task 12), `isTerminalEvent` (`sse.bal`, unchanged), `ReconnectingStreamGenerator` (`sse.bal`, unchanged — composes over any `stream<StreamResponse, error?>` regardless of source).
- Produces: `class GrpcStreamAdapter` implementing `next()`/`close()` over
  `stream<StreamResponse, error?>`; `Client.openEventStream` gains a
  `GRPC` branch calling it for `SendStreamingMessage`/`SubscribeToTask`.

- [ ] **Step 1: Write the failing tests**

```ballerina
@test:Config {groups: ["grpc"]}
function testGrpcStreamAdapterDecodesAndClosesOnTerminal() returns error? {
    grpcstub:StreamResponse[] scripted = [
        {task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}},
        {status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_WORKING}}},
        {status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_COMPLETED}}}
    ];
    stream<grpcstub:StreamResponse, error?> upstream = scripted.toStream();
    GrpcStreamAdapter adapter = new (upstream);
    record {|StreamResponse value;|}? r1 = check adapter.next();
    test:assertTrue(r1 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}? r2 = check adapter.next();
    test:assertTrue(r2 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}? r3 = check adapter.next();
    test:assertTrue(r3 is record {|StreamResponse value;|});
    if r3 is record {|StreamResponse value;|} {
        test:assertEquals(r3.value?.statusUpdate?.status?.state, TASK_STATE_COMPLETED);
    }
    // Terminal event reached — a well-behaved upstream would end here too,
    // but assert the adapter itself also treats this as closed:
    record {|StreamResponse value;|}|error? r4 = adapter.next();
    test:assertEquals(r4, ());
}

@test:Config {groups: ["grpc"]}
function testGrpcStreamAdapterSurfacesMidStreamError() returns error? {
    ErroringStreamGenerator gen = new ({task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}});
    stream<grpcstub:StreamResponse, error?> upstream = new (gen);
    GrpcStreamAdapter adapter = new (upstream);
    record {|StreamResponse value;|}? r1 = check adapter.next();
    test:assertTrue(r1 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}|error? r2 = adapter.next();
    test:assertTrue(r2 is A2AError, "a mid-stream grpc:Error must surface as a typed A2AError");
}

// Test-only generator that yields one value then a grpc:Error, to exercise
// the mid-stream-error path without a real network stream.
isolated class ErroringStreamGenerator {
    private grpcstub:StreamResponse first;
    private boolean firstServed = false;

    isolated function init(grpcstub:StreamResponse first) {
        self.first = first;
    }

    public isolated function next() returns record {|grpcstub:StreamResponse value;|}|grpc:Error? {
        if !self.firstServed {
            self.firstServed = true;
            return {value: self.first};
        }
        return error grpc:UnavailableError("connection dropped");
    }
}
```

- [ ] **Step 2: Write `a2a/grpc_stream.bal`**

```ballerina
// The gRPC binding's streaming adapter — the per-element analogue of
// sse.bal's A2AStreamGenerator for the JSON-RPC/REST bindings. Simpler at
// the stream layer than either (gRPC has no envelope and no mid-stream
// "error"-named frame to special-case — a transport error surfaces
// directly as a grpc:Error from upstream.next()) and more involved at the
// type layer (every element needs decodeGrpcStreamResponse). See design
// spec Design decision 4.
import ballerina/grpc;

class GrpcStreamAdapter {
    private stream<grpcstub:StreamResponse, error?> upstream;
    private boolean closed = false;

    isolated function init(stream<grpcstub:StreamResponse, error?> upstream) {
        self.upstream = upstream;
    }

    public isolated function next() returns record {|StreamResponse value;|}|error? {
        if self.closed {
            return ();
        }
        record {|grpcstub:StreamResponse value;|}|error? chunk = self.upstream.next();
        if chunk is () {
            self.closed = true;
            return ();
        }
        if chunk is error {
            self.closed = true;
            if chunk is grpc:Error {
                return toA2AErrorFromGrpc(chunk);
            }
            return chunk;
        }
        StreamResponse|error decoded = decodeGrpcStreamResponse(chunk.value);
        if decoded is error {
            self.closed = true;
            return decoded;
        }
        if isTerminalEvent(decoded) {
            self.closed = true;
        }
        return {value: decoded};
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.upstream.close();
    }
}
```

- [ ] **Step 3: Rename `openSseStream` to `openEventStream` and add the `GRPC` branch**

Rename every occurrence of `openSseStream` in `client.bal` to
`openEventStream` (its two callers, `sendMessageStream` and
`openTaskSubscriptionStream`). At the top of the renamed function's body,
add the `GRPC` branch before the existing `HTTP+JSON` check:

```ballerina
    private isolated function openEventStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        if self.binding == "GRPC" {
            return self.openGrpcStream(method, params);
        }
        if self.binding == "HTTP+JSON" {
            return self.openRestSseStream(method, params);
        }
        // ... existing JSON-RPC body unchanged (still calls readSseStream) ...
    }

    # Opens a gRPC streaming call and wraps it in a GrpcStreamAdapter.
    #
    # + method - "SendStreamingMessage" or "SubscribeToTask"
    # + params - the same params map the JSON-RPC binding would build
    # + return - a stream of StreamResponse values, or a typed A2AError
    private isolated function openGrpcStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        grpcstub:A2AServiceClient stub = <grpcstub:A2AServiceClient>self.grpcStub;
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        if method == "SendStreamingMessage" {
            grpcstub:ContextStreamResponseStream|grpc:Error result =
                stub->SendStreamingMessageContext(<grpcstub:SendMessageRequest>req, headers);
            if result is grpc:Error {
                return toA2AErrorFromGrpc(result);
            }
            self.captureGrantedExtensionsFromGrpc(result.headers);
            return new (new GrpcStreamAdapter(result.content));
        }
        grpcstub:ContextStreamResponseStream|grpc:Error result =
            stub->SubscribeToTaskContext(<grpcstub:SubscribeToTaskRequest>req, headers);
        if result is grpc:Error {
            return toA2AErrorFromGrpc(result);
        }
        self.captureGrantedExtensionsFromGrpc(result.headers);
        return new (new GrpcStreamAdapter(result.content));
    }
```

(The generated streaming-response wrapper type name —
`ContextStreamResponseStream` per the design spec's §Design decision 4 —
must be confirmed against Task 1's actual stub and adjusted if the
generator names it differently.)

- [ ] **Step 4: Run tests, expect PASS**

Run: `bal test a2a --tests testGrpcStreamAdapterDecodesAndClosesOnTerminal,testGrpcStreamAdapterSurfacesMidStreamError` (PowerShell)
Expected: PASS. Then run the full suite once — `bal test a2a` — to confirm
the `openSseStream` → `openEventStream` rename didn't break any existing
REST/JSON-RPC test referencing the old name directly (test files should
only call the public `sendMessageStream`/`subscribeToTask` remote
functions, not the renamed private helper, so this should be a no-op for
them, but confirm).

- [ ] **Step 5: Add an end-to-end streaming test through the gRPC mock**

```ballerina
@test:Config {groups: ["grpc"]}
function testClientGrpcSendMessageStreamEndToEnd() returns error? {
    grpcstub:StreamResponse[] scripted = [
        {task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}},
        {status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_COMPLETED}}}
    ];
    setNextGrpcResponse(scripted);
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    stream<StreamResponse, error?> s = check grpcClient->sendMessageStream({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first?.task is Task);
    StreamResponse second = check expectValue(s.next());
    test:assertEquals(second?.statusUpdate?.status?.state, TASK_STATE_COMPLETED);
}
```

Run: `bal test a2a --tests testClientGrpcSendMessageStreamEndToEnd` (PowerShell)
Expected: PASS (this depends on `service.bal`'s `SendStreamingMessage`
handler from Task 2 correctly turning a scripted `StreamResponse[]` into a
`stream<grpcstub:StreamResponse, error?>` server-side — revisit that mock
handler if this fails).

- [ ] **Step 6: Commit**

```bash
git add a2a/client.bal a2a/grpc_stream.bal a2a/tests/grpc_stream_test.bal a2a/tests/client_test.bal
git commit -m "feat: add GrpcStreamAdapter and wire gRPC streaming into openEventStream"
```

---

## Task 15: Equivalence tests and the codegen-freshness CI check

**Files:**
- Test: `a2a/tests/equivalence_test.bal` (extend existing file from the REST task, or create if it doesn't yet cover gRPC)
- Modify: `a2a/scripts/regen-grpc-stub.sh` (already asserts freshness — this task only wires it into a test/CI-runnable form, see Task 17)

**Interfaces:**
- Consumes: everything from Tasks 1–14.

- [ ] **Step 1: Write the equivalence test**

```ballerina
@test:Config {groups: ["grpc"]}
function testJsonRpcAndGrpcReturnIdenticalSendMessageResult() returns error? {
    setNextJsonResponse({"jsonrpc": "2.0", "id": "x", "result": {"task": {"id": "t1", "status": {"state": "TASK_STATE_COMPLETED"}}}});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task|Message jsonRpcResult = check jsonRpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    setNextGrpcResponse(grpcstub:SendMessageResponse {task: {id: "t1", status: {state: grpcstub:TASK_STATE_COMPLETED}}});
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    Task|Message grpcResult = check grpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    test:assertTrue(jsonRpcResult is Task && grpcResult is Task);
    if jsonRpcResult is Task && grpcResult is Task {
        test:assertEquals(jsonRpcResult.id, grpcResult.id);
        test:assertEquals(jsonRpcResult.status.state, grpcResult.status.state);
    }
}

@test:Config {groups: ["grpc"]}
function testJsonRpcAndGrpcReturnIdenticalNotFoundErrorType() returns error? {
    setNextJsonResponse({"jsonrpc": "2.0", "id": "x", "error": {"code": -32001, "message": "not found"}});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task|error jsonRpcResult = jsonRpcClient->getTask("missing");

    setNextGrpcError(error grpc:NotFoundError("not found"));
    Client grpcClient = check new (getGrpcMockUrl(), binding = "GRPC");
    Task|error grpcResult = grpcClient->getTask("missing");

    // Per design spec Design decision 6, the error half of this
    // equivalence assertion is deliberately narrowed to success paths and
    // NOT_FOUND only — five other A2A errors collapse into
    // UnsupportedOperationError over gRPC because ballerina/grpc exposes
    // no status details, so e.g. TaskNotCancelableError parity cannot
    // hold and is not asserted here.
    test:assertTrue(jsonRpcResult is TaskNotFoundError);
    test:assertTrue(grpcResult is TaskNotFoundError);
}
```

- [ ] **Step 2: Run tests, expect PASS**

Run: `bal test a2a --tests testJsonRpcAndGrpcReturnIdenticalSendMessageResult,testJsonRpcAndGrpcReturnIdenticalNotFoundErrorType` (PowerShell)
Expected: PASS.

- [ ] **Step 3: Run the full suite once**

Run: `bal test a2a` (PowerShell)
Expected: PASS, zero failures, across every binding's tests.

- [ ] **Step 4: Commit**

```bash
git add a2a/tests/equivalence_test.bal
git commit -m "test: add JSON-RPC/gRPC equivalence tests for success paths and NOT_FOUND"
```

---

## Task 16: Interop verification against the reference agents; record the coverage gap

**Files:**
- Modify (in the **`a2a-interop-tests`** repo, not this one): `FINDINGS.md`

**Interfaces:**
- Consumes: nothing code-level — this is a verification + documentation task.

- [ ] **Step 1: Check each reference agent's AgentCard for a GRPC interface**

For each of `helloworld`, `adk_currency_agent`, and the langgraph agent
(all in `a2a-interop-tests/servers/`), fetch `/.well-known/agent-card.json`
(or wherever each publishes its card — see each agent's own findings.md in
that repo for its exact discovery path) and check
`supportedInterfaces[].protocolBinding` for a `"GRPC"` entry.

- [ ] **Step 2: Record the finding in `a2a-interop-tests/FINDINGS.md`**

If none advertise `GRPC` (the expected outcome, since this mirrors the
REST binding's own gap recorded in that file already), append a section
matching the existing "REST (HTTP+JSON) transport binding — known coverage
gap" one:

```markdown
## gRPC transport binding — known coverage gap

`ballerina/a2a` added a gRPC transport binding (see that repo's
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md` and
`docs/superpowers/plans/2026-08-01-grpc-transport-binding.md`). None of the
three reference agents above advertise a `GRPC` entry in
`supportedInterfaces` — same situation as the REST binding gap recorded
above. So the gRPC binding is currently **mock-verified only**, with the
one exception of the mandatory `Part.data` wire round-trip test (Task 3 of
the implementation plan), which does exercise the real protobuf codec
against a Ballerina-hosted mock service, just not a third-party reference
server. Two things a mock genuinely cannot settle and a real server can,
per the design spec: whether A2A servers populate
`google.rpc.ErrorInfo` in their gRPC status details at all (which decides
how much the binding's error-fidelity limitation actually costs in
practice), and whether `A2A-Version`/`A2A-Extensions` are honoured as gRPC
metadata by real implementations. Closing this needs either a
gRPC-serving A2A agent added to this repo's server set, or one of the
existing reference implementations upgraded to publish a `GRPC` interface.
```

- [ ] **Step 3: Commit (in `a2a-interop-tests`, not `a2a-ballerina`)**

```bash
git add FINDINGS.md
git commit -m "docs: record gRPC transport binding's mock-only interop coverage gap"
```

---

## Task 17: CI for `a2a-ballerina` — build, test, and codegen-freshness on every push/PR

**Files:**
- Create: `.github/workflows/ci.yml` (in `a2a-ballerina`)

**Interfaces:**
- Consumes: `a2a/scripts/regen-grpc-stub.sh` (Task 1).

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Ballerina
        uses: ballerina-platform/setup-ballerina@v1
        with:
          version: 2201.13.4

      - name: Build
        working-directory: a2a
        run: bal build

      - name: Test
        working-directory: a2a
        run: bal test

  grpc-stub-freshness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Ballerina
        uses: ballerina-platform/setup-ballerina@v1
        with:
          version: 2201.13.4

      - name: Check gRPC stub is up to date with vendored proto
        working-directory: a2a
        run: bash scripts/regen-grpc-stub.sh
```

(`ballerina-platform/setup-ballerina@v1` is the standard community action
for installing a pinned Ballerina distribution in GitHub Actions — confirm
its exact tag/version input name against its current README when writing
this, since third-party action interfaces can change between major
versions; pin to a specific major version tag, not `@main`.)

- [ ] **Step 2: Push and confirm the workflow runs**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add build/test and gRPC stub freshness checks"
git push
```

Then check: `gh run list --limit 5` and `gh run watch <run-id>` (or view in
the GitHub UI) to confirm both jobs go green on the pushed commit. If
`grpc-stub-freshness` fails because `bal grpc` behaves slightly differently
in the CI runner's environment than in local development (e.g. a different
bundled `protoc` version producing a byte-different-but-semantically-equal
stub), that is a real finding — investigate and either pin `protoc`
explicitly or adjust the script's diff to tolerate the specific
non-semantic difference, rather than disabling the check.

- [ ] **Step 3: No separate commit needed — Step 1's commit already covers this task**

---

## Task 18: CI for `a2a-interop-tests` — build the demo and test package against `a2a-ballerina`'s `main`

**Files:**
- Create: `.github/workflows/ci.yml` (in `a2a-interop-tests`)

**Interfaces:**
- Consumes: `a2a-ballerina`'s packed `ballerina/a2a` package (built fresh
  from its `main` branch on every run, not a stale pinned version) via
  `bal pack` + `bal push --repository=local`.

**Prerequisite this task cannot do on its own — a manual, one-time setup
step for you (not something to script or automate):** `a2a-ballerina` is a
**private** GitHub repo; `a2a-interop-tests` is public. A public repo's
default `GITHUB_TOKEN` cannot check out a different private repo. Before
this workflow can run successfully, create a fine-grained GitHub Personal
Access Token scoped to read-only access on `Anuja-jayasinghe/a2a-ballerina`
only, and add it as a repository secret named `A2A_BALLERINA_PAT` on
`a2a-interop-tests` (Settings → Secrets and variables → Actions → New
repository secret). This plan does not create that token or set that
secret — it requires your GitHub UI action, and a PAT is a credential this
plan should not generate or handle on your behalf.

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout a2a-interop-tests
        uses: actions/checkout@v4
        with:
          path: a2a-interop-tests

      - name: Checkout a2a-ballerina (private, PAT required)
        uses: actions/checkout@v4
        with:
          repository: Anuja-jayasinghe/a2a-ballerina
          token: ${{ secrets.A2A_BALLERINA_PAT }}
          path: a2a-ballerina

      - name: Set up Ballerina
        uses: ballerina-platform/setup-ballerina@v1
        with:
          version: 2201.13.4

      - name: Pack and push ballerina/a2a to the local repository
        working-directory: a2a-ballerina/a2a
        run: |
          bal pack
          bal push --repository=local

      - name: Build the demo package
        working-directory: a2a-interop-tests/demo
        run: bal build

      - name: Build the tests package
        working-directory: a2a-interop-tests
        run: bal build
```

(If `a2a-interop-tests`'s root `Ballerina.toml` package has no `bal test`
target beyond compiling — the repo is interop test *scripts* run
interactively against locally-running reference agents, not a `bal test`
suite, per its `REPO_MAP.md`/`DEMO_GUIDE.md` — this workflow deliberately
only builds, not tests, both packages. This still catches real breakage:
a `[[dependency]]` on `ballerina/a2a` that no longer compiles against this
repo's demo/test code, which is exactly the failure mode that matters
most here — this repo is what actually exercises the client library end
to end.)

- [ ] **Step 2: Push and confirm the workflow runs**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build demo and tests packages against a2a-ballerina's main on every push/PR"
git push
```

Then, after the `A2A_BALLERINA_PAT` secret has been added (Prerequisite
above), check `gh run list --limit 5` and confirm the workflow goes green.
Until the secret exists, the "Checkout a2a-ballerina" step will fail with
an authentication error — that failure is expected and not a bug in this
workflow, it's the missing prerequisite manifesting.

- [ ] **Step 3: No separate commit needed — Step 1's commit already covers this task**

---

## Summary of files touched

**`a2a-ballerina`:**
- `a2a/proto/a2a.proto`, `a2a/proto/PROVENANCE.md` — new
- `a2a/scripts/regen-grpc-stub.sh` — new
- `a2a/modules/grpcstub/a2a_pb.bal`, `a2a/modules/grpcstub/Module.md` — new
- `a2a/tests/grpcmock/service.bal`, `a2a/tests/grpcmock/scripting.bal` — new
- `a2a/grpc_binding.bal` — new (all `encodeGrpc*`/`decodeGrpc*`, shared helpers)
- `a2a/grpc_stream.bal` — new (`GrpcStreamAdapter`)
- `a2a/client.bal` — `TransportBinding` gains `"GRPC"`; `Client` gains
  `grpcStub`; `init` gains the gRPC construction/rejection arm;
  `buildHeaders` gains binding-aware `Content-Type` omission; `rpcCall`
  gains a `grpcCall` branch; `openSseStream` renamed `openEventStream` and
  gains an `openGrpcStream` branch
- `a2a/compat_v03.bal` — `detectProtocolModeForBinding` extended to reject `V0_3` + `GRPC`
- `a2a/errors.bal` — new `toA2AErrorFromGrpc`
- `a2a/auth.bal` — new `projectToGrpcClientConfig`
- `a2a/tests/` — new test files per task above
- `.github/workflows/ci.yml` — new

**`a2a-interop-tests`:**
- `FINDINGS.md` — gRPC coverage-gap section
- `.github/workflows/ci.yml` — new

## Execution notes for whoever runs this plan

- Tasks 1–4 are pure prerequisites (codegen, mock service, the mandatory
  gate test, enum parity) — nothing in Tasks 5–16 should start before
  Task 3 passes.
- Tasks 6–11 (the conversion layer) can be reviewed/executed in the given
  order since each depends on helpers from the one before, but a
  subagent-driven approach could parallelize Tasks 9–11 once Tasks 6–8 are
  merged, since they don't depend on each other.
- Task 17 and 18 are independent of the gRPC work itself and could be done
  first if you'd rather have CI in place before this feature lands — the
  only reason they're last here is narrative ordering, not a real
  dependency. Consider doing Task 17 immediately, in parallel with Task 1,
  so every subsequent task's commits are already covered by CI as they land.
