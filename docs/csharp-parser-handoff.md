# C# Parser Handoff

This document captures the current state of the C# parser work so a cold-start agent can continue without rediscovering the same context.

## Status Snapshot

- Zig is installed at `/usr/local/bin/zig`; `zig version` reports `0.16.0`.
- The C# parser has been moved into a dedicated module: `src/csharp_parser.zig`.
- `src/explore.zig` now integrates the dedicated parser and computes C# symbol `line_end` values using brace matching.
- Focused C# and related regression tests pass.
- The full `zig build test` suite is not green, but the observed failures are the same non-C# perf/environment failures seen during this work.
- Raw-string handling now compiles and is covered by focused C# tests.

Current changed files:

- `.gitignore`
- `src/explore.zig`
- `src/tests.zig`
- `src/csharp_parser.zig`
- `docs/csharp-parser-handoff.md`

## Latest Completed Follow-Up

The latest follow-up completed the C# 11 raw string work and `.csx` detection:

- `src/csharp_parser.zig`
  - Fixed optional unwrapping around `rawStringDelimiterLength`.
  - Preserves raw string parser state across lines.
  - Allows multiline raw-string field declarations such as `private const string Raw = """` to emit the field symbol from the opening line.
  - Preserves operator detail for conversion/operator declarations, for example `operator int`.
- `src/explore.zig`
  - Added `csharp_raw_string_quotes` state in C# outline parsing.
  - Skips parser work while inside multiline C# raw strings.
  - Teaches `findBraceEnd` to ignore braces inside C# raw strings.
  - Changed language detection so `.csx` maps to `.c_sharp`.
- `src/tests.zig`
  - Added a multiline raw-string fixture containing fake C# declarations and braces.
  - Added `AfterRaw` coverage to prove parsing resumes after the raw string.
  - Added `.csx` detection coverage.
  - Added direct parser-level coverage for raw string state, operator detail, and comment-stripped constants.

## Implemented Improvements

### Parser Module

`src/csharp_parser.zig` is a new allocation-free, line-oriented parser module. Public API:

- `Kind`: `class_def`, `interface_def`, `enum_def`, `struct_def`, `function`, `method`, `variable`, `constant`, `type_alias`
- `Symbol`
- `ParsedLine`
- `parseLine(raw_line)`
- `isVerbatimStringStart(line, quote_index)`
- `rawStringDelimiterLength(line, quote_index)`
- `updateRawStringState(line, raw_quote_count: *usize)`
- `stripAttributeLine(line, in_attribute_block: *bool)`

The parser handles:

- C# comments while respecting normal, interpolated, and verbatim strings.
- Single-line and multi-line attributes.
- `using`, `global using`, `using static`, using aliases, and `extern alias`.
- Qualified and file-scoped namespaces.
- Classes, interfaces, enums, structs, records, record classes, and record structs.
- Delegates.
- Constructors, methods, generic methods, expression-bodied methods, and `where` constraints.
- Qualified return types such as `System.Threading.Tasks.Task<T>` and `global::System.String?`.
- Explicit interface implementations.
- Multi-line method signature starts when the first line is declaration-shaped.
- Operator and conversion declarations with detail such as `operator int`.
- Properties, constants, fields, and events.
- Multiline raw-string field openings.
- Top-level/minimal API invocation false-positive reduction.

### Explorer Integration

`src/explore.zig` now:

- Imports `src/csharp_parser.zig`.
- Tracks C# multi-line attribute blocks in `parseOutlineWithParser`.
- Routes C# lines through the dedicated parser via a thin `parseCSharpLine` wrapper.
- Maps parser kinds through `cSharpSymbolKind`.
- Includes `.c_sharp` in brace-aware symbol range calculation.
- Uses `csharp_parser.isVerbatimStringStart` inside brace matching so braces inside C# verbatim strings do not corrupt `line_end`.

### Tests

`src/tests.zig` now includes expanded C# coverage:

- Modern declarations and member shapes: imports, namespaces, records, interfaces, enums, delegates, constants, events, properties, constructors, generic methods, multi-line signatures, operators, explicit interface implementations, and line ranges.
- False-positive protection for comments, attributes, strings, verbatim strings, raw strings, and interpolated strings.
- Direct parser-level raw string state, operator detail, and comment-stripped constant coverage.
- Minimal API/top-level statement suppression.
- `.cs` and `.csx` language detection.

`.gitignore` now excludes generated Zig package cache entries matching `zig-pkg/mcp_zig-*`.

## Verification Evidence

These focused commands were run successfully after the implementation:

```bash
zig fmt src/csharp_parser.zig src/explore.zig src/tests.zig
git diff --check -- .gitignore src/explore.zig src/csharp_parser.zig src/tests.zig
zig build test -Dtest-filter=csharp
zig build test -Dtest-filter='issue-321'
zig build test -Dtest-filter='detectLanguage: all supported extensions'
zig build test -Dtest-filter='fsharp parser'
```

Do not claim the full suite passes until the remaining failures below are resolved or proven environmental.

## Known Full-Suite Failures

`zig build test` currently runs but fails on three non-C# tests:

- `perf regression: trigram candidate lookup under 1ms per query`
  - Observed failure includes allocator OOM from `cloneOutline` via `getOutline`.
- `perf regression: word index lookup under 100ns per query`
  - Observed failure is a threshold assertion around `ns_per_query < 500`.
- `issue-77: mcp index accepts temporary-directory roots that cause pathological cache growth`
  - Observed failure is `AccessDenied` from `Dir.createDirPath`.

These failures appeared consistently before and after the C# parser refinements. Treat them as outstanding repository/test-environment issues unless new evidence connects them to the C# changes.

## Outstanding Refinements

- The parser is still line-oriented. It handles many declaration starts, but it is not a full C# grammar parser.
- Local functions may be emitted as methods because there is no brace-depth/type-context filter. Decide whether local functions should appear in codedb outlines.
- Multiple field declarations such as `int a, b;` currently emit only one symbol. Improve this if field recall matters.
- Indexers are intentionally skipped to avoid false `index` symbols. If needed, add a stable symbol name such as `this[]` or `Item`.
- Function pointer syntax such as `delegate*` is not specifically modeled.
- C# project dependencies from `.csproj`/MSBuild `PackageReference` are not extracted. This is outside source-line parsing but valuable for C# project discovery.
- Preprocessor directives are only skipped line-by-line. The parser does not evaluate `#if false` blocks, so disabled-code symbols may still appear.
- XML doc comments are ignored; no documentation extraction is implemented.
- Symbol scoping and nesting remain flat because the existing outline model is flat.
- Real-world C# repository benchmarking has not been done yet.

## Suggested Next Steps

1. Re-run the focused verification commands above on the current branch.
2. Inspect `git diff` for the changed files and confirm the shape of the parser matches repository style.
3. Decide whether local functions, indexers, and multiple field declarations should be represented in outlines.
4. Investigate the three full-suite failures separately from the C# parser work, especially because repository guidelines treat benchmark regressions as review-sensitive.

## Cautions for Continuation

- Follow `AGENTS.md` context-mode routing rules for large outputs and analysis.
- Use `apply_patch` for manual edits.
- Do not revert unrelated worktree changes.
- Keep C# parsing allocation-free unless there is a measured reason to change that.
- Run `zig fmt` after Zig edits.
