// codedb MCP — explore tool handlers.
//
// Extracted from mcp.zig. Contains:
//   - codedb_tree, codedb_outline, codedb_symbol, codedb_hierarchy,
//     codedb_search, codedb_word, codedb_callers, codedb_hot, codedb_deps
//   - plus shared helpers (hierarchy base-name matching, search hints,
//     hasWholeWordMatch / langHasCallSites used by mcp/query.zig)
//
// mcp.zig re-imports them so dispatch + tests keep resolving.

const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const ident = @import("../explore/ident_utils.zig");

const mcp = @import("../mcp.zig");
const appendBundleArgKeysDiagnostic = mcp.appendBundleArgKeysDiagnostic;
const appendFuzzyPathSuggestions = mcp.appendFuzzyPathSuggestions;

const aspnet = @import("aspnet.zig");
const decoratorsContain = aspnet.decoratorsContain;

const pathglob = @import("pathglob.zig");
const globMatch = pathglob.globMatch;

pub fn handleTree(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const tree = explorer.getTree(alloc, false) catch {
        out.appendSlice(alloc, "error: failed to get tree") catch {};
        return;
    };
    defer alloc.free(tree);
    out.appendSlice(alloc, tree) catch {};
}

pub fn handleOutline(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const compact = getBool(args, "compact");
    const grouped = getBool(args, "grouped");
    var outline = explorer.getOutline(path, alloc) catch {
        out.appendSlice(alloc, "error: outline retrieval failed") catch {};
        return;
    } orelse {
        out.appendSlice(alloc, "error: file not indexed: ") catch {};
        out.appendSlice(alloc, path) catch {};
        // Issue #356-2: fuzzy path fallback — surface top matches so the
        // caller can self-correct without a separate codedb_find round-trip.
        appendFuzzyPathSuggestions(alloc, out, explorer, path);
        // Issue #356-p3: stale-index recovery hint. The most common cause of
        // 'not indexed' once you've ruled out a typo is a freshly-added file
        // the watcher hasn't seen yet — pointing at codedb_index makes the
        // recovery action explicit.
        out.appendSlice(alloc, "\nhint: try codedb_index if the file was added recently\n") catch {};
        return;
    };
    defer outline.deinit();
    const w = cio.listWriter(out, alloc);
    w.print("{s} ({s}, {d} lines, {d} bytes)", .{
        outline.path, @tagName(outline.language), outline.line_count, outline.byte_size,
    }) catch {};
    if (explore_mod.Explorer.isStubLikeOutline(&outline)) w.writeAll(" [stub]") catch {};
    const descriptor = explore_mod.Explorer.buildOutlineDescriptor(alloc, &outline) catch null;
    defer if (descriptor) |d| alloc.free(d);
    if (descriptor) |d| w.print(" — {s}", .{d}) catch {};
    w.writeAll("\n") catch {};
    if (grouped) {
        writeGroupedOutline(alloc, out, &outline, compact);
        return;
    }
    for (outline.symbols.items) |sym| {
        if (compact) {
            w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
        } else {
            w.print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
            if (sym.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
            if (sym.param_types.len > 0) {
                w.writeAll(" (") catch {};
                for (sym.param_types, 0..) |pt, i| {
                    if (i > 0) w.writeAll(", ") catch {};
                    w.print("{s}", .{pt}) catch {};
                }
                w.writeAll(")") catch {};
            }
            if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
            writeDecoratorsInline(w, sym.decorators);
            w.writeAll("\n") catch {};
        }
    }
}

fn writeGroupedOutline(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outline: *const explore_mod.FileOutline, compact: bool) void {
    const kinds = [_]explore_mod.SymbolKind{
        .class_def,
        .interface_def,
        .trait_def,
        .struct_def,
        .enum_def,
        .union_def,
        .impl_block,
        .method,
        .function,
        .test_decl,
        .constant,
        .variable,
        .type_alias,
        .macro_def,
        .import,
        .comment_block,
    };
    const w = cio.listWriter(out, alloc);
    var emitted_any = false;
    for (kinds) |kind| {
        var count_for_kind: usize = 0;
        var line_start: u32 = std.math.maxInt(u32);
        var line_end: u32 = 0;
        for (outline.symbols.items) |sym| {
            if (sym.kind != kind) continue;
            count_for_kind += 1;
            line_start = @min(line_start, sym.line_start);
            line_end = @max(line_end, sym.line_end);
        }
        if (count_for_kind == 0) continue;
        emitted_any = true;
        w.print("  [{s}] L{d}-L{d} ({d} symbols)\n", .{ @tagName(kind), line_start, line_end, count_for_kind }) catch {};
        for (outline.symbols.items) |sym| {
            if (sym.kind != kind) continue;
            if (compact) {
                w.print("    L{d}: {s}\n", .{ sym.line_start, sym.name }) catch {};
            } else {
                w.print("    L{d}: {s}", .{ sym.line_start, sym.name }) catch {};
                if (sym.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
                if (sym.param_types.len > 0) {
                    w.writeAll(" (") catch {};
                    for (sym.param_types, 0..) |pt, i| {
                        if (i > 0) w.writeAll(", ") catch {};
                        w.print("{s}", .{pt}) catch {};
                    }
                    w.writeAll(")") catch {};
                }
                if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
                writeDecoratorsInline(w, sym.decorators);
                w.writeAll("\n") catch {};
            }
        }
    }
    if (!emitted_any) {
        w.writeAll("  (no symbols)\n") catch {};
    }
}

pub fn handleSymbol(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const include_body = getBool(args, "body");
    const decorator_filter = getStr(args, "decorator_filter");
    const results = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer {
        for (results) |r| {
            alloc.free(r.path);
            alloc.free(r.symbol.name);
            if (r.symbol.detail) |d| alloc.free(d);
            for (r.symbol.decorators) |decorator| alloc.free(decorator);
            if (r.symbol.decorators.len > 0) alloc.free(r.symbol.decorators);
            if (r.symbol.return_type) |rt| alloc.free(rt);
            for (r.symbol.param_types) |pt| alloc.free(pt);
            if (r.symbol.param_types.len > 0) alloc.free(r.symbol.param_types);
        }
        alloc.free(results);
    }

    var visible_count: usize = 0;
    for (results) |r| {
        if (decorator_filter) |filter| {
            if (!decoratorsContain(r.symbol.decorators, filter)) continue;
        }
        visible_count += 1;
    }

    if (visible_count == 0) {
        out.appendSlice(alloc, "no results for: ") catch {};
        out.appendSlice(alloc, name) catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} results for '{s}':\n", .{ visible_count, name }) catch {};
    for (results) |r| {
        if (decorator_filter) |filter| {
            if (!decoratorsContain(r.symbol.decorators, filter)) continue;
        }
        w.print("  {s}:{d} ({s})", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
        if (r.symbol.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
        if (r.symbol.param_types.len > 0) {
            w.writeAll(" (") catch {};
            for (r.symbol.param_types, 0..) |pt, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.print("{s}", .{pt}) catch {};
            }
            w.writeAll(")") catch {};
        }
        if (r.symbol.detail) |d| w.print("  // {s}", .{d}) catch {};
        writeDecoratorsInline(w, r.symbol.decorators);
        w.writeAll("\n") catch {};
        if (include_body) {
            const body = explorer.getSymbolBody(r.path, r.symbol.line_start, r.symbol.line_end, alloc) catch null;
            if (body) |b| {
                defer alloc.free(b);
                out.appendSlice(alloc, b) catch {};
            }
        }
    }
}

fn writeDecoratorsInline(w: anytype, decorators: []const []const u8) void {
    if (decorators.len == 0) return;
    w.writeAll("  decorators:") catch {};
    for (decorators) |decorator| {
        w.print(" {s}", .{decorator}) catch {};
    }
}

pub fn handleHierarchy(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (name.len == 0) {
        out.appendSlice(alloc, "error: empty name — pass a non-empty 'name' string") catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var found = false;
    var derived_count: usize = 0;

    w.print("hierarchy for '{s}':\n", .{name}) catch {};
    w.writeAll("  definitions:\n") catch {};
    var iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (!isHierarchySymbolKind(sym.kind)) continue;
            found = true;
            w.print("    {s}:{d} ({s})", .{ entry.key_ptr.*, sym.line_start, @tagName(sym.kind) }) catch {};
            if (sym.detail) |detail| w.print("  // {s}", .{detail}) catch {};
            w.writeAll("\n") catch {};
            if (sym.detail) |detail| {
                w.writeAll("      bases:\n") catch {};
                const before = out.items.len;
                writeHierarchyBaseNames(w, detail, sym.name, "        ");
                if (out.items.len == before) w.writeAll("        (none)\n") catch {};
            }
        }
    }

    if (!found) {
        w.writeAll("    (none)\n") catch {};
    }

    w.writeAll("  direct_derived:\n") catch {};
    iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (!isHierarchySymbolKind(sym.kind)) continue;
            if (std.mem.eql(u8, sym.name, name)) continue;
            const detail = sym.detail orelse continue;
            if (!hierarchyDetailMentionsBase(detail, sym.name, name)) continue;
            derived_count += 1;
            w.print("    {s}:{d} {s} ({s})", .{ entry.key_ptr.*, sym.line_start, sym.name, @tagName(sym.kind) }) catch {};
            w.print("  // {s}\n", .{detail}) catch {};
        }
    }
    if (derived_count == 0) {
        w.writeAll("    (none)\n") catch {};
    }
}

