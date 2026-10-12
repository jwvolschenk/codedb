const project_file = @import("../project_file.zig");
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
const pathglob = @import("pathglob.zig");

pub fn handleRoutes(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const framework = getStr(args, "framework") orelse "aspnet";
    if (!std.mem.eql(u8, framework, "aspnet")) {
        out.appendSlice(alloc, "error: unsupported framework; currently supported: aspnet") catch {};
        return;
    }

    // Large controllers sets (hundreds of actions) overflow client tool-result
    // limits, so output is windowed and filterable. Defaults keep small
    // projects byte-identical: the cap only bites past `max_results` routes.
    const max_results: usize = if (mcpj.getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 5000))) else default_max_routes;
    const offset: usize = if (mcpj.getInt(args, "offset")) |n| @intCast(@max(0, n)) else 0;
    const controller_filter = getStr(args, "controller");
    const method_filter = getStr(args, "method");
    const glob_filter = getStr(args, "path_glob");

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

    var shown: usize = 0;
    for (paths.items) |path| {
        if (glob_filter) |g| {
            if (!pathglob.globMatch(g, path)) continue;
        }
        const outline = explorer.outlines.get(path) orelse continue;
        for (outline.symbols.items) |sym| {
            if (sym.kind != .method) continue;
            const method = aspNetHttpMethod(sym.decorators) orelse if (decoratorsContain(sym.decorators, "Route")) "ANY" else continue;
            if (method_filter) |m| {
                if (!std.ascii.eqlIgnoreCase(m, method)) continue;
            }
            const controller = findEnclosingController(&outline, sym.line_start) orelse continue;
            if (controller_filter) |c| {
                if (!containsAsciiIgnoreCase(controller.name, c)) continue;
            }
            // Matching routes beyond the window are counted but not printed.
            const index = route_count;
            route_count += 1;
            if (index < offset or shown >= max_results) continue;
            shown += 1;
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
        }
    }

    if (route_count == 0) {
        w.writeAll("  (none)\n") catch {};
    } else if (shown == route_count) {
        w.print("({d} routes)\n", .{route_count}) catch {};
    } else {
        w.print("(showing {d}-{d} of {d} routes; narrow with controller=, method=, path_glob= or page with offset=/max_results=)\n", .{ if (shown == 0) 0 else offset + 1, offset + shown, route_count }) catch {};
    }
}

