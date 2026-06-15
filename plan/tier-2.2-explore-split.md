# Tier 2.2 — Detailed execution plan: split `src/explore.zig`

## Status: ✅ Complete

All 7 steps landed as commits `ac79bbd`..`6cb4c4b` on `feature/refactore-glm-5.2`.
`src/explore.zig` went from 5,308 → 451 lines. Each step independently passed
`zig build`, `zig build test`, `zig build bench`, `zig fmt --check`, and the
17-scenario `e2e_mcp_test.py`. Kept here as a record of the member-level
categorization and the delegation pattern, which the same approach can reuse
for Tier 2.3+.

Companion to `plan/refactoring-plan.md` Tier 2.2. Produced by reading the full
`Explorer` struct body (lines 41–5249 of `src/explore.zig`, which is the
*entire* struct — every one of its 166 direct members is either a field (22),
a method/helper (131), or a nested type (13)).

## The extraction pattern (validated in Zig 0.16.0)

A method `fn name(self: *Explorer, ...) T { ... }` moves to `explore/x.zig` as:

```zig
// explore/x.zig
const Explorer = @import("../explore.zig").Explorer;

pub fn name(self: *Explorer, ...) T {
    ... unchanged body ...
}
```

Back in `explore.zig`, inside the `Explorer` struct body, add:

```zig
pub const name = @import("explore/x.zig").name;
```

