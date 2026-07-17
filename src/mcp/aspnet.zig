// codedb MCP — ASP.NET tool implementations.
//
// Extracted from mcp.zig to keep the route/config-xref subsystem (which is
// framework-specific and largely self-contained) in its own file. Entry
// points (`handleRoutes`, `handleConfigXref`, `decoratorsContain`) are
// re-exported by mcp.zig so existing call sites keep resolving.

const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;

pub fn handleRoutes(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const framework = getStr(args, "framework") orelse "aspnet";
    if (!std.mem.eql(u8, framework, "aspnet")) {
        out.appendSlice(alloc, "error: unsupported framework; currently supported: aspnet") catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    w.writeAll("ASP.NET routes:\n") catch {};

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var route_count: usize = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);
    var iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.language == .c_sharp) paths.append(alloc, entry.key_ptr.*) catch {};
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (paths.items) |path| {
        const outline = explorer.outlines.get(path) orelse continue;
        for (outline.symbols.items) |sym| {
            if (sym.kind != .method) continue;
            const method = aspNetHttpMethod(sym.decorators) orelse if (decoratorsContain(sym.decorators, "Route")) "ANY" else continue;
            const controller = findEnclosingController(&outline, sym.line_start) orelse continue;
            const action_template = aspNetRouteTemplate(sym.decorators) orelse "";
            const class_template = aspNetRouteTemplate(controller.decorators) orelse "[controller]/[action]";
            var route_buf: [512]u8 = undefined;
            const route = formatAspNetRoute(&route_buf, class_template, action_template, controller.name, sym.name) orelse "";
            const authorize = decoratorsContain(controller.decorators, "Authorize") or decoratorsContain(sym.decorators, "Authorize");
            const antiforgery = decoratorsContain(sym.decorators, "ValidateAntiForgeryToken");
            const missing_antiforgery = std.mem.eql(u8, method, "POST") and !antiforgery;
            w.print("  {s} /{s} -> {s}.{s} ({s}:{d})", .{ method, route, controller.name, sym.name, path, sym.line_start }) catch {};
            if (authorize) w.writeAll(" [authorize]") catch {};
            if (antiforgery) w.writeAll(" [antiforgery]") catch {};
            if (missing_antiforgery) w.writeAll(" [missing_antiforgery]") catch {};
            w.writeAll("\n") catch {};
            route_count += 1;
        }
    }

    if (route_count == 0) {
        w.writeAll("  (none)\n") catch {};
    } else {
        w.print("({d} routes)\n", .{route_count}) catch {};
    }
}

pub const ConfigReadHit = struct {
    key: []const u8,
    path: []const u8,
    line: u32,
};

