# codedb — Architecture & Design

A lightweight, zero-dependency code intelligence server written in Zig. Indexes a codebase at startup, watches for changes, and serves structural queries over HTTP and MCP (Model Context Protocol).

## Overview

codedb scans a project directory, builds in-memory indexes (outlines, symbols, trigrams, word index, dependency graph), and exposes them via two interfaces:

- **HTTP server** on `:7719` — REST-style JSON API
- **MCP server** over stdio — JSON-RPC for tool-calling LLMs

Both interfaces share the same core: `Explorer` (code intelligence) and `Store` (version tracking).

## File Layout

The codebase follows the **aggregator pattern**: a top-level `foo.zig` becomes a thin re-export shell over a `foo/` directory of focused modules. Consumers continue to write `@import("foo.zig").X` — no caller-side changes needed.

```
src/
├── main.zig                  # 23-line executable shell
├── commands/                 # CLI command handlers
│   ├── mod.zig               #   arg parse, root/config setup, dispatch
│   ├── context.zig           #   shared Context struct
│   ├── tree.zig              #   tree command
│   ├── outline.zig           #   outline command
│   ├── find.zig              #   find command
│   ├── search.zig            #   search command
│   ├── word.zig              #   word command
│   ├── hot.zig               #   hot command
│   ├── snapshot.zig          #   snapshot command
│   ├── serve.zig             #   serve command
│   └── mcp.zig               #   mcp command
├── cli/                      # shared CLI helpers
│   ├── shell.zig             #   Out writer, isCommand
│   ├── disk_cache.zig        #   snapshot/config loading, persistence
│   └── scan.zig              #   background scan, idle watchdog
│
├── explore.zig               # aggregator → Explorer struct + re-exports
├── explore/
│   ├── search.zig            #   searchContent, ranked, regex, fuzzy, scope
│   ├── search_utils.zig      #   searchInContent, fuzzyScore, helpers
│   ├── tree.zig              #   getTree, lsDir, globPaths
│   ├── deps.zig              #   dependency graph, symbol/type index mutations
│   ├── lifecycle.zig         #   indexFile, removeFile, symbol-end detection
│   ├── type_extract.zig      #   per-language type-index extraction
│   ├── types.zig             #   Symbol, FileOutline types
│   ├── ident_utils.zig       #   shared identifier helpers (canonical)
│   ├── outline_builders.zig  #   appendOutlineSymbol*, kind mappings
│   ├── parse_utils.zig       #   compatibility shim over focused modules
│   ├── glob.zig              #   glob matching
│   ├── dependency_graph.zig  #   DependencyGraph struct
│   └── parsers/              # per-language parser modules
│       ├── systems.zig       #     Zig, Rust, Go
│       ├── web.zig           #     TypeScript, JavaScript, CSS, Shell
│       ├── jvm.zig           #     Java, Kotlin
│       ├── clang.zig         #     C, C++, Objective-C, Swift
│       ├── csharp_family.zig #     C#, F#, Razor, T4
│       ├── scripting.zig     #     Ruby, PHP, Python
│       ├── declarative.zig   #     HCL, R, SQL, Proto, Fortran, Dart, etc.
│       ├── c_family.zig      #     C-family parser helpers
│       ├── sql.zig           #     SQL parser helpers
│       ├── shell_css.zig     #     Shell/CSS parser helpers
│       └── misc.zig          #     misc language helpers
│
├── mcp.zig                   # aggregator → re-exports
├── mcp/
│   ├── server.zig            #   MCP session, scan-state machine, dispatch
│   ├── explore_tools.zig     #   tree/outline/symbol/search/word/callers/hot/deps
│   ├── mutation_tools.zig    #   read/edit/changes/status/snapshot
│   ├── composite_tools.zig   #   types/bundle/projects/index/find/glob/ls
│   ├── aspnet.zig            #   ASP.NET route/config analysis
│   ├── query.zig             #   aggregator → query pipeline
│   ├── query/
│   │   ├── driver.zig        #     handleQuery dispatch
│   │   ├── combo_boost.zig   #     combo-boost reranking
│   │   ├── shared.zig        #     shared Context
│   │   └── steps/            #     per-op pipeline steps
│   │       ├── find.zig
│   │       ├── search.zig
│   │       ├── deps.zig
│   │       ├── filter.zig
│   │       ├── outline.zig
│   │       ├── read.zig
│   │       ├── word.zig
│   │       ├── callers.zig
│   │       ├── symbol.zig
│   │       ├── limit.zig
│   │       ├── transform.zig
│   │       └── types.zig
│   ├── format.zig            #   MCP JSON framing helpers
│   ├── jsonio.zig            #   JSON read/write I/O
│   ├── pathglob.zig          #   path glob matching
│   ├── remote.zig            #   remote repo queries (api.wiki.codes)
│   ├── wal.zig               #   write-ahead log
│   └── tests.zig             #   MCP-specific tests
│
├── server.zig                # aggregator → re-exports
├── server/
│   ├── transport.zig         #   serve, HandlerCtx, Conn, respondJson
│   ├── routes.zig            #   handleConnection HTTP route handler
│   └── http_parsing.zig      #   query param extraction, percent decode
│
├── watcher.zig               # aggregator → re-exports
├── watcher/
│   ├── skip_rules.zig        #   skip_dirs/extensions, isSensitivePath (security)
│   ├── filtered_walker.zig   #   FilteredWalker directory pruner
│   ├── initial_scan.zig      #   initialScan, Worker types
│   └── incremental.zig       #   incrementalLoop, FsEvent, EventQueue
│
├── snapshot.zig              # aggregator → re-exports
├── snapshot/
│   ├── format.zig            #   MAGIC, FORMAT_VERSION, SectionId, cleanup
│   ├── writer.zig            #   writeSnapshot, writeSnapshotDual
│   ├── loader_validated.zig  #   loadSnapshotValidated, rebuildDeps
│   ├── loader_fast.zig       #   loadSnapshotFast
│   └── sensitive.zig         #   re-exports path_safety.isSensitivePath
│
├── cio.zig                   # aggregator → re-exports
├── cio/
│   ├── platform.zig          #   posix/win backends
│   ├── file.zig              #   File, ListWriter
│   ├── sync.zig              #   Mutex, RwLock, flockFd
│   ├── time.zig              #   nanoTimestamp, Timer, randU64
│   ├── process.zig           #   pipes, getenv, args
│   └── spawn.zig             #   CaptureResult, RunOptions, runCapture
│
├── index.zig                 # aggregator → re-exports
├── index/
│   ├── trigram.zig           #   aggregator → heap/mmap/any
│   ├── trigram/
│   │   ├── heap.zig          #     TrigramIndex (in-memory)
│   │   ├── mmap.zig          #     MmapTrigramIndex (disk-mapped)
│   │   └── any.zig           #     AnyTrigramIndex (tagged union)
│   ├── word_index.zig        #   WordIndex inverted index
│   ├── word_tokenizer.zig    #   WordTokenizer
│   ├── sparse_ngram.zig      #   SparseNgramIndex
│   ├── regex_query.zig       #   RegexQuery engine
│   ├── type_index.zig        #   TypeIndex
│   ├── type_graph.zig        #   TypeGraph
│   ├── trigram_posting.zig   #   PostingMask bloom filter
│   ├── frequency.zig         #   frequency table
│   └── chars.zig             #   character classification
│
├── tests.zig                 # aggregator (31 lines) → 28 focused test files
├── tests/
│   ├── store.zig, agent.zig, word_tokenizer.zig, word_index.zig
│   ├── trigram.zig, sparse_ngram.zig, bloom.zig, mmap_trigram.zig
│   ├── explorer_core.zig, explorer_core_extra.zig
│   ├── explorer_search.zig, explorer_search_extra.zig
│   ├── edit.zig, regressions.zig, regressions_extra.zig
│   ├── snapshot.zig, mcp_protocol.zig, mcp_search.zig
│   ├── regex.zig, perf.zig, disk_index.zig, concurrency.zig
│   ├── fuzzy.zig, query_pipeline.zig, nuke.zig, update.zig
│   ├── git.zig, dep_graph.zig, symbol_index.zig, type_index.zig
│   ├── path_safety.zig, root_policy.zig, glob.zig, telemetry.zig
│   └── parsers/
│       ├── c.zig, csharp.zig, fsharp.zig, php.zig, tsql.zig, misc.zig
│
├── path_safety.zig           # isPathSafe, isSensitivePath (canonical, security)
├── json_utils.zig            # writeJsonEscaped (shared)
├── store.zig                 # Store version log
├── version.zig               # Version, Op, FileVersions
├── edit.zig                  # line-range file editor
├── snapshot_json.zig         # on-demand JSON snapshot renderer
├── agent.zig                 # AgentRegistry, file locking, heartbeats
├── telemetry.zig             # opt-out telemetry
├── config.zig                # user config
├── root_policy.zig           # root directory policy
├── lib.zig                   # public module surface for importable codedb
├── build.zig                 # Zig build system
│
├── csharp_parser.zig         # C# parser (imports ident_utils for shared helpers)
├── fsharp_parser.zig         # F# parser (imports ident_utils for shared helpers)
├── tsql_parser.zig           # T-SQL parser (imports ident_utils for shared helpers)
├── ssrs_parser.zig           # SSRS/RDL parser
├── t4_parser.zig             # T4 template parser
├── autumn_parser.zig         # Autumn Equinox mapping parser
├── nuke.zig                  # nuke command
├── update.zig                # self-update command
├── hot_cache.zig             # content cache
├── git.zig                   # git helpers
├── compat.zig                # cross-platform compatibility
├── style.zig                 # terminal style/color
├── wasm.zig                  # WASM bindings
└── release_info.zig          # release version stub
```