This preserves `explorer.name(...)` dot-calls from **every** existing caller
(inside explore.zig and in mcp/*.zig, server.zig, main.zig, tests.zig) with
**zero caller-side changes**, because `pub const name = ...` is itself a
declaration in `Explorer`'s namespace — Zig resolves both
`instance.name(...)` and bare sibling calls `name(...)` from other
still-resident Explorer methods through it. Verified with a circular-import
`zig run` smoke test (struct in `a.zig` delegates to a free fn in `b.zig`
that imports `Explorer`/`Foo` back from `a.zig` — compiles and runs).

**Mechanical rules per moved member:**
1. The moved fn becomes `pub fn` in its new file (even if it was private
   `fn` before) — required for `@import(...).name` to work. This *widens*
   visibility at file scope; it does not violate "no public API removal"
   (the `@import("explore.zig").Explorer.name` surface is unchanged).
2. Any bare-identifier call inside the moved body to **another Explorer
   member that is not moving to the same new file** must be qualified as
   `Explorer.theName(...)` (works once that member has its own `pub const`
   delegation, regardless of whether it physically still lives in
   `explore.zig` or was moved to yet another file).
3. Any bare-identifier call to a **file-level alias in explore.zig**
   (e.g. `extractIdent`, `startsWith`, `parse_utils.*` — see the block of
   `const X = parse_utils.X;` aliases near the end of explore.zig) needs its
   own import in the new file, e.g. `const parse_utils = @import("parse_utils.zig");`
   (same-directory import since both live under `src/explore/`).
4. Extraction order across the 7 steps below is **unconstrained** —
   correctness doesn't depend on which step runs first.

## Full member table

Columns: `start–end | #lines | kind | name | first_param | target`

```
  42-  42    1 field        outlines                                              KEEP (field)
  43-  43    1 field        dep_graph                                             KEEP (field)
  44-  44    1 field        contents                                              KEEP (field)
  45-  45    1 field        symbol_index                                          KEEP (field)
  46-  46    1 field        word_index                                            KEEP (field)
  47-  47    1 field        trigram_index                                         KEEP (field)
  48-  48    1 field        sparse_ngram_index                                    KEEP (field)
  49-  49    1 field        type_index                                            KEEP (field)
  50-  50    1 field        type_graph                                            KEEP (field)
  53-  53    1 field        skip_trigram_files                                    KEEP (field)
  54-  54    1 field        ignore_patterns                                       KEEP (field)
  58-  58    1 field        codedbignore_hash                                     KEEP (field)
  59-  59    1 field        allocator                                             KEEP (field)
  60-  60    1 field        word_index_complete                                   KEEP (field)
  61-  61    1 field        word_index_can_load_from_disk                         KEEP (field)
  62-  62    1 field        word_index_generation                                 KEEP (field)
  63-  63    1 field        word_index_persisted_generation                       KEEP (field)
  64-  64    1 field        mu                                                    KEEP (field)
  65-  65    1 field        root_dir                                              KEEP (field)
  66-  66    1 field        io                                                    KEEP (field)
  70-  70    1 field        content_cache_limit                                   KEEP (field)
  74-  74    1 field        rerank_trace_path                                     KEEP (field)
  76-  79    4 fn           setRoot                          self: *Explorer      KEEP
  80-  94   15 fn           init                             allocator            KEEP
  96- 125   30 fn           deinit                           self: *Explorer      KEEP
 127- 139   13 fn           setIgnorePatterns                self: *Explorer      KEEP
 141- 156   16 fn           getIgnorePatterns                self: *Explorer      KEEP
 159- 164    6 fn           trigramIdToPathLen               self: *Explorer      KEEP
 167- 172    6 fn           trigramFreeIdsLen                self: *Explorer      KEEP
 173- 177    5 fn           releaseContents                  self: *Explorer      lifecycle.zig
 179- 184    6 fn           releaseSecondaryIndexes          self: *Explorer      lifecycle.zig
 186- 188    3 fn           indexFile                        self: *Explorer      lifecycle.zig
 191- 193    3 fn           indexFileOutlineOnly             self: *Explorer      lifecycle.zig
 196- 198    3 fn           indexFileSkipTrigram             self: *Explorer      lifecycle.zig
 200- 270   71 fn           commitParsedFileOwnedOutline     self: *Explorer      lifecycle.zig
 272- 314   43 fn           computeSymbolEnds                content: []const u8  lifecycle.zig
 316- 443  128 fn           findBraceEnd                     content: []const u8  lifecycle.zig
 445- 492   48 fn           findPythonEnd                    content: []const u8  lifecycle.zig
 494- 514   21 fn           findRubyEnd                      content: []const u8  lifecycle.zig
 516- 523    8 fn           countIndent                      content: []const u8  lifecycle.zig
 525- 863  339 fn           parseOutlineWithParser           parser: *Explorer    lifecycle.zig
 865- 880   16 fn           parseContentForIndexing          allocator            lifecycle.zig
 886- 930   45 fn           collapseConsecutiveProperties    allocator            lifecycle.zig
 932- 944   13 fn           collectCSharpDecorators          allocator            lifecycle.zig
 946- 972   27 fn           findCSharpDecoratorClose         s: []const u8        lifecycle.zig
 974- 979    6 fn           attachDecoratorsToSymbols        allocator            lifecycle.zig
 981- 984    4 fn           clearDecoratorList               allocator            lifecycle.zig
 986- 989    4 fn           indexFileInner                   self: *Explorer      lifecycle.zig
 992-1012   21 fn           rebuildTrigrams                  self: *Explorer      lifecycle.zig
1017-1070   54 fn           rebuildWordIndex                 self: *Explorer      lifecycle.zig
1072-1079    8 fn           markWordIndexIncomplete          self: *Explorer      lifecycle.zig
1083-1089    7 fn           markWordIndexAsComplete          self: *Explorer      lifecycle.zig
1091-1097    7 fn           disableWordIndexDiskLoad         self: *Explorer      lifecycle.zig
1099-1103    5 fn           wordIndexCanLoadFromDisk         self: *Explorer      lifecycle.zig
1105-1109    5 fn           wordIndexIsComplete              self: *Explorer      lifecycle.zig
1111-1115    5 fn           wordIndexNeedsPersist            self: *Explorer      lifecycle.zig
1117-1123    7 fn           wordIndexGenerationToPersist     self: *Explorer      lifecycle.zig
1125-1131    7 fn           markWordIndexPersisted           self: *Explorer      lifecycle.zig
1133-1142   10 fn           replaceWordIndex                 self: *Explorer      lifecycle.zig
1144-1176   33 fn           removeFile                       self: *Explorer      lifecycle.zig
1178-1184    7 fn           getOutline                       self: *Explorer      KEEP
1187-1193    7 fn           getContent                       self: *Explorer      KEEP
1195-1203    9 type_struct  ContentRef                                            lifecycle.zig
1206-1214    9 fn           readContentForSearch             self: *Explorer      lifecycle.zig
1216-1259   44 fn           cloneOutline                     src: *const FileOutl lifecycle.zig
1261-1274   14 fn           cloneDecorators                  allocator            lifecycle.zig
1276-1279    4 fn           freeDecorators                   allocator            lifecycle.zig
1281-1294   14 fn           cloneParamTypes                  allocator            lifecycle.zig
1296-1299    4 fn           freeParamTypes                   allocator            lifecycle.zig
1301-1367   67 fn           getTree                          self: *Explorer      tree.zig
1369-1435   67 fn           findSymbol                       self: *Explorer      deps.zig
1437-1520   84 fn           findAllSymbols                   self: *Explorer      deps.zig
1522-1742  221 fn           searchContent                    self: *Explorer      search.zig
1749-1770   22 fn           rerankAndFinalize                self: *const Explorer search.zig
1773-1820   48 fn           rerankSignalScore                self: *const Explorer search.zig
1827-1905   79 fn           appendRerankTrace                self: *const Explorer search.zig
1912-2085  174 fn           searchContentRanked              self: *Explorer      search.zig
2090-2143   54 fn           searchContentRegex               self: *Explorer      search.zig
2146-2158   13 fn           searchWord                       self: *Explorer      search.zig
2160-2163    4 type_struct  FuzzyMatch                                            search.zig
2165-2234   70 fn           fuzzyFindFiles                   self: *Explorer      search.zig
2236-2246   11 type_struct  LsEntry                                               tree.zig
2248-2277   30 fn           globPaths                        self: *Explorer      tree.zig
2279-2362   84 fn           lsDir                            self: *Explorer      tree.zig
2364-2382   19 fn           lsDirHotspotScore                self: *Explorer      tree.zig
2384-2388    5 fn           isStubLikeOutline                outline: *const Fil  tree.zig
2390-2449   60 fn           buildOutlineDescriptor           allocator            tree.zig
2451-2455    5 fn           appendFmt                        allocator            tree.zig
2457-2462    6 fn           decoratorsContainText             decorators           tree.zig
2464-2472    9 fn           extractBaseDescriptor            detail: ?[]const u8  tree.zig
2474-2479    6 fn           isStubCandidateLanguage          lang: Language       tree.zig
2481-2485    5 fn           getImportedBy                    self: *Explorer      deps.zig
2487-2491    5 fn           getTransitiveDependents          self: *Explorer      deps.zig
2493-2497    5 fn           getTransitiveDependencies        self: *Explorer      deps.zig
2499-2545   47 fn           getHotFiles                      self: *Explorer      deps.zig
2552-2552    1 type_struct  ZigTypes                                              type_extract.zig
2553-2620   68 fn           extractZigFuncTypes              line: []const u8     type_extract.zig
2622-2677   56 fn           parseZigLine                     self: *Explorer      parsers/systems.zig (NEW)
2682-2682    1 type_struct  PyTypes                                               type_extract.zig
2683-2748   66 fn           extractPythonFuncTypes           line: []const u8     type_extract.zig
2750-2804   55 fn           parsePythonLine                  self: *Explorer      parsers/scripting.zig
2809-2809    1 type_struct  TsTypes                                               type_extract.zig
2810-2877   68 fn           extractTsFunctionTypes           line: []const u8     type_extract.zig
2881-2899   19 fn           extractTsParamType               param: []const u8    type_extract.zig
2901-2968   68 fn           parseTsLine                      self: *Explorer      parsers/web.zig
2970-2990   21 fn           stripJavaModifiers               s: []const u8        type_extract.zig
2993-3003   11 fn           extractJvmParamType              param: []const u8    type_extract.zig
3008-3008    1 type_struct  JvmTypes                                              type_extract.zig
3009-3071   63 fn           extractJvmFuncTypes              line: []const u8     type_extract.zig
3073-3097   25 fn           parseJavaLine                    self: *Explorer      parsers/jvm.zig
3102-3102    1 type_struct  KtTypes                                               type_extract.zig
3103-3168   66 fn           extractKotlinFuncTypes           line: []const u8     type_extract.zig
3170-3198   29 fn           parseKotlinLine                  self: *Explorer      parsers/jvm.zig
3200-3228   29 fn           parseCSharpLine                  self: *Explorer      parsers/csharp_family.zig
3232-3239    8 fn           extractCSharpEnumValue           raw_line: []const u8 parsers/csharp_family.zig
3241-3248    8 fn           parseFSharpLine                  self: *Explorer      parsers/csharp_family.zig
3254-3418  165 fn           parseRazorLine                   self: *Explorer      parsers/csharp_family.zig
3422-3440   19 fn           razorIsControlFlow               line: []const u8     parsers/csharp_family.zig
3446-3461   16 fn           extractRazorInjectType           line: []const u8     parsers/csharp_family.zig
3463-3484   22 fn           parseSwiftLine                   self: *Explorer      parsers/clang.zig
3486-3496   11 fn           parseComponentLine               self: *Explorer      parsers/web.zig
3498-3527   30 fn           parseShellLine                   self: *Explorer      parsers/web.zig
3529-3545   17 fn           parseStyleLine                   self: *Explorer      parsers/web.zig
3547-3555    9 fn           parseSqlLine                     self: *Explorer      parsers/declarative.zig
3557-3573   17 fn           parseProtoLine                   self: *Explorer      parsers/declarative.zig
3575-3593   19 fn           parseFortranLine                 self: *Explorer      parsers/declarative.zig
3595-3607   13 fn           parseLlvmIrLine                  self: *Explorer      parsers/declarative.zig
3609-3619   11 fn           parseMlirLine                    self: *Explorer      parsers/declarative.zig
3621-3639   19 fn           parseTableGenLine                self: *Explorer      parsers/declarative.zig
3641-3688   48 fn           parseCLine                       self: *Explorer      parsers/clang.zig
3693-3693    1 type_struct  RustTypes                                             type_extract.zig
3694-3759   66 fn           extractRustFuncTypes             line: []const u8     type_extract.zig
3761-3959  199 fn           parseRustLine                    self: *Explorer      parsers/systems.zig (NEW)
3961-4053   93 fn           parsePhpLine                     self: *Explorer      parsers/scripting.zig
4055-4101   47 fn           parsePhpUseImport                _: *Explorer         parsers/scripting.zig
4103-4109    7 fn           phpStripAlias                    s: []const u8        parsers/scripting.zig
4111-4126   16 fn           phpMatchConstant                 _: *Explorer         parsers/scripting.zig
4128-4131    4 type_struct  PhpClassMatch                                         parsers/scripting.zig
4133-4152   20 fn           phpMatchClassLike                _: *Explorer         parsers/scripting.zig
4157-4157    1 type_struct  GoTypes                                               type_extract.zig
4158-4271  114 fn           extractGoFuncTypes               line: []const u8     type_extract.zig
4275-4289   15 fn           extractGoParamType               param: []const u8    type_extract.zig
4291-4381   91 fn           parseGoLine                      self: *Explorer      parsers/systems.zig (NEW)
4383-4594  212 fn           parseDartLine                    self: *Explorer      parsers/declarative.zig  (contains local TypeDecl, moves with it)
4596-4660   65 fn           parseRubyLine                    self: *Explorer      parsers/scripting.zig
4662-4719   58 fn           parseHclLine                     self: *Explorer      parsers/declarative.zig
4721-4764   44 fn           parseRLine                       self: *Explorer      parsers/declarative.zig
4766-4801   36 fn           rebuildDepsFor                   self: *Explorer      deps.zig
4806-4825   20 fn           resolveSqlDepKey                 self: *Explorer      deps.zig
4827-4829    3 type_struct  DependencyKey                                         deps.zig
4831-4848   18 fn           resolveDependencyKey             path: []const u8     deps.zig
4850-4892   43 fn           rebuildSymbolIndexFor             self: *Explorer      deps.zig
4896-4902    7 fn           rebuildTypeIndexes                self: *Explorer      deps.zig
4906-4914    9 fn           buildTypeGraphForFile             self: *Explorer      deps.zig
4917-4939   23 fn           extractAndRecordBases             graph: *TypeGraph    deps.zig
4941-4954   14 fn           findBasePortion                   detail: []const u8   deps.zig
4958-4968   11 fn           symbolNameMatches                 sym_name: []const u8 deps.zig
4970-4976    7 fn           isHierarchyKeyword                token: []const u8    deps.zig
4978-5001   24 fn           removeSymbolIndexFor              self: *Explorer      deps.zig
5005-5011    7 fn           getSymbolBody                      self: *Explorer      deps.zig
5015-5064   50 fn           findEnclosingSymbolLocked          self: *Explorer      deps.zig
5066-5074    9 type_struct  ScopedSearchResult                                    search.zig
5077-5123   47 fn           searchContentWithScope             self: *Explorer      search.zig
5127-5187   61 fn           searchContentRegexWithScope        self: *Explorer      search.zig
5189-5216   28 fn           searchInContentWithScope           self: *Explorer      search.zig
5218-5248   31 fn           searchInContentRegexWithScope      self: *Explorer      search.zig
```

## Deviations from `refactoring-plan.md`'s literal Tier 2.2 text (judgment calls)

1. **New `parsers/systems.zig`** (Zig/Rust/Go — `parseZigLine`, `parseRustLine`,
   `parseGoLine`, 346 lines). The plan's 7 named families never mention
   Zig/Rust/Go; this is the natural 8th bucket.
2. **`jvm_static.zig` dropped** — its would-be contents
   (`stripJavaModifiers`, `extractJvmParamType`) fold into `type_extract.zig`
   alongside the other `extractXFuncTypes` helpers.
3. **`findSymbol`/`findAllSymbols`/`getSymbolBody`/`findEnclosingSymbolLocked`**
   (206 lines, not named in the plan) → `deps.zig`, alongside
   `rebuildSymbolIndexFor`/`removeSymbolIndexFor`.
4. **`rerankAndFinalize`/`ScopedSearchResult`/`searchContentRegexWithScope`/
   `searchInContentWithScope`/`searchInContentRegexWithScope`** (171 lines,
   not named) → `search.zig`.
5. **Tree descriptor helpers** `appendFmt`/`decoratorsContainText`/
   `extractBaseDescriptor`/`isStubCandidateLanguage`/`isStubLikeOutline`
   (31 lines) → `tree.zig`.
6. **Word-index lifecycle** (`rebuildTrigrams`, `rebuildWordIndex`,
   `markWordIndex*`, `wordIndex*`, `replaceWordIndex` — 11 fns, ~127 lines,
   not named) → `lifecycle.zig`.
7. `getOutline`/`getContent`/`trigramIdToPathLen`/`trigramFreeIdsLen` → KEEP
   (small accessors, alongside init/deinit/setRoot/setIgnorePatterns).

## Step plan (7 commits — "Tier 2.2 (step N/7)")

| Step | Target file(s) | Members | ~Lines |
|---|---|---|---|
| 1/7 | `explore/type_extract.zig` | 7 `extractXFuncTypes` + 7 `XTypes` structs + `extractTsParamType`, `extractJvmParamType`, `extractGoParamType`, `stripJavaModifiers` (18) | 584 |
| 2/7 | `explore/parsers/jvm.zig`, `clang.zig`, `web.zig`, `systems.zig` (new) | parseJavaLine, parseKotlinLine, parseCLine, parseSwiftLine, parseTsLine, parseComponentLine, parseShellLine, parseStyleLine, parseZigLine, parseRustLine, parseGoLine (11) | 596 |
| 3/7 | `explore/parsers/csharp_family.zig`, `scripting.zig`, `declarative.zig` | 6 C#/F#/Razor + 8 Ruby/PHP/Python + 9 HCL/R/SQL/Proto/Fortran/LLVM/MLIR/TableGen/Dart (23) | 954 |
| 4/7 | `explore/tree.zig` | getTree, globPaths, lsDir, lsDirHotspotScore, buildOutlineDescriptor + 5 descriptor helpers + LsEntry (11) | 302 |
| 5/7 | `explore/deps.zig` | 16 named deps fns + findSymbol/findAllSymbols/getSymbolBody/findEnclosingSymbolLocked + DependencyKey (20) | 485 |
| 6/7 | `explore/search.zig` | 9 named search fns + rerankAndFinalize + 4 scoped-search fns + FuzzyMatch/ScopedSearchResult (14) | 861 |
| 7/7 | `explore/lifecycle.zig` | indexFile*, removeFile, commit/clone/free/parseOutline/parseContent, decorator helpers, word-index lifecycle, ContentRef (38) | 1060 |

After all 7 steps, `explore.zig` retains: imports/aliases, the `Explorer`
struct shell (22 fields), `setRoot`/`init`/`deinit`/`setIgnorePatterns`/
`getIgnorePatterns`/`trigramIdToPathLen`/`trigramFreeIdsLen`/`getOutline`/
`getContent` (~104 lines of real code), plus ~166 `pub const name =
@import("explore/x.zig").name;` delegation lines — roughly 350–400 lines.

## Verification per step (from `refactoring-plan.md`)

```bash
zig build test
zig build
zig build bench   # must not regress >10%
python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /home/jwvolschenk/repos/codedb
```
