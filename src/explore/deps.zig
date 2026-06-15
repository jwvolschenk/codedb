const std = @import("std");
const Explorer = @import("../explore.zig").Explorer;
const Symbol = @import("../explore.zig").Symbol;
const SymbolResult = @import("../explore.zig").SymbolResult;
const SymbolLocation = @import("../explore.zig").SymbolLocation;
const FileOutline = @import("../explore.zig").FileOutline;
const TypeGraph = @import("../index.zig").TypeGraph;
const Store = @import("../store.zig").Store;
const tsql_parser = @import("../tsql_parser.zig");
const parse_utils = @import("parse_utils.zig");

pub fn findSymbol(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) !?struct { path: []const u8, symbol: Symbol } {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    // O(1) lookup via symbol_index
    if (self.symbol_index.get(name)) |locs| {
        if (locs.items.len > 0) {
            const loc = locs.items[0];
            // Fetch detail from outline
            var detail: ?[]const u8 = null;
            var decorators: []const []const u8 = &.{};
            var return_type: ?[]const u8 = null;
            var param_types: []const []const u8 = &.{};
            if (self.outlines.getPtr(loc.path)) |outline| {
                for (outline.symbols.items) |sym| {
                    if (sym.line_start == loc.line_start and symbolNameMatches(sym.name, name)) {
                        detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                        decorators = try Explorer.cloneDecorators(allocator, sym.decorators);
                        return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
                        param_types = try Explorer.cloneParamTypes(allocator, sym.param_types);
                        break;
                    }
                }
            }
            errdefer if (detail) |d| allocator.free(d);
            errdefer Explorer.freeDecorators(allocator, decorators);
            errdefer if (return_type) |rt| allocator.free(rt);
            errdefer Explorer.freeParamTypes(allocator, param_types);
            return .{
                .path = try allocator.dupe(u8, loc.path),
                .symbol = .{
                    .name = try allocator.dupe(u8, name),
                    .kind = loc.kind,
                    .line_start = loc.line_start,
                    .line_end = loc.line_end,
                    .detail = detail,
                    .decorators = decorators,
                    .return_type = return_type,
                    .param_types = param_types,
                },
            };
        }
    }

    // Fallback: scan outlines (handles edge cases during index build)
    var iter = self.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (symbolNameMatches(sym.name, name)) {
                return .{
                    .path = try allocator.dupe(u8, entry.key_ptr.*),
                    .symbol = .{
                        .name = try allocator.dupe(u8, sym.name),
                        .kind = sym.kind,
                        .line_start = sym.line_start,
                        .line_end = sym.line_end,
                        .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                        .decorators = try Explorer.cloneDecorators(allocator, sym.decorators),
                        .return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null,
                        .param_types = try Explorer.cloneParamTypes(allocator, sym.param_types),
                    },
                };
            }
        }
    }
    return null;
}

pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    var result_list: std.ArrayList(SymbolResult) = .empty;
    errdefer result_list.deinit(allocator);

    // Track (path, line_start) pairs already appended. symbol_index can be
    // incomplete after fast-snapshot restore (outlines are populated before
    // rebuildSymbolIndexFor runs on every file), so we must still fall
    // through to the outline scan — and dedupe against what the index
    // already supplied. Keys are "<path>:<line>" allocated from the caller
    // allocator, freed at end of call.
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var sit = seen.keyIterator();
        while (sit.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    if (self.symbol_index.get(name)) |locs| {
        for (locs.items) |loc| {
            var detail: ?[]const u8 = null;
            var decorators: []const []const u8 = &.{};
            var return_type: ?[]const u8 = null;
            var param_types: []const []const u8 = &.{};
            if (self.outlines.getPtr(loc.path)) |outline| {
                for (outline.symbols.items) |sym| {
                    if (sym.line_start == loc.line_start and symbolNameMatches(sym.name, name)) {
                        detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                        decorators = try Explorer.cloneDecorators(allocator, sym.decorators);
                        return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
                        param_types = try Explorer.cloneParamTypes(allocator, sym.param_types);
                        break;
                    }
                }
            }
            errdefer if (detail) |d| allocator.free(d);
            errdefer Explorer.freeDecorators(allocator, decorators);
            errdefer if (return_type) |rt| allocator.free(rt);
            errdefer Explorer.freeParamTypes(allocator, param_types);
            try result_list.append(allocator, .{
                .path = try allocator.dupe(u8, loc.path),
                .symbol = .{
                    .name = try allocator.dupe(u8, name),
                    .kind = loc.kind,
                    .line_start = loc.line_start,
                    .line_end = loc.line_end,
                    .detail = detail,
                    .decorators = decorators,
                    .return_type = return_type,
                    .param_types = param_types,
                },
            });
            const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ loc.path, loc.line_start });
            seen.put(key, {}) catch allocator.free(key);
        }
    }

    // Safety scan: append any outline symbols the index missed.
    var iter = self.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (!symbolNameMatches(sym.name, name)) continue;
            var key_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ entry.key_ptr.*, sym.line_start }) catch continue;
            if (seen.contains(key)) continue;
            try result_list.append(allocator, .{
                .path = try allocator.dupe(u8, entry.key_ptr.*),
                .symbol = .{
                    .name = try allocator.dupe(u8, sym.name),
                    .kind = sym.kind,
                    .line_start = sym.line_start,
                    .line_end = sym.line_end,
                    .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                    .decorators = try Explorer.cloneDecorators(allocator, sym.decorators),
                    .return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null,
                    .param_types = try Explorer.cloneParamTypes(allocator, sym.param_types),
                },
            });
        }
    }
    return result_list.toOwnedSlice(allocator);
}