pub fn handleConfigXref(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer, project_root: []const u8) void {
    const framework = getStr(args, "framework") orelse "aspnet";
    if (!std.mem.eql(u8, framework, "aspnet")) {
        out.appendSlice(alloc, "error: unsupported framework; currently supported: aspnet") catch {};
        return;
    }

    var definitions = std.StringHashMap(usize).init(alloc);
    defer {
        var iter = definitions.iterator();
        while (iter.next()) |entry| alloc.free(entry.key_ptr.*);
        definitions.deinit();
    }

    var reads = std.StringHashMap(usize).init(alloc);
    defer {
        var iter = reads.iterator();
        while (iter.next()) |entry| alloc.free(entry.key_ptr.*);
        reads.deinit();
    }

    var read_hits: std.ArrayList(ConfigReadHit) = .empty;
    defer {
        for (read_hits.items) |hit| {
            alloc.free(hit.key);
            alloc.free(hit.path);
        }
        read_hits.deinit(alloc);
    }

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);
    var iter = explorer.outlines.iterator();
    while (iter.next()) |entry| paths.append(alloc, entry.key_ptr.*) catch {};
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (paths.items) |path| {
        const outline = explorer.outlines.get(path) orelse continue;
        const content = explorer.contents.get(path) orelse continue;
        if (isAspNetConfigJsonPath(path, outline.language)) {
            collectJsonConfigDefinitions(alloc, path, content, &definitions) catch {};
        } else if (outline.language == .c_sharp) {
            collectCSharpConfigReads(alloc, path, content, &reads, &read_hits) catch {};
        }
    }

    // appsettings*.json is normally EXCLUDED from the index (it can hold
    // secrets), so the loop above finds no definitions in real projects.
    // Parse key paths on demand from disk instead — keys only, the parsed
    // values never reach the output or any index. Candidate dirs: the
    // project root plus every indexed dir holding a Program.cs/Startup.cs.
    var ondemand_sources: std.ArrayList([]const u8) = .empty;
    defer {
        for (ondemand_sources.items) |s| alloc.free(s);
        ondemand_sources.deinit(alloc);
    }
    if (definitions.count() == 0 and project_root.len > 0) {
        var candidate_dirs = std.StringHashMap(void).init(alloc);
        defer candidate_dirs.deinit();
        candidate_dirs.put("", {}) catch {};
        for (paths.items) |path| {
            const base = std.fs.path.basename(path);
            if (!std.mem.eql(u8, base, "Program.cs") and !std.mem.eql(u8, base, "Startup.cs")) continue;
            const dir = std.fs.path.dirname(path) orelse "";
            candidate_dirs.put(dir, {}) catch {};
        }
        var dir_iter = candidate_dirs.keyIterator();
        while (dir_iter.next()) |rel_dir| {
            collectOnDemandConfigDefinitions(io, alloc, project_root, rel_dir.*, &definitions, &ondemand_sources) catch {};
        }
    }

    const w = cio.listWriter(out, alloc);
    w.writeAll("ASP.NET config xref:\n") catch {};
    w.print("  definitions: {d}\n", .{definitions.count()}) catch {};
    if (ondemand_sources.items.len > 0) {
        w.writeAll("  definitions_source: parsed on demand (keys only; appsettings files stay excluded from the index):\n") catch {};
        for (ondemand_sources.items) |s| {
            w.print("    {s}\n", .{s}) catch {};
        }
    }
    w.print("  reads: {d}\n", .{read_hits.items.len}) catch {};

    w.writeAll("  read_sites:\n") catch {};
    if (read_hits.items.len == 0) {
        w.writeAll("    (none)\n") catch {};
    } else {
        for (read_hits.items) |hit| {
            w.print("    {s}: {s}:{d}\n", .{ hit.key, hit.path, hit.line }) catch {};
        }
    }

    w.writeAll("  unused_definitions:\n") catch {};
    var unused_count: usize = 0;
    const def_keys = sortedMapKeys(alloc, &definitions) catch &.{};
    defer if (def_keys.len > 0) alloc.free(def_keys);
    for (def_keys) |key| {
        if (reads.contains(key)) continue;
        w.print("    {s}\n", .{key}) catch {};
        unused_count += 1;
    }
    if (unused_count == 0) w.writeAll("    (none)\n") catch {};

    w.writeAll("  missing_definitions:\n") catch {};
    var missing_count: usize = 0;
    const read_keys = sortedMapKeys(alloc, &reads) catch &.{};
    defer if (read_keys.len > 0) alloc.free(read_keys);
    for (read_keys) |key| {
        if (definitions.contains(key)) continue;
        w.print("    {s}\n", .{key}) catch {};
        missing_count += 1;
    }
    if (missing_count == 0) w.writeAll("    (none)\n") catch {};
}

fn sortedMapKeys(alloc: std.mem.Allocator, map: *const std.StringHashMap(usize)) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(alloc);
    try keys.ensureTotalCapacity(alloc, map.count());
    var iter = map.keyIterator();
    while (iter.next()) |key| keys.appendAssumeCapacity(key.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return keys.toOwnedSlice(alloc);
}

/// Read `appsettings*.json` files in `<project_root>/<rel_dir>` and merge
/// their KEY PATHS into `definitions`. Values are parsed transiently and
/// discarded — they must never be indexed, cached, or printed.
fn collectOnDemandConfigDefinitions(
    io: std.Io,
    alloc: std.mem.Allocator,
    project_root: []const u8,
    rel_dir: []const u8,
    definitions: *std.StringHashMap(usize),
    sources: *std.ArrayList([]const u8),
) !void {
    const dir_path = if (rel_dir.len == 0)
        try alloc.dupe(u8, project_root)
    else
        try std.fs.path.join(alloc, &.{ project_root, rel_dir });
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "appsettings")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const content = dir.readFileAlloc(io, entry.name, alloc, .limited(4 * 1024 * 1024)) catch continue;
        defer alloc.free(content);
        collectJsonConfigDefinitions(alloc, entry.name, content, definitions) catch continue;
        const rel = if (rel_dir.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fs.path.join(alloc, &.{ rel_dir, entry.name });
        try sources.append(alloc, rel);
    }
}

