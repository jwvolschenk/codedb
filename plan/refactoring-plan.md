# codedb Refactoring Plan — Agent Manageability

## Status (updated 2026-06-15)

- ✅ **Tier 1.1–1.5** — done (`5542d1b`..`a5b1079`)
- ✅ **Tier 2.1** — done (`9a40afc`..`44b0844`) — finished the in-progress `mcp.zig` split (now a 74-line aggregator)
- ✅ **Tier 2.2** — done (`ac79bbd`..`6cb4c4b`) — `src/explore.zig` 5,309 → 451 lines; see `plan/tier-2.2-explore-split.md` for the member-level breakdown and the new `explore/{type_extract,tree,deps,search,lifecycle,parsers/*}.zig` files
- ✅ **Tier 2.3** — done — `src/snapshot.zig` now follows the aggregator pattern over `snapshot/{format,writer,loader_validated,loader_fast,sensitive}.zig`
- ⬜ **Next up: Tier 2.4** (split `src/watcher.zig`)
- ⬜ Tier 2.5, 3.x, 4.x, cross-cutting cleanup — not started

## Goals

- **No behavior change, no new features** — pure file restructuring.
- Reduce the largest files so an agent can read each one in a single hop without burning its context.
- Follow the existing **aggregator pattern** already proven in this repo (`foo.zig` + `foo/` directory; `index.zig`, `explore.zig`, `mcp.zig` already do this).
- Preserve the public API surface exactly — every `@import(...).X` referenced from `lib.zig`, `build.zig`, and downstream files keeps resolving unchanged.

## The Aggregator Pattern (canonical for this codebase)

A file `foo.zig` becomes a thin re-export shell:

```zig
// foo.zig
const a = @import("foo/a.zig");
const b = @import("foo/b.zig");
pub const Thing = a.Thing;
pub const helper = b.helper;
```

Consumers continue to write `@import("foo.zig").Thing` — no caller-side changes, no `build.zig` changes. We use this for every split below.

## Guiding principles

1. **Move, don't rewrite.** No logic changes, just `mv` of declarations + import wiring.
2. **One PR per file split** (with one follow-up cleanup PR for cross-cutting dedup). Each split must independently pass `zig build test`.
3. **No public API removal.** If a symbol is currently reachable through `lib.zig` / `index.zig` / `explore.zig` / `mcp.zig`, it stays reachable at the same path.
4. **Security-sensitive code (`isSensitivePath`, `isPathSafe`, telemetry) gets its own file** — explicit per `AGENTS.md` review guidelines.
5. **Don't restructure tests in the same PR as code splits.** Tests move last.

## Inventory — current monoliths (lines / symbols)

| File | Lines | Status | Notes |
|---|---:|---|---|
| `src/tests.zig` | 13,442 | ⬜ pending (Tier 4) | worst offender — 1,684 test decls concatenated |
| `src/explore.zig` | 451 | ✅ done (Tier 2.2) | was 5,309 — split into `explore/{type_extract,tree,deps,search,lifecycle,parsers/*}.zig` |
| `src/mcp.zig` | 74 | ✅ done (Tier 2.1) | was 3,711 — now a thin aggregator over `mcp/*.zig` |
| `src/main.zig` | 1,331 | ⬜ pending (Tier 3.1) | 727-line `mainImpl` switch-on-command |
| `src/index/trigram.zig` | 30 | ✅ done (Tier 1.2) | was 1,482 — split into heap/mmap/any variants |
| `src/watcher.zig` | 1,371 | ⬜ pending (Tier 2.4) | skip-lists + initial scan + incremental loop |
| `src/explore/parse_utils.zig` | 1,299 | ⬜ pending (Tier 3.4) | grab-bag of per-language helpers |
| `src/snapshot.zig` | 44 | ✅ done (Tier 2.3) | aggregator over `snapshot/{format,writer,loader_validated,loader_fast,sensitive}.zig` |
| `src/cio.zig` | 903 | ⬜ pending (Tier 2.5) | platform + sync + time + spawn |
| `src/csharp_parser.zig` | 962 | — | single-concern, optional polish |
| `src/mcp/query.zig` | 875 | ⬜ pending (Tier 3.2) | 754-line `handleQuery` switch |
| `src/server.zig` | 858 | ⬜ pending (Tier 3.3) | 579-line `handleConnection` switch |
| `src/tsql_parser.zig` | 583 | ✅ done (Tier 1.3) | was 852 — embedded tests extracted |
| `src/index/word_index.zig` | 673 | ⬜ pending (not yet scheduled) | disk I/O = 45% of file |

