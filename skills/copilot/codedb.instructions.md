# codedb MCP Tools

Codebase intelligence via MCP. Index once, query many.

## Setup

```
codedb_index path=/absolute/path/to/repo
```

## Critical Rules

1. **Always pass `project=/path/to/repo`** on every MCP call
2. **Batch calls**: use `codedb_query` for dependent chains, batch independent ops together
3. **Avoid individual calls** when batch is possible

## Batching

**Dependent chains** — each step feeds the next:
```json
codedb_query pipeline=[
  {"op":"symbol","name":"handleRequest","body":true},
  {"op":"callers","name":"handleRequest"},
  {"op":"read","context_lines":5}
]
```

**Independent ops** — parallel, no data flow:
```json
codedb_batch_execute commands=[
  {"tool":"codedb_status"},
  {"tool":"codedb_search","query":"TODO"},
  {"tool":"codedb_types","return_type":"bool"}
]
```

## Mono-Repos

Index each project separately. Pass the specific project path, not the mono-repo root.

```
codedb_index path=/home/user/monorepo/services/api
codedb_search query="UserService" project=/home/user/monorepo/services/api
```

## Tools

**Navigate:** `codedb_tree`, `codedb_outline` (grouped=true), `codedb_ls`, `codedb_hot`

**Search:** `codedb_search` (substring/regex), `codedb_word` (exact O(1)), `codedb_symbol` (definition), `codedb_find` (fuzzy filename), `codedb_glob`

**Analyze:** `codedb_callers`, `codedb_deps` (transitive=true), `codedb_types`, `codedb_hierarchy`, `codedb_config_xref`, `codedb_routes`

**Index:** `codedb_index`, `codedb_index force=true`, `codedb_status`, `codedb_changes`

## Language Notes

- **C#**: Use `decorator_filter` on `codedb_symbol` to find attributed methods (e.g. `[Authorize]`, `[HttpPost]`)
- **All**: `codedb_outline grouped=true` shows sections by symbol kind
- **All**: `codedb_word` is O(1) — prefer over `codedb_search` for known identifiers

## Common Workflows

**Bug origin:** `codedb_search` for error → `codedb_callers` for the failing method → `codedb_read` the code

**Feature walkthrough:** `codedb_find` for topic → `codedb_outline grouped=true` → `codedb_deps transitive=true`

**Refactor:** `codedb_symbol` for definition → `codedb_callers` for all sites → `codedb_types` for typed deps → change → `codedb_index force=true`

## Exclusions

`.codedbignore` in project root (gitignore syntax). Re-index with `codedb_index force=true` after changes.

## Pitfalls

1. **Omitting `project=` on MCP calls.** Every call must include the full absolute path.
2. **Indexing a mono-repo root instead of individual projects.** Pollutes search results.
3. **Forgetting to re-index after `.codedbignore` changes.** Use `codedb_index force=true`.
4. **Making individual calls when batch is possible.** Use `codedb_query` for chains.
5. **Using `codedb_search` for exact identifiers.** Use `codedb_word` (O(1)) instead.