fn isAspNetConfigJsonPath(path: []const u8, language: explore_mod.Language) bool {
    if (language != .json) return false;
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "appsettings") and std.mem.endsWith(u8, base, ".json");
}

fn collectJsonConfigDefinitions(alloc: std.mem.Allocator, path: []const u8, content: []const u8, definitions: *std.StringHashMap(usize)) !void {
    _ = path;
    // ASP.NET tooling writes JSONC — appsettings files routinely carry
    // `//` and `/* */` comments that std.json rejects. Strip them (outside
    // strings) so real-world files parse.
    const stripped = stripJsoncComments(alloc, content) catch content;
    defer if (stripped.ptr != content.ptr) alloc.free(stripped);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, stripped, .{}) catch return;
    defer parsed.deinit();

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    try walkJsonConfigValue(alloc, &parsed.value, &stack, definitions);
}

/// Replace `//` line comments and `/* */` block comments (outside strings)
/// with spaces, preserving offsets and newlines.
fn stripJsoncComments(alloc: std.mem.Allocator, content: []const u8) ![]const u8 {
    var out = try alloc.dupe(u8, content);
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                if (out[i] != '\n') out[i] = ' ';
            }
            if (i + 1 < out.len) {
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 1;
            }
            continue;
        }
    }
    return out;
}

fn walkJsonConfigValue(alloc: std.mem.Allocator, value: *const std.json.Value, stack: *std.ArrayList([]const u8), definitions: *std.StringHashMap(usize)) !void {
    switch (value.*) {
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                try stack.append(alloc, entry.key_ptr.*);
                try walkJsonConfigValue(alloc, entry.value_ptr, stack, definitions);
                _ = stack.pop();
            }
        },
        .array => |array| {
            for (array.items) |*item| try walkJsonConfigValue(alloc, item, stack, definitions);
        },
        else => {
            if (stack.items.len == 0) return;
            const key = try joinConfigPath(alloc, stack.items);
            errdefer alloc.free(key);
            try incrementOwnedKey(alloc, definitions, key);
        },
    }
}

fn collectCSharpConfigReads(
    alloc: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    reads: *std.StringHashMap(usize),
    read_hits: *std.ArrayList(ConfigReadHit),
) !void {
    var line_num: u32 = 1;
    var start: usize = 0;
    while (start <= content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        try collectConfigReadsFromLine(alloc, path, line, line_num, reads, read_hits);
        if (end == content.len) break;
        start = end + 1;
        line_num += 1;
    }
}

fn collectConfigReadsFromLine(
    alloc: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    line_num: u32,
    reads: *std.StringHashMap(usize),
    read_hits: *std.ArrayList(ConfigReadHit),
) !void {
    if (!containsAsciiIgnoreCase(line, "configuration")) return;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, pos, '"')) |start_quote| {
        const end_quote = std.mem.indexOfScalarPos(u8, line, start_quote + 1, '"') orelse break;
        const key = line[start_quote + 1 .. end_quote];
        pos = end_quote + 1;
        if (!looksLikeConfigKey(key)) continue;
        const owned_key = try alloc.dupe(u8, key);
        errdefer alloc.free(owned_key);
        try incrementOwnedKey(alloc, reads, owned_key);
        try read_hits.append(alloc, .{
            .key = try alloc.dupe(u8, key),
            .path = try alloc.dupe(u8, path),
            .line = line_num,
        });
    }
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn looksLikeConfigKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key.len > 256) return false;
    for (key) |c| {
        if (std.ascii.isAlphanumeric(c) or c == ':' or c == '_' or c == '-' or c == '.') continue;
        return false;
    }
    return true;
}

