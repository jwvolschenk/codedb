# Autumn Parsers Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add codedb parsers for Autumn's proprietary XML-based file formats (.adm, .acfg, .adpt, .arc) so the Autumn project gets meaningful code intelligence beyond "unknown file".

**Architecture:** Four new line-based parsers in a single `autumn_parser.zig` file. All four formats share the same XML namespace (`http://schemas.autumn-software.com/amd`) and follow similar patterns — XML tags with named attributes. One parser file keeps them DRY. Each format gets its own `Kind` enum variant and `parseLine` dispatch.

**Tech Stack:** Zig (codedb_custom fork), XML attribute extraction, line-based parsing.

---

## Context

The Autumn project (~/repos/credo_main/src/Autumn/) has 42 active sub-projects
defined in Autumn.sln. The codebase uses four proprietary XML file formats:

| Format | Count | Purpose | Root Element |
|--------|-------|---------|--------------|
| .adm   | 74    | Data model definitions (entities, attributes, types) | `<autumnDataModel>` |
| .acfg  | 119   | Environment configuration (hosts, DBs, settings) | `<autumnConfiguration>` |
| .adpt  | 123   | Adapter workflow definitions (state machines) | `<autumnAdapterConfiguration>` |
| .arc   | 22    | Rule collection catalogs (ordered rule sets) | `<autumnRuleSetCatalog>` |

Currently all 338 files show as "unknown" in codedb. The .adm parser is the
highest-value target — it defines the entire data model backbone.

### Key Relationships
- `.acfg` defines template variables (`{{varName}}`) consumed by `.adpt`
- `.adpt` references `.acfg` via `HOST|hostName`, `DBC|catalogName`, `{{settingKey}}`
- `.arc` references rules by name (`RUL|Rulename`) that map to .fs/.eq logic
- `.aproj` ties everything together via `<acfgCompile>`, `<admCompile>`, `<adptCompile>`

---

## Parser Design

### Symbol Extraction Targets

**.adm (Data Model):**
- `entitySchema` → kind: `struct_def`, name: schema name, detail: `isSystemEntity`
- `entity` → kind: `class_def`, name: entity name, detail: entityTypeId + schema ref
- `entityAttribute` → kind: `variable`, name: attribute name, detail: attributeTypeId

**.acfg (Config):**
- `configuration` → kind: `namespace`, name: configurationName (Debug/Dev/Release/etc)
- `databaseCatalog` → kind: `variable`, name: catalog key, detail: server/database
- `messageQueueCatalog` → kind: `variable`, name: queue name, detail: queue type
- `setting` → kind: `constant`, name: key, detail: value (truncated)

**.adpt (Adapter):**
- Component (state machine node) → kind: `class_def`, name: stateName, detail: componentType
- `setting` within component → kind: `constant`, name: key, detail: value (truncated)

**.arc (Rule Collection):**
- `ruleSet` → kind: `class_def`, name: ruleSetName, detail: ruleSetDescription
- `ruleReference` → kind: `variable`, name: ruleName, detail: ruleOrder

### XML Attribute Extraction Helper

All four formats need to extract named attributes from XML tags. A shared helper:
```zig
fn extractXmlAttribute(line: []const u8, attr_name: []const u8) ?[]const u8
```
Searches for `attr_name="` and returns the value up to the closing quote.

---

## Tasks

### Task 1: Create `src/autumn_parser.zig` with Language enum additions

**Objective:** Add .adm/.acfg/.adpt/.arc extensions to Language enum and detectLanguage.

**Files:**
- Create: `src/autumn_parser.zig`
- Modify: `src/explore/types.zig:86-163` (Language enum + detectLanguage)

**Step 1: Add Language variants**

In `src/explore/types.zig`, add after `razor,` (line 121):
```zig
    autumn_adm,
    autumn_acfg,
    autumn_adpt,
    autumn_arc,
```

**Step 2: Add detectLanguage entries**