## Core Modules

### `main.zig` — CLI Entry Point (23 lines)

Thin executable shell. Delegates to `commands/mod.zig` for arg parsing and dispatch.

| Command | Handler |
|---------|---------|
| `tree` | `commands/tree.zig` |
| `outline <path>` | `commands/outline.zig` |
| `find <name>` | `commands/find.zig` |
| `search <query>` | `commands/search.zig` |
| `word <id>` | `commands/word.zig` |
| `hot` | `commands/hot.zig` |
| `serve` | `commands/serve.zig` |
| `mcp` | `commands/mcp.zig` |
| `snapshot` | `commands/snapshot.zig` |

Shared CLI helpers live under `cli/`: `disk_cache.zig` (snapshot/config loading), `scan.zig` (background scan, idle watchdog), `shell.zig` (Out writer).

Data is stored per-project at `~/.codedb/projects/<hash>/`.

### `explore.zig` — Code Intelligence Engine (452-line aggregator)

The central `Explorer` struct holds all indexed data behind a single mutex.

**Data structures:**
- `outlines: StringHashMap(FileOutline)` — per-file symbol lists
- `contents: StringHashMap([]const u8)` — raw file content cache
- `dep_graph: StringHashMap(ArrayList([]const u8))` — file → imported files
- `word_index: WordIndex` — inverted word index for O(1) identifier lookup
- `trigram_index: TrigramIndex` — trigram index for fast substring search