fn joinConfigPath(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var len: usize = 0;
    for (parts, 0..) |part, i| len += part.len + if (i == 0) @as(usize, 0) else @as(usize, 1);
    var out = try alloc.alloc(u8, len);
    var pos: usize = 0;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            out[pos] = ':';
            pos += 1;
        }
        @memcpy(out[pos .. pos + part.len], part);
        pos += part.len;
    }
    return out;
}

fn incrementOwnedKey(alloc: std.mem.Allocator, map: *std.StringHashMap(usize), owned_key: []const u8) !void {
    const gop = try map.getOrPut(owned_key);
    if (gop.found_existing) {
        alloc.free(owned_key);
        gop.value_ptr.* += 1;
    } else {
        gop.value_ptr.* = 1;
    }
}

fn findEnclosingController(outline: *const explore_mod.FileOutline, line_num: u32) ?explore_mod.Symbol {
    var best: ?explore_mod.Symbol = null;
    var best_span: u32 = std.math.maxInt(u32);
    for (outline.symbols.items) |sym| {
        if (sym.kind != .class_def) continue;
        if (!std.mem.endsWith(u8, sym.name, "Controller")) continue;
        if (sym.line_start > line_num or sym.line_end < line_num) continue;
        const span = sym.line_end - sym.line_start;
        if (span < best_span) {
            best = sym;
            best_span = span;
        }
    }
    return best;
}

fn aspNetHttpMethod(decorators: []const []const u8) ?[]const u8 {
    for (decorators) |decorator| {
        if (std.mem.indexOf(u8, decorator, "HttpGet") != null) return "GET";
        if (std.mem.indexOf(u8, decorator, "HttpPost") != null) return "POST";
        if (std.mem.indexOf(u8, decorator, "HttpPut") != null) return "PUT";
        if (std.mem.indexOf(u8, decorator, "HttpDelete") != null) return "DELETE";
        if (std.mem.indexOf(u8, decorator, "HttpPatch") != null) return "PATCH";
        if (std.mem.indexOf(u8, decorator, "HttpHead") != null) return "HEAD";
    }
    return null;
}

fn aspNetRouteTemplate(decorators: []const []const u8) ?[]const u8 {
    for (decorators) |decorator| {
        if (std.mem.indexOf(u8, decorator, "Route") == null and std.mem.indexOf(u8, decorator, "Http") == null) continue;
        if (extractFirstQuoted(decorator)) |quoted| return quoted;
        if (std.mem.indexOfScalar(u8, decorator, '(') == null) return "";
    }
    return null;
}

fn extractFirstQuoted(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const end_rel = std.mem.indexOfScalar(u8, s[start + 1 ..], '"') orelse return null;
    return s[start + 1 .. start + 1 + end_rel];
}

fn formatAspNetRoute(buf: []u8, class_template: []const u8, action_template: []const u8, controller_name: []const u8, action_name: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .initBuffer(buf);
    appendRouteTemplate(&out, class_template, controller_name, action_name) catch return null;
    if (action_template.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '/') out.appendBounded('/') catch return null;
        appendRouteTemplate(&out, action_template, controller_name, action_name) catch return null;
    }
    trimRouteSlashes(&out);
    return out.items;
}

fn appendRouteTemplate(out: *std.ArrayList(u8), template: []const u8, controller_name: []const u8, action_name: []const u8) !void {
    const controller = stripControllerSuffix(controller_name);
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "[controller]")) {
            try out.appendSliceBounded(controller);
            i += "[controller]".len;
        } else if (std.mem.startsWith(u8, template[i..], "[action]")) {
            try out.appendSliceBounded(action_name);
            i += "[action]".len;
        } else {
            try out.appendBounded(template[i]);
            i += 1;
        }
    }
}

fn stripControllerSuffix(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, "Controller")) name[0 .. name.len - "Controller".len] else name;
}

fn trimRouteSlashes(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and out.items[0] == '/') {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '/') {
        out.items.len -= 1;
    }
}

pub fn decoratorsContain(decorators: []const []const u8, needle: []const u8) bool {
    for (decorators) |decorator| {
        if (std.mem.indexOf(u8, decorator, needle) != null) return true;
    }
    return false;
}

const getStr = mcpj.getStr;
