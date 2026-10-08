# codedb data-quality completion plan

This is a cold-session handoff for the small amount of work left after the
five-root release validation. It is intentionally narrower than the original
upstream-improvement plan: the product priority is accurate, concise, current
answers from codedb, not another performance or client-compatibility campaign.

**Completed 2026-10-08:** both focused fresh-cache checks pass after the narrow
F# resolver repair recorded below. Packages 1–5 and the existing release
evidence remain complete; no broader validation campaign was rerun.

## Starting state

- Repository: `C:\repos\codedb`
- Branch: `feature/upstream-changes-2026-10`
- Starting commit: `3f5e7f5` (`Clarify data-quality handoff and resolve F# modules`)
- Toolchain: `.build\zig-x86_64-windows-0.16.0\zig.exe`
- Required constraints: preserve security boundaries, local-only telemetry,
  retained edit/remote tools, Zig 0.16, and every fork language. Do not upload
  private source, use hosted embeddings, index `C:\repos\credo_main` broadly,
  push or merge upstream, or register production clients.

The completed evidence is summarized in
[`plans/evidence/release-2026-10-08/README.md`](evidence/release-2026-10-08/README.md).
The original scope and historical evidence remain in
[`plans/2026-10-06-upstream-and-mcp-improvement-plan.md`](2026-10-06-upstream-and-mcp-improvement-plan.md).

## Only required task

Build the current source with Zig 0.16 and exercise `codedb_deps` from a fresh,
isolated cache for these two source-backed cases:

| Root | Query path | Direction | Expected dependency |
|---|---|---|---|
| `C:\repos\autumn` | `src/Autumn.Publisher/Publisher.fs` | `depends_on` | `src/Autumn.Publisher/Domain.fs` |
| `C:\repos\credo_main\src\Autumn` | `EquinoxLib/Compiler.fs` | `depends_on` | `EquinoxShared/Metadata.fs` |

The resolver now prefers a unique sibling F# source for a bare module name such
as `open Domain`, then a unique F# source across the indexed root for names such
as `open Metadata`. Verify that the result is stable
across a second read from the same cache, that no unrelated path is returned,
and that `codedb_status` reports a ready terminal state. Use synthetic fixtures
or the existing local source copies only; retain private transcripts under the
ignored local evidence directory.

Run the focused unit/build check needed to validate the change:

```powershell
$zig = (Resolve-Path .build/zig-x86_64-windows-0.16.0/zig.exe).Path
& $zig build test
& $zig build -Doptimize=ReleaseFast --prefix .build/data-quality-candidate
```

Use an isolated `CODEDB_CACHE_DIR`, `HOME`, and `USERPROFILE` for the focused
MCP check. Reuse the existing stdio harness in `scripts/release-matrix.py` or a
small equivalent local driver; do not invoke the five-root timing matrix,
extended agents, installer suite, or external client smoke scripts.

## Acceptance and evidence

The task is complete when:

1. `zig build test` exits 0 with Zig 0.16.
2. Both dependency queries return their expected relative path on a fresh cache.
3. Repeating each query returns identical JSON and `codedb_status` is `ready`.
4. No source, secret, query, or telemetry payload leaves the machine.
5. This document records the command, binary hash, cache isolation location,
   result summaries, and any limitation. Keep detailed transcripts ignored.

The 10% performance result is already recorded as informational. ChatGPT and
OpenCode were unavailable locally; no new AI-client testing is required. Human
review of the existing 50-question golden corpus is optional. If the focused
F# check fails, fix only the dependency-resolution issue, add a narrow regression
test, rerun the focused checks, and record the failure and repair here.

## Completion evidence (2026-10-08)

Work continued on `feature/upstream-changes-2026-10` from clean commit
`8e614c8` (`Add focused data quality cold-session plan`). The pinned executable
reported Zig `0.16.0`. Both commands below exited 0 on the original source and
again after the focused repair:

```powershell
& .\.build\zig-x86_64-windows-0.16.0\zig.exe build test
& .\.build\zig-x86_64-windows-0.16.0\zig.exe build -Doptimize=ReleaseFast --prefix .build/data-quality-candidate
```

The first fresh-cache run reached `ready` on both roots and repeated identical
dependency JSON. The credo Autumn case passed, but standalone Autumn failed:
multiple corpus-wide `Domain` basenames prevented sibling resolution, and an
external module name incorrectly resolved to an XML documentation file.
The original binary SHA-256 was
`bb4c62dde515a1556eb155d2b8170bce735b4a37efb1aa786e31551daed4d071`.