---

## Tier 1 — Quick wins, near-zero risk (do first) — ✅ ALL DONE (`5542d1b`..`a5b1079`)

Each is a self-contained extract with minimal coupling.

### 1.1 — Extract `src/mcp/aspnet.zig`
- **Source:** `src/mcp.zig:1375–1755` (~380 lines)
- **Symbols:** `handleRoutes`, `handleConfigXref`, and ~15 ASP.NET helpers (`isAspNetConfigJsonPath`, `collectJsonConfigReads`, `aspNetHttpMethod`, `stripControllerSuffix`, …)
- **Why first:** zero shared state with the rest of `mcp.zig`, single-call-site entry points, biggest single-block win.
- **Wiring:** add `const aspnet = @import("mcp/aspnet.zig");` and re-export the two `handle*` fns in `mcp.zig`.

### 1.2 — Split `src/index/trigram.zig` → three files
- `index/trigram/heap.zig` — `TrigramIndex` (lines 20–920)
- `index/trigram/mmap.zig` — `MmapTrigramIndex` (lines 921–1327)
- `index/trigram/any.zig` — `AnyTrigramIndex` (lines 1328–1481)
- `index/trigram.zig` becomes the aggregator.
- **Why first:** three complete, self-contained structs that share only their public API.

### 1.3 — Move tests out of `src/tsql_parser.zig`
- **Source:** `src/tsql_parser.zig:583–851` (~270 lines, 32% of the file)
- **Target:** `src/tsql_parser_tests.zig` (added to `build.zig` test step OR imported from `tests.zig`).
- Same recipe applies to other parsers that embed tests (`csharp_parser.zig`, `fsharp_parser.zig`, `ssrs_parser.zig`, `t4_parser.zig`, `autumn_parser.zig`).

### 1.4 — Unify duplicated `isPathSafe` / `isSensitivePath`
- Currently in: `mcp/pathglob.zig` (canonical), `server.zig:701`, `snapshot.zig:985`, `watcher.zig:1199`.
- Replace local copies with `@import` from the canonical location.
- **Security win:** isolated code review surface per `AGENTS.md`.

### 1.5 — Extract `src/json_utils.zig`
- `writeJsonEscaped` is duplicated in: `mcp/jsonio.zig`, `snapshot.zig:1106`, `server.zig:725`, `explore/parse_utils.zig:324`, `wasm.zig:24`.
- Single shared file, all callers re-import.

---

## Tier 2 — Medium-effort structural splits

### 2.1 — Finish splitting `src/mcp.zig` (continues the in-progress refactor) — ✅ DONE (`9a40afc`..`44b0844`)

After Tier 1.1, the remaining ~3,330 lines split into:

| Target file | Source range | Contents |
|---|---|---|
| `mcp/server.zig` | 1–1162 | imports, `DeferredScan`, `SnapshotCache`, `ProjectCtx`/`ProjectCache`, `BenchContext`, `Tool` enum, scan-state machine, `Session`, `run`, `handleInitialize`/`handleResponse`/`parseRoots`, `handleCall`, `dispatch` |
| `mcp/explore_tools.zig` | 1163–1374, 1757–1916, 1917–2487 | tree/outline/symbol/hierarchy/search/word/callers/hot/deps + their helpers |
| `mcp/mutation_tools.zig` | 2488–2772 | read/edit/changes/status/snapshot handlers |
| `mcp/composite_tools.zig` | 2773–3060, 3064–3413 | types/bundle/projects/index/find/glob/ls + diagnostics |
| `mcp/tests.zig` | 3465–3710 | tests |

