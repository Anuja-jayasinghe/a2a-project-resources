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

# Post-processing step 1 of 2 -- the Ballerina type of Part.data.
#
# `bal grpc` has no mapping for a field typed directly `google.protobuf.Value`
# and emits a reference to an undefined type name `google_protobuf_Value`
# (it DOES map `google.protobuf.Struct` correctly, to `map<anydata>`). The
# correct Ballerina representation of a `google.protobuf.Value` is plain
# `anydata`: that is exactly how ballerina/grpc's own runtime models it
# already, since the values of a `Struct`'s field map are `Value`s and those
# surface as the `anydata` values of a `map<anydata>`. So this rewrite is not
# an erasure -- it lines the generated type up with the runtime's real
# representation. See a2a/modules/grpcstub/wellknown_desc.bal.
echo "Post-processing 1/3: rewriting google_protobuf_Value -> anydata ..."
OCCURRENCES=$(grep -o "google_protobuf_Value" "$GENERATED_FILE" | wc -l | tr -d ' ')
if [ "$OCCURRENCES" -ne 2 ]; then
    echo "ERROR: expected exactly 2 occurrences of google_protobuf_Value, found $OCCURRENCES." >&2
    echo "The bal grpc tool's output shape has changed — do not proceed with this rewrite." >&2
    exit 1
fi
sed -i 's/google_protobuf_Value/anydata/g' "$GENERATED_FILE"

# Post-processing step 2 of 2 -- the dependency descriptor map.
#
# `bal grpc` emits `initStub(self, A2A_DESC)` with no descriptor map, so
# a2a.proto's `google/protobuf/struct.proto` dependency never gets resolved.
# ballerina/grpc's ServiceDefinition.getFileDescriptor() then falls back to
# `FileDescriptor.buildFrom(proto, deps, /*allowUnknownDependencies=*/true)`,
# which turns every google.protobuf.* type into a *placeholder* descriptor.
# Placeholders are re-resolved at (de)serialization time by
# StandardDescriptorBuilder's message-name table, which covers
# google.protobuf.Struct (hence metadata/params/header always worked) but NOT
# google.protobuf.Value -- so Part.data died at runtime with
#   "Failed to frame message: Cannot invoke
#    Descriptors$FileDescriptor.findMessageTypeByName(String) because
#    fileDescriptor is null".
# Passing A2A_DESCRIPTOR_MAP (defined in the hand-maintained companion file
# a2a/modules/grpcstub/wellknown_desc.bal, which this script does NOT
# generate or overwrite) resolves struct.proto for real, so Value/ListValue/
# NullValue are proper descriptors and the runtime's existing
# google.protobuf.Value <-> anydata machinery is reachable.
echo "Post-processing 2/3: wiring A2A_DESCRIPTOR_MAP into initStub ..."
STUB_OCCURRENCES=$(grep -c "initStub(self, A2A_DESC)" "$GENERATED_FILE" | tr -d ' ')
if [ "$STUB_OCCURRENCES" -ne 1 ]; then
    echo "ERROR: expected exactly 1 occurrence of 'initStub(self, A2A_DESC)', found $STUB_OCCURRENCES." >&2
    echo "The bal grpc tool's output shape has changed — do not proceed with this rewrite." >&2
    echo "If the tool now emits its own descriptor map, drop this step and delete" >&2
    echo "A2A_DESCRIPTOR_MAP from modules/grpcstub/wellknown_desc.bal." >&2
    exit 1
fi
sed -i 's/initStub(self, A2A_DESC)/initStub(self, A2A_DESC, A2A_DESCRIPTOR_MAP)/' "$GENERATED_FILE"

# Post-processing step 3 of 3 -- the Apache-2.0 license header.
#
# `bal grpc` emits no header at all. Every other .bal file in this repo
# carries one (see the other 35 files), matching real ballerina-platform
# module convention -- checked directly against module-ballerina-http and
# module-ballerina-ai, neither of which exempts generated files. Prepended
# here, not hand-edited into the checked-in file, because a hand-added
# header would be silently wiped by the next --apply run.
echo "Post-processing 3/3: prepending the Apache-2.0 license header ..."
HEADER_FILE="$SCRATCH_DIR/license_header.txt"
cat > "$HEADER_FILE" <<'EOF'
// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

EOF
cat "$HEADER_FILE" "$GENERATED_FILE" > "$GENERATED_FILE.headered"
mv "$GENERATED_FILE.headered" "$GENERATED_FILE"

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
echo "Note: modules/grpcstub/wellknown_desc.bal is hand-maintained, not generated,"
echo "      and is deliberately not compared here."