pub fn getImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.dep_graph.getImportedBy(path, allocator);
}

pub fn getTransitiveDependents(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.dep_graph.getTransitiveDependents(path, allocator, max_depth);
}

pub fn getTransitiveDependencies(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.dep_graph.getTransitiveDependencies(path, allocator, max_depth);
}

pub fn getHotFiles(self: *Explorer, store: *Store, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
    // Collect stable path copies under explorer lock.
    var path_list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (path_list.items) |path| allocator.free(path);
        path_list.deinit(allocator);
    }
    defer path_list.deinit(allocator);
    {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        var iter = self.outlines.iterator();
        while (iter.next()) |kv| {
            const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
            try path_list.append(allocator, path_copy);
        }
    }

    // Query store seqs without holding explorer lock.
    const Entry = struct { path: []u8, seq: u64 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    {
        store.mu.lock();
        defer store.mu.unlock();
        for (path_list.items) |path| {
            const seq = store.getLatestSeqUnlocked(path);
            try entries.append(allocator, .{ .path = path, .seq = seq });
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn cmp(_: void, a: Entry, b: Entry) bool {
            return a.seq > b.seq;
        }
    }.cmp);

    const count = @min(limit, entries.items.len);
    const paths = try allocator.alloc([]const u8, count);
    for (entries.items[0..count], 0..) |e, i| {
        paths[i] = e.path;
    }
    for (entries.items[count..]) |e| {
        allocator.free(e.path);
    }
    return paths;
}

pub fn rebuildDepsFor(self: *Explorer, path: []const u8, outline: *FileOutline) !void {
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer deps.deinit(self.allocator);

    // Issue #445: outline.imports.items contains one entry per `@import`
    // site, so a file aliasing the same dep multiple times emits dupes.
    // Dedup by path before storing — the reverse index already dedupes
    // naturally via StringHashMap, only forward edges need this.
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    const is_sql = outline.language == .sql;

    for (outline.imports.items) |imp| {
        // For SQL imports, try to resolve object names to file paths.
        // SQL imports are like "dbo.vwHalfCommClients" or "Holding.vPosition".
        // We need to find the actual file path for proper dependency tracking.
        if (is_sql) {
            const resolved = self.resolveSqlDepKey(imp);
            if (resolved) |key| {
                const gop = try seen.getOrPut(key);
                if (!gop.found_existing) {
                    try deps.append(self.allocator, key);
                }
                continue;
            }
        }

        const dep_key = resolveDependencyKey(path, imp, self.allocator) orelse continue;
        const gop = try seen.getOrPut(dep_key.key);
        if (gop.found_existing) continue;
        try deps.append(self.allocator, dep_key.key);
    }

    try self.dep_graph.setDeps(path, deps);
}

/// Resolve a SQL import (e.g., "dbo.vwHalfCommClients") to a file path
/// by looking up the bare object name in the symbol index.
/// Returns the file path if found, or the bare object name as fallback.
pub fn resolveSqlDepKey(self: *Explorer, imp: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, imp, " \t\r\n\"'");
    if (trimmed.len == 0) return null;

    // Extract bare object name: dbo.vwHalfCommClients -> vwHalfCommClients
    const bare = tsql_parser.extractBareObjectName(trimmed);
    if (bare.len == 0) return null;

    // Look up the bare name in the symbol index
    if (self.symbol_index.get(bare)) |locs| {
        if (locs.items.len > 0) {
            // Return the file path of the first match
            return locs.items[0].path;
        }
    }

    // Fallback: use the bare object name as the dep key.
    // This enables reverse lookup via stem matching in getImportedBy.
    return bare;
}

