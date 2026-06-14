---
name: codedb-instructions
description: "Use when querying, searching, or navigating a codebase via codedb MCP tools. Covers indexing, search, symbols, dependencies, and batching patterns."
version: 1.0.0
author: codedb
license: MIT
metadata:
  hermes:
    tags: [codedb, code-intelligence, mcp, search, symbols]
    related_skills: []
---

# codedb — Code Intelligence for AI Agents

codedb is a local code intelligence server. It indexes a project once and provides fast symbol lookup, full-text search, dependency analysis, and code navigation via MCP tools or CLI.

## When to Use

- Searching for symbols, functions, classes, or identifiers in a codebase
- Finding callers or dependencies of a function
- Navigating an unfamiliar project structure
- Performing impact analysis before refactoring
- Auditing ASP.NET config keys or routes

## Prerequisites

- codedb binary installed at `~/.local/bin/codedb` (or on PATH)
- A project directory to index

## Indexing a Project

Before querying, index the project:

```
codedb_index path=/absolute/path/to/project
```

Or via CLI:

```bash
codedb /absolute/path/to/project
```

The first run creates a `codedb.snapshot` in the project root and a central cache at `~/.codedb/projects/<hash>/`. Subsequent runs are incremental.

## Critical Rule: Always Pass the Project Path

**Every MCP call MUST include `project=/absolute/path/to/project`.**

codedb does not assume a working directory. If you omit `project=`, the tool either fails or queries the wrong index.

```
codedb_search query="handleOrder" project=/home/user/repos/myapp
codedb_symbol name="OrderController" project=/home/user/repos/myapp
codedb_outline path="src/Controllers/OrderController.cs" project=/home/user/repos/myapp
```

## Mono-Repos

In a mono-repo with multiple projects (e.g., `services/api`, `services/web`, `libs/shared`), index and query each project separately:

```
# Index each project independently
codedb_index path=/home/user/monorepo/services/api
codedb_index path=/home/user/monorepo/services/web

# Query the specific project you're working on
codedb_search query="UserService" project=/home/user/monorepo/services/api
```

Do NOT index the mono-repo root unless it contains a single cohesive codebase. Indexing unrelated projects together pollutes search results and symbol lookups.

## Available MCP Tools

### Navigation

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_tree` | File tree with languages and symbol counts | Orient in an unfamiliar project |
| `codedb_outline` | Symbols in a file (functions, classes, imports) | Before reading a file — know what's inside |
| `codedb_outline grouped=true` | Same but grouped by symbol kind | See all methods, then all classes, etc. |
| `codedb_ls` | Directory listing with file descriptors | Quick directory scan |
| `codedb_hot` | Recently modified files | What changed recently |

### Search

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_search` | Full-text substring search | Broad queries, partial names, comments |
| `codedb_search regex=true` | Regex search | Pattern matching |
| `codedb_word` | Exact identifier lookup (O(1)) | You know the exact name — `word="OrderController"` |
| `codedb_symbol` | Find where a symbol is defined | `symbol name="handleOrder"` returns definition site |
| `codedb_find` | Fuzzy file-name search | `find query="authmidlware"` finds `auth_middleware.go` |
| `codedb_glob` | Glob pattern match | `glob pattern="src/**/*.test.cs"` |

### Analysis

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_callers` | Every call site of a symbol | Impact analysis — who calls this? |
| `codedb_deps` | Dependency graph (imported_by / depends_on) | What does this file depend on? What imports it? |
| `codedb_deps transitive=true` | Full transitive closure | Blast radius analysis |
| `codedb_types` | Find functions by return type or param type | `types return_type="Task<UserDto>"` |
| `codedb_hierarchy` | Class/interface inheritance tree | What extends this class? |
| `codedb_config_xref` | Config key cross-reference (ASP.NET) | Find unused/missing appsettings keys |
| `codedb_routes` | Route map extraction (ASP.NET) | List all API endpoints |

### Indexing & Status

| Tool | Purpose |
|------|---------|
| `codedb_index` | Index a folder (creates/updates snapshot) |
| `codedb_index force=true` | Full re-index after changing `.codedbignore` |
| `codedb_status` | File count, sequence number, scan phase |
| `codedb_changes since=N` | Files changed since sequence N |

### Remote Queries

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `codedb_remote` | Query public repos via api.wiki.codes | `remote repo="vercel/next.js" action=search query="middleware"` |

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

This finds the definition, then its callers, then reads 5 lines of context around each call site — in one round trip.

### Independent Operations — batch in one call

```json
codedb_batch_execute commands=[
  {"tool":"codedb_status"},
  {"tool":"codedb_search","query":"TODO"},
  {"tool":"codedb_types","return_type":"bool"}
]
```

**Never make individual calls when batch is possible.** Each call is a round trip.

## Common Patterns

### Find a bug's origin

```
1. codedb_search query="NullReferenceException"  — find error sites
2. codedb_callers name="GetOrder"                — who calls the failing method
3. codedb_read path="src/Services/OrderService.cs" lines="45-60"  — read the code
```

### Understand a feature end-to-end

```
1. codedb_find query="payment"                   — find relevant files
2. codedb_outline path="src/Controllers/PaymentController.cs" grouped=true
3. codedb_deps path="src/Controllers/PaymentController.cs" direction="depends_on" transitive=true
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