In `detectLanguage()`, add before `return .unknown;` (line 163):
```zig
    if (std.mem.endsWith(u8, path, ".adm")) return .autumn_adm;
    if (std.mem.endsWith(u8, path, ".acfg")) return .autumn_acfg;
    if (std.mem.endsWith(u8, path, ".adpt")) return .autumn_adpt;
    if (std.mem.endsWith(u8, path, ".arc")) return .autumn_arc;
```

**Step 3: Create `src/autumn_parser.zig`**

Minimal skeleton:
```zig
const std = @import("std");

pub const Kind = enum {
    entity_schema,
    entity,
    entity_attribute,
    configuration,
    database_catalog,
    message_queue,
    setting,
    rule_set,
    rule_reference,
    component,
};

pub fn extractXmlAttribute(line: []const u8, attr_name: []const u8) ?[]const u8 {
    // Find attr_name=" in the line
    var search_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "{s}=\"", .{attr_name}) catch return null;
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOf(u8, line[value_start..], "\"") orelse return null;
    return line[value_start..][0..value_end];
}
```

**Step 4: Verify build compiles**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

**Step 5: Commit**

```bash
git add src/autumn_parser.zig src/explore/types.zig
git commit -m "feat(autumn): add autumn_adm/acfg/adpt/arc language variants and parser skeleton"
```

---

### Task 2: Implement .adm parser

**Objective:** Parse .adm files extracting entity schemas, entities, and attributes.

**Files:**
- Modify: `src/autumn_parser.zig`
- Modify: `src/explore.zig:521-720` (parseOutlineWithParser dispatch)
- Modify: `src/explore.zig:282-291` (is_brace_lang — do NOT add, XML is not brace-based)

**Step 1: Implement parseAdmLine in autumn_parser.zig**

```zig
pub fn parseAdmLine(allocator: std.mem.Allocator, trimmed: []const u8, line_num: u32, outline: anytype) !void {
    // Entity schema: <entitySchema isSystemEntity="True" entitySchemaName="Audit" />
    if (std.mem.indexOf(u8, trimmed, "<entitySchema ") != null) {
        const name = extractXmlAttribute(trimmed, "entitySchemaName") orelse return;
        const is_sys = extractXmlAttribute(trimmed, "isSystemEntity");
        var detail: ?[]const u8 = null;
        if (is_sys) |sys| {
            detail = try std.fmt.allocPrint(allocator, "isSystem={s}", .{sys});
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .struct_def,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }

    // Entity: <entity schema="SCH|Audit" entityName="CommandLog" entityTypeId="Table" ...>
    if (std.mem.indexOf(u8, trimmed, "<entity ") != null and
        std.mem.indexOf(u8, trimmed, "<entityAttributes>") == null and
        std.mem.indexOf(u8, trimmed, "<entityAttribute ") == null)
    {
        const name = extractXmlAttribute(trimmed, "entityName") orelse return;
        const etype = extractXmlAttribute(trimmed, "entityTypeId");
        const schema = extractXmlAttribute(trimmed, "schema");
        var detail_buf: std.ArrayList(u8) = .empty;
        defer detail_buf.deinit(allocator);
        if (etype) |t| {
            try detail_buf.appendSlice(allocator, t);
        }
        if (schema) |s| {
            if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, " ");
            // Strip "SCH|" prefix for readability
            const schema_clean = if (std.mem.startsWith(u8, s, "SCH|")) s[4..] else s;
            try detail_buf.appendSlice(allocator, schema_clean);
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (detail_buf.items.len > 0) try allocator.dupe(u8, detail_buf.items) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .class_def,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }

    // Entity attribute: <entityAttribute ... entityAttributeName="ID" attributeTypeId="INT" isPrimaryKey="True" ...>
    if (std.mem.indexOf(u8, trimmed, "<entityAttribute ") != null) {
        const name = extractXmlAttribute(trimmed, "entityAttributeName") orelse return;
        const atype = extractXmlAttribute(trimmed, "attributeTypeId");
        const is_pk = extractXmlAttribute(trimmed, "isPrimaryKey");
        var detail_buf: std.ArrayList(u8) = .empty;
        defer detail_buf.deinit(allocator);
        if (atype) |t| {
            try detail_buf.appendSlice(allocator, t);
        }
        if (is_pk) |pk| {
            if (std.mem.eql(u8, pk, "True")) {
                if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, " ");
                try detail_buf.appendSlice(allocator, "PK");
            }
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (detail_buf.items.len > 0) try allocator.dupe(u8, detail_buf.items) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .variable,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }
}
```

