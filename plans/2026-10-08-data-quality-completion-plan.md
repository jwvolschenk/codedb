# codedb data-quality completion plan

This is a cold-session handoff for the small amount of work left after the
five-root release validation. It is intentionally narrower than the original
upstream-improvement plan: the product priority is accurate, concise, current
answers from codedb, not another performance or client-compatibility campaign.

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

The working tree now resolves a unique bare F# module name such as `open Domain`
or `open Metadata` to its indexed `.fs` path. Verify that the result is stable
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

## Cold-session prompt

Copy the following prompt into a new session:

> Read `plans/2026-10-08-data-quality-completion-plan.md` in `C:\repos\codedb` and continue on `feature/upstream-changes-2026-10`. Treat packages 1–5 and all evidence in `plans/evidence/release-2026-10-08/` as complete. Do not run another five-root benchmark, extended performance test, installer suite, or AI-client matrix. Use the pinned Zig 0.16 executable at `.build\zig-x86_64-windows-0.16.0\zig.exe`, build the current source, and perform only the two fresh-cache `codedb_deps direction=depends_on` checks listed in the plan: Autumn `src/Autumn.Publisher/Publisher.fs` must return `src/Autumn.Publisher/Domain.fs`, and `credo_main\src\Autumn` `EquinoxLib/Compiler.fs` must return `EquinoxShared/Metadata.fs`. Repeat each query to confirm stable JSON and confirm `codedb_status` is ready. Preserve security boundaries, local-only telemetry, all fork languages, retained edit/remote tools, and synthetic-secret isolation. Keep private transcripts under ignored local evidence. If the resolver fails, make the smallest focused fix and regression test; otherwise update this plan with the binary hash, isolated cache path, results, and any limitation, commit the changes on the current branch, and do not push or merge upstream.
