---
name: codedb-instructions
description: "Use when querying, searching, or navigating a codebase via codedb MCP tools. Covers indexing, search, symbols, dependencies, and batching patterns."
---

# codedb — Code Intelligence for AI Agents

codedb is a local code intelligence server. It indexes a project once and provides
fast symbol lookup, full-text search, dependency analysis, and code navigation
via MCP tools or CLI.

## When to Use

- Searching for symbols, functions, classes, or identifiers
- Finding callers or dependencies of a function
- Navigating an unfamiliar project structure
- Performing impact analysis before refactoring

## Prerequisites

- codedb binary installed (`~/.local/bin/codedb` or on PATH)
- A project directory to index

## Indexing

Before querying, index the project:

```
codedb_index path=/absolute/path/to/project
```

Or via CLI:

```bash
codedb /absolute/path/to/project
```

First run creates `codedb.snapshot` in the project root and a central cache at
`~/.codedb/projects/<hash>/`. Subsequent runs are incremental — only changed
files are re-parsed.

## Critical Rule: Always Pass the Project Path

**Every MCP call MUST include `project=/absolute/path/to/project`.**

codedb does not assume a working directory. Omitting `project=` causes failures
or queries against the wrong index.

```
codedb_search query="handleOrder" project=/home/user/repos/myapp
codedb_symbol name="OrderController" project=/home/user/repos/myapp
codedb_outline path="src/Controllers/OrderController.cs" project=/home/user/repos/myapp
```

## Mono-Repos

Index and query each project separately. Do NOT index the mono-repo root unless
it contains a single cohesive codebase.

```
codedb_index path=/home/user/monorepo/services/api
codedb_index path=/home/user/monorepo/services/web

codedb_search query="UserService" project=/home/user/monorepo/services/api
```

## MCP Tools

### Navigation

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_tree` | File tree with languages and symbol counts | Orient in an unfamiliar project |
| `codedb_outline` | Symbols in a file (functions, classes, imports) | Before reading a file |
| `codedb_outline grouped=true` | Same, grouped by symbol kind | See all methods, then all classes |
| `codedb_ls` | Directory listing with file descriptors | Quick directory scan |
| `codedb_ls ranked=true` | Sorted by hotspot score | Find high-activity files |
| `codedb_hot` | Recently modified files | What changed recently |

### Search

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_search` | Full-text substring/regex search | Broad queries, partial names |
| `codedb_word` | Exact identifier lookup (O(1)) | Known identifier — fastest path |
| `codedb_symbol` | Find where a symbol is defined | Returns definition site with line |
| `codedb_find` | Fuzzy file-name search | Typos tolerated — `authmidlware` finds `auth_middleware.go` |
| `codedb_glob` | Glob pattern match | `glob pattern="src/**/*.test.cs"` |

