# codedb MCP Tools

Codebase intelligence via MCP. Index once, query many.

## Setup

```
codedb_index path=/absolute/path/to/repo
```

## Critical Rules

1. **Always pass `project=/path/to/repo`** on every MCP call
2. **Batch calls**: use `codedb_query` for dependent chains, `codedb_bundle` for independent ops
3. **Avoid individual calls** when batch is possible

## Batching

**Dependent chains** — each step feeds the next:
```json
codedb_query: [
  {"op":"symbol","name":"handleRequest","body":true},
  {"op":"callers","name":"handleRequest"},
  {"op":"read","context_lines":5}
]
```

**Independent ops** — parallel, no data flow:
```json
codedb_bundle: [
  {"tool":"codedb_status"},
  {"tool":"codedb_search","query":"TODO"},
  {"tool":"codedb_types","return_type":"bool"}
]
```

## Language Notes

- **Zig/C/C++**: Pointer types use explicit syntax — search `*Explorer` not `Explorer` for params
- **C#/Java**: Use `decorator_filter` on symbol to find attributed methods (e.g. `[Authorize]`)
- **All**: `codedb_outline` with `grouped=true` shows sections by symbol kind