**Sub-modules** (all re-exported through `explore.zig`):
- `explore/search.zig` — `searchContent`, ranked search, regex, fuzzy, scoped
- `explore/tree.zig` — `getTree`, `lsDir`, `globPaths`
- `explore/deps.zig` — dependency graph, symbol/type index mutations
- `explore/lifecycle.zig` — `indexFile`, `removeFile`, symbol-end detection
- `explore/type_extract.zig` — per-language type-index extraction
- `explore/ident_utils.zig` — shared identifier helpers (canonical source for `extractIdent`, `isIdentChar`, `startsWith`, etc.)
- `explore/parsers/` — per-language parser modules (systems, web, jvm, clang, csharp_family, scripting, declarative)

### `index.zig` — Search Indexes (70-line aggregator)

**WordIndex** — inverted index mapping words to `(path, line_num)` hits.

**TrigramIndex** — maps 3-byte character sequences to file sets. Three variants:
- `TrigramIndex` (heap) — in-memory
- `MmapTrigramIndex` — disk-mapped
- `AnyTrigramIndex` — tagged union

### `store.zig` — Version Store

Append-only version log per file. Each mutation gets a monotonically increasing sequence number.

### `watcher.zig` — File System Watcher (19-line aggregator)

Polling-based file watcher (2-second interval). Sub-modules:
- `watcher/skip_rules.zig` — skip dirs/extensions, `isSensitivePath` (security-isolated)
- `watcher/filtered_walker.zig` — `FilteredWalker` directory pruner
- `watcher/initial_scan.zig` — `initialScan`, Worker types
- `watcher/incremental.zig` — `incrementalLoop`, `FsEvent`, `EventQueue`

### `server.zig` — HTTP Server (13-line aggregator)

Thread-per-connection HTTP server on `:7719`. Sub-modules:
- `server/transport.zig` — `serve`, `HandlerCtx`, `Conn`, `respondJson`
- `server/routes.zig` — `handleConnection` HTTP route handler
- `server/http_parsing.zig` — query param extraction, percent decode, JSON parsing

**Endpoints:**

| Route | Method | Description |
|-------|--------|-------------|
| `/tree` | GET | File tree |
| `/outline?path=` | GET | File outline |
| `/symbol?name=` | GET | Find symbol definitions |
| `/search?q=&max=` | GET | Full-text search |
| `/word?w=` | GET | Inverted index word lookup |
| `/hot?limit=` | GET | Recently modified files |
| `/deps?path=` | GET | Reverse dependencies |
| `/read?path=` | GET | Read file content |
| `/edit` | POST | Apply a line-range edit |
| `/changes?since=` | GET | Changed files since sequence N |
| `/status` | GET | File count + current sequence |
| `/snapshot` | GET | Full pre-rendered JSON snapshot |
| `/events` | GET | SSE stream of file change events |

### `mcp.zig` — MCP Server (75-line aggregator)