`mcp.zig` becomes the aggregator. Pattern matches `index.zig` exactly.

### 2.2 — Split `src/explore.zig` (5,309 lines) — ✅ DONE (`ac79bbd`..`6cb4c4b`)

The central `Explorer` struct stays in `explore.zig`, but the per-language `parseXLine` functions and the search/tree/type code move out:

| Target | Source | Contents |
|---|---|---|
| `explore/parsers/` (new dir) | `parseZigLine` … `parseRubyLine` (~25 line parsers, lines 2552–4765) | One file per language family: `parsers/jvm.zig` (Java/Kotlin), `parsers/clang.zig` (C/C++/ObjC/Swift), `parsers/web.zig` (TS/JS/CSS/Shell), `parsers/jvm_static.zig`, `parsers/csharp_family.zig` (C#/F#/Razor/T4), `parsers/scripting.zig` (Ruby/PHP/Python), `parsers/declarative.zig` (HCL/R/SQL/Proto/Fortran/LLVM/MLIR/TableGen/Dart) |
| `explore/type_extract.zig` | `extractZigFuncTypes`, `extractPythonFuncTypes`, `extractTsFunctionTypes`, `extractJvmFuncTypes`, `extractKotlinFuncTypes`, `extractRustFuncTypes`, `extractGoFuncTypes` + supporting structs | Type-index extraction |
| `explore/search.zig` | `searchContent`, `searchContentRanked`, `searchContentRegex`, `searchWord`, `fuzzyFindFiles`, `searchContentWithScope`, `rerankSignalScore`, `appendRerankTrace`, all search-only structs (`Tier0File`, `SortCtx`, `DocAgg`, `Cand`, `FuzzyMatch`) | Search operations as free fns taking `*Explorer` |
| `explore/tree.zig` | `getTree`, `lsDir`, `globPaths`, `lsDirHotspotScore`, `buildOutlineDescriptor`, descriptor helpers | Tree/LS/glob operations |
| `explore/lifecycle.zig` | `indexFile*`, `removeFile`, `commitParsedFileOwnedOutline`, `releaseContents`, `releaseSecondaryIndexes`, `cloneOutline`, `cloneDecorators`, `computeSymbolEnds`, `findBraceEnd`, `findPythonEnd`, `findRubyEnd`, `countIndent`, `parseOutlineWithParser`, `parseContentForIndexing` | Per-file lifecycle + symbol-end detection |
| `explore/deps.zig` | `rebuildDepsFor`, `resolveSqlDepKey`, `resolveDependencyKey`, `getImportedBy`, `getTransitiveDependents`, `getTransitiveDependencies`, `rebuildSymbolIndexFor`, `removeSymbolIndexFor`, `rebuildTypeIndexes`, `buildTypeGraphForFile`, `extractAndRecordBases`, `findBasePortion`, `symbolNameMatches`, `isHierarchyKeyword`, `getHotFiles` | Dependency/type-graph/symbol-index mutations |

`explore.zig` keeps the `Explorer` struct declaration, `init`/`deinit`/`setRoot`/`setIgnorePatterns`, and re-exports everything. All current `@import("explore.zig").X` references keep working.

**Result:** see `plan/tier-2.2-explore-split.md` for the exact member-level table and the 7-commit breakdown actually used. Two deviations from the table above: (1) `parsers/jvm_static.zig` was dropped — its contents folded into `type_extract.zig`; (2) a new `parsers/systems.zig` was added for Zig/Rust/Go parsers, which this table omitted. `explore.zig` is now 451 lines (struct shell + 9 KEEP accessor methods + ~128 `pub const x = @import("explore/...").x;` delegations).

### 2.3 — Split `src/snapshot.zig` — ✅ DONE

| Target | Source | Contents |
|---|---|---|
| `snapshot/format.zig` | 36–52, 363–475, 647–679, 958–984, 1033–1068 | `MAGIC`, `FORMAT_VERSION`, `SectionId`, `SectionEntry`, section readers, JSON int helpers, `cleanupStaleTmpFiles` |
| `snapshot/writer.zig` | 55–362, 1069–1099, 1106–1123 | `writeSnapshot`, `writeSnapshotDual`, `writeProjectCacheSnapshot` |
| `snapshot/loader_validated.zig` | 488–646, 680–794 | `loadSnapshotValidated`, `loadOutlineStateMap`, `rebuildDepsFromOutline`, `insertRestoredFile` |
| `snapshot/loader_fast.zig` | 795–957 | `loadSnapshotFast` |
| `snapshot/sensitive.zig` | 985–1032 | `isSensitivePath` (after Tier 1.4 unifies it) |

`snapshot.zig` is now the aggregator and preserves the existing public API. `cleanupStaleTmpFiles` lives in `snapshot/format.zig` with the other binary-format helpers; `snapshot/sensitive.zig` stays focused on the shared `path_safety.zig` re-export.

### 2.4 — Split `src/watcher.zig`

| Target | Source | Contents |
|---|---|---|
| `watcher/skip_rules.zig` | 110–235, 1155–1240 | `skip_dirs`, `skip_extensions`, `skip_lockfile_names`, `shouldSkip*`, `isSensitivePath`, glob matchers — **security-isolated** |
| `watcher/filtered_walker.zig` | 236–465 | `FilteredWalker` |
| `watcher/initial_scan.zig` | 466–925, `indexFileOutline` | All `*Worker*` types + `initialScan*` entrypoints + `buildTrigramsFromCache` |
| `watcher/incremental.zig` | 926–1154, 1241–1370 | `incrementalLoop`, `incrementalDiff`, `hashFile`, `pushEventOrWait`, `indexFileContent`, `drainNotifyFile`, `notifyLineBelongsToOtherRoot`, `pathUnderRoot`, `EventKind`, `FsEvent`, `EventQueue` |

### 2.5 — Split `src/cio.zig`

| Target | Source | Contents |
|---|---|---|
| `cio/platform.zig` | 16–50, 386–409 | `posix`/`win` backends, darwin argv shim |
| `cio/file.zig` | 52–118, 464–498 | `File`, `ListWriter`, `listWriter` |
| `cio/sync.zig` | 119–208 | `Mutex`, `RwLock`, `flockFd` |
| `cio/time.zig` | 209–310 | `nanoTimestamp`, `milliTimestamp`, `Timer`, `randU64`, `sleepMs` |
| `cio/process.zig` | 311–463 | pipes, `posixGetenv`, `getHomeDir`, `argsAlloc`/`argsFree` |
| `cio/spawn.zig` | 499–903 | `CaptureResult`, `RunOptions`, spawn impls, `runCapture` |

---

## Tier 3 — Large structural splits (highest effort)

### 3.1 — Split `src/main.zig`

The 727-line `mainImpl` switch-on-command becomes:

| Target | Contents |
|---|---|
| `commands/mod.zig` | dispatcher (the new `mainImpl`, reduced to ~150 lines of arg parse + branch) |
| `commands/tree.zig` | tree command |
| `commands/outline.zig` | outline command |
| `commands/find.zig` | find command |
| `commands/search.zig` | search command |
| `commands/word.zig` | word command |
| `commands/hot.zig` | hot command |
| `commands/snapshot.zig` | snapshot command |
| `commands/serve.zig` | serve command |
| `commands/mcp.zig` | mcp command (sets up MCP server, deferred scan, idle watchdog) |
| `cli/disk_cache.zig` | 803–1062: `loadUserConfig`, `loadSnapshotIfHeadMatches`, `loadBestSnapshot`, `getDataDir`, `loadTrigramFromDiskIfPresent`, `loadWordIndexFromDiskIfPresent`, `persist*`, `compactMcpReadyMemory`, `wordIndexMatchesOutlines` |
| `cli/scan.zig` | 1128–1299: `reapLoop`, `scanBg`, `triggerScanFromRoots`, `watcherDeferredLoop`, `idleWatchdog` |
| `main.zig` (shell) | `main`, `mainInner`, `Out`, `isCommand`, `resolveRoot`, `printUsage` |

### 3.2 — Split `src/mcp/query.zig`

The 754-line `handleQuery` switch becomes one file per pipeline op:

| Target | Contents |
|---|---|
| `mcp/query/driver.zig` | arg validation, `StageInfo` tracking, summary tail, `handleQuery` itself (now ~80 lines of dispatch) |
| `mcp/query/combo_boost.zig` | `applyComboBoosts`, `extractJson*Local`, `recordHitLine`, `COMBO_*` consts |
| `mcp/query/steps/find.zig` | `find` op |
| `mcp/query/steps/search.zig` | `search` op |
| `mcp/query/steps/deps.zig` | `deps` op |
| `mcp/query/steps/filter.zig` | `filter` op |
| `mcp/query/steps/outline.zig` | `outline` op |
| `mcp/query/steps/read.zig` | `read` op (107 lines) |
| `mcp/query/steps/word.zig` | `word` + `symbol` ops |
| `mcp/query/steps/callers.zig` | `callers` op (109 lines) |
| `mcp/query/steps/transform.zig` | `limit`, `sort` ops |
| `mcp/query/steps/types.zig` | `type_search`, `type_compat` ops |

### 3.3 — Split `src/server.zig`

| Target | Contents |
|---|---|
| `server/transport.zig` | `serve`, `HandlerCtx`, `handleThread`, `Conn`, `readSome`, `respondJson` |
| `server/routes.zig` | `handleConnection` (now a dispatcher calling per-route fns) |
| `server/http_parsing.zig` | `writeJsonEscaped` (or delete in favor of Tier 1.5), `extractQueryParam*`, `percentDecode`, `extractBody`, `jsonString`, `jsonU64`, `findUnescapedQuote`, `extractJsonString` |

After Tier 1.4, `server/routes.zig` should also call shared tool implementations instead of duplicating MCP's handlers (currently admitted in code comment at line 5 of `server.zig`). That dedup is **optional**, lower priority than the structural split.

### 3.4 — Split `src/explore/parse_utils.zig`

Per-language helpers fan out under `explore/parsers/` (which also receives the `parseXLine` functions from Tier 2.2):

| Target | Contents |
|---|---|
| `explore/search_utils.zig` | `searchInContent`, `extractLineByNumber`, `searchInContentRegex`, `regexMatch`, `indexOfCaseInsensitive`, `countOccurrences`, `fuzzyScore` + fuzzy helpers |
| `explore/outline_builders.zig` | `appendOutlineSymbol*`, `appendImportSymbol`, `cSharpSymbolKind`, `fSharpSymbolKind` |
| `explore/ident_utils.zig` | `extractIdent`, `extractIdentAfterKeyword*`, `extractLastIdent*`, `IdentSpan`, `isIdentChar`, `isControlKeyword`, `startsWith`, `startsWithIgnoreCase`, `containsAny`, `skipKeywords` — shared with `csharp_parser.zig` (currently duplicated) |
| `explore/parsers/c_family.zig` | `stripLineComment`, `extractCIncludePath`, `parseCNamedType`, `parseCBraceType`, `parseObjCType`, `extractObjCMethodName`, `extractCFunctionName`, `applyBraceDelta`, `countBracesDelta`, `firstIndexOfAny`, `hasCAssignmentBeforeName`, `isCForbiddenFunctionPrefix`, `isCKeyword` |
| `explore/parsers/sql.zig` | `stripSqlLineComment`, `parseSqlCreate`, `SqlSymbol` |
| `explore/parsers/shell_css.zig` | `firstShellWord`, `parseShellAssignment`, `parseCssVariable`, `parseCssSelector` |
| `explore/parsers/misc.zig` | `extractAtName`, `extractLlvmGlobalName`, `extractLlvmLikeName`, `stripFortranComment`, `parseFortranUse`, `parseFortranTypeName`, `extractRubyMethodName`, `extractHclQuotedName`, `extractHclBlockName`, `extractStringLiteral`, `resolveDartImport`, `extractPythonModulePath`, `phpNamespaceToPath` |

---

## Tier 4 — Tests refactor (do LAST, after all code splits land)

### 4.1 — Split `src/tests.zig` (13,442 lines)

Tests are grouped by concern already (visible in the outline). Strategy: one file per subsystem under `tests/`, each `tests/<x>.zig` is a standalone Zig source with the same imports its tests need. `tests.zig` becomes a thin aggregator:

```zig
// tests.zig — aggregator
comptime {
    _ = @import("tests/store.zig");
    _ = @import("tests/agent.zig");
    _ = @import("tests/word_index.zig");
    // ... etc
}
```

(`comptime { _ = @import(...); }` forces the compiler to analyze the file and collect its `test` blocks — this is the standard Zig pattern for a test aggregator.)

Proposed split (each file ≤ ~1,500 lines, most < 800):

| Target | Source line range | Theme |
|---|---|---|
| `tests/store.zig` | 54–176 | Store / version log |
| `tests/agent.zig` | 177–265 | AgentRegistry |
| `tests/word_tokenizer.zig` | 266–278 | WordTokenizer |
| `tests/word_index.zig` | 279–336, 1845–1858, 8583–8802 | WordIndex |
| `tests/trigram.zig` | 337–390, 1859–1878 | TrigramIndex |
| `tests/sparse_ngram.zig` | 391–614 | SparseNgramIndex + frequency table |
| `tests/explorer_core.zig` | 615–1140, 1942–2063 | Explorer lifecycle, parsing |
| `tests/explorer_search.zig` | 1522–1649, 2867–2956, 8583–8900 | searchContent, ranked, scope |
| `tests/edit.zig` | 1214–1378 | Edit operations |
| `tests/regressions.zig` | 1442–1719 | Old issue regressions |
| `tests/snapshot.zig` | 1745–1783, 4575–5006, 7328–7424 | Snapshot read/write |
| `tests/mcp_protocol.zig` | 6394–6545 | MCP handshake/protocol |
| `tests/mcp_search.zig` | 8880–8912 | search guidance hints |
| `tests/parsers/fsharp.zig` | 2064–2285 | F# parser |
| `tests/parsers/csharp.zig` | 2286–2484, 2580–2702 | C# parser |
| `tests/parsers/tsql.zig` | merge with moved `tsql_parser_tests.zig` (Tier 1.3) | T-SQL parser |
| `tests/parsers/php.zig` | 5117–5628 | PHP parser |
| `tests/parsers/c.zig` | 7609–7732, 8936–9007 | C parser |
| `tests/parsers/misc.zig` | 7670–7937, 7478–7556, 8068–8163 | HCL/R/Go/Ruby/Dart/etc. |
| `tests/regex.zig` | 3373–3640 | Regex query engine |
| `tests/bloom.zig` | 3641–3870 | PostingMask bloom filter |
| `tests/perf.zig` | 3971–4088 | Performance regressions |
| `tests/disk_index.zig` | 4124–4485 | Disk round-trips |
| `tests/concurrency.zig` | 4486–4545, 1551–1598 | Concurrent indexes / hot+read+remove |
| `tests/mmap_trigram.zig` | 6545–6660 | MmapTrigramIndex |
| `tests/fuzzy.zig` | 6661–6776 | fuzzyScore / fuzzyFindFiles |
| `tests/query_pipeline.zig` | 6776–6994, 6994–7162 | Pipeline ops |
| `tests/nuke.zig` | 6252–6380 | nuke command |
| `tests/update.zig` | 6105–6252 | update command |
| `tests/git.zig` | 4361–4378, 6380–6394 | git helpers |
| `tests/dep_graph.zig` | 8221–8492 | Dependency graph |
| `tests/symbol_index.zig` | 8492–8583 | Symbol index |
| `tests/type_index.zig` | 2478–2580 | Type index/graph |
| `tests/path_safety.zig` | 1720–1744, 5646–5676 | `isPathSafe` / `isSensitivePath` |
| `tests/root_policy.zig` | 9007–9018 | Root policy |
| `tests/glob.zig` | 9018–9166 | globPaths / lsDir |
| `tests/telemetry.zig` | 5074–5117 | Telemetry no-op path |

The remaining ~4,000 lines of issue-specific regression tests get bucketed by subsystem.

---

## Cross-cutting cleanup PR (after all splits land)

- Remove `extractIdent`, `isIdentChar`, `isControlKeyword`, `startsWith`, `containsAny` duplications across parsers — all import from `explore/ident_utils.zig`.
- Collapse the two `isSensitivePath` copies (Tier 1.4 already started this).
- Update `docs/architecture.md` to reflect the new file layout.

---

## Execution order (suggested)

Each phase = one PR. CI must pass `zig build test` after every PR.

1. ✅ **Tier 1.1–1.5** — five independent small PRs, can land in any order. DONE.
2. ✅ **Tier 2.1** (mcp.zig finish) — depends on Tier 1.1. DONE.
3. ✅ **Tier 2.2** (explore.zig) — independent of 2.1. DONE.
4. ✅ **Tier 2.3** (`src/snapshot.zig`) — DONE.
5. **Tier 2.4, 2.5** — independent of each other and 2.1/2.2; can parallelize. ← NEXT (start with 2.4, `src/watcher.zig`)
6. **Tier 3.1** (main.zig) — independent.
7. **Tier 3.2** (mcp/query.zig) — depends on Tier 2.1.
8. **Tier 3.3** (server.zig) — independent.
9. **Tier 3.4** (parse_utils.zig) — depends on Tier 2.2.
10. **Tier 4.1** (tests.zig) — last; only after all source files are at their final locations.
11. **Cross-cutting dedup + docs update.**

---

## Verification (every PR)

```bash
zig build test                # must pass — functional regression
zig build                     # must succeed — public API intact
zig build bench               # must not regress >10% per AGENTS.md
python3 scripts/e2e_mcp_test.py \
    --binary zig-out/bin/codedb \
    --project /home/jwvolschenk/repos/codedb    # MCP E2E
```

Additionally, after each split: `rg '@import\("old/path\.zig"\)'` must return nothing in `src/` that wasn't there before (catches missed call sites).

---

## Estimated impact

After full execution:

| File | Before | After (max) | Actual |
|---|---:|---:|---:|
| `tests.zig` | 13,442 | ~50 (aggregator) | — |
| `explore.zig` | 5,309 | ~600 (struct + lifecycle) | ✅ 451 |
| `mcp.zig` | 3,711 | ~50 (aggregator) | ✅ 74 |
| `main.zig` | 1,331 | ~250 (CLI shell) | — |
| `index/trigram.zig` | 1,482 | ~30 (aggregator) | ✅ 30 |
| `watcher.zig` | 1,371 | ~50 (aggregator) | — |
| `explore/parse_utils.zig` | 1,300 | ~30 (aggregator) | — |
| `snapshot.zig` | 1,124 | ~30 (aggregator) | — |
| `cio.zig` | 903 | ~30 (aggregator) | — |
| `mcp/query.zig` | 875 | ~80 (driver) | — |
| `server.zig` | 858 | ~30 (aggregator) | — |
| `tsql_parser.zig` | 852 | ~580 (tests moved) | ✅ 583 |
| `index/word_index.zig` | 673 | ~375 (persistence split) | — |

Largest file in the repo drops from 13,442 lines to ~1,500.

---

## What this plan deliberately does NOT do

- No new tools, endpoints, or features.
- No public API changes — every existing `@import` path keeps resolving.
- No algorithm changes, no behavior changes, no perf work (other than incidental).
- No `build.zig` changes (test root stays `src/tests.zig`; aggregator pattern means new files don't need to be registered).
- No test deletion — tests are moved, never dropped.