fn isHierarchySymbolKind(kind: explore_mod.SymbolKind) bool {
    return switch (kind) {
        .class_def, .interface_def, .trait_def, .struct_def => true,
        else => false,
    };
}

fn writeHierarchyBaseNames(w: anytype, detail: []const u8, self_name: []const u8, indent: []const u8) void {
    var bases = hierarchyBasePortion(detail, self_name) orelse return;
    bases = trimHierarchyBasePortion(bases);
    var token_start: ?usize = null;
    for (bases, 0..) |c, i| {
        if (isHierarchyTokenChar(c)) {
            if (token_start == null) token_start = i;
        } else if (token_start) |start| {
            writeHierarchyBaseToken(w, bases[start..i], self_name, indent);
            token_start = null;
        }
    }
    if (token_start) |start| {
        writeHierarchyBaseToken(w, bases[start..], self_name, indent);
    }
}

fn writeHierarchyBaseToken(w: anytype, raw_token: []const u8, self_name: []const u8, indent: []const u8) void {
    const token = std.mem.trim(u8, raw_token, " \t\r\n");
    if (token.len == 0) return;
    if (isHierarchyKeyword(token)) return;
    if (std.mem.eql(u8, token, self_name)) return;
    w.print("{s}{s}\n", .{ indent, token }) catch {};
}