### Analysis

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_callers` | Every call site of a symbol | Impact analysis — who calls this? |
| `codedb_deps` | Dependency graph (imported_by / depends_on) | What does this file import? What imports it? |
| `codedb_deps transitive=true` | Full transitive closure | Blast radius analysis |
| `codedb_types` | Find functions by return type or param type | `types return_type="Task<UserDto>"` |
| `codedb_hierarchy` | Class/interface inheritance tree | What extends this class? |
| `codedb_config_xref` | Config key cross-reference (ASP.NET) | Find unused/missing config keys |
| `codedb_routes` | Route map extraction (ASP.NET) | List all API endpoints |

### Indexing & Status

| Tool | Purpose |
|------|---------|
| `codedb_index` | Index a folder (creates/updates snapshot) |
| `codedb_index force=true` | Full re-index after changing `.codedbignore` |
| `codedb_status` | File count, sequence number, scan phase |
| `codedb_changes since=N` | Files changed since sequence N |

### Remote Queries

| Tool | Purpose |
|------|---------|
| `codedb_remote` | Query public repos via api.wiki.codes |

### Editing

| Tool | Purpose |
|------|---------|
| `codedb_edit` | Line-based file edit (replace, insert, delete) |

## Batching (Important for Performance)

### Dependent Chains — use `codedb_query`

When each step feeds the next, chain them in one call:

```json
codedb_query pipeline=[
  {"op":"symbol","name":"handleRequest","body":true},
  {"op":"callers","name":"handleRequest"},
  {"op":"read","context_lines":5}
]
```

This finds the definition, then its callers, then reads 5 lines of context
around each call site — in one round trip.

### Independent Operations — use `codedb_bundle`

```json
codedb_bundle commands=[
  {"tool":"codedb_status"},
  {"tool":"codedb_search","query":"TODO","max_results":10},
  {"tool":"codedb_types","return_type":"bool","max_results":5}
]
```

**Never make individual calls when batch is possible.** Each call is a round trip.

## Result Limiting

Always set `max_results` or `limit` to avoid context bloat:

- `codedb_search`: defaults to 50 — set `max_results: 10` for broad queries
- `codedb_word`: capped at 50 — use `path_glob` to scope common identifiers
- `codedb_callers`: defaults to 50 — reduce for focused investigation
- `codedb_types`: defaults to 50 — reduce if you only need a few examples
- `codedb_read`: use `line_start`/`line_end` after `codedb_outline` — never read entire large files

## Common Workflows

### Find a bug's origin

```
1. codedb_search query="NullReferenceException"  — find error sites
2. codedb_callers name="GetOrder"                — who calls the failing method
3. codedb_read path="src/Services/OrderService.cs" lines="45-60"  — read the code
```

### Understand a feature end-to-end

```
1. codedb_find query="payment"                   — find relevant files
2. codedb_outline path="src/PaymentController.cs" grouped=true
3. codedb_deps path="src/PaymentController.cs" direction="depends_on" transitive=true
4. codedb_search query="IPaymentService" scope=true
```

### Refactor safely

```
1. codedb_symbol name="OldMethod" body=true      — see current implementation
2. codedb_callers name="OldMethod" max_results=100 — all call sites
3. codedb_types param_type="OldClass"             — typed dependencies
4. Make changes
5. codedb_index force=true                        — re-index after refactor
```

## Excluding Files from Indexing

Create `.codedbignore` in the project root (same syntax as `.gitignore`):

```
# Vendor libraries
node_modules/
vendor/
Lib/

# Build output
bin/
obj/
dist/

# Config/runtime files
appsettings*.json
*.min.js

# Binary files
*.dll
*.exe
*.nupkg
```

After changing `.codedbignore`, re-index with `codedb_index force=true`.

codedb automatically skips `.git`, `node_modules`, `dist`, `build`,
`__pycache__`, `.venv`, `target`, `vendor`, `coverage`, and 30+ others.

## CLI Usage (Non-MCP)

```bash
codedb /path/to/project                              # index
codedb /path/to/project search "handleOrder"         # search
codedb /path/to/project find OrderController         # find symbol
codedb /path/to/project tree                         # file tree
codedb /path/to/project outline src/File.cs          # file outline
```

## Data Storage

- Project snapshot: `<project>/codedb.snapshot`
- Central cache: `~/.codedb/projects/<hash>/`

To remove a project's index: delete `codedb.snapshot` from the project root
and its entry in `~/.codedb/projects/`.

## Common Pitfalls

1. **Omitting `project=` on MCP calls.** Every call must include the full
   absolute path to the project root.
2. **Indexing a mono-repo root instead of individual projects.** Pollutes
   search results with unrelated code.
3. **Forgetting to re-index after `.codedbignore` changes.** Use
   `codedb_index force=true`.
4. **Making individual calls when batch is possible.** Use `codedb_query` for
   dependent chains, `codedb_bundle` for independent ops.
5. **Using `codedb_search` for exact identifiers.** Use `codedb_word` (O(1))
   instead of `codedb_search` (O(n)).
6. **Not setting `max_results` on broad queries.** Defaults can return 50
   results — always scope with `max_results`, `path_glob`, or `limit`.
7. **Reading entire large files.** Use `codedb_outline` first to find line
   ranges, then `codedb_read` with `line_start`/`line_end`.
