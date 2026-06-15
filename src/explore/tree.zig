const std = @import("std");
const Explorer = @import("../explore.zig").Explorer;
const Symbol = @import("../explore.zig").Symbol;
const FileOutline = @import("../explore.zig").FileOutline;
const Language = @import("../explore.zig").Language;
const matchGlob = @import("../explore.zig").matchGlob;

pub fn getTree(self: *Explorer, allocator: std.mem.Allocator, use_color: bool) ![]u8 {
    const s = @import("../style.zig").style(use_color);

    self.mu.lockShared();
    defer self.mu.unlockShared();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var iter = self.outlines.iterator();
    while (iter.next()) |entry| {
        try paths.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var seen_dirs = std.StringHashMap(void).init(allocator);
    defer seen_dirs.deinit();

    for (paths.items) |path| {
        const outline = self.outlines.get(path) orelse continue;

        // Emit directory nodes we haven't seen yet
        var prefix_end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
            const dir = path[0 .. sep + 1];
            if (!seen_dirs.contains(dir)) {
                try seen_dirs.put(dir, {});
                const depth = std.mem.count(u8, dir[0..sep], "/");
                for (0..depth) |_| try writer.writeAll("  ");
                const dir_name = path[if (depth > 0) std.mem.lastIndexOfScalar(u8, dir[0..sep], '/').? + 1 else 0..sep];
                try writer.print("{s}{s}/{s}\n", .{ s.bold, dir_name, s.reset });
            }
            prefix_end = sep + 1;
        }

        // Emit file leaf
        const depth = std.mem.count(u8, path, "/");
        for (0..depth) |_| try writer.writeAll("  ");
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        const lang = @tagName(outline.language);
        const descriptor = buildOutlineDescriptor(allocator, &outline) catch null;
        defer if (descriptor) |d| allocator.free(d);
        try writer.print("{s}  {s}{s}{s}  {s}{d}L  {d} sym{s}", .{
            basename,
            s.langColor(lang),
            lang,
            s.reset,
            s.dim,
            outline.line_count,
            outline.symbols.items.len,
            s.reset,
        });
        if (descriptor) |d| try writer.print(" - {s}", .{d});
        try writer.writeAll("\n");
    }

    return aw.toOwnedSlice();
}

pub const LsEntry = struct {
    name: []const u8,
    is_dir: bool,
    line_count: u32 = 0,
    sym_count: u32 = 0,
    language: Language = .unknown,
    dependent_count: u32 = 0,
    hotspot_score: u32 = 0,
    is_stub: bool = false,
    descriptor: []const u8 = "",
};