fn hierarchyDetailMentionsBase(detail: []const u8, self_name: []const u8, base_name: []const u8) bool {
    var bases = hierarchyBasePortion(detail, self_name) orelse return false;
    bases = trimHierarchyBasePortion(bases);
    var token_start: ?usize = null;
    for (bases, 0..) |c, i| {
        if (isHierarchyTokenChar(c)) {
            if (token_start == null) token_start = i;
        } else if (token_start) |start| {
            if (hierarchyTokenMatches(bases[start..i], base_name)) return true;
            token_start = null;
        }
    }
    if (token_start) |start| {
        if (hierarchyTokenMatches(bases[start..], base_name)) return true;
    }
    return false;
}

fn hierarchyBasePortion(detail: []const u8, self_name: []const u8) ?[]const u8 {
    _ = self_name;
    if (std.mem.indexOf(u8, detail, " extends ")) |pos| return detail[pos + " extends ".len ..];
    if (std.mem.indexOf(u8, detail, " implements ")) |pos| return detail[pos + " implements ".len ..];
    if (std.mem.indexOfScalar(u8, detail, '(')) |open| {
        if (std.mem.indexOfScalarPos(u8, detail, open + 1, ')')) |close| {
            return detail[open + 1 .. close];
        }
    }
    if (std.mem.indexOfScalar(u8, detail, ':')) |colon| {
        return detail[colon + 1 ..];
    }
    return null;
}