**Step 2: Wire into parseOutlineWithParser in explore.zig**

Add import at top of explore.zig:
```zig
const autumn_parser = @import("autumn_parser.zig");
```

Add dispatch in `parseOutlineWithParser` after the razor block (around line 714):
```zig
            } else if (outline.language == .autumn_adm) {
                try autumn_parser.parseAdmLine(parser.allocator, trimmed, line_num, &outline);
            } else if (outline.language == .autumn_acfg) {
                try autumn_parser.parseAcfgLine(parser.allocator, trimmed, line_num, &outline);
            } else if (outline.language == .autumn_adpt) {
                try autumn_parser.parseAdptLine(parser.allocator, trimmed, line_num, &outline);
            } else if (outline.language == .autumn_arc) {
                try autumn_parser.parseArcLine(parser.allocator, trimmed, line_num, &outline);
            }
```

Note: Add stubs for parseAcfgLine, parseAdptLine, parseArcLine that return immediately (implemented in later tasks).

**Step 3: Build and verify**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

**Step 4: Commit**

```bash
git add src/autumn_parser.zig src/explore.zig
git commit -m "feat(autumn): implement .adm parser — entity schemas, entities, attributes"
```

---

### Task 3: Implement .acfg parser

**Objective:** Parse .acfg files extracting configurations, database catalogs, message queues, and settings.

**Files:**
- Modify: `src/autumn_parser.zig`

**Step 1: Implement parseAcfgLine**

```zig
pub fn parseAcfgLine(allocator: std.mem.Allocator, trimmed: []const u8, line_num: u32, outline: anytype) !void {
    // Configuration: <configuration configurationName="Debug">
    if (std.mem.indexOf(u8, trimmed, "<configuration ") != null and
        std.mem.indexOf(u8, trimmed, "configurationName") != null)
    {
        const name = extractXmlAttribute(trimmed, "configurationName") orelse return;
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .namespace,
            .line_start = line_num,
            .line_end = line_num,
            .detail = null,
        });
        return;
    }

    // Database catalog: <databaseCatalog ... key="AutumnDotNet" server="..." database="...">
    if (std.mem.indexOf(u8, trimmed, "<databaseCatalog ") != null) {
        const name = extractXmlAttribute(trimmed, "key") orelse return;
        const server = extractXmlAttribute(trimmed, "server");
        const db = extractXmlAttribute(trimmed, "database");
        var detail_buf: std.ArrayList(u8) = .empty;
        defer detail_buf.deinit(allocator);
        if (server) |s| try detail_buf.appendSlice(allocator, s);
        if (db) |d| {
            if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, "/");
            try detail_buf.appendSlice(allocator, d);
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (detail_buf.items.len > 0) try allocator.dupe(u8, detail_buf.items) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .variable,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }

    // Message queue: <messageQueueCatalog ... messageQueueName="..." messageQueueType="...">
    if (std.mem.indexOf(u8, trimmed, "<messageQueueCatalog ") != null) {
        const name = extractXmlAttribute(trimmed, "messageQueueName") orelse return;
        const qtype = extractXmlAttribute(trimmed, "messageQueueType");
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (qtype) |t| try allocator.dupe(u8, t) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .variable,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }
}
```