pub const DependencyKey = struct {
    key: []const u8,
};

pub fn resolveDependencyKey(path: []const u8, imp: []const u8, allocator: std.mem.Allocator) ?DependencyKey {
    const trimmed = std.mem.trim(u8, imp, " \t\r\n\"'");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "../")) {
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[0..sep] else ".";
        const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, trimmed }) catch return null;
        defer allocator.free(joined);

        const normalized = parse_utils.normalizePath(joined, allocator) orelse return null;
        allocator.free(normalized);
        const basename = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |sep| trimmed[sep + 1 ..] else trimmed;
        if (basename.len == 0) return null;
        return .{ .key = basename };
    }

    return .{ .key = trimmed };
}

pub fn rebuildSymbolIndexFor(self: *Explorer, path: []const u8, outline: *FileOutline) void {
    self.removeSymbolIndexFor(path);
    for (outline.symbols.items) |sym| {
        const gop = self.symbol_index.getOrPut(sym.name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(SymbolLocation).empty;
        }
        gop.value_ptr.append(self.allocator, .{
            .path = path,
            .kind = sym.kind,
            .line_start = sym.line_start,
            .line_end = sym.line_end,
        }) catch {};

        // For SQL files, also register the bare object name as an alias.
        // This enables codedb_symbol(name="vPosition") to find [Holding].[vPosition].
        if (outline.language == .sql and sym.kind != .import and sym.kind != .variable) {
            const bare = tsql_parser.extractBareObjectName(sym.name);
            if (bare.len > 0 and !std.mem.eql(u8, bare, sym.name)) {
                const alias_gop = self.symbol_index.getOrPut(bare) catch continue;
                if (!alias_gop.found_existing) {
                    alias_gop.value_ptr.* = std.ArrayList(SymbolLocation).empty;
                }
                // Check if this path is already registered for the alias
                var already = false;
                for (alias_gop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing.path, path) and existing.line_start == sym.line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    alias_gop.value_ptr.append(self.allocator, .{
                        .path = path,
                        .kind = sym.kind,
                        .line_start = sym.line_start,
                        .line_end = sym.line_end,
                    }) catch {};
                }
            }
        }
    }
}

/// Rebuild TypeIndex and TypeGraph from all loaded outlines.
/// Called after snapshot loading to populate type query indexes.
pub fn rebuildTypeIndexes(self: *Explorer) void {
    var iter = self.outlines.iterator();
    while (iter.next()) |entry| {
        self.type_index.indexFileSymbols(entry.key_ptr.*, entry.value_ptr.symbols.items) catch {};
        self.buildTypeGraphForFile(entry.key_ptr.*, entry.value_ptr);
    }
}

/// Build type graph from class/interface declarations in a file.
/// Parses detail text for "extends", "implements", ":" (C#/Kotlin) keywords.
pub fn buildTypeGraphForFile(self: *Explorer, path: []const u8, outline: *const FileOutline) void {
    _ = path;
    for (outline.symbols.items) |sym| {
        if (sym.kind != .class_def and sym.kind != .interface_def and
            sym.kind != .struct_def and sym.kind != .enum_def) continue;
        const detail = sym.detail orelse continue;
        extractAndRecordBases(&self.type_graph, sym.name, detail) catch {};
    }
}

/// Extract base type names from a declaration detail line and record in TypeGraph.
pub fn extractAndRecordBases(graph: *TypeGraph, type_name: []const u8, detail: []const u8) !void {
    // Find the portion after "extends", "implements", or ":" (C#/Kotlin)
    const bases = findBasePortion(detail, type_name) orelse return;
    // Tokenize: split on commas, spaces, angle brackets, etc.
    var token_start: ?usize = null;
    for (bases, 0..) |c, i| {
        if (parse_utils.isIdentChar(c) or c == '.' or c == '_' or c == '<' or c == '>' or c == '[' or c == ']') {
            if (token_start == null) token_start = i;
        } else if (token_start) |start| {
            const token = std.mem.trim(u8, bases[start..i], " \t");
            if (token.len > 0 and !isHierarchyKeyword(token) and !std.mem.eql(u8, token, type_name)) {
                try graph.addRelationship(type_name, token);
            }
            token_start = null;
        }
    }
    if (token_start) |start| {
        const token = std.mem.trim(u8, bases[start..], " \t");
        if (token.len > 0 and !isHierarchyKeyword(token) and !std.mem.eql(u8, token, type_name)) {
            try graph.addRelationship(type_name, token);
        }
    }
}