const default_max_routes: usize = 150;

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

    // Pass 1: string constants, so `GetSection(Constants.SSRS_CONFIG)` resolves.
    var consts = ConstMap.init(alloc);
    defer freeConstMap(alloc, &consts);
    for (paths.items) |path| {
        const outline = explorer.outlines.get(path) orelse continue;
        if (outline.language != .c_sharp) continue;
        const content = explorer.contents.get(path) orelse continue;
        collectCSharpConstants(alloc, path, content, &outline, &consts) catch {};
    }

    for (paths.items) |path| {
        const outline = explorer.outlines.get(path) orelse continue;
        const content = explorer.contents.get(path) orelse continue;
        if (isAspNetConfigJsonPath(path, outline.language)) {
            collectJsonConfigDefinitions(alloc, path, content, &definitions) catch {};
        } else if (outline.language == .c_sharp) {
            collectCSharpConfigReads(alloc, path, content, &outline, &consts, &reads, &read_hits) catch {};
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

    const def_keys = sortedMapKeys(alloc, &definitions) catch &.{};
    defer if (def_keys.len > 0) alloc.free(def_keys);
    const read_keys = sortedMapKeys(alloc, &reads) catch &.{};
    defer if (read_keys.len > 0) alloc.free(read_keys);

    // A definition is used when a read names it exactly OR names an ancestor
    // section (`GetSection("PowerBI")` / options binding consumes every key
    // under PowerBI). A read is missing only when no definition equals it or
    // sits beneath it.
    w.writeAll("  unused_definitions:\n") catch {};
    var unused_count: usize = 0;
    for (def_keys) |key| {
        var covered = false;
        for (read_keys) |read_key| {
            if (keyCoveredBySection(key, read_key)) {
                covered = true;
                break;
            }
        }
        if (covered) continue;
        w.print("    {s}\n", .{key}) catch {};
        unused_count += 1;
    }
    if (unused_count == 0) w.writeAll("    (none)\n") catch {};

    w.writeAll("  missing_definitions:\n") catch {};
    var missing_count: usize = 0;
    for (read_keys) |key| {
        var defined = false;
        for (def_keys) |def_key| {
            if (keyCoveredBySection(def_key, key)) {
                defined = true;
                break;
            }
        }
        if (defined) continue;
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
        const content = project_file.readAlloc(io, dir, entry.name, alloc, .limited(4 * 1024 * 1024)) catch continue;
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

fn collectJsonConfigDefinitions(alloc: std.mem.Allocator, path: []const u8, raw_content: []const u8, definitions: *std.StringHashMap(usize)) !void {
    _ = path;
    // Editors such as Visual Studio save appsettings.json with a UTF-8 BOM, which
    // std.json rejects; without this the file is silently dropped and every
    // configuration read is reported as a missing definition.
    const content = if (std.mem.startsWith(u8, raw_content, "\xEF\xBB\xBF")) raw_content[3..] else raw_content;
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

/// String constants (`const string Name = "Value"`) keyed by `<declaring type>.<Name>`
/// so `Constants.SSRS_CONFIG` and `ReadingWorkQueueOptions.ConfigKey` resolve to
/// the section names they hold. The declaring type comes from the file outline, so
/// several options classes can share one file; the file stem is only a fallback
/// when a constant sits outside any type. Keys and values are allocator-owned.
const ConstMap = std.StringHashMap([]const u8);

const ConfigCtx = struct {
    consts: *const ConstMap,
    /// Outline of the file being scanned, used to find the type enclosing a line.
    outline: *const explore_mod.FileOutline,
    /// File stem of the file being scanned; fallback for unqualified constants.
    stem: []const u8,
    /// 1-based line of the read being resolved (0 until set per line).
    line: u32 = 0,
};

/// Name of the innermost class/struct/interface/enum whose span contains `line`.
fn enclosingTypeName(outline: *const explore_mod.FileOutline, line: u32) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_span: u32 = std.math.maxInt(u32);
    for (outline.symbols.items) |sym| {
        switch (sym.kind) {
            .class_def, .struct_def, .interface_def, .enum_def => {},
            else => continue,
        }
        if (sym.line_start > line or sym.line_end < line) continue;
        const span = sym.line_end - sym.line_start;
        if (span < best_span) {
            best = sym.name;
            best_span = span;
        }
    }
    return best;
}

fn freeConstMap(alloc: std.mem.Allocator, consts: *ConstMap) void {
    var iter = consts.iterator();
    while (iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.*);
    }
    consts.deinit();
}

fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
}

fn collectCSharpConstants(alloc: std.mem.Allocator, path: []const u8, content: []const u8, outline: *const explore_mod.FileOutline, consts: *ConstMap) !void {
    const stem = fileStem(path);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (lines.next()) |line| {
        line_num += 1;
        const marker = std.mem.indexOf(u8, line, "string ") orelse continue;
        if (std.mem.indexOf(u8, line[0..marker], "const ") == null and std.mem.indexOf(u8, line[0..marker], "static readonly") == null) continue;
        var i = marker + "string ".len;
        const name_start = i;
        while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
        if (i == name_start) continue;
        const name = line[name_start..i];
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len or line[i] != '=') continue;
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len or line[i] != '"') continue;
        const close = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse continue;
        const owner = enclosingTypeName(outline, line_num) orelse stem;
        const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ owner, name });
        errdefer alloc.free(key);
        const value = try alloc.dupe(u8, line[i + 1 .. close]);
        errdefer alloc.free(value);
        const gop = try consts.getOrPut(key);
        if (gop.found_existing) {
            alloc.free(key);
            alloc.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = value;
    }
}

