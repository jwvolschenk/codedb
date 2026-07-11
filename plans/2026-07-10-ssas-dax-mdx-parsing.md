# SSAS, DAX, and MDX Parsing Plan

## Summary

Create `plans/2026-07-10-ssas-dax-mdx-parsing.md` containing this implementation plan, then update both codedb and `/home/jwvolschenk/repos/ssas`.

Current baseline:

- `zig build test` passes.
- The SSAS corpus indexes 20 files in 69 ms but recognizes `.bim` as `unknown` and produces no useful symbols.
- Its six compatibility-level-1500 models contain 80 tables, 1,361 columns, 130 measures, 93 calculated columns, 56 relationships, and 7 calculation items.
- V1 will cover `.bim`, `.tmdl`, `.dax`, `.mdx`, `.cube`, `.xmla`, `.smproj`, and `.dwproj`. TMDL is included because it is Microsoft’s current source-control-friendly tabular format; TMSL/`.bim` remains JSON-based. [TMDL overview](https://learn.microsoft.com/en-us/analysis-services/tmdl/tmdl-overview?view=sql-analysis-services-2025), [TMSL reference](https://learn.microsoft.com/en-us/analysis-services/tmsl/tabular-model-scripting-language-tmsl-reference?view=sql-analysis-services-2025)

## Implementation Changes

### Language and parser integration

- Add `Language` values for DAX, MDX, TMDL, tabular models, multidimensional cubes/XMLA, and SSAS projects; update extension detection, comment handling, caller eligibility, tests, and snapshot serialization.
- Add a zero-dependency `ssas_parser.zig`, using Zig’s JSON support plus bounded source scanning. Do not add tree-sitter or external parsers.
- Increment `INDEX_VERSION` so existing snapshots containing `.bim` as unstructured text are rebuilt.
- Keep existing `SymbolKind` and MCP schemas unchanged.

| Source construct | codedb representation |
|---|---|
| Table / calculation group | `class_def` |
| Physical or calculated column | `variable` |
| Measure / calculation item / DAX function | `function` |
| Hierarchy | `struct_def` |
| Partition / perspective / role | `type_alias` |
| Relationship | `type_alias` with qualified endpoints in detail |
| Project model include | `import` dependency |

- Preserve exact object names for `codedb_symbol`; include the owning table, object subtype, data type, and a bounded expression preview in `detail`.
- Never include server addresses, usernames, credential objects, or connection strings in symbol details.

### Tabular and project parsing

- Parse `.bim` and JSON TMSL shapes by locating `model` beneath direct model, database, or `createOrReplace` roots.
- Extract tables, all columns, measures, calculation groups/items, hierarchies, relationships, partitions, perspectives, and roles.
- Support scalar and string-array expressions. Parse calculated objects as DAX; expose partition type and searchable raw M/SQL text without grammar-aware M parsing.
- Use source offsets for line-accurate symbols; minified JSON may place multiple symbols on line 1.
- Parse TMDL indentation and quoted identifiers for tables, columns, measures, hierarchies, partitions, relationships, roles, perspectives, shared expressions, and DAX user-defined functions.
- Parse `.smproj`/`.dwproj` project identity and source-file includes while omitting deployment server values.

### DAX, MDX, and references

- For standalone DAX, recognize `DEFINE MEASURE`, `VAR`, `TABLE`, `COLUMN`, DAX UDFs, `name := expression`, and `EVALUATE` query blocks. DAX queries officially use `EVALUATE` with optional `DEFINE` entities. [DAX query syntax](https://learn.microsoft.com/en-gb/dax/dax-queries)
- For MDX, recognize `WITH/CREATE MEMBER`, named sets, calculated cells, `SCOPE` blocks, assignments, and query `SELECT` blocks.
- Extract MDX commands from `MdxScript` content in `.cube` and XML/XMLA, including CDATA and escaped XML text. [MdxScript element](https://learn.microsoft.com/en-us/analysis-services/assl/objects/mdxscript-element-assl?view=sql-analysis-services-2025)
- Add DAX/MDX-aware caller matching:
  - DAX measures: `[Measure]`
  - DAX columns: `'Table'[Column]` and `Table[Column]`
  - Tables: quoted and bare table references
  - MDX objects: `[Measures].[Name]` and qualified dimension/hierarchy/member references
- Ignore matches inside strings and comments. Malformed strings, brackets, comments, JSON, XML, or TMDL must return partial/empty results without panics.

### Sensitive-content handling

- Add an extension-gated content check for SSAS sources and deployment artifacts.
- Treat non-empty password, `pwd`, account-key, access-token, client-secret, API-key, or private-key values as sensitive. Do not classify usernames, endpoints, `AuthenticationKind`, or an empty/null credential field as secrets.
- Apply the check consistently to initial scans, parallel/trigram scans, outline-only scans, incremental updates, warm-start reconciliation, MCP reads, and edits.
- If an indexed file becomes secret-bearing, immediately remove its outline and all word/trigram/search entries and record its deletion.
- Block secret-bearing files from snapshots and MCP access, and invalidate older indexes through the index-version bump.

## SSAS Repository Configuration

Create `/home/jwvolschenk/repos/ssas/.codedbignore` with codedb-compatible, case-insensitive patterns for:

- IDE/build directories: `.vs/`, `.idea/`, `.vscode/`, `bin/`, `obj/`, `Debug/`, `Release/`, `x64/`, `x86/`, `bld/`, `Log/`, `TestResults/`
- Dependencies/output: `packages/`, `node_modules/`, `artifacts/`, `publish/`, `Backup*/`
- Temporary/binary files: `*.suo`, `*.user`, `*.tmp`, `*.log`, `*.cache`, `*.pdb`, `*.dll`, `*.exe`, `*.nupkg`
- SSAS-generated artifacts: `*.bim.layout`, `*.bim_*.settings`, `*.asdatabase`, `*.deploymenttargets`, `*.deploymentoptions`, `*.deploymentmetadata`
- codedb output and conventional secrets: `codedb.snapshot`, `.env`, `.env.*`, `*.pem`, `*.key`, `credentials.json`, `secrets.json`

Explicitly retain `.sln`, `.smproj`, `.dwproj`, `.bim`, `.tmdl`, `.dax`, `.mdx`, `.cube`, and source `.xmla` files.

Append the missing SSAS deployment patterns and `codedb.snapshot` to the SSAS `.gitignore`. Keep `.codedbignore` tracked; no `.codedbrc` is needed for this small repository.

## Test and Acceptance Plan

- Add unit fixtures for DAX/MDX declarations and references, TMDL objects, `.bim`/TMSL structures, project includes, and embedded MDX XML.
- Cover escaped braces/quotes, quoted identifiers, comments containing syntax, unterminated comments/strings/CDATA, malformed JSON/XML/TMDL, minified JSON, duplicate object names, and expression arrays.
- Add security tests proving:
  - endpoint/username-only models remain indexed;
  - actual secret-bearing files are absent from outlines, symbols, search, snapshots, reads, and edits;
  - introducing a secret incrementally evicts previously indexed content.
- Add an MCP integration scenario using sanitized generated fixtures: index, outline, symbol lookup, DAX/MDX callers, search, project dependencies, and sensitive-file rejection.
- Validate against `/home/jwvolschenk/repos/ssas` without committing its proprietary content:
  - all 20 intended source/project files remain discoverable;
  - at least 80 tables, 1,361 columns, 130 measures, 93 calculated columns, 56 relationships, and 7 calculation items are structurally exposed;
  - representative measure lookups and bracketed callers resolve correctly.
- Run:
  - `zig build test`
  - `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /mnt/storage/repos/codedb`
  - the new sanitized SSAS MCP scenario
  - before/after repository benchmarks, enforcing the project’s less-than-10% regression threshold on existing languages and recording SSAS indexing time/symbol counts.

## Assumptions

- V1 surfaces Power Query M and embedded SQL as partition metadata/searchable content but does not parse their grammars.
- V1 extracts MDX scripts and key cube/project structure without attempting a complete legacy ASSL object model.
- No new MCP tools, generic symbol kinds, external dependencies, or telemetry fields are introduced.