fn trimHierarchyBasePortion(bases: []const u8) []const u8 {
    var end = bases.len;
    for (bases, 0..) |c, i| {
        if (c == '{' or c == ';') {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, bases[0..end], " \t\r\n");
}

fn hierarchyTokenMatches(raw_token: []const u8, target: []const u8) bool {
    const token = std.mem.trim(u8, raw_token, " \t\r\n");
    if (token.len == 0 or isHierarchyKeyword(token)) return false;
    if (std.mem.eql(u8, token, target)) return true;
    if (std.mem.endsWith(u8, token, target) and token.len > target.len) {
        const sep = token[token.len - target.len - 1];
        return sep == '.';
    }
    return false;
}

fn isHierarchyTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn isHierarchyKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{ "public", "private", "protected", "internal", "abstract", "sealed", "partial", "class", "interface", "struct", "extends", "implements", "where", "new", "record", "readonly", "static", "final", "open", "data" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, token, kw)) return true;
    }
    return false;
}

/// Append post-search hints: code syntax warnings and cross-pollution detection.
fn appendSearchHints(alloc: std.mem.Allocator, out: *std.ArrayList(u8), query: []const u8, visible_count: usize, dir_count: usize) void {
    const w = cio.listWriter(out, alloc);

    // Hint 1: code syntax characters that break substring search
    if (visible_count == 0) {
        var has_brackets = false;
        var has_slash = false;
        var has_dot_suffix = false;
        for (query) |c| {
            if (c == '[' or c == ']' or c == '(' or c == ')' or c == '{' or c == '}') has_brackets = true;
            if (c == '/') has_slash = true;
        }
        if (query.len > 1 and query[query.len - 1] == '.') has_dot_suffix = true;

        if (has_brackets) {
            w.print("\n  hint: query has brackets [](){{}} which are not indexed \u{2014} try stripping them and searching for the identifier inside, e.g. 'Route' instead of '[Route(\"/mqtt\")'\n", .{}) catch {};
        } else if (has_slash and query.len <= 10) {
            w.print("\n  hint: query contains '/' which is not indexed as part of identifiers \u{2014} try the path segment without slashes\n", .{}) catch {};
        } else if (has_dot_suffix) {
            w.print("\n  hint: trailing '.' is not indexed \u{2014} try without the dot\n", .{}) catch {};
        }
    }

    // Hint 2: cross-pollution warning when results span many directories
    if (visible_count >= 5 and dir_count >= 5) {
        w.print("\n  warning: results span {d} different directories \u{2014} consider using path_glob to scope to a specific feature, e.g. path_glob=\"**/Portfolio*\"\n", .{dir_count}) catch {};
    }
}

