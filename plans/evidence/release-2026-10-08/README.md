# Local release evidence (2026-10-08)

This directory contains source-free summaries and hashes. Private corpus copies,
queries, synthetic secrets, MCP transcripts, and detailed timing runs remain in
the ignored `plans/evidence/local/release-2026-10-07-final/` directory.

## Data-quality acceptance

- The candidate was built with Zig 0.16.0 and reaches `ready` on all five roots.
- The frozen golden corpus has 10 source-anchored questions per root (50 total).
  Candidate results contain 48/50 expected target sets; the baseline contains
  44/50. The two shared misses are the F# bare-module dependency cases. A
  unique module-name resolver is in the working tree; its fresh-cache result is
  the one focused accuracy check still outstanding.
- Standalone Autumn reports an explicit `ready` terminal state with scanned,
  parsed, oversized, failure, and peak-memory metrics.
- Root/cache evidence covers parent/child isolation, secondary-root reuse,
  forced add/delete convergence, root switching, and synthetic secret/junction
  boundaries. The original isolation log contains one presentation-only false
  negative: the tree prints `child/` and an indented `child.ts` on separate
  lines. Its captured output contains both expected entries; the harness now
  accepts that stable format.

## Reproducible checks

`validation.json` records the Zig unit test, ReleaseFast build, 42/42 MCP E2E,
plan integration, and PowerShell/Bash installer results with hashes. Telemetry
integration used a loopback endpoint and synthetic fixtures only.

## Client observations

Codex CLI, Claude Code, and the bundled Copilot runtime each passed isolated
full and navigation read-only smokes. ChatGPT had no accessible local
registration surface and OpenCode was not installed. Those unavailable rows are
recorded in `clients.json`; no compatibility claim is inferred from them, and
no further client matrix is required for this handoff.

## Performance and rollback

`performance.json` retains the five-root paired timing matrix. It exceeds the
10% timing threshold on warm-load medians, so this branch makes no performance
improvement claim. Performance is informational for this handoff because the
requested priority is accurate, concise, current data. Rollback and stale-cache
cleanup are documented in `docs/release-validation.md`.
