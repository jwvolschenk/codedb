# codedb — Feasibility Assessment of Agent Feedback (REQ-01 … REQ-11)

> Source: `codedb_requirements.md` (derived from a live navigation session on the
> MyCredoPro ASP.NET Core MVC project).
> This assessment is grounded in the **actual codedb codebase** and judged against the
> hard constraint that codedb must remain **language/framework-agnostic** — MyCredoPro is
> only the stress test, not the target.

## TL;DR triage

| ID | Verdict | Real effort | Gating prerequisite |
|----|---------|-------------|---------------------|
| REQ-04 callers scope bug | ✅ Do now | **Low** (as stated) | none |
| REQ-11 `.codedbignore` visibility | ✅ Do now | **Low** | ignore state already exists |
| REQ-09 hotspot ranking in `ls` | ✅ Do soon | **Low** | reuse dep/symbol indexes |
| REQ-05 JS/TS import deps | ✅ Do soon | **Low–Med** (lower than stated) | remove `..` guard + resolve |
| REQ-01 class hierarchy | ✅ Doable | **Med** (lower than "High") | parse `detail`, no Symbol change |
| REQ-06 grouped outlines | ✅ Doable | **Med** | `#region` capture |
| REQ-10 stub detection | ⚠️ Doable, heuristic | **Low** | depends on dep accuracy |
| REQ-02 route map | ⚠️ Partial / framework-scoped | **Med–High** | needs attribute capture |
| REQ-07 convention lint | ⚠️ Partial (MVP only) | **High** | **Symbol needs `decorators`** |
| REQ-08 config xref | ⚠️ Niche / framework-scoped | **Med** | C#/.NET-specific value |
| REQ-03 per-file semantic summaries | ❗ Re-scope | **High + cost** | LLM inference at index time |

**Cross-cutting prerequisite:** three requirements (REQ-02, REQ-07, and the auth-flag part
of REQ-02) all need one data-model change — capturing **decorators/attributes** on symbols.
Doing that once unlocks all of them. Recommend prioritising it.

---

## Detailed findings

### REQ-04 — `codedb_callers` scope context 🟡 → **fix now, Low effort**

**Root cause (confirmed in code).** `Explorer.findEnclosingSymbolLocked`
(`src/explore.zig`) is *already* containment-based (tightest `line_start ≤ N ≤ line_end`).
The bug is that it ranks candidates by smallest `span = line_end - line_start`, so a
**zero-span symbol** (`L50-L50`) beats the true enclosing method `Index (L40-L65)`.
Those zero-span symbols come from the C# parser indexing a *method call*
(`GetAccountsToolbar(...)`) as if it were a definition — `computeSymbolEnds` →
`findBraceEnd` finds no body brace and leaves `line_end == line_start`.

**Fix (repo-agnostic, targeted).** When resolving an *enclosing scope*, ignore candidates
with `line_end == line_start` (a single line cannot be a block scope); keep them only as the
last-resort fallback. Optionally also prefer container kinds (`method`, `function`,
`class_def`, `struct_def`, `impl_block`, `interface_def`, `trait_def`).
This fixes the reported symptom across every language without touching any parser.

**Note / follow-up.** The deeper cause — C# (and likely TS/JS) parsers emitting false-positive
method symbols for call expressions — also pollutes outlines (relevant to REQ-03/06/10) and
deserves its own issue. The scope fix above is correct regardless.

**Test:** `codedb_callers` on a symbol called inside a multi-line method must report the
method as scope, not a same-line call. Easy to write as a failing test first per CLAUDE.md.

---

### REQ-11 — `.codedbignore` exclusion visibility 🟢 → **fix now, Low effort**

Ignore filtering already exists (referenced in `watcher.zig`, `explore.zig`, `snapshot.zig`).
This REQ only asks to **surface** it. Scope to the cheap, high-value parts:

- Add an `ignore_rules` / `excluded_count` section to `codedb_status` (handler
  `handleStatus`, `src/mcp.zig`). Just echo the already-loaded patterns.
- The "zero results but a match is excluded" hint is nice but more expensive (requires
  walking excluded files on a miss); defer to a follow-up.

Repo-agnostic: yes (pattern list is generic).

---

### REQ-09 — Hotspot ranking in `codedb_ls` 🟢 → **Low effort**

Centrality = importers + callers is already computable from existing indexes
(`DependencyGraph.getImportedBy`, the `symbol_index`, and `getHotFiles`). Add a `ranked`
flag to the `ls` handler that annotates/sorts by `dependents + reference count`.
Caveat: importer counts are only as good as the dep graph, which today under-reports JS
(see REQ-05) and class inheritance (REQ-01) — so **REQ-05/REQ-01 make this materially more
accurate.** Ship after them for best results.