### ASP.NET config audit

```
1. codedb_config_xref framework=aspnet            — unused/missing keys
2. codedb_routes framework=aspnet                 — all endpoints
```

## Excluding Files from Indexing

Create a `.codedbignore` file in the project root. Same syntax as `.gitignore`:

```
# Vendor libraries
Lib/
node_modules/
vendor/

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

## Built-in Skip Directories

codedb automatically skips: `.git`, `node_modules`, `dist`, `build`, `__pycache__`, `.venv`, `target`, `vendor`, `coverage`, and 30+ others. You don't need to add these to `.codedbignore`.

## CLI Usage (Non-MCP)

```bash
# Index
codedb /path/to/project

# Search
codedb /path/to/project search "handleOrder"

# Find symbol
codedb /path/to/project find OrderController

# File tree
codedb /path/to/project tree

# Outline a file
codedb /path/to/project outline src/Controllers/OrderController.cs
```

## Data Storage

- Project snapshot: `<project>/codedb.snapshot`
- Central cache: `~/.codedb/projects/<hash>/`
- Hash is based on the absolute project path

To remove a project's index: delete `codedb.snapshot` from the project root and its entry in `~/.codedb/projects/`.

## Common Pitfalls

1. **Omitting `project=` on MCP calls.** Every call must include the full absolute path to the project root.
2. **Indexing a mono-repo root instead of individual projects.** This pollutes search results with unrelated code.
3. **Forgetting to re-index after changing `.codedbignore`.** Use `codedb_index force=true`.
4. **Making individual calls when batch is possible.** Use `codedb_query` for dependent chains, batch independent ops.
5. **Using `codedb_search` for exact identifiers.** Use `codedb_word` (O(1)) instead of `codedb_search` (O(n)).

## SQL Server / TSQL Projects

codedb has a dedicated TSQL parser for `.sql` files. It extracts CREATE VIEW/PROCEDURE/FUNCTION/TABLE as symbols and tracks FROM/JOIN/INSERT/UPDATE/DELETE/EXEC as dependencies.

### What Works Well

- **Forward dependencies** (`codedb_deps direction=depends_on`): Correctly resolves cross-schema references from FROM/JOIN clauses.
- **Reverse dependencies** (`codedb_deps direction=imported_by`): Resolves "who uses this view/table?" via the dependency graph.
- **Symbol lookup** (`codedb_symbol`): Finds definitions by bare name (e.g., `vPosition`) or schema-qualified name (e.g., `Holding.vPosition`).
- **Outlines**: Captures CREATE objects, DECLARE variables, and cross-schema imports at correct line numbers.

### Caveats and Limitations

1. **Common names explode.** `codedb_symbol name="Account"` may return hundreds of hits across schemas. Always scope with `path_glob` or use the schema-qualified name:
   ```
   codedb_symbol name="vPosition" path_glob="**/Holding/**"
   codedb_symbol name="Holding.vPosition"
   ```

2. **`codedb_types` is not useful for SQL.** SQL has no typed function signatures like C#/TS. Skip this tool for SQL repos.

3. **`codedb_callers` won't trace EXEC calls.** SQL EXEC/EXECUTE is tracked as an import (dependency), not a function call. Use `codedb_search` to find EXEC patterns instead:
   ```
   codedb_search query="LoadDecomAccount" path_glob="**/*.sql"
   ```

4. **`codedb_tree` output is very large for big SQL repos** (18k+ files). Prefer `codedb_ls ranked=true` or `codedb_hot` for orientation instead.

5. **Some files have shallow outlines.** User Defined Types and short template functions may show as `[stub]` with minimal symbols. This is expected — they're small files.

6. **`.sqlproj` files are not parsed.** MSBuild XML project files are indexed but have no code intelligence. They don't affect SQL parsing.

7. **Backup/deprecated files** (`_xxx_backup.sql`, `_old/*.sql`) are indexed but may lack trigram search. Use `codedb_word` for exact lookups on these.

### Recommended SQL Workflow

```
# Orient: what schemas exist?
codedb_ls path="" project=/path/to/sql ranked=true

# Find a specific object
codedb_symbol name="vAccount" project=/path/to/sql

# What does this view depend on? (forward)
codedb_deps path="src/Portfolio/Views/vAccount.sql" direction="depends_on" project=/path/to/sql

# Who depends on this view? (reverse)
codedb_deps path="src/Portfolio/Views/vAccount.sql" direction="imported_by" project=/path/to/sql

# Find all EXEC calls to a proc
codedb_search query="LoadDecomAccount" path_glob="**/*.sql" project=/path/to/sql

# Find FROM/JOIN references to a table
codedb_search query="[Portfolio].[Account]" path_glob="**/*.sql" project=/path/to/sql
```