fn collectCSharpConfigReads(
    alloc: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    outline: *const explore_mod.FileOutline,
    consts: *const ConstMap,
    reads: *std.StringHashMap(usize),
    read_hits: *std.ArrayList(ConfigReadHit),
) !void {
    const ctx = ConfigCtx{ .consts = consts, .outline = outline, .stem = fileStem(path) };
    var line_num: u32 = 1;
    var start: usize = 0;
    while (start <= content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        try collectConfigReadsFromLine(alloc, path, line, line_num, ctx, reads, read_hits);
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
    ctx: ConfigCtx,
    reads: *std.StringHashMap(usize),
    read_hits: *std.ArrayList(ConfigReadHit),
) !void {
    // Only a key that is the direct argument of a configuration accessor is a
    // read. Matching every string on a line that merely mentions
    // "Configuration" (e.g. `ToolbarConfiguration.GetX("Grid")`) reports
    // unrelated literals as config keys.
    var line_ctx = ctx;
    line_ctx.line = line_num;
    var pos: usize = 0;
    while (pos < line.len) {
        const hit = nextConfigAccessorKey(line, pos, line_ctx) orelse break;
        pos = hit.next;
        if (!looksLikeConfigKey(hit.key)) continue;
        const owned_key = try alloc.dupe(u8, hit.key);
        errdefer alloc.free(owned_key);
        try incrementOwnedKey(alloc, reads, owned_key);
        try read_hits.append(alloc, .{
            .key = try alloc.dupe(u8, hit.key),
            .path = try alloc.dupe(u8, path),
            .line = line_num,
        });
    }
}

// `.Bind("Section", target)` reads a section by key; `section.Bind(target)` has
// no key argument and is ignored because `target` is not a known string constant.
const config_accessors = [_][]const u8{ ".GetSection", ".GetRequiredSection", ".GetValue", ".GetConnectionString", ".Bind" };

const ConfigAccessorHit = struct {
    key: []const u8,
    next: usize,
};

/// Find the next configuration read at or after `from`: either
/// `<receiver>["Key"]` where the receiver identifier mentions "config"
/// (`configuration`, `_config`, `Configuration`), or the first string argument
/// of `.GetSection(`, `.GetRequiredSection(`, `.GetValue<T>(` or
/// `.GetConnectionString(`.
fn nextConfigAccessorKey(line: []const u8, from: usize, ctx: ConfigCtx) ?ConfigAccessorHit {
    var best: ?ConfigAccessorHit = null;
    var best_start: usize = line.len;

    for (config_accessors) |accessor| {
        var search = from;
        while (std.mem.indexOfPos(u8, line, search, accessor)) |at| {
            search = at + accessor.len;
            var i = search;
            // Optional generic arguments: `.GetValue<bool>(`.
            if (i < line.len and line[i] == '<') {
                var depth: usize = 0;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '<') depth += 1;
                    if (line[i] == '>') {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
            }
            if (i >= line.len or line[i] != '(') continue;
            if (configArgAt(line, i + 1, ctx)) |hit| {
                if (at < best_start) {
                    best = hit;
                    best_start = at;
                }
                break;
            }
        }
    }

    var search = from;
    while (std.mem.indexOfScalarPos(u8, line, search, '[')) |open| {
        search = open + 1;
        var recv_start = open;
        while (recv_start > 0 and (std.ascii.isAlphanumeric(line[recv_start - 1]) or line[recv_start - 1] == '_')) recv_start -= 1;
        if (!containsAsciiIgnoreCase(line[recv_start..open], "config")) continue;
        if (configArgAt(line, open + 1, ctx)) |hit| {
            if (open < best_start) {
                best = hit;
                best_start = open;
            }
            break;
        }
    }
    return best;
}

/// If the argument at `line[start..]` (after optional spaces) is a string
/// literal or a known string constant (`Constants.SSRS_CONFIG`) followed by
/// `)`, `]` or `,`, return the key it names and the offset just past it.
fn configArgAt(line: []const u8, start: usize, ctx: ConfigCtx) ?ConfigAccessorHit {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;

    var key: []const u8 = undefined;
    var end: usize = undefined;
    if (line[i] == '"') {
        const close = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse return null;
        key = line[i + 1 .. close];
        end = close + 1;
    } else if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
        var j = i;
        while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_' or line[j] == '.')) j += 1;
        key = resolveConstant(line[i..j], ctx) orelse return null;
        end = j;
    } else return null;

    var after = end;
    while (after < line.len and (line[after] == ' ' or line[after] == '\t')) after += 1;
    // `GetValue<T>("Key", default)` is still a read of "Key".
    if (after >= line.len or (line[after] != ')' and line[after] != ']' and line[after] != ',')) return null;
    return .{ .key = key, .next = end };
}

/// Resolve `Class.NAME` (last two segments) or an unqualified `NAME` (looked up
/// in the type enclosing the read) against the collected string constants.
fn resolveConstant(expr: []const u8, ctx: ConfigCtx) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const name = if (std.mem.lastIndexOfScalar(u8, expr, '.')) |dot| expr[dot + 1 ..] else expr;
    var qualifier = enclosingTypeName(ctx.outline, ctx.line) orelse ctx.stem;
    if (std.mem.lastIndexOfScalar(u8, expr, '.')) |dot| {
        const head = expr[0..dot];
        qualifier = if (std.mem.lastIndexOfScalar(u8, head, '.')) |d2| head[d2 + 1 ..] else head;
    }
    const joined = std.fmt.bufPrint(&buf, "{s}.{s}", .{ qualifier, name }) catch return null;
    return ctx.consts.get(joined);
}

fn keysEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// True when `key` is `section` itself or lives underneath it
/// (`PowerBI:ClientId` is under `PowerBI`). Configuration keys are
/// case-insensitive in .NET.
fn keyCoveredBySection(key: []const u8, section: []const u8) bool {
    if (keysEqual(key, section)) return true;
    return key.len > section.len and key[section.len] == ':' and keysEqual(key[0..section.len], section);
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