---

### REQ-05 — JavaScript/TS inter-module dependency tracking 🟡 → **lower effort than stated**

**Root cause (confirmed).** `Explorer.rebuildDepsFor` (`src/explore.zig:3417-3422`) does:
```zig
for (outline.imports.items) |imp| {
    if (std.mem.indexOf(u8, imp, "..") != null) continue;   // ← drops every ../ import
    ...
}
```
The `..` guard is a path-traversal safety check that also discards all relative ES6 imports.
TS/JS parsers *do* record import specifiers into `outline.imports`; they just never survive
to the graph. `DependencyGraph.getImportedBy` already resolves by **basename**
(`dependency_graph.zig:84`), so the missing piece is normalising a relative specifier
(`../../scripts/mycredopro.common`) to a basename (`mycredopro.common` / `.js`) instead of
dropping it.

**Approach (repo-agnostic for module languages):**
1. Replace the blanket `..` skip with proper resolution: join the specifier against the
   importing file's directory, normalise (`normalizePath` already exists in
   `explore/parse_utils.zig`), strip to a comparable key, and add extension candidates
   (`.js/.ts/.jsx/.tsx/index.*`).
2. Keep the *security* intent of the guard by clamping resolution to repo root, not by
   dropping the edge.

This generalises to any relative-import language (TS, JS, Python relative, Dart). Aliased/
webpack paths (REQ-05's stretch goal) need tsconfig/webpack parsing — explicitly out of scope
for v1; document as unsupported.

---

### REQ-01 — Class hierarchy / inheritance graph 🔴 → **doable, Med effort (not High)**

**Why it's cheaper than rated:** the base-type information is **already indexed**. For class
symbols, `detail` = the raw declaration line (`parseCSharpLine:2294`,
`appendOutlineSymbol(..., raw_line)`), e.g. `public class OrderController : MyCredoProTraderBaseController`.
So a hierarchy index can be built by post-processing existing `detail` strings — **no parser
or Symbol struct changes required** for the common cases.

**Approach:**
- Add a per-language "extends/implements extractor" that pulls base names from a class
  symbol's `detail`:
  - C#: `: A, B` after the type name (first = base class or interface; resolve by kind).
  - Java/TS: `extends A` / `implements B, C`.
  - Python: `class X(A, B):`.
  - ES6 JS: `class X extends A`.
- Build a `subclass`/`implementor` reverse map keyed by simple type name (same basename
  matching philosophy the dep graph already uses).
- Expose as a new `codedb_hierarchy` action with `direction = subclasses | ancestry |
  implementors` (cleaner than overloading `codedb_deps`, whose semantics are file-level).

**Repo-agnostic caveats:** name resolution is by simple name (no namespace disambiguation),
so two `Foo` types in different namespaces merge — acceptable v1, document it. Generics
(`List<T>`) and partial classes need trimming. Languages without the data (Go, Rust traits)
get empty results gracefully.

**Verdict:** highest-ROI 🔴. Recommend doing this early; it also feeds REQ-09 and REQ-10.

---

### REQ-06 — Grouped / sectioned outlines for large files 🟡 → **Med effort**

Two tiers:
- **Explicit regions** (`#region`/`#endregion` in C#, `// MARK:` in Swift/JS, `//#region`).
  codedb already strips comments during parsing; capturing region markers as section
  boundaries is a focused parser addition and is the most useful tier for this codebase.
- **Inferred grouping** by name-prefix or kind is a pure post-process over the existing flat
  symbol list — cheap and language-agnostic.

`grouped: true` lives entirely in the `outline` handler + a grouping helper; the symbol data
already exists. Recommend shipping inferred-grouping first (no parser work), regions second.
Correct `line_end` values (REQ-04 follow-up) make ranges accurate.

---

### REQ-10 — Stub / skeleton detection 🟢 → **Low effort, heuristic**

Cheap signals already available per file: symbol count, presence of methods beyond ctor,
line count. A `[stub]` annotation gated on a `.codedbrc` threshold is straightforward.
The stronger criteria ("no injected services", "subclass with no overrides") depend on
REQ-01 hierarchy data. Ship the simple heuristic now; enrich after REQ-01.

---

### REQ-02 — Route map 🔴 → **partial; framework-scoped, Med–High**

**Constraint:** routing is inherently framework-specific (ASP.NET attributes, Express
`app.get`, FastAPI decorators, Rails `routes.rb`, Spring `@RequestMapping`). A generic engine
isn't realistic; this is a set of per-framework extractors behind one `codedb_routes` action.

**Gap:** the auth-flag feature (`missing [Authorize]`/`[ValidateAntiForgeryToken]`) needs the
**attribute capture** that the C# parser currently throws away (`stripAttributePrefix`). So
REQ-02's richer half shares REQ-07's prerequisite.

**Recommendation:** scope v1 to **one** framework (ASP.NET Core, since that's the driving
case) deriving routes from controller/action naming + `[HttpGet/Post]` + `[Route]`
attributes (requires attribute capture). Treat Express/FastAPI/Rails/Spring as follow-ups.
Be explicit that this is a framework-plugin surface, not a universal feature.

---

### REQ-07 — Convention compliance / pattern queries 🟡 → **MVP only, High**

The full declarative-rule engine (YAML rules, `require`/`match`) is a sizeable subsystem and
arguably belongs in a linter, not an index. **But the MVP the REQ itself proposes is the
right scope** and is unlocked by one change:

- **Prerequisite:** add a `decorators: [][]const u8` (and optional `bases`) field to `Symbol`,
  and stop discarding attributes in `csharp_parser` (and analogous decorator lines in
  Python/TS). This is the single highest-leverage data-model investment — it enables:
  - `decorator_filter` on `codedb_symbol` (REQ-07 MVP),
  - `[Authorize]`/`[ValidateAntiForgeryToken]` flags (REQ-02),
  - `async without CancellationToken` is derivable from the signature in `detail`.

Recommend implementing **decorator capture** as its own foundational issue, then exposing
`codedb_symbol --decorator/--inherits/--async` filters. Defer the full YAML rule engine.

---

### REQ-08 — Config key cross-reference 🟢 → **niche, framework-scoped, Med**

Valuable but specific to .NET (`appsettings.json` ↔ `IConfiguration`/`IOptions<T>`). The
"defined but never read / read but not defined" diff is genuinely useful but the value
patterns (`Configuration["x"]`, `GetSection`, `GetValue<T>`) are .NET-isms. Lowest priority;
implement only if a .NET-focused workflow justifies a framework plugin.

---

### REQ-03 — Per-file semantic summaries 🔴 → **re-scope before building**

The request says "generate a one-line semantic summary per file." A genuine *semantic*
summary ("CRUD grid for client accounts; AJAX reads…") requires LLM inference, which codedb
does not do and which carries cost, latency, determinism, and offline-operation concerns at
index time over hundreds of files. That conflicts with codedb's design (fast, deterministic,
local index).

**Recommendation — split the requirement:**
- **Deterministic "descriptor" (build now, cheap):** derive a structured one-liner from data
  codedb already has — dominant symbol kinds, public method count, base class (via REQ-01),
  route/attribute presence (via REQ-02/07), stub flag (REQ-10). e.g.
  `AccountsController.cs (c_sharp, 356L, 54 sym) — extends MyCredoProTraderBaseController; 12 actions, 5 POST`.
  This is useful, deterministic, free, and cacheable by hash exactly as the REQ asks.
- **True LLM summaries (out of scope for the index):** if wanted, generate them in the
  *agent layer* and let codedb store/serve them via an optional sidecar
  (`.codedb/summaries.json`), not compute them. Keep inference out of the indexer.

Push back on doing LLM inference inside codedb; deliver the deterministic descriptor instead.

---

## Recommended implementation order

1. **REQ-04** scope fix + **REQ-11** status visibility — quick, self-contained, immediate value.
2. **REQ-05** JS/TS dep resolution (drop the `..` guard) — unblocks accurate centrality.
3. **REQ-01** `codedb_hierarchy` from `detail` — biggest 🔴 win, no model change.
4. **Decorator capture** (Symbol model change) — foundational, then **REQ-07 MVP** filters
   and the auth-flag half of **REQ-02**.
5. **REQ-06** grouped outlines, **REQ-09** ranked ls, **REQ-10** stub flag — polish that
   compounds on 1–3.
6. **REQ-03 descriptor** (deterministic) — after 1–4 supply the inputs.
7. **REQ-02 full routes**, **REQ-08 config xref** — framework plugins, lowest priority.

## Things to push back on / clarify
- **REQ-03**: no LLM inference inside the indexer — deliver a deterministic descriptor; serve
  agent-generated summaries via an optional sidecar if needed.
- **REQ-02 / REQ-07 / REQ-08**: these are framework-specific plugin surfaces, not universal
  features; commit to ASP.NET first and label others as roadmap.
- **REQ-07**: ship the filter MVP, not the YAML rule engine.
- Config file is **`.codedbrc`** (existing), not `.codedbconfig` as the doc assumes — reuse it.
