# Local release validation and rollback

The 3.1.0 candidate continues packages 1–5 from `fd851bf` on
`feature/upstream-changes-2026-10`. It is not a published release. The release
decision and measured blockers are recorded in the
[October plan](../plans/2026-10-06-upstream-and-mcp-improvement-plan.md) and its
[evidence](../plans/evidence/release-2026-10-08/README.md).

## Reproduce the Windows checks

The native publisher is `scripts/publish-codedb.ps1` (see the README for usage).
Its offline safety checks run with either Windows PowerShell 5.1 or PowerShell 7:

```powershell
powershell -NoProfile -File scripts/test-publisher.ps1
```

These checks simulate native commands and never push tags or publish releases.
The publisher requires the recorded performance gate to pass before publishing;
the existing failing report blocks release. `-BuildOnly` prepares local artifacts
while restoring the original source versions and performing no remote actions.

Use the verified **Zig 0.16.0** executable explicitly. A different `zig` on PATH
is not an equivalent test. Verify the compiler archive against
`scripts/zig-0.16.0-sha256.txt`, then run:

```powershell
& .build/zig-x86_64-windows-0.16.0/zig.exe build test
& .build/zig-x86_64-windows-0.16.0/zig.exe build -Doptimize=ReleaseFast --prefix .build/release-candidate
python scripts/test-plan-integration.py --binary .build/release-candidate/bin/codedb.exe
pwsh -NoProfile -File scripts/test-installers.ps1
& 'C:/Program Files/Git/bin/bash.exe' scripts/test-installers.sh
```

Run the eight-scenario E2E suite in a child shell with an isolated `HOME`,
`USERPROFILE`, and `CODEDB_CACHE_DIR`, and `CODEDB_NO_TELEMETRY=1`:

```powershell
python scripts/e2e_mcp_test.py --binary .build/release-candidate/bin/codedb.exe --project C:/repos/codedb
```

The local release harnesses use Python's standard library, native Windows
process counters, and stdio JSON-RPC. Run them sequentially, after compilation
and other test workloads have finished:

```powershell
python scripts/release-matrix.py run
python scripts/release-matrix.py extended
python scripts/release-isolation.py
python scripts/release-report.py
```

These commands expect the locally frozen corpus and baseline under the paths
declared in `release-matrix.py`. The baseline is a fresh ReleaseFast build of
`915b9b961c8daa7cc804524888532cea0c040030` with the same compiler. `prepare` is
an explicit one-time operation that refuses to overwrite a frozen corpus.
Before re-running with changed binaries/questions, archive the previous report
and cache directories under the ignored evidence directory. Never reuse live
agent caches, silently combine binary revisions, or upload private evidence.

The corpus consists of Git-visible working-tree bytes, with sensitive names,
binary dependencies, and literal excluded directories omitted. Original source
HEADs, dirty status, every copied file hash, and fixture commit IDs are recorded
locally. This evaluates the frozen corpus, not every byte on the original disk.
The selected Autumn monorepo subdirectory is copied independently; this does
not authorize indexing its containing monorepo.

## Measurement and interpretation

Three alternating baseline/candidate pairs measure empty-cache startup, warm
snapshot load, ten questions per root, and 30 post-warmup samples per question.
Windows `PeakWorkingSetSize` measures peak RSS through readiness; later idle
resource observations are recorded separately. Warm runs reuse their own
variant's snapshot. The OS filesystem cache is not flushed. First-run effects
and variability must be read alongside the medians; p95 across only three
startup repetitions is the maximum and is not a stable tail estimate.

The extended suite measures independently running MCP processes at 1/4/8
agents and synthetic addition/edit/deletion latency. Aggregate RSS is sampled
after readiness; the sum of each process's historical peak is not a simultaneous
aggregate peak. Idle CPU is CPU seconds over the stated wall interval. A zero
baseline makes relative CPU change undefined. The extended measurements have
one trial per setting and therefore provide limited variability evidence.

The strict gate flags **every measured critical-path increase over 10%** and is
retained as a performance-release signal. For this handoff, accuracy, concise
answers, freshness, security boundaries, and local-only telemetry are the
acceptance priorities; do not repeat timing runs solely to improve the report.
Corpus/result losses are reviewed separately; incomplete indexes cannot pass by
being faster. Human golden-corpus review is an optional remaining sign-off, not
a reason to expand client or benchmark testing. Optional context/explain remains
deferred, so the golden workflow uses the existing tools and `codedb_query`.

Both variants use 4 GiB per-process budgets. Standalone Autumn also has retained
eight-worker partial-index diagnostics. Its complete paired runs use one worker
for **both** binaries; the other four roots use eight. This is an explicit
measurement setting, not a change to the product default.

Real-client smoke tests use only synthetic TypeScript and isolated configuration.
Codex app-server, Claude's CLI, and the installed Copilot SDK/runtime are
covered in the attached evidence. ChatGPT and OpenCode were unavailable locally;
their absence is recorded without inferring compatibility. Generic protocol
tests alone do not prove compatibility, and no further client matrix is needed
for the data-quality handoff.

## Versions, cache policy, and rollback

`src/release_info.zig` and `build.zig.zon` are aligned at **3.1.0**. Packages 1–5
already bumped snapshot format to **4**, semantic/policy index version to **5**,
word-index disk format to **4**, and trigram format to **4**. The scoped-search
fix changes query-time filtering and requires no persisted-format bump. The
subsequent ignore-character-class correction raises the semantic/policy index
version to **6** so previously included files cannot survive a warm restore.
Incompatible snapshots and disk indexes rebuild under the new policy.

Before deploying an approved build, retain its SHA-256, verified toolchain,
source commit, configuration, and the previous binary's hash. Stop the affected
MCP client processes before switching binaries; do not terminate unrelated agents.
Start the replacement with an empty, explicitly selected cache directory and
rebuild only the intended project roots. Validate status and a source-backed
query before reconnecting the clients.

The 3.0.1 baseline has known security defects and is **not a safe rollback for
private repositories**. Prefer a forward fix or a previously validated hardened
binary. If using 3.0.1 solely for reproduction, restrict it to isolated fixture
copies. Never reuse a candidate cache with an older binary. Retire old root-level
`codedb.snapshot` files, per-project cache artifacts, and exported snapshot copies
that may contain previously indexed sensitive content. Resolve and inspect each
exact cache path before removal; do not delete a source root or an entire shared
cache tree indiscriminately. Ordinary deletion is not a claim of forensic erasure.

No release tag, publish, push, upstream merge, hosted embedding service, or
production client registration is part of this validation procedure.
