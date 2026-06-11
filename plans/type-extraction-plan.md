# codedb Type Extraction — Implementation Plan

## Problem Statement

codedb currently stores symbols with `name`, `kind`, `line_start`, `line_end`,
`detail` (raw line text), and `decorators`. There is no structured type
information — no return types, no parameter types, no type graph. This means:

- "Find all functions returning `Task<UserDto>>`" requires scanning every raw
  detail string at query time (slow, imprecise)
- "What does this function return?" requires reading the full source line
- "Which functions accept an `ILogger` parameter?" is impossible without
  full content scan
- Type-aware refactoring ("change this interface, find all conforming
  implementations") has no index support

Adding structured type extraction would let codedb answer these queries at
index time with O(1) lookups, and lay the groundwork for a type graph.

## Current State (from source analysis)

```
Symbol struct (src/explore/types.zig:25):
  name: []const u8,
  kind: SymbolKind,
  line_start: u32,
  line_end: u32,
  detail: ?[]const u8 = null,     // raw line text, e.g. "public async Task<UserDto> GetUser(int id)"
  decorators: []const []const u8 = &.{},
```

Snapshot format (src/snapshot.zig): writes name, kind, line_start, line_end,
has_detail flag, detail bytes. FORMAT_VERSION = 2.

Parsers (src/explore.zig): each language has a parse*Line function. Most store
the entire raw line as `detail`. The C# parser (src/csharp_parser.zig) already
has helper functions like `looksLikeReturnTypePrefix`, `extractCallableName`,
`extractLastTypeIdent` — but they're used only for name extraction, not type
capture.

## Design: What to Add

### New fields on Symbol

```zig
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    detail: ?[]const u8 = null,
    decorators: []const []const u8 = &.{},
    // --- NEW ---
    return_type: ?[]const u8 = null,    // e.g. "Task<ActionResult<UserDto>>"
    param_types: []const []const u8 = &.{},  // e.g. ["int", "string", "ILogger"]
};
```

### Snapshot Format Change

FORMAT_VERSION bump: 2 -> 3.

After the existing detail field, write:
  - has_return_type: u8 (0 or 1)
  - if 1: return_type_len: u16, return_type bytes
  - param_types_count: u32
  - for each param_type: len: u16, bytes

Backward compat: loadSnapshotValidated already checks FORMAT_VERSION. Old
snapshots (v2) are handled by the existing fast-load path which will simply
not populate the new fields (they default to null/&.{}).

### Parser Changes

Priority order by language (your team's stack):

#### Phase 1: C# (highest impact — your primary language)

The C# parser already has the building blocks. The `parseLine` function in
`src/csharp_parser.zig` recognizes methods via `extractMethodName`. We need to:

1. Extract return type: everything between the declaration prefix
   (public/private/async/static/virtual/override/abstract) and the method name.
   Example: "public async Task<UserDto> GetUser(int id)"
   - Strip modifiers: "async Task<UserDto> GetUser(int id)"
   - Extract callable name at '(': "GetUser"
   - Everything before the name (trimmed) = return type: "Task<UserDto>"

2. Extract parameter types: parse the content between '(' and ')', split on
   commas, extract the type portion of each parameter (everything before the
   last identifier).
   Example: "(int id, string name, ILogger logger)" -> ["int", "string", "ILogger"]

3. Handle edge cases:
   - Constructors: no return type (name == class name, no type before it)
   - Expression-bodied: `public string Name => _name;` -> return_type = "string"
   - Properties: return_type = property type
   - Delegates: return_type from delegate signature
   - Generic methods: `public T Get<T>(int id)` -> return_type = "T"
   - Nullable: `string?` -> return_type = "string?"
   - Tuple returns: `(int, string)` -> return_type = "(int, string)"

4. Modify the C# parser's `Symbol` struct (csharp_parser.zig:15) to carry
   return_type and param_types through to the outline.

#### Phase 2: TypeScript/JavaScript

TypeScript has explicit type annotations:
  - `function getUser(id: number): Promise<User>` -> return "Promise<User>", params ["number"]
  - `const fn = (x: string): void =>` -> return "void", params ["string"]
  - `interface User { name: string; }` -> no return type, but property types

JS: limited — JSDoc @returns annotations only (stretch goal).

#### Phase 3: Other typed languages

- Go: `func GetUser(id int) (*User, error)` -> return "*User, error", params ["int"]
- Rust: `fn get_user(id: i32) -> Result<User, Error>` -> return "Result<User, Error>", params ["i32"]
- Java/Kotlin: similar to C#
- Python: type hints `def get_user(id: int) -> User:` -> return "User", params ["int"]
- Zig: `pub fn getUser(id: i32) !User` -> return "!User", params ["i32"]

#### Phase 4: Untyped languages (best-effort)

- Ruby, PHP, Shell, etc.: extract what's available, leave null otherwise.

## MCP Tool Changes

### Enriched output

- `codedb_symbol`: include return_type and param_types in response
- `codedb_outline`: include type info in symbol listings
- `codedb_callers`: include param types so callers can be filtered by signature
- `codedb_hierarchy`: use return types to infer interface implementations

### New query capabilities

- `codedb_query` new op: `type_search` — find all symbols with a given
  return type or parameter type
  Example: `{"op":"type_search","return_type":"Task<UserDto>"}`
  Example: `{"op":"type_search","param_type":"ILogger"}`

- `codedb_query` new op: `type_compat` — find all symbols whose return type
  is assignable to a given type (requires type graph, Phase 3)

### `codedb_types` tool (new)

Dedicated tool for type queries:
- "What does this function return?" -> symbol lookup + return_type
- "What parameters does this function take?" -> symbol lookup + param_types
- "Find all functions returning X" -> inverted type index lookup
- "Find all functions accepting X" -> inverted type index lookup

## New Data Structures

### Type Index (inverted index, like word_index)

```
TypeIndex {
    // return_type -> list of (file_path, symbol_name, line)
    return_type_map: StringHashMap(ArrayList(TypeHit)),

    // param_type -> list of (file_path, symbol_name, line, param_position)
    param_type_map: StringHashMap(ArrayList(TypeHit)),

    // for fast "implements interface" queries
    interface_impl_map: StringHashMap(ArrayList(TypeHit)),
}
```

Persisted to: `type.index` alongside `word.index` and `trigram.*` in the
project data dir.

### Type Graph (stretch — Phase 3)

```
TypeGraph {
    // type_name -> set of types it extends/implements
    bases: StringHashMap(StringHashSet),

    // type_name -> set of types that extend/implement it
    derived: StringHashMap(StringHashSet),

    // type_name -> set of files that define it
    definitions: StringHashMap(StringHashSet),
}
```

This enables: "Find all implementations of IUserRepository" without scanning.

## Implementation Order

### Sprint 1: Data Model + C# Return Types (core foundation)

1. Add `return_type` and `param_types` fields to Symbol in types.zig
2. Bump snapshot FORMAT_VERSION to 3, update writeSnapshot + loadSnapshot
3. Add snapshot serialization for the new fields
4. Update C# parser to extract return_type from method declarations
5. Update C# parser to extract param_types from method signatures
6. Update `codedb_symbol` MCP output to include type fields
7. Update `codedb_outline` MCP output to include type fields
8. Write tests: parse C# method signatures, verify round-trip through snapshot

### Sprint 2: Type Index + C# Parameter Types

1. Build TypeIndex data structure (return_type_map, param_type_map)
2. Populate TypeIndex during file indexing (commitParsedFileOwnedOutline)
3. Persist TypeIndex to disk (type.index file)
4. Load TypeIndex from disk on startup
5. Add `type_search` op to codedb_query pipeline
6. Add `codedb_types` MCP tool
7. Write tests: index a C# project, query by return type and param type

### Sprint 3: TypeScript + Go Type Extraction

1. Implement return_type/param_types extraction for TypeScript parser
2. Implement return_type/param_types extraction for Go parser
3. Update tests for new languages
4. Benchmark: verify indexing time doesn't regress > 10%

### Sprint 4: Remaining Languages + Type Graph

1. Implement for Rust, Java, Kotlin, Python, Zig parsers
2. Build TypeGraph from class/interface/struct declarations + inheritance
3. Add `type_compat` op to codedb_query (find implementations of interface)
4. Update `codedb_hierarchy` to use TypeGraph instead of detail-text parsing
5. Integration test: end-to-end refactoring scenario

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Multi-line signatures | Types split across lines | Parse from `detail` (raw line) only; accept we miss multi-line for now. The detail field already captures the first line. |
| Snapshot size increase | +2-5 bytes per symbol average | Type strings are short. For 10K symbols = ~50KB extra. Negligible. |
| Indexing time regression | Each parser does more work | Type extraction is string slicing, no allocation in hot path. Benchmark Sprint 2. |
| Format version migration | Old snapshots incompatible | FORMAT_VERSION check already exists. Old snapshots load fine with null types. Re-index picks up types. |
| Complex generic types | `Dictionary<string, List<Func<int, Task<bool>>>>` | Store as-is, don't try to parse nested generics. The string is still useful for matching. |

## What This Enables (End State)

After all 4 sprints, an agent can ask codedb:

- "Find all functions returning Task<UserDto>" -> instant TypeIndex lookup
- "Which functions take an ILogger parameter?" -> instant param_type_map hit
- "What does UserController.GetUser return?" -> symbol lookup + return_type
- "Find all implementations of IRepository<T>" -> TypeGraph traversal
- "I changed IUserRepository.Add signature — what breaks?" ->
  callers + param_types = exact answer without reading source
- "Extract the validation logic from OrderService" ->
  type_search for validation-related params + structural analysis

This is the foundation for type-aware refactoring in codedb.

## Files to Modify

| File | Changes |
|------|---------|
| `src/explore/types.zig` | Add return_type, param_types to Symbol |
| `src/snapshot.zig` | FORMAT_VERSION 3, serialize new fields |
| `src/csharp_parser.zig` | Extract return_type, param_types in parseLine |
| `src/explore.zig` | Update parseCSharpLine to pass types through; update all parsers |
| `src/index.zig` | Re-export TypeIndex |
| `src/index/type_index.zig` | **NEW** — TypeIndex struct, persist, load |
| `src/mcp.zig` | Update symbol/outline/callers output; add type_search; add codedb_types tool |
| `src/mcp/query.zig` | Add type_search pipeline op |
| `src/explore/parse_utils.zig` | Add extractReturnType, extractParamTypes helpers |
| `tests.zig` | Type extraction tests, snapshot round-trip, TypeIndex tests |

## Estimated Effort

- Sprint 1: ~2-3 days (data model + C# extraction)
- Sprint 2: ~2-3 days (TypeIndex + MCP integration)
- Sprint 3: ~2 days (TypeScript + Go parsers)
- Sprint 4: ~2-3 days (remaining langs + TypeGraph)
- Total: ~8-11 days of focused work

Sprint 1+2 alone deliver 80% of the value for your team's C# codebase.
Sprint 3+4 are incremental improvements.