JSON-RPC 2.0 over stdio with Content-Length framing. Sub-modules:
- `mcp/server.zig` — session management, scan-state machine, dispatch
- `mcp/explore_tools.zig` — tree/outline/symbol/hierarchy/search/word/callers/hot/deps
- `mcp/mutation_tools.zig` — read/edit/changes/status/snapshot
- `mcp/composite_tools.zig` — types/bundle/projects/index/find/glob/ls
- `mcp/aspnet.zig` — ASP.NET route/config analysis
- `mcp/query.zig` — composable query pipeline (driver + per-op steps)

**Tools exposed (16):**

| Tool | Description |
|------|-------------|
| `codedb_tree` | File tree |
| `codedb_outline` | File outline |
| `codedb_symbol` | Symbol lookup |
| `codedb_search` | Full-text search (trigram, regex, scoped) |
| `codedb_word` | Word index lookup |
| `codedb_hot` | Hot files |
| `codedb_deps` | Reverse dependencies |
| `codedb_read` | Read file content (line ranges, hash caching) |
| `codedb_edit` | Apply edits (replace, insert, delete) |
| `codedb_changes` | Changes since seq |
| `codedb_status` | Index status |
| `codedb_snapshot` | Full snapshot |
| `codedb_bundle` | Batch multiple queries (max 20 ops) |
| `codedb_remote` | Query indexed public repos via api.wiki.codes |
| `codedb_projects` | List locally indexed projects |
| `codedb_index` | Index a local folder |

### `snapshot.zig` — Snapshot (57-line aggregator)

Binary snapshot format for fast startup. Sub-modules:
- `snapshot/format.zig` — MAGIC, FORMAT_VERSION, SectionId, cleanup
- `snapshot/writer.zig` — `writeSnapshot`, `writeSnapshotDual`
- `snapshot/loader_validated.zig` — `loadSnapshotValidated`, rebuildDeps
- `snapshot/loader_fast.zig` — `loadSnapshotFast`
- `snapshot/sensitive.zig` — re-exports `path_safety.isSensitivePath`

### `cio.zig` — Cross-platform I/O (46-line aggregator)

Platform abstraction layer. Sub-modules:
- `cio/platform.zig` — posix/win backends
- `cio/file.zig` — `File`, `ListWriter`
- `cio/sync.zig` — `Mutex`, `RwLock`, `flockFd`
- `cio/time.zig` — `nanoTimestamp`, `Timer`, `randU64`
- `cio/process.zig` — pipes, getenv, args
- `cio/spawn.zig` — `CaptureResult`, `RunOptions`, `runCapture`

### Shared Utilities

| File | Purpose |
|------|---------|
| `path_safety.zig` | `isPathSafe`, `isSensitivePath` — canonical, security-isolated |
| `json_utils.zig` | `writeJsonEscaped` — shared JSON string escaping |
| `explore/ident_utils.zig` | `extractIdent`, `isIdentChar`, `startsWith`, `containsAny`, etc. |

## Architecture Diagram

```
┌─────────────┐     ┌─────────────┐
│  HTTP :7719 │     │  MCP stdio  │
│ server/*.zig│     │  mcp/*.zig  │
└──────┬──────┘     └──────┬──────┘
       │                   │
       └───────┬───────────┘
               │
    ┌──────────▼──────────┐
    │     Explorer        │
    │   explore.zig       │
    │  ┌───────────────┐  │
    │  │ WordIndex      │  │
    │  │ TrigramIndex   │  │
    │  │ Outlines       │  │
    │  │ Contents       │  │
    │  │ DepGraph       │  │
    │  └───────────────┘  │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │      Store          │──── data.log
    │    store.zig        │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │     Watcher         │ ← polls every 2s
    │   watcher/*.zig     │
    │  (FilteredWalker)   │
    └─────────────────────┘
```

## Threading Model

- **Main thread** — runs HTTP accept loop or MCP read loop
- **Watcher thread** — `incrementalLoop`, polls filesystem every 2s
- **ISR thread** — `isrLoop`, rebuilds snapshot when stale flag is set
- **Reap thread** — `reapLoop`, cleans up stale agents every 5s
- **Per-connection threads** — HTTP server spawns a thread per connection

All threads share a `shutdown: std.atomic.Value(bool)` flag for graceful termination.

## Data Flow

1. **Startup:** `initialScan` walks the project (via `FilteredWalker`), indexes each file's outline and content into `Explorer`, records snapshots in `Store`
2. **Steady state:** `incrementalLoop` detects changes, re-indexes modified files, and pushes events to `EventQueue`
3. **Queries:** HTTP/MCP handlers call `Explorer` methods under its mutex, return JSON responses
4. **Edits:** `/edit` applies line-range changes atomically, re-indexes the file, records the edit in `Store`
