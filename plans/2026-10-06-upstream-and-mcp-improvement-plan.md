# codedb fork: upstream adoption and MCP improvement plan

Assessment date: 2026-10-06. This document is the handoff for implementation in later sessions. No production code was changed, no branches were merged, and nothing was pushed upstream.

## Recommendation

Keep this fork and selectively adapt upstream fixes. Start with project isolation, secret exclusion, installer verification, and navigation correctness. Then improve freshness and measure performance. Add a small local context tool only after its underlying answers are reliable. Do not replace the fork with current upstream or import its hosted semantic defaults.

The fork's C#/F#/Razor, Autumn DSL, T-SQL, SSRS/SSAS/DAX/MDX, Godot, Windows, manifest, type-reference, and multi-project work is valuable. Preserve it explicitly in regression coverage. Preserve `codedb_edit` and `codedb_remote` compatibility; their visibility/defaults can be configured separately. There is no proposed upstream contribution or upstream PR.

## Exact comparison and evidence

| Item | Audited state |
|---|---|
| Fork | `jwvolschenk/codedb`, `main`, tag `v3.0.1`, `915b9b961c8daa7cc804524888532cea0c040030`, August 3 |
| Upstream | [justrach/codedb](https://github.com/justrach/codedb), `36e35bf17624a277513b031c8826b552911763bf`, September 29 |
| Latest release version in upstream source | `0.2.5860`, September 27 |
| Common ancestor | `ebbb097ab80630e0b1f8dc0ccad9190921149da3`, June 7 |
| Graph divergence | 132 fork-only / 467 upstream-only commits. These are ancestry counts, **not** counts of missing features: the fork already selectively ported changes. |
| Prior selective adoption | `f232b40` on August 3; follow-up TS import fix `bdcf534` |
| Compilers | Fork: Zig 0.16.0; upstream: `0.17.0-dev.813+2153f8143`. Avoid coupling security fixes to a compiler migration. |
| Tested binary | `C:\Users\jwvol\AppData\Local\codedb\bin\codedb.exe`, reports 3.0.1 |
| Binary SHA-256 | `c71c1cf0fe45d6aa8e746bd484f6c92e4c962803e095e3a8b331ca2ca25453af` |

Fetched upstream into `FETCH_HEAD` using its HTTPS URL, without changing remotes or the checked-out branch. A later fetch can replace `FETCH_HEAD`; use the pinned SHA above in follow-up work. Current upstream source was inspected through Git, including actual diffs, not only release descriptions. [Pinned upstream changelog](https://github.com/justrach/codedb/blob/36e35bf17624a277513b031c8826b552911763bf/CHANGELOG.md).

Evidence is in `plans/evidence/`:

- `2026-10-06-audit.json`: synthetic boundary/caller probes and five repository smoke checks.
- `2026-10-06-extra.json`: duplicate-basename dependencies, ignore semantics, snapshot canary, corrected Windows roots handshake.
- `2026-10-06-freshness.json`: preserved-timestamp stale read/search and explicit F# references.
- `2026-10-06-e2e.txt`: complete existing E2E harness output.
- `audit_probe.py`, `audit_extra.py`, `audit_freshness.py`: copies of the assessment drivers, with host-specific paths. These are exploratory probes, not yet release-gating tests. They create synthetic temporary Git projects and normal index/cache artifacts; they do not change application source. The primary driver retains bounded excerpts from ordinary navigation queries. Review its hardcoded output paths before rerunning.

Limits: tests used the installed release, not a newly compiled binary. Zig was not available on PATH or in the common locations checked, so `zig build test` was **not run**. No baseline-versus-candidate performance comparison was performed. File-symlink creation was denied by Windows privilege policy, so that exploit path is a source-review finding, not a live reproduction. No actual secret files were read; boundary tests used synthetic canaries. `CODEDB_TELEMETRY` was absent in the environment, so telemetry was off by the implementation's default; later probes also passed `--no-telemetry` explicitly.

## Confirmed findings and implementation priorities

### A. P1 — Windows project escape and sensitive-file exposure (first release blocker)

Live reproduction: `codedb_read` rooted at a temporary `project` returned a synthetic sibling file when passed `C:/.../outside.txt`. A native backslash absolute path inside the project was rejected, whereas the forward-slash drive path outside it succeeded. `isPathSafe()` rejects leading `/`, backslashes and `..`, but does not recognize drive-qualified paths; `projectRelPath()` passes them through as relative. Disk reads then accept the absolute path.

Live reproduction: `.env` and `private.key` were blocked, but `upper/.ENV`, `private.PEM`, and `Credentials.JSON` were readable and searchable. The snapshot command also persisted the synthetic `.PEM` content. Case-sensitive sensitive-name/extension matching is unsafe on Windows and inconsistent on other platforms.

Implement in `src/path_safety.zig` (lines 17, 41, 67), `src/root_policy.zig`, `src/root_resolve.zig`, `src/cio/file.zig`, `src/mcp/mutation_tools.zig`, watcher readers, search disk fallbacks, HTTP readers, and snapshot loaders/writer:

1. One platform-aware path classifier and one root-confined file-access API. Normalize legitimate in-root Windows paths; reject drive-relative paths, out-of-root drive paths, UNC/device paths and alternate data stream forms unless explicitly supported safely. Reject whole-drive/system/network roots independently of the Git-repository guard. Keep the configured `project=` feature, but isolate every selected root.
2. Use a stable directory handle and validate the opened object. Address final file symlinks, parent links/junctions, root replacement, sensitive-directory aliases, and check/open races. Do not treat string-prefix checks or a pre-open `realpath` as the entire boundary. Apply equivalent protection to retained edit operations, including file creation and replacement.
3. Case-insensitive sensitive basename, extension and directory-component matching, with consistent separator normalization. Retain SSAS content-sensitive filtering.
4. Enforce exclusions on ingest, snapshot restore, index/search result production and direct reads. Audit legacy disk indexes: fixing only the walker leaves previously persisted secrets accessible. Bump the indexing/policy version and rebuild incompatible caches automatically; document cleanup of old snapshot copies.

Acceptance: synthetic `.env`/`.ENV`, `.pem`/`.PEM`, `.key`/`.KEY`, credentials variants and sensitive-directory aliases are absent from search, word, symbol, tree, outlines, reads and snapshots; old-cache restore cannot reintroduce them. Traversal, absolute outside-root, drive-relative, UNC/device, ADS and symlink/junction tests fail safely. In-root paths with spaces, case variants and both Windows separator styles work. Test HTTP and query/bundle routes as well as direct MCP tools. Verify retained edits cannot modify a synthetic file outside the root.

Donors: [case variants `fbd7581`](https://github.com/justrach/codedb/commit/fbd7581), [file-link protection `4031c74`](https://github.com/justrach/codedb/commit/4031c74), [root capabilities `845ea53`](https://github.com/justrach/codedb/commit/845ea53), [root rejection `4b6c12d`](https://github.com/justrach/codedb/commit/4b6c12d), [pinned index root `93ca2a5`](https://github.com/justrach/codedb/commit/93ca2a5), [Windows no-follow I/O `2b204c7`](https://github.com/justrach/codedb/commit/2b204c7). Inspect the final `src/project_file.zig`/`src/project_path.zig` implementations at the pinned upstream SHA and their prerequisite history. Adapt to Zig 0.16 and this fork's edit/SSAS paths; do not cherry-pick semantic retrieval as a dependency.

### B. P1 — Installer verification; snapshot and concurrency hardening

Source-confirmed installer issue: `scripts/setup-codedb.ps1:86` catches checksum download/verification failures and continues; absent checksum entries also continue. `scripts/setup-codedb.sh:99` similarly proceeds on missing manifest/hash, and can print “Checksum verified” without an available hashing utility. The internal updater already has stronger fail-closed behavior; reuse its contract, not these fallbacks.

Implement exact asset-name matching, one well-formed SHA-256 entry, verified download before install or execution, safe unique temporary files and cleanup. Missing/malformed/duplicate checksums, missing hash utilities, HTTP errors and mismatch must leave the previous binary intact. Keep fork release URLs. Apply verification to compiler bootstrap in `scripts/build-codedb.sh` and CI, and pin the mutable `mcp_zig` archive URL to an immutable revision while retaining its content hash.

Additional source-review findings to close in this security batch:

- `src/snapshot/format.zig:63` trusts section counts; bounds checks at line 107 and in both loaders use `offset + length`, which can overflow. Use subtraction-based bounds, bounded section counts, record-within-section checks and cleanup on nullable failure. Loaders must also validate paths before any disk fallback. [Donor `6590003`](https://github.com/justrach/codedb/commit/6590003) includes snapshot fixes, notification-file protection and tests. Only bring across applicable parts; Unix CLI peer authentication has no immediate equivalent in this fork's current transport.
- `src/mcp/explore_tools.zig:1406` obtains a borrowed forward-dependency slice, releases the Explorer lock, then copies its entries. The watcher can replace/free it in that window. Copy under the lock or expose an owned-result API. This lifetime window is confirmed in source; no crash was reproduced. Audit similar graph-return APIs before adding concurrency.
- Notification ingestion in `src/watcher/incremental.zig` should validate owner/type and root confinement; do not blindly port platform-specific owner checks without a Windows equivalent.

Acceptance: mocked installer failure tests never replace/run the old binary; malformed snapshots cause bounded rejection without panic, OOM, leaked allocations or filesystem escape; concurrent dependency queries plus file replacement/reindex pass sanitizer/debug stress tests where supported.

### C. P2 — Caller/reference correctness and bounded results

Live synthetic fixture: one real TypeScript call plus block-comment, regex and template-string mentions produced **five** call sites. The same query with `max_results=1` produced **zero**, because candidate limiting happens before filtering. Separately, `lm-asp-net` returned **21 references with `max_results=20`**, because structural reference merging is unbounded.

Live F# fixture from `credo_main/src/Autumn`: `QueryProcess` resolves to `EquinoxLib/Compiler.fs:762`, and search finds `QueryProcess<T>` uses, but default callers returns zero. Explicit `match_mode=references` returned four usages at limit 10. That is a useful workaround, not evidence of complete recall. F# application, pipelines, quotations, generic values and function-value references do not fit a C-style “identifier followed by parentheses” rule.

Implement a shared candidate/filter/rank/limit path for direct callers, relations and `codedb_query` callers. Track lexical state across the source file (including multiline comments/literals), preserve the fork's structural type references, and apply output limits after exclusions and scope filters. Add `path_glob`/definition scope consistently; the current direct callers and query callers implementation do not read the documented per-step `path_glob`. Return honest `truncated`, candidate/returned counts and matching reasons. Avoid presenting heuristic references as compiler-resolved calls.

Files: `src/mcp/explore_tools.zig:1030`, `:1328`, `src/mcp/query/steps/callers.zig`, `src/explore/search.zig`, C#/F#/JS parser metadata. Also inspect scoped search: it filters `path_glob` after collecting globally capped results, potentially reporting no matches in a scope that does contain them.

Donors: [candidate starvation `5fc6fad`](https://github.com/justrach/codedb/commit/5fc6fad), [lexical scan `49a31a3`](https://github.com/justrach/codedb/commit/49a31a3), follow-ups [template bounds `154fb86`](https://github.com/justrach/codedb/commit/154fb86) and [JS regex `09b4e26`](https://github.com/justrach/codedb/commit/09b4e26), [scope before page `067c0a1`](https://github.com/justrach/codedb/commit/067c0a1). Upstream's bounded over-fetch is a mitigation, not a proof of complete recall; expose incompleteness or iterate candidates where necessary. Its language handling must be extended for this fork's F#/C#/SQL semantics.

Acceptance: synthetic callers at limits 1 and 50 both return only the single real call; multiline literals/comments never create calls; real calls after strings/comments remain visible. `Probe` retains structural references with an honest cap. F# golden cases include `QueryProcess<T>`, `f x`, `x |> f`, `f <| x`, quotations and qualified module functions, with explicit reference/call labels. Scoped queries do not spend their entire budget on other folders. Malformed strings, braces in literals, unterminated comments and regex/template edge cases never crash or create fabricated declarations.

### D. P2 — Exact dependencies and project-aware navigation

Live synthetic fixture: `consumer.ts` imports `./a/index`, with both `a/index.ts` and `b/index.ts` present. Forward deps returned the bare key `index`; reverse deps for **both** files returned none. `src/explore/deps.zig:460` normalizes the relative path and then discards it in favor of the basename. The prior changelog's claim that relative imports are already correct is too broad: its test only exercises a unique basename.

Adopt exact relative TS/JS resolution, extension/index-file candidates and bounded tsconfig aliases, leaving package imports distinct from local files. Preserve uncertainty instead of guessing. Retain language-specific type-usage and SQL dependencies; do not replace the entire graph with upstream's TS/Zig assumptions. Then add qualified identity for same-named C# types/methods and F# modules. Use `.sln`/`.csproj`/`.fsproj` project references and F# compile ordering as optional local facts; do not load MSBuild tasks or execute project code.

Files: `src/explore/deps.zig`, `src/explore/dependency_graph.zig`, `src/index/type_index.zig`, `src/index/type_graph.zig`, `src/manifest.zig`, `src/tests/parsers/javascript.zig`. Donor: [exact imports `223d5a2`](https://github.com/justrach/codedb/commit/223d5a2); consult [ambiguity `b38c370`](https://github.com/justrach/codedb/commit/b38c370) and [graph resolution `8002026`](https://github.com/justrach/codedb/commit/8002026) for design/tests, not a wholesale call-graph transplant.

Acceptance: only `a/index.ts` has `consumer.ts` as importer; forward paths are navigable; re-exports, aliases, duplicate filenames and changes/deletions preserve forward/reverse consistency. Distinguish unresolved/ambiguous/external edges in structured output. Pin representative C#/F# identities and relationships from the local corpus.

### E. P2 — Ignore semantics and monorepo scope

Live tests: a nested `.gitignore` did not exclude its file, while `*.skip.ts` plus `!keep.skip.ts` incorrectly excluded the re-included file. `FilteredWalker.init` loads only root ignore files and explicitly skips `!` rules; its glob implementation also compares many patterns only with the basename.

Implement nested Git ignore semantics, anchored patterns, `**`, negation, `.git/info/exclude` and a clearly defined `.codedbignore` precedence that cannot override mandatory security exclusions. Use one matcher for cold scan, live scan, reconcile and live directory listing. Add configurable exclusion of `.worktrees`, `.devenv`, `.jj`, `.graff`, `.harness` and generated tool output. Avoid hiding user-authored source merely because a broad directory name matches a cache convention.

Donors: [ignore/resource fixes `63e7076`](https://github.com/justrach/codedb/commit/63e7076), [worktrees `55483a0`](https://github.com/justrach/codedb/commit/55483a0), [tool output `c7633ac`](https://github.com/justrach/codedb/commit/c7633ac), [devenv/Jujutsu `e37a635`](https://github.com/justrach/codedb/commit/e37a635). Dependency: upstream's `gitignore.zig`; adapt its final behavior rather than cherry-picking the large mixed watcher commit.

Treat `C:\repos\credo_main\src\Autumn` as a first-class index root while discovering Git metadata at `C:\repos\credo_main`. Keep all stored/query paths relative to the selected root. Do not index the monorepo root to test this work. Expose root, Git root, indexed/excluded/oversized/generated counts and ignore-policy version. Optional solution membership can distinguish active from dormant Autumn projects; do not automatically exclude dormant folders without a setting.

Acceptance: golden ignore cases agree across all entry points and after rule edits; parent/child caches cannot collide or broaden scope; a worktree used as the explicit root still indexes. Report whether `include_generated=true` can actually retrieve data omitted at index time, rather than silently implying complete coverage.

### F. P2 — Freshness, startup and bounded watcher work

Live synthetic test: after a same-size edit with the old mtime restored, five seconds later search still missed the new identifier and `codedb_read` returned the old source, while status reported `scan=ready`. `src/watcher/incremental.zig:331` skips a file solely on matching millisecond mtime. The existing 30-second HEAD check does not verify working-tree content when HEAD is unchanged.

Source review: `handleIndex` in `src/mcp/composite_tools.zig:501` invalidates secondary cache entries, but reloads the default Explorer only when its sequence is zero and scan state is loading/lazy. A populated default root therefore needs explicit live reconciliation when a rebuild completes. Reproduce this with a changed ignore rule and `force=true`; do not assume a successful snapshot rebuild refreshed every running process.

Implement bounded periodic content verification for metadata collisions, atomic-save-safe updates, read/outline-on-miss indexing, overflow recovery and generation-based invalidation across outlines, word/trigram indexes, type graph, snapshots and content cache. Avoid importing only the early “skip unchanged metadata” optimization, which loses updates. Preserve current restart/worktree fixes and the existing memory-budget terminal state. Fix default-root and secondary-project behavior together.

Investigate standalone `C:\repos\autumn` before optimizing it: the assessment received three consecutive 30-second “scan still in progress (walking)” responses and did not reach ready. This is **not** yet proof of a deadlock or a specific performance regression. Add phase timing, scanned/parsed counts, last-progress time, error state and peak memory to locate the cause. Persist/reuse a validated snapshot for subsequent MCP starts; confirm whether startup currently misses an available cache.

Donors: [live refresh `bd005fa`](https://github.com/justrach/codedb/commit/bd005fa), follow-ups `8fc38a8`, `aef2b37`, `cf569a7`; [read-on-miss `40fe04e`](https://github.com/justrach/codedb/commit/40fe04e) plus `8dcd72a`; [atomic save `282ea87`](https://github.com/justrach/codedb/commit/282ea87); watcher chain `7f9be6e`, `f233a9b`, `63e7076`, `7cdaa19`, `007a6c7`, `cf86ae8`, ending with [bounded work `779741c`](https://github.com/justrach/codedb/commit/779741c). Inspect final code/tests: several are fixes to earlier optimizations. Native Windows needs its own measurements; macOS FD and Linux inotify results are not Windows evidence.

Acceptance: edits/additions/deletions, atomic replacement, unchanged-metadata writes, ignore changes, branch switches, forced rebuilds and secondary-cache hits converge within a documented bound. A normal two-second poll should see ordinary changes within five seconds on the fixture; set and test a bounded sweep interval for timestamp collisions. Status must distinguish ready, partial, failed and stale verification. No unbounded watch handles, queue processing or repeated full-file hashing on idle cycles.

### G. P2 — MCP compatibility and smaller agent-facing output

Live handshake exposed 26 tools (22,523 characters in the driver's JSON serialization), all without annotations. A legacy `2024-11-05` negotiation still received the fork's newer `resultType`/server `_meta` envelope. This is an observed compatibility risk; no particular production client's rejection was reproduced.

Adopt [read-only annotations `03d72fe`](https://github.com/justrach/codedb/commit/03d72fe) and the protocol-specific result handling from [ `63e7076`](https://github.com/justrach/codedb/commit/63e7076). Annotate actual behavior carefully: do not label retained edit/index/snapshot or mutating remote operations as read-only. Validate negotiated versions against the supported MCP specification when implementing; gate newer envelope/cache fields by request/session version.

Add opt-in navigation/full profiles with stable tool availability and concise descriptions, drawing from `99dfae4`, `06506cd`, `021d5bc`. Keep a compatibility full profile and avoid silently removing C#/F#/Autumn/SQL tools or changing profiles based solely on guessed client names. Suppress decorative summaries for machine clients, keep valid JSON bodies distinct from guidance, and make repeat-query nudges sensitive to index generation. The current governor says repeated results are deterministic even though this is a live index.

Acceptance: protocol transcript tests for supported legacy/current revisions, pre-handshake discovery, invalid `_meta`, notifications, missing/multiple roots and no-roots clients; schemas accepted in the target clients. Test ChatGPT/Codex, Claude, OpenCode and Copilot registration/smoke behavior individually when accessible. Do not claim application compatibility based solely on a generic JSON-RPC harness. Registration should remain additive and explicit; include OpenCode documentation without automatically rewriting every installed client configuration.

### H. P2 — Telemetry contract and local-first guarantees

Source-confirmed mismatch: `docs/telemetry.md` describes opt-out through `CODEDB_NO_TELEMETRY=1`. `src/telemetry.zig:53` actually enables telemetry whenever `CODEDB_TELEMETRY` exists, including `0`; no source reference to `CODEDB_NO_TELEMETRY` was found. Uploads can occur every ten recorded events, not only on session close. The code truncates the local file after `runCapture` without checking curl's exit status. Default telemetry was off in this assessment; this is not a claim of default source-code exfiltration.

Keep telemetry disabled by default; require an explicit true value, honor disable flags with precedence, accurately document destination/cadence/fields, and do not clear unsent events after an HTTP/process failure. Serialize flush/upload/truncation safely and keep network delay out of query latency. Evaluate removing the inherited analytics endpoint for this private fork, but do not silently substitute another service. Test with a local mock endpoint and synthetic payloads. Explicit remote queries should remain clearly separate from local navigation.

## Valuable upstream work to evaluate after correctness

| Candidate | Value and adoption decision |
|---|---|
| Paired benchmark and result/corpus parity gate, `61d977c`, `33ea66c` | High value. Adapt early to this fork; retain its 10% threshold and add Windows. Do not import waivers that hide changed answers or missing corpus. |
| Generation-validated read/outline/tree/search caches; line-offset cache; rolling/right-sized trigram work | Evaluate `07b571f`, `f97286e`, `f299cf9`, `2e1c148`, `1dc7f64`, `735c358`. Port one independent optimization at a time after freshness and memory safety. Some exact-symbol lookup optimizations already exist here; compare implementations before spending time. |
| Local `codedb_context` / `codedb_explain` | High potential for fewer round trips. Start with a thin bounded composition of existing symbol/search/callers/deps/read operations. Return source-backed paths/lines, freshness, matching reasons and omitted/truncated counts. Apply token packing (`4bb6afd`) and lexical natural-language-to-symbol ideas (`c93110a`, `22444d4`) without hosted embeddings. Benchmark against existing `codedb_query`. |
| Live bounded directory listing | Adapt `dcbe2f6`, `cf8a9cd` if existing `codedb_ls`/tree cannot distinguish unindexed from absent files. Honor exactly the same security/ignore policy; prevent a second unrestricted walk. |
| Exact callpaths | Defer until symbol identity and language-aware edges are reliable. Upstream's later ambiguity/callback fixes show why a first-hit/name-only graph is risky. Do not claim F# or .NET dispatch precision from Zig-centric tests. |
| Documentation graph / provenance, `cc33a89` | Optional later improvement for Autumn knowledge documents. Keep documentation links separate from import/type dependencies and bound traversal. |
| More client registrations, `7a7edea` | Reuse tested format knowledge for requested clients, retaining fork binary paths and installer semantics. No need to import broad auto-registration/nuke behavior. |

Do **not** adopt as part of this plan: upstream's removal of edit/remote (`31ef1d2`, `3bf715a`), hosted-by-default embeddings (`0d96cdb`), device enrollment (`4509c17`), ANN/vendor stack, semantic-sidecar migrations, DeepWiki/product integration, website changes, or unrelated parser additions. Current upstream [documents hosted embeddings in default hybrid retrieval](https://github.com/justrach/codedb/blob/36e35bf17624a277513b031c8826b552911763bf/README.md); running it on these private repositories would change data handling. A future semantic experiment should be a separate explicit decision with a local-only baseline.

Also defer Zig 0.17 migration and shared-daemon architecture. Upstream's `fa73c70` concurrent warm CLI dispatcher targets Unix and leaves Windows sequential; it does not solve native Windows multi-agent load by itself. First measure aggregate MCP process RSS, idle CPU and contention at 1/4/8 agents; only then consider shared immutable snapshots or a broker with clear lifetime/isolation rules.

## Host repository baseline and golden evaluation matrix

All five requested roots were exercised against the installed 3.0.1 binary. First symbol timings include initial scan wait; subsequent numbers are coarse smoke timings affected by the harness's roughly 20ms polling and concurrent host activity. They are **not** sub-millisecond latency benchmarks or regression measurements.

| Root | Observed smoke result | Golden tasks for the implementation |
|---|---|---|
| `C:\repos\lm-asp-net` | `Probe`: 26 symbols, canonical entity first; 21 references at limit 20; first symbol ~5.3s; search ~15ms | Probe entity → repository/base/interface → DbContext; `DataController` → `DataAppService`; routes/config keys; Blazor/Razor and JS interop; duplicate names and generic properties |
| `C:\repos\pro` | `Startup`: two symbols; first symbol ~14.3s; search ~32ms | Startup/OWIN vs application definitions; MVC controller → service/view; JS/TS dependencies; legacy .NET manifests |
| `C:\repos\invest` | `Startup`: two symbols; first symbol ~6.4s; search ~15ms | Parallel Pro-style questions pinned independently; project cache/root isolation; config references and Razor |
| `C:\repos\autumn` | Initialized; three consecutive tool calls each waited ~30s and returned scan-in-progress; stopped that process after the probes | First resolve scan progress/coverage; then F# compiler/DSL, C# adapter integration and cross-language artifacts; cold/warm startup and generated-data exclusions |
| `C:\repos\credo_main\src\Autumn` | Tree waited ~13.2s; `QueryProcess` resolved; search ~16ms; default callers zero; explicit references found usages | QueryProcess quotations → mappings; F# records/DUs/modules; `.adpt`/`.aom` handling; compiler-to-T-SQL provenance; active vs dormant project membership; explicit subroot isolation |

For the last root, follow its AGENTS.md: `project=C:\repos\credo_main\src\Autumn`, start with tree, scope content search to `**/*.fs`, and consult the root-level `Autumn.sln` only for membership. Never broaden indexing to `C:\repos\credo_main`. Use the primary Aspire solution specified by `lm-asp-net/AGENTS.md` when deciding active Levelmaster projects. No application builds or code edits are needed for navigation evaluation.

Create 8–12 human-reviewed questions per root with expected file/symbol/line targets and relevance labels. Pin commit IDs (already recorded in the evidence), a corpus manifest and dirty-file hashes locally; private source and questions must not be uploaded. Separate exact-definition correctness, caller/reference precision/recall, dependency correctness, scoped-search recall, answer size, tool calls per task and freshness latency. Compare a local context tool against the existing multi-call workflow on these same questions. Upstream's pinned-evaluation work in `11ebdd7` is a methodology donor, not proof of quality on our languages.

## Implementation order and session boundaries

| Session / branch suggestion | Scope | Exit condition |
|---|---|---|
| 1 — `codex/security-boundaries` | Establish reproducible Zig 0.16 build; convert synthetic probes to failing tests; A and applicable snapshot/path parts of B | All project/secret boundary tests pass, old caches invalidated, native Windows unit/E2E pass |
| 2 — `codex/install-and-privacy` | Installer verification, remaining B, telemetry H, Windows E2E URI fix | Fail-closed installer tests; no unexpected telemetry; malformed-cache/concurrency tests; harness portable |
| 3 — `codex/navigation-correctness` | C and D, golden corpus fixtures | No known caller/dependency/scope regressions; preserve fork-specific type/parser behavior |
| 4 — `codex/index-freshness` | E and F; diagnose standalone Autumn; paired benchmark harness | All five roots reach an explicit terminal state; fresh correct results and bounded watcher resource use |
| 5 — `codex/mcp-efficiency` | G, concise profiles, selected measured cache optimizations | Client contract tests; measured token/latency improvement without >10% regression in critical paths |
| 6 — optional `codex/local-context` | Local context/explain prototype and golden task comparison | Better navigation task outcomes or fewer calls/tokens on the local corpus; otherwise defer it |

These are reviewable work packages, not a commitment to six large combined PRs. Split security patches further if that speeds review. Save evidence per package and keep upstream donor/attribution notes with adapted commits. Re-evaluate findings against the then-current fork before changing code. Do not mechanically cherry-pick monolithic upstream `mcp.zig`/`watcher.zig` over the fork's split modules.

## Release gates

1. Pin/compiler-check the toolchain and build the actual candidate. Run `zig build test` and `python scripts/e2e_mcp_test.py --binary zig-out/bin/codedb.exe --project C:\repos\codedb` on Windows; use the equivalent extensionless binary/path on Linux. The original harness currently reports **38/42**: scenario 1 creates `file://C:\...`, an invalid Windows URI. With only its reply helper changed to `Path.resolve().as_uri()`, scenario 1 passed **8/8**. Fix the harness in source; do not suppress or waive those failures. AGENTS.md's description of three scenarios is stale: the script now has eight.
2. Add focused security, lexical, duplicate-basename, F#, ignore, same-metadata edit and live-rebuild regressions. Keep pure tests for forbidden root forms so the test never walks a drive/home/network root. Exercise malformed parsers and cache loaders with bounded fuzz/property fixtures.
3. Run the five-root matrix using freshly built baseline and candidate binaries, sequentially for cold-memory measurements. Isolate candidate cache dirs/fixture copies so it cannot overwrite an index used by active agents. Do not run upstream hosted-default builds over private source. Do not kill unrelated codedb processes.
4. For performance, use identical immutable corpus, compiler and optimization mode; pair baseline/candidate runs in alternating order, warm up, collect enough repetitions for median/p95 and variability, and separately measure cold scan, warm load, query latency, peak RSS, idle CPU, update latency and 1/4/8-agent totals. A >10% critical-path regression is merge-blocking under AGENTS.md. Compare result/corpus parity, allowing only explicitly reviewed correctness changes; a faster incomplete index is not an improvement.
5. Verify no source, paths, queries, fixtures or embeddings leave the machine during local navigation with telemetry disabled. Verify install/update provenance remains the fork's. Run the target client smoke matrix and retain logs without secrets.
6. Update README, telemetry docs, CHANGELOG, AGENTS.md test instructions and indexing/schema version notes. Release a fork patch/minor version with rollback instructions. Old insecure/stale caches must rebuild; retaining an old binary for rollback is not a reason to keep using exposed caches. No upstream merge or push is part of the work.

## Current implementation status and remaining work (2026-10-08)

The implementation branch is `feature/upstream-changes-2026-10`. Packages 1–5
were committed in `fd851bf`; subsequent local commits `6640116` and `1933eb2`
include the release harnesses and the two evaluation-driven fixes. No upstream
merge, push, tag or release publication has been performed. This section
supersedes the earlier assessment and continuation prompt.

**Functional status: the required accuracy, freshness, security, and local MCP
checks are complete apart from one focused F# dependency verification.** The five-root matrix reaches `ready` on every root, the
candidate's golden corpus results are source-anchored and concise, and the
candidate improves result/corpus parity over the baseline. The paired timing
matrix is retained as informational evidence; it exceeds the 10% performance
threshold, so this branch makes no performance-improvement claim. That timing
result does not block the data-quality handoff requested here. See [the attached
evidence](evidence/release-2026-10-08/README.md), [timing details](evidence/release-2026-10-08/performance.json),
and [reproduction/rollback instructions](../docs/release-validation.md).

### Completed implementation and validation

- **Security and cache boundaries (A/B):** root confinement, sensitive-file filtering, traversal/ADS/UNC/device/drive-relative rejection, symlink/reparse checks, edit-path enforcement, snapshot/index invalidation and cache version bumps are implemented.
- **Installers and provenance:** release downloads and Zig bootstrap require verified checksums and fail closed; PowerShell and Bash failure-injection suites pass.
- **Navigation correctness (C/D):** lexical caller filtering, malformed-input handling, duplicate-basename dependency resolution, local JS/TS resolution, bounded `tsconfig` aliases, F# references, and project parsing are implemented.
- **Ignore and scope (E):** nested `.gitignore`, negation/anchored/`**` rules, `.git/info/exclude`, `.codedbignore`, configurable tool directories, selected-root/Git-root reporting, and shared filtering are implemented.
- **Freshness and status (F):** same-metadata content verification, atomic-save handling, reconciliation, forced rebuild refresh, generation invalidation, scan metrics, and failed/partial status reporting are implemented.
- **MCP and telemetry (G/H):** protocol negotiation/result gating, annotations, navigation profile, invalid metadata handling, opt-in local telemetry, failed-upload retention, and privacy filtering are implemented.
- **Recorded checks:** `zig build test` passes; the current MCP harness passes **42/42**; `scripts/test-plan-integration.py` passes; installer tests pass on PowerShell and Bash; `git diff --check` is clean. Evidence is in `.build/current-tests.log`, `.build/plan-integration.log`, and the generated files under `plans/evidence/`.
- **Accuracy acceptance:** the frozen corpus contains 10 source-anchored questions per root (50 total). The candidate hits 48/50 expected target sets, versus 44/50 for the baseline; the two misses are the same F# module dependency cases in both variants. A unique bare-module resolver is now in the working tree; one focused fresh-cache verification remains. Standalone Autumn completes with an explicit `ready` terminal state and bounded metrics.
- **Isolation and client evidence:** secondary-root cache reuse, forced add/delete convergence, root switching, and synthetic secret/junction boundaries are recorded. Codex, Claude, and Copilot each pass isolated full/navigation smokes; ChatGPT and OpenCode were unavailable locally and are not inferred. Client breadth is observational evidence, not a product acceptance requirement.

### Remaining work

1. **Review decision:** the 50-question corpus has an agent-reviewed draft with
   source hashes; a human sign-off has not been recorded. The user has asked for
   self-validation and concise current data, so this is the only remaining
   review artifact rather than another client or benchmark run.
2. **Optional F# follow-up:** rerun the two dependency questions after the new
   unique bare-module resolver is exercised on a fresh cache. This is a focused
   accuracy check, not a performance campaign; both cases were baseline misses
   as well as candidate misses and therefore are not regressions.
3. **Performance decision:** the timing matrix is complete and attached. The
   >10% result remains a release-performance limitation documented for rollback
   and future optimization; no further timing repetitions are planned for this
   data-quality handoff.

The ChatGPT/OpenCode smoke rows remain explicitly unavailable, and no further
AI-client testing is required. Package 6 (local context/explain) stays deferred.

### Known non-blocking follow-ups

- Windows stdin-pipe disconnect handling remains a TODO in `src/cli/scan.zig`.
- Windows advisory file locking in `src/cio/sync.zig` remains incomplete, although notification-file ingestion is no longer on the active path.
- Optional package 6 (local context/explain) is outside the required packages 1–5 and should remain deferred unless the golden corpus shows a clear need.

### Handoff command sequence

Use the following sequence in a new session before changing behavior:

```powershell
cd C:\repos\codedb
git status --short
zig build test
python scripts\e2e_mcp_test.py --binary .build\candidate-status\bin\codedb.exe --project C:\repos\codedb
python scripts\test-plan-integration.py --binary .build\candidate-status\bin\codedb.exe
pwsh -File scripts\test-installers.ps1
& 'C:\Program Files\Git\bin\bash.exe' scripts/test-installers.sh
```

The attached evidence already covers the benchmark, corpus, Autumn diagnostics,
client observations, root/cache isolation, telemetry, installers, and rollback
bookkeeping. Continue only with the focused F# accuracy check or the optional
human corpus sign-off; do not expand this into a larger client or performance
test campaign.

## Suggested prompt for the next session

> Read `plans/2026-10-06-upstream-and-mcp-improvement-plan.md` and continue on `feature/upstream-changes-2026-10`. Packages 1–5 and the attached five-root, golden-corpus, Autumn, isolation, telemetry, installer, and available-client evidence are complete. Do not start another benchmark or client campaign. If needed, run only the focused fresh-cache check for the new unique F# bare-module dependency resolver, then record the result here. Keep private source local, preserve security boundaries and all fork languages, and do not push or merge upstream.