**Step 2: Build and verify**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add src/autumn_parser.zig
git commit -m "feat(autumn): implement .acfg parser — configurations, DB catalogs, message queues"
```

---

### Task 4: Implement .adpt parser

**Objective:** Parse .adpt files extracting adapter components (state machine nodes).

**Files:**
- Modify: `src/autumn_parser.zig`

**Step 1: Implement parseAdptLine**

```zig
pub fn parseAdptLine(allocator: std.mem.Allocator, trimmed: []const u8, line_num: u32, outline: anytype) !void {
    // Component: <component ... stateName="BcpTableToWork" name="BcpTableToWork" componentGuid="..." componentType="1">
    if (std.mem.indexOf(u8, trimmed, "<component ") != null and
        std.mem.indexOf(u8, trimmed, "stateName") != null)
    {
        const name = extractXmlAttribute(trimmed, "stateName") orelse return;
        const ctype = extractXmlAttribute(trimmed, "componentType");
        const is_branch = extractXmlAttribute(trimmed, "isBranchCondition");
        var detail_buf: std.ArrayList(u8) = .empty;
        defer detail_buf.deinit(allocator);
        if (ctype) |t| {
            try detail_buf.appendSlice(allocator, "type=");
            try detail_buf.appendSlice(allocator, t);
        }
        if (is_branch) |b| {
            if (std.mem.eql(u8, b, "true")) {
                if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, " ");
                try detail_buf.appendSlice(allocator, "branch");
            }
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (detail_buf.items.len > 0) try allocator.dupe(u8, detail_buf.items) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .class_def,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }
}
```

**Step 2: Build and verify**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add src/autumn_parser.zig
git commit -m "feat(autumn): implement .adpt parser — adapter components (state machine nodes)"
```

---

### Task 5: Implement .arc parser

**Objective:** Parse .arc files extracting rule sets and rule references.

**Files:**
- Modify: `src/autumn_parser.zig`

**Step 1: Implement parseArcLine**

```zig
pub fn parseArcLine(allocator: std.mem.Allocator, trimmed: []const u8, line_num: u32, outline: anytype) !void {
    // Rule set: <ruleSet ruleSetDescription="..." ruleSetName="AxysEtlToAutumn" isSystemEntity="False">
    if (std.mem.indexOf(u8, trimmed, "<ruleSet ") != null and
        std.mem.indexOf(u8, trimmed, "ruleSetName") != null)
    {
        const name = extractXmlAttribute(trimmed, "ruleSetName") orelse return;
        const desc = extractXmlAttribute(trimmed, "ruleSetDescription");
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        // Truncate description to keep outline compact
        const detail = if (desc) |d| blk: {
            const max_len: usize = 80;
            if (d.len <= max_len) {
                break :blk try allocator.dupe(u8, d);
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}...", .{d[0..max_len]});
            }
        } else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .class_def,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }

    // Rule reference: <ruleReference ... ruleOrder="1" ruleName="MapAxysTransactions" />
    if (std.mem.indexOf(u8, trimmed, "<ruleReference ") != null) {
        const name = extractXmlAttribute(trimmed, "ruleName") orelse return;
        const order = extractXmlAttribute(trimmed, "ruleOrder");
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const detail = if (order) |o| try std.fmt.allocPrint(allocator, "order={s}", .{o}) else null;
        try outline.appendSymbol(allocator, .{
            .name = name_copy,
            .kind = .variable,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail,
        });
        return;
    }
}
```