pub fn findBasePortion(detail: []const u8, self_name: []const u8) ?[]const u8 {
    _ = self_name;
    if (std.mem.indexOf(u8, detail, " extends ")) |pos| return detail[pos + " extends ".len ..];
    if (std.mem.indexOf(u8, detail, " implements ")) |pos| return detail[pos + " implements ".len ..];
    // C#/Kotlin: "class Foo : IBar, IBaz" — find ':' not inside strings
    if (std.mem.indexOf(u8, detail, " : ")) |pos| return detail[pos + " : ".len ..];
    // Python: "class Foo(Bar, Baz):" — find '('
    if (std.mem.indexOfScalar(u8, detail, '(')) |open| {
        if (std.mem.indexOfScalarPos(u8, detail, open + 1, ')')) |close| {
            return detail[open + 1 .. close];
        }
    }
    return null;
}

/// Check if a symbol name matches a query, supporting SQL schema-qualified names.
/// Exact match first, then checks if sym_name ends with ".query" (e.g. "API_V1.DecomAccount" matches "DecomAccount").
pub fn symbolNameMatches(sym_name: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, sym_name, query)) return true;
    // SQL schema-qualified: "schema.object" matches bare "object"
    if (query.len > 0 and sym_name.len > query.len + 1) {
        const dot_pos = sym_name.len - query.len - 1;
        if (sym_name[dot_pos] == '.' and std.mem.eql(u8, sym_name[dot_pos + 1 ..], query)) {
            return true;
        }
    }
    return false;
}

pub fn isHierarchyKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{ "extends", "implements", "class", "interface", "struct", "enum", "trait", "record", "abstract", "sealed", "final", "static", "public", "private", "protected", "internal", "override", "virtual", "async", "partial", "where", "super", "protocol", ":", ",", "with", "data", "object", "fun", "val", "var" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, token, kw)) return true;
    }
    return false;
}

pub fn removeSymbolIndexFor(self: *Explorer, path: []const u8) void {
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(self.allocator);

    var iter = self.symbol_index.iterator();
    while (iter.next()) |entry| {
        var list = entry.value_ptr;
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i].path, path)) {
                _ = list.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        if (list.items.len == 0) {
            list.deinit(self.allocator);
            to_remove.append(self.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (to_remove.items) |key| {
        _ = self.symbol_index.remove(key);
    }
}

/// Return the source body for a symbol given its file path and line range.
/// Caller owns the returned slice.
pub fn getSymbolBody(self: *Explorer, path: []const u8, line_start: u32, line_end: u32, allocator: std.mem.Allocator) !?[]u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    const ref = self.readContentForSearch(path, allocator) orelse return null;
    defer ref.deinit();
    return try parse_utils.extractLines(ref.data, line_start, line_end, true, false, .unknown, allocator);
}

/// Find the smallest enclosing symbol for a given line in a file.
/// Must be called while holding at least a shared lock.
pub fn findEnclosingSymbolLocked(self: *Explorer, path: []const u8, line_num: u32) ?Symbol {
    const outline = self.outlines.getPtr(path) orelse return null;
    const symbols = outline.symbols.items;
    if (symbols.len == 0) return null;

    // Binary search: find rightmost symbol with line_start <= line_num.
    // Symbols are stored in source order (line_start ascending).
    var lo: usize = 0;
    var hi: usize = symbols.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (symbols[mid].line_start <= line_num) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    // lo is the insertion point; candidates are symbols[0..lo] with line_start <= line_num.

    // Check candidates in reverse for tightest enclosing block. Zero-span
    // symbols are often call-like parser artifacts, so keep them only as a
    // fallback when no real enclosing scope exists.
    var best: ?Symbol = null;
    var best_span: u32 = std.math.maxInt(u32);
    var fallback: ?Symbol = null;
    var i: usize = lo;
    while (i > 0) {
        i -= 1;
        const sym = symbols[i];
        if (sym.line_end >= line_num) {
            if (sym.line_end == sym.line_start) {
                if (fallback == null) fallback = sym;
                continue;
            }
            const span = sym.line_end - sym.line_start;
            if (span < best_span) {
                best = sym;
                best_span = span;
            }
        }
        // Once we're past a reasonable gap, stop scanning backwards
        if (line_num - sym.line_start > 500 and best != null) break;
    }
    if (best != null) return best;
    if (fallback != null) return fallback;

    // Fallback: nearest preceding symbol (already at the right position from binary search)
    if (lo > 0) return symbols[lo - 1];
    return null;
}