pub fn handleSearch(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const query = getStr(args, "query") orelse {
        out.appendSlice(alloc, "error: missing 'query' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    // Bug 7: validate args explicitly. Pre-fix: empty query / non-positive
    // max_results all returned "0 results" and the agent thought the search
    // ran with nothing matching, when really the call was malformed.
    if (query.len == 0) {
        out.appendSlice(alloc, "error: empty query — pass a non-empty 'query' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 50;
    const scope = getBool(args, "scope");
    const compact = getBool(args, "compact");
    const is_regex = getBool(args, "regex");
    const path_glob_raw = getStr(args, "path_glob");
    // Auto-promote basename-only patterns ('*.zig') to '**/*.zig' so they match
    // nested files. Without this the matcher rejects 'src/main.zig' because
    // '*' doesn't cross '/' (see explore.zig:matchGlob). Issue surfaced by the
    // recall eval — agents reach for '*.zig' first.
    var pg_buf: [256]u8 = undefined;
    const path_glob: ?[]const u8 = if (path_glob_raw) |g| blk: {
        if (std.mem.indexOfScalar(u8, g, '/') == null and g.len + 3 < pg_buf.len) {
            const promoted = std.fmt.bufPrint(&pg_buf, "**/{s}", .{g}) catch break :blk g;
            break :blk promoted;
        }
        break :blk g;
    } else null;

    if (scope and is_regex) {
        const results = explorer.searchContentRegexWithScope(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: scoped regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, not the pre-filter explorer count.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else if (scope) {
        const results = explorer.searchContentWithScope(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, and so the "truncated" footer only fires
        // for per-file-cap truncation — not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            // Track unique parent directories for cross-pollution detection
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s} ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else if (is_regex) {
        const results = explorer.searchContentRegex(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else {
        const results = explorer.searchContent(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            // Track unique parent directories for cross-pollution detection
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    }
}

pub fn handleWord(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const word = getStr(args, "word") orelse {
        out.appendSlice(alloc, "error: missing 'word' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const hits = explorer.searchWord(word, alloc) catch {
        out.appendSlice(alloc, "error: word search failed") catch {};
        return;
    };
    defer alloc.free(hits);

    // Path glob filtering — scope results to matching files
    const path_glob_raw = getStr(args, "path_glob");
    var pg_buf: [256]u8 = undefined;
    const path_glob: ?[]const u8 = if (path_glob_raw) |g| blk: {
        if (std.mem.indexOfScalar(u8, g, '/') == null and g.len + 3 < pg_buf.len) {
            const promoted = std.fmt.bufPrint(&pg_buf, "**/{s}", .{g}) catch break :blk g;
            break :blk promoted;
        }
        break :blk g;
    } else null;

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    // Count visible hits after glob filter
    var visible_total: usize = 0;
    for (hits) |h| {
        const p = explorer.word_index.hitPath(h);
        if (path_glob) |g| if (!globMatch(g, p)) continue;
        visible_total += 1;
    }

    const w = cio.listWriter(out, alloc);
    const WORD_CAP: usize = 50;
    if (visible_total > WORD_CAP) {
        w.print("{d} hits for '{s}' (showing first {d}):\n", .{ visible_total, word, WORD_CAP }) catch {};
    } else {
        w.print("{d} hits for '{s}':\n", .{ visible_total, word }) catch {};
    }
    var shown: usize = 0;
    for (hits) |h| {
        const p = explorer.word_index.hitPath(h);
        if (path_glob) |g| if (!globMatch(g, p)) continue;
        if (shown >= WORD_CAP) break;
        w.print("  {s}:{d}\n", .{ p, h.line_num }) catch {};
        shown += 1;
    }
    if (visible_total > WORD_CAP) {
        w.print("... ({d} more — use path_glob to scope results)\n", .{visible_total - WORD_CAP}) catch {};
    }
}

pub fn handleCallers(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (name.len == 0) {
        out.appendSlice(alloc, "error: empty name — pass a non-empty 'name' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 50;

    const defs = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: symbol lookup failed") catch {};
        return;
    };
    defer {
        for (defs) |d| {
            alloc.free(d.path);
            alloc.free(d.symbol.name);
            if (d.symbol.detail) |dd| alloc.free(dd);
            for (d.symbol.decorators) |decorator| alloc.free(decorator);
            if (d.symbol.decorators.len > 0) alloc.free(d.symbol.decorators);
            if (d.symbol.return_type) |rt| alloc.free(rt);
            for (d.symbol.param_types) |pt| alloc.free(pt);
            if (d.symbol.param_types.len > 0) alloc.free(d.symbol.param_types);
        }
        alloc.free(defs);
    }

    const results = explorer.searchContentWithScope(name, alloc, max_results) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer {
        for (results) |r| {
            alloc.free(r.line_text);
            alloc.free(r.path);
            if (r.scope_name) |n2| alloc.free(n2);
        }
        alloc.free(results);
    }

    var shown: usize = 0;
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        shown += 1;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} call sites for '{s}':\n", .{ shown, name }) catch {};
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        if (r.scope_name) |sn| {
            w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
            }) catch {};
        } else {
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
        }
    }
}

const isIdentChar = ident.isIdentChar;

/// Returns true iff `needle` appears in `haystack` with non-identifier
/// characters (or string boundary) on both sides — i.e. as a whole-word
/// identifier match, not as a substring inside a longer identifier.
pub fn hasWholeWordMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search_from, needle)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(haystack[pos - 1]);
        const after_idx = pos + needle.len;
        const after_ok = after_idx >= haystack.len or !isIdentChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        search_from = pos + 1;
    }
    return false;
}

/// Languages where the concept of a "call site" is meaningful. Excludes
/// data formats (json, yaml), markup/styling (markdown, css, scss),
/// declarative schemas (protobuf), and unknown files — callers found
/// inside these are mentions in prose or config, not real invocations.
pub fn langHasCallSites(lang: explore_mod.Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
        else => true,
    };
}

pub fn handleHot(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    const limit: usize = if (getInt(args, "limit")) |n| @intCast(@min(@max(1, n), 1000)) else 10;
    const hot = explorer.getHotFiles(store, alloc, limit) catch {
        out.appendSlice(alloc, "error: hot files failed") catch {};
        return;
    };
    defer {
        for (hot) |path| alloc.free(path);
        alloc.free(hot);
    }

    const w = cio.listWriter(out, alloc);
    for (hot, 0..) |path, i| {
        w.print("{d}. {s}\n", .{ i + 1, path }) catch {};
    }
}

pub fn handleDeps(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const direction = getStr(args, "direction") orelse "imported_by";
    const transitive = getBool(args, "transitive");
    const max_depth: ?u32 = if (getInt(args, "max_depth")) |n| @intCast(@max(1, n)) else null;

    const is_forward = std.mem.eql(u8, direction, "depends_on");

    var results: []const []const u8 = &.{};
    if (is_forward) {
        if (transitive) {
            results = explorer.getTransitiveDependencies(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            explorer.mu.lockShared();
            const fwd = explorer.dep_graph.getForwardDeps(path);
            explorer.mu.unlockShared();
            if (fwd) |deps| {
                var result_list: std.ArrayList([]const u8) = .empty;
                for (deps) |dep| {
                    const d = alloc.dupe(u8, dep) catch continue;
                    result_list.append(alloc, d) catch {
                        alloc.free(d);
                        continue;
                    };
                }
                results = result_list.toOwnedSlice(alloc) catch &.{};
            }
        }
    } else {
        if (transitive) {
            results = explorer.getTransitiveDependents(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            results = explorer.getImportedBy(path, alloc) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        }
    }
    defer {
        for (results) |dep| alloc.free(dep);
        alloc.free(results);
    }

    const w = cio.listWriter(out, alloc);
    if (is_forward) {
        if (transitive) {
            w.print("{s} transitively depends on:\n", .{path}) catch {};
        } else {
            w.print("{s} depends on:\n", .{path}) catch {};
        }
    } else {
        if (transitive) {
            w.print("{s} is transitively imported by:\n", .{path}) catch {};
        } else {
            w.print("{s} is imported by:\n", .{path}) catch {};
        }
    }
    if (results.len == 0) {
        w.writeAll("  (none)\n") catch {};
        // Bug 4: if the path isn't indexed at all, agents read "(none)" as
        // "file exists but no callers" — which is wrong. Append fuzzy
        // suggestions so a typo is recoverable in one shot.
        explorer.mu.lockShared();
        const known = explorer.outlines.contains(path);
        explorer.mu.unlockShared();
        if (!known) appendFuzzyPathSuggestions(alloc, out, explorer, path);
    } else {
        for (results) |dep| {
            w.print("  {s}\n", .{dep}) catch {};
        }
        w.print("({d} files)\n", .{results.len}) catch {};
    }
}
