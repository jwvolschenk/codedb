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

pub fn handleConfigXref(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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

    const w = cio.listWriter(out, alloc);
    w.writeAll("ASP.NET config xref:\n") catch {};
    w.print("  definitions: {d}\n", .{definitions.count()}) catch {};
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

fn isAspNetConfigJsonPath(path: []const u8, language: explore_mod.Language) bool {
    if (language != .json) return false;
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "appsettings") and std.mem.endsWith(u8, base, ".json");
}

fn collectJsonConfigDefinitions(alloc: std.mem.Allocator, path: []const u8, content: []const u8, definitions: *std.StringHashMap(usize)) !void {
    _ = path;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
    defer parsed.deinit();

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    try walkJsonConfigValue(alloc, &parsed.value, &stack, definitions);
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