The focused fix passes the importing path to dependency resolution. F# bare
module matching now considers only indexed F# sources and prefers a unique
same-directory candidate; ambiguity within that scope remains unresolved.
Other languages retain their matching behavior. Direct, transitive, and
pipeline dependency callers share this rule, and the pipeline holds its read
lock while resolving and copying paths. The synthetic regression in
`src/tests/upstream_plan.zig` covers duplicate basenames, unrelated XML files,
unique cross-directory modules, direct JSON and transitive results,
same-directory ambiguity, and deletion. No private source was added to tests.

Final binary: `C:\repos\codedb\.build\data-quality-candidate\bin\codedb.exe`.
SHA-256:
`abdd44a1d168c68e28d419397df4cb4f28e9f0fb78ddb54d4e2336bf63c446cf`.

The ignored local driver imports only the stdio harness class from
`scripts/release-matrix.py`; it does not invoke a matrix phase. The repair was
checked with this command (exit 0):

```powershell
& 'C:\Users\jwvol\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  plans/evidence/local/data-quality-2026-10-08/focused_deps.py `
  plans/evidence/local/data-quality-2026-10-08/repaired
```

| Root | Expected resolved dependency | Repeated JSON | Status before / after | Unrelated resolved paths |
|---|---|---|---|---|
| `C:\repos\autumn` | `src/Autumn.Publisher/Domain.fs` | Byte-identical; pass | `ready` / `ready` | None |
| `C:\repos\credo_main\src\Autumn` | `EquinoxShared/Metadata.fs` | Byte-identical; pass | `ready` / `ready` | None |

Each query used the path from the required-task table, `direction=depends_on`,
and `output_format=json`, followed by one identical query in the same session.
Remaining unresolved module names were checked against the source's `open`
statements. Stability refers to the dependency JSON data block; JSON-RPC
request IDs and repeat-query guidance are transport/presentation metadata.

Final `CODEDB_CACHE_DIR` values (both absent before their runs):

- `C:\repos\codedb\plans\evidence\local\data-quality-2026-10-08\repaired\homes\autumn\.codedb`
- `C:\repos\codedb\plans\evidence\local\data-quality-2026-10-08\repaired\homes\credo-autumn\.codedb`

For each process, `HOME` and `USERPROFILE` were set to the corresponding parent
of `.codedb`. Explicit cache isolation bypassed source-root snapshots. The
driver used one scan worker, a 4096 MB memory budget, `CODEDB_NO_AUTO_UPDATE=1`,
`CODEDB_TELEMETRY=0`, `CODEDB_NO_TELEMETRY=1`, and `--no-telemetry`, and removed
`CODEDB_TELEMETRY_URL` from the child environment. All checks used local stdio
and the two exact source roots, with no upload, hosted embeddings, analytics
endpoint, client registration, or broader `credo_main` indexing. Security
boundaries, local-only telemetry behavior, every fork language, retained
edit/remote tools, and synthetic-secret isolation were preserved.

The failed run's private transcript and cache remain under ignored
`plans/evidence/local/data-quality-2026-10-08/`; the passing run's complete
results, transcripts, stderr, status history, and caches are under its
`repaired/` subdirectory. Unit/build logs and the local driver are also ignored.
Only this source-free summary and the focused implementation/test changes are
committed.

Limitations: module resolution remains a conservative filename/scope heuristic,
not F# compiler binding or project-reference evaluation. No five-root benchmark,
extended performance test, installer suite, AI-client matrix, or broader MCP
E2E suite was rerun. The previously recorded failing 10% performance gate still
blocks release; this accuracy completion does not turn it into a passing gate.
The prior ChatGPT/OpenCode availability limitations remain unchanged. No push
or upstream merge was performed.

## Original cold-session prompt (completed)

Retained for provenance; the requested work is complete:

> Read `plans/2026-10-08-data-quality-completion-plan.md` in `C:\repos\codedb` and continue on `feature/upstream-changes-2026-10`. Treat packages 1–5 and all evidence in `plans/evidence/release-2026-10-08/` as complete. Do not run another five-root benchmark, extended performance test, installer suite, or AI-client matrix. Use the pinned Zig 0.16 executable at `.build\zig-x86_64-windows-0.16.0\zig.exe`, build the current source, and perform only the two fresh-cache `codedb_deps direction=depends_on` checks listed in the plan: Autumn `src/Autumn.Publisher/Publisher.fs` must return `src/Autumn.Publisher/Domain.fs`, and `credo_main\src\Autumn` `EquinoxLib/Compiler.fs` must return `EquinoxShared/Metadata.fs`. Repeat each query to confirm stable JSON and confirm `codedb_status` is ready. Preserve security boundaries, local-only telemetry, all fork languages, retained edit/remote tools, and synthetic-secret isolation. Keep private transcripts under ignored local evidence. If the resolver fails, make the smallest focused fix and regression test; otherwise update this plan with the binary hash, isolated cache path, results, and any limitation, commit the changes on the current branch, and do not push or merge upstream.
