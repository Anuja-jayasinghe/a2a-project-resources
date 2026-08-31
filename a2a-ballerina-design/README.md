# a2a-ballerina design docs

Real design and planning material for the [`a2a-ballerina`](https://github.com/Anuja-jayasinghe/a2a-ballerina)
client library, relocated here from that repo's `ballerina/docs/` — the
package directory should only contain what actually ships as part of the
`ballerina/a2a` module, not project-level design documents.

- `A2A_Technical_Design.md` — the technical design doc; source of truth
  for implementing any type or method in the client.
- `API_PROVENANCE.md` — every public symbol in `ballerina/a2a`, classified
  by where it comes from (the A2A spec, a reference SDK convention, or an
  invention of this library) and why.
- `archive/` — superseded drafts, kept for history.
- `planning/plans/` and `planning/specs/` — dated engineering plans and
  their corresponding design specs for individual features as they were
  built (v0.3 compat, remaining operations, security-scheme typing,
  client hardening, REST/gRPC transport bindings, transport-specific
  clients).
- `scripts/regen-grpc-stub.sh` — **backup copy only**, not the working
  copy. The real one still lives at `ballerina/scripts/regen-grpc-stub.sh`
  in `a2a-ballerina` and is what actually gets run; this is insurance in
  case that file is ever lost, pending a decision on whether it moves to
  `a2a-ballerina`'s repo-root `scripts/` or gets removed entirely (see
  that repo's `API_REVIEW_CHECKLIST.md`). It regenerates
  `modules/grpcstub/a2a_pb.bal` from the vendored `proto/a2a.proto` and
  applies the two scripted rewrites documented in `a2a-ballerina`'s
  `ballerina/proto/PROVENANCE.md` (that file stays in `a2a-ballerina` —
  it's tied to the vendored `proto/a2a.proto`, a real package resource,
  not project-level documentation like everything else in this folder).

A mirrored copy also lives in
[`wso2-internship-notes/dump/a2a-ballerina-design`](https://github.com/Anuja-jayasinghe/wso2-internship-notes/tree/master/dump/a2a-ballerina-design)
for the personal-journal trail — this repo is the canonical copy.
