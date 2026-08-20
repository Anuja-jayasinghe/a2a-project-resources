# Migration notes

This repo holds the original, hand-authored material from the local
`A2A_Project` working folder — the proposal doc, diagram, design-doc
templates, and a small evidence-capture Ballerina package. It deliberately
does **not** include the following, which lived alongside it in that same
folder but are either vendored third-party clones or downloaded toolchain
binaries — re-obtain them fresh on the new machine instead of copying them:

## Vendored upstream repos (re-clone, don't copy)

| Folder | Upstream | Commit at time of migration |
| :--- | :--- | :--- |
| `a2a-samples` | https://github.com/a2aproject/a2a-samples | `e580a885a73e689eb448c377789b3a65e97b6c0` (`main`, 2026-07-27) |
| `a2a-java` | https://github.com/a2aproject/a2a-java | `a7a85d46e8d978b21e69c52b2a81f614882ccee` (`main`, 2026-07-30) |
| `a2a-tck` | https://github.com/a2aproject/a2a-tck | `5996b79f9cefa6fc390980e383e358a66fb9e49` (`main`, 2026-06-29) |

```bash
git clone https://github.com/a2aproject/a2a-samples.git
git clone https://github.com/a2aproject/a2a-java.git
git clone https://github.com/a2aproject/a2a-tck.git
```

Each was a plain clone with no local modifications — a fresh `git clone`
of `main` will be at or ahead of the commits above, which is fine unless
you specifically need to reproduce a past result, in which case
`git checkout <commit>` after cloning gets you the exact state.

## Toolchain (reinstall, don't copy)

| Tool | Version |
| :--- | :--- |
| JDK | 21.0.12+8 |
| Apache Maven | 3.9.16 |

On macOS, `brew install openjdk@21 maven` (or your preferred JDK
distribution) gets equivalent versions.

## What's actually in this repo

- `A2A_Ballerina_Library_Proposal.docx`, `A2A_Proposal diagram.drawio.png`
  — the original proposal and diagram.
- `Templates & info/` — design-doc templates and samples referenced while
  writing the proposal.
- `evidence_capture/` — a small Ballerina package (`main.bal`) used to
  manually capture real request/response evidence against a locally
  running agent (push-notification-config CRUD, in-flight task
  cancellation) while verifying `ballerina/a2a`'s client behavior.

## Where the actual library and test work live

- [`a2a-ballerina`](https://github.com/Anuja-jayasinghe/a2a-ballerina) —
  the `ballerina/a2a` client library itself.
- [`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
  — interoperability tests, demos, and `a2a-ballerina`'s design-history
  docs (`docs/a2a-ballerina-design/`).

Both are separate repos with their own remotes — clone them directly
rather than through this one.