**Step 2: Build and verify**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add src/autumn_parser.zig
git commit -m "feat(autumn): implement .arc parser — rule sets and rule references"
```

---

### Task 6: Add tests

**Objective:** Verify all four parsers extract correct symbols from sample input.

**Files:**
- Modify: `src/tests.zig`

**Step 1: Add language detection tests**

```zig
// Autumn file type detection
try expect(detectLanguage("System.adm") == .autumn_adm);
try expect(detectLanguage("SqlBulkExporter.acfg") == .autumn_acfg);
try expect(detectLanguage("APIadapter.adpt") == .autumn_adpt);
try expect(detectLanguage("AxysRuleSets.arc") == .autumn_arc);
```

**Step 2: Add .adm outline test**

```zig
test "autumn adm parser extracts entities and attributes" {
    const alloc = std.testing.allocator;
    const content =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<autumnDataModel xmlns="http://schemas.autumn-software.com/amd">
        \\  <entitySchemas>
        \\    <entitySchema isSystemEntity="True" entitySchemaName="Audit" />
        \\  </entitySchemas>
        \\  <entities>
        \\    <entity schema="SCH|Audit" entityName="CommandLog" entityTypeId="Table">
        \\      <entityAttributes>
        \\        <entityAttribute entityAttributeName="ID" attributeTypeId="INT" isPrimaryKey="True" />
        \\        <entityAttribute entityAttributeName="DatabaseName" attributeTypeId="NVARCHAR" isNullable="True" />
        \\      </entityAttributes>
        \\    </entity>
        \\  </entities>
        \\</autumnDataModel>
    ;
    var parser = Explorer.init(alloc);
    defer parser.deinit();
    const outline = try parser.indexFile("System.adm", content);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 4), outline.symbols.items.len);

    // entitySchema
    try std.testing.expectEqualStrings("Audit", outline.symbols.items[0].name);
    try std.testing.expect(outline.symbols.items[0].kind == .struct_def);

    // entity
    try std.testing.expectEqualStrings("CommandLog", outline.symbols.items[1].name);
    try std.testing.expect(outline.symbols.items[1].kind == .class_def);

    // attributes
    try std.testing.expectEqualStrings("ID", outline.symbols.items[2].name);
    try std.testing.expect(outline.symbols.items[2].kind == .variable);

    try std.testing.expectEqualStrings("DatabaseName", outline.symbols.items[3].name);
    try std.testing.expect(outline.symbols.items[3].kind == .variable);
}
```

**Step 3: Add .acfg, .adpt, .arc tests (similar pattern)**

**Step 4: Run tests**

```bash
cd ~/repos/codedb_custom && zig build test --summary all 2>&1 | tail -10
```

**Step 5: Commit**

```bash
git add src/tests.zig
git commit -m "test(autumn): add parser tests for .adm, .acfg, .adpt, .arc"
```

---

### Task 7: Install, re-index Autumn, and verify

**Objective:** Deploy the new parsers and verify the Autumn project indexes correctly.

**Step 1: Build and install**

```bash
cd ~/repos/codedb_custom && zig build -Doptimize=ReleaseFast
install -m 755 zig-out/bin/codedb ~/.local/bin/codedb
```

**Step 2: Kill old MCP server**

```bash
kill $(pgrep -f "codedb mcp")
```

**Step 3: Delete stale snapshot**

```bash
rm ~/repos/credo_main/src/Autumn/codedb.snapshot
rm ~/.codedb/projects/*/codedb.snapshot 2>/dev/null
```

**Step 4: Re-index via MCP**

```
codedb_index(path="/home/jwvolschenk/repos/credo_main/src/Autumn")
```

**Step 5: Verify with codedb_tree**

Check that .adm, .acfg, .adpt, .arc files now show real symbols instead of "unknown".

**Step 6: Commit final state**

```bash
git add -A && git commit -m "feat(autumn): all four Autumn parsers complete — adm, acfg, adpt, arc"
```

---

## Verification Checklist

- [ ] `zig build test` passes with 0 new failures
- [ ] `.adm` files show entity schemas, entities, and attributes as symbols
- [ ] `.acfg` files show configurations, DB catalogs, and message queues
- [ ] `.adpt` files show adapter components (state machine nodes)
- [ ] `.arc` files show rule sets and rule references
- [ ] Autumn project indexes from 625 to ~625 files (no change in count — these were already indexed as "unknown")
- [ ] `codedb_outline` on a .adm file shows meaningful symbols
- [ ] `codedb_search` finds entity names across .adm files
- [ ] `codedb_word` finds attribute names in .adm files

## Files Modified Summary

| File | Change |
|------|--------|
| `src/autumn_parser.zig` | NEW — all four parsers + XML attribute helper |
| `src/explore/types.zig` | Add 4 Language variants + detectLanguage entries |
| `src/explore.zig` | Import autumn_parser, add dispatch in parseOutlineWithParser |
| `src/tests.zig` | Add detection + outline tests for all four formats |