pub fn globPaths(self: *Explorer, allocator: std.mem.Allocator, pattern: []const u8, max_results: usize) ![][]const u8 {
    if (pattern.len == 0) return &.{};

    self.mu.lockShared();
    defer self.mu.unlockShared();

    var matches: std.ArrayList([]const u8) = .empty;
    errdefer matches.deinit(allocator);
    // Reserve a guess so small/medium glob result sets don't trigger
    // multiple geometric reallocations.
    matches.ensureTotalCapacity(allocator, @min(64, self.outlines.count())) catch {};

    var iter = self.outlines.keyIterator();
    while (iter.next()) |key_ptr| {
        const path = key_ptr.*;
        if (matchGlob(pattern, path)) {
            try matches.append(allocator, path);
        }
    }

    std.mem.sort([]const u8, matches.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    if (matches.items.len > max_results) matches.items.len = max_results;

    return matches.toOwnedSlice(allocator);
}

pub fn lsDir(self: *Explorer, allocator: std.mem.Allocator, prefix: []const u8, ranked: bool) ![]LsEntry {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    // Normalize: trim trailing slash. Empty prefix means root.
    var p = prefix;
    if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];

    var entries: std.ArrayList(LsEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            if (!entry.is_dir and entry.descriptor.len > 0) allocator.free(entry.descriptor);
        }
        entries.deinit(allocator);
    }
    // Most listings produce a small set; a single up-front allocation
    // avoids the geometric-realloc dance for typical directories.
    entries.ensureTotalCapacity(allocator, 32) catch {};

    // Each outline key is unique, so a file `rel` is emitted at most once
    // by construction. We only need a dedup map for directory names since
    // multiple paths can share a parent dir.
    var seen_dirs = std.StringHashMap(void).init(allocator);
    defer seen_dirs.deinit();

    var iter = self.outlines.iterator();
    while (iter.next()) |kv| {
        const path = kv.key_ptr.*;

        var rel: []const u8 = undefined;
        if (p.len == 0) {
            rel = path;
        } else {
            if (!std.mem.startsWith(u8, path, p)) continue;
            if (path.len <= p.len + 1 or path[p.len] != '/') continue;
            rel = path[p.len + 1 ..];
        }
        if (rel.len == 0) continue;

        if (std.mem.indexOfScalar(u8, rel, '/')) |sep| {
            const dir_name = rel[0..sep];
            const dir_score = if (ranked) self.lsDirHotspotScore(p, dir_name) else 0;
            if (!seen_dirs.contains(dir_name)) {
                try seen_dirs.put(dir_name, {});
                try entries.append(allocator, .{ .name = dir_name, .is_dir = true, .hotspot_score = dir_score });
            }
        } else {
            const fo = kv.value_ptr.*;
            const dependent_count: u32 = if (ranked) @intCast(@min(self.dep_graph.importedByCount(path), std.math.maxInt(u32))) else 0;
            const sym_count: u32 = @intCast(fo.symbols.items.len);
            const descriptor = try buildOutlineDescriptor(allocator, &fo);
            try entries.append(allocator, .{
                .name = rel,
                .is_dir = false,
                .line_count = fo.line_count,
                .sym_count = sym_count,
                .language = fo.language,
                .dependent_count = dependent_count,
                .hotspot_score = dependent_count +| sym_count,
                .is_stub = isStubLikeOutline(&fo),
                .descriptor = descriptor,
            });
        }
    }

    if (ranked) {
        std.mem.sort(LsEntry, entries.items, {}, struct {
            fn lt(_: void, a: LsEntry, b: LsEntry) bool {
                if (a.hotspot_score != b.hotspot_score) return a.hotspot_score > b.hotspot_score;
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
    } else {
        std.mem.sort(LsEntry, entries.items, {}, struct {
            fn lt(_: void, a: LsEntry, b: LsEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
    }

    return entries.toOwnedSlice(allocator);
}

pub fn lsDirHotspotScore(self: *Explorer, prefix: []const u8, dir_name: []const u8) u32 {
    var score: u32 = 0;
    var child_prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const child_prefix = if (prefix.len == 0)
        std.fmt.bufPrint(&child_prefix_buf, "{s}/", .{dir_name}) catch return 0
    else
        std.fmt.bufPrint(&child_prefix_buf, "{s}/{s}/", .{ prefix, dir_name }) catch return 0;

    var iter = self.outlines.iterator();
    while (iter.next()) |kv| {
        const path = kv.key_ptr.*;
        if (!std.mem.startsWith(u8, path, child_prefix)) continue;
        const fo = kv.value_ptr.*;
        const dependent_count: u32 = @intCast(@min(self.dep_graph.importedByCount(path), std.math.maxInt(u32)));
        const sym_count: u32 = @intCast(fo.symbols.items.len);
        score +|= dependent_count +| sym_count;
    }
    return score;
}

pub fn isStubLikeOutline(outline: *const FileOutline) bool {
    if (!isStubCandidateLanguage(outline.language)) return false;
    const sym_count = outline.symbols.items.len;
    return outline.line_count > 0 and outline.line_count <= 80 and sym_count > 0 and sym_count <= 2;
}

pub fn buildOutlineDescriptor(allocator: std.mem.Allocator, outline: *const FileOutline) ![]const u8 {
    var functions: usize = 0;
    var methods: usize = 0;
    var types_count: usize = 0;
    var imports_count: usize = 0;
    var route_actions: usize = 0;
    var post_actions: usize = 0;
    var authorized = false;
    var first_type: ?Symbol = null;

    for (outline.symbols.items) |sym| {
        switch (sym.kind) {
            .function => functions += 1,
            .method => methods += 1,
            .class_def, .interface_def, .trait_def, .struct_def, .enum_def => {
                types_count += 1;
                if (first_type == null) first_type = sym;
            },
            .import => imports_count += 1,
            else => {},
        }
        if (sym.decorators.len > 0) {
            if (decoratorsContainText(sym.decorators, "Authorize")) authorized = true;
            if (decoratorsContainText(sym.decorators, "Http")) route_actions += 1;
            if (decoratorsContainText(sym.decorators, "HttpPost")) post_actions += 1;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (isStubLikeOutline(outline)) {
        try buf.appendSlice(allocator, "Stub");
    } else if (first_type) |sym| {
        try appendFmt(allocator, &buf, "{s} {s}", .{ @tagName(sym.kind), sym.name });
        if (extractBaseDescriptor(sym.detail)) |base| {
            try appendFmt(allocator, &buf, " extends {s}", .{base});
        }
    } else if (functions > 0) {
        try appendFmt(allocator, &buf, "{d} functions", .{functions});
    } else if (methods > 0) {
        try appendFmt(allocator, &buf, "{d} methods", .{methods});
    } else {
        try appendFmt(allocator, &buf, "{s} file", .{@tagName(outline.language)});
    }

    if (route_actions > 0) {
        try appendFmt(allocator, &buf, "; {d} routes", .{route_actions});
        if (post_actions > 0) try appendFmt(allocator, &buf, ", {d} POST", .{post_actions});
    } else if (methods > 0) {
        try appendFmt(allocator, &buf, "; {d} methods", .{methods});
    } else if (functions > 0 and first_type != null) {
        try appendFmt(allocator, &buf, "; {d} functions", .{functions});
    }

    if (types_count > 1) try appendFmt(allocator, &buf, "; {d} types", .{types_count});
    if (imports_count > 0) try appendFmt(allocator, &buf, "; {d} imports", .{imports_count});
    if (authorized) try buf.appendSlice(allocator, "; authorized");

    return buf.toOwnedSlice(allocator);
}

pub fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}

pub fn decoratorsContainText(decorators: []const []const u8, needle: []const u8) bool {
    for (decorators) |decorator| {
        if (std.mem.indexOf(u8, decorator, needle) != null) return true;
    }
    return false;
}

pub fn extractBaseDescriptor(detail: ?[]const u8) ?[]const u8 {
    const d = detail orelse return null;
    const colon = std.mem.indexOfScalar(u8, d, ':') orelse return null;
    var rest = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n{");
    if (std.mem.indexOfScalar(u8, rest, ',')) |comma| rest = rest[0..comma];
    if (std.mem.indexOfScalar(u8, rest, '{')) |brace| rest = rest[0..brace];
    rest = std.mem.trim(u8, rest, " \t\r\n");
    return if (rest.len > 0) rest else null;
}

pub fn isStubCandidateLanguage(lang: Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
        else => true,
    };
}
