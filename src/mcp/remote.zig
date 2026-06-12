// codedb MCP — remote repository (DeepWiki) tool handler + slug helpers.
const std = @import("std");
const testing = std.testing;
const cio = @import("../cio.zig");
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const eql = mcpj.eql;

pub fn isRemoteRepoChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

pub fn isRemoteRepoPart(part: []const u8) bool {
    if (part.len == 0) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| {
        if (!isRemoteRepoChar(c)) return false;
    }
    return true;
}

pub fn appendSlugChar(out: []u8, len: *usize, c: u8, last_dash: *bool) void {
    const lower = std.ascii.toLower(c);
    if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
        out[len.*] = lower;
        len.* += 1;
        last_dash.* = false;
    } else if (!last_dash.* and len.* > 0) {
        out[len.*] = '-';
        len.* += 1;
        last_dash.* = true;
    }
}

pub fn ingestSlugForOwnerRepo(owner: []const u8, repo: []const u8, buf: []u8) ?[]const u8 {
    if (!isRemoteRepoPart(owner) or !isRemoteRepoPart(repo)) return null;

    var len: usize = 0;
    var last_dash = false;
    for (owner) |c| appendSlugChar(buf, &len, c, &last_dash);
    appendSlugChar(buf, &len, '-', &last_dash);
    for (repo) |c| appendSlugChar(buf, &len, c, &last_dash);
    if (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) return null;
    return buf[0..len];
}

pub fn wikiSlugForRepo(repo: []const u8, buf: []u8) ?[]const u8 {
    if (repo.len == 0 or repo.len >= buf.len or repo[0] == '/') return null;
    if (std.mem.indexOf(u8, repo, "..") != null or
        std.mem.indexOf(u8, repo, "//") != null)
    {
        return null;
    }

    if (std.mem.indexOfScalar(u8, repo, '/')) |slash_pos| {
        if (std.mem.indexOfScalarPos(u8, repo, slash_pos + 1, '/') != null) return null;
        return ingestSlugForOwnerRepo(repo[0..slash_pos], repo[slash_pos + 1 ..], buf);
    }

    if (!isRemoteRepoPart(repo)) return null;
    @memcpy(buf[0..repo.len], repo);
    return buf[0..repo.len];
}

test "wikiSlugForRepo normalizes owner repo and raw slugs" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings("justrach-codedb", wikiSlugForRepo("justrach/codedb", buf[0..]).?);
    try testing.expectEqualStrings("vercel-next-js", wikiSlugForRepo("vercel/next.js", buf[0..]).?);
    try testing.expectEqualStrings("owner-repo-name", wikiSlugForRepo("OWNER/Repo.Name", buf[0..]).?);
    try testing.expectEqualStrings("chromium", wikiSlugForRepo("chromium", buf[0..]).?);
}

test "remote repo validation rejects traversal and malformed paths" {
    var buf: [256]u8 = undefined;

    try testing.expect(wikiSlugForRepo("chromium", buf[0..]) != null);
    try testing.expect(wikiSlugForRepo("../codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach//codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach/codedb/extra", buf[0..]) == null);
}

pub const RemoteParam = struct { name: []const u8, value: []const u8 };

/// Run `curl -G` against URL with optional query params. Caller frees result.stdout/stderr.
pub const RemoteResponse = struct {
    captured: cio.CaptureResult,
    /// HTTP status code (0 = curl failed before -w fired / sentinel not found).
    status: u16,
    /// Length of the response body within `captured.stdout`. The body is
    /// `captured.stdout[0..body_len]`; the suffix is the curl status sentinel.
    body_len: usize,
};

pub const STATUS_SENTINEL = "[CODEDB-STATUS]";

/// Run `curl -G` against URL with optional query params. Captures HTTP status
/// via `-w` and lets non-2xx responses through (no `-f`) so callers can format
/// detailed errors. Caller frees response.captured.stdout/stderr.
pub fn fetchRemote(
    alloc: std.mem.Allocator,
    url: []const u8,
    params: []const RemoteParam,
) !RemoteResponse {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, "curl");
    try argv.append(alloc, "-s");
    try argv.append(alloc, "--max-time");
    try argv.append(alloc, "30");
    try argv.append(alloc, "-w");
    try argv.append(alloc, "\n" ++ STATUS_SENTINEL ++ "%{http_code}");

    var pair_bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (pair_bufs.items) |b| alloc.free(b);
        pair_bufs.deinit(alloc);
    }

    if (params.len > 0) {
        try argv.append(alloc, "-G");
        try pair_bufs.ensureTotalCapacity(alloc, params.len);
        for (params) |p| {
            const buf = try std.fmt.allocPrint(alloc, "{s}={s}", .{ p.name, p.value });
            try pair_bufs.append(alloc, buf);
            try argv.append(alloc, "--data-urlencode");
            try argv.append(alloc, buf);
        }
    }
    try argv.append(alloc, url);

    const captured = try cio.runCapture(.{ .allocator = alloc, .argv = argv.items });

    var status: u16 = 0;
    var body_len: usize = captured.stdout.len;
    if (std.mem.lastIndexOf(u8, captured.stdout, STATUS_SENTINEL)) |sentinel_idx| {
        const status_str = std.mem.trim(u8, captured.stdout[sentinel_idx + STATUS_SENTINEL.len ..], " \r\n\t");
        status = std.fmt.parseInt(u16, status_str, 10) catch 0;
        // Strip the trailing "\n[CODEDB-STATUS]NNN" from the body view.
        var end = sentinel_idx;
        while (end > 0 and captured.stdout[end - 1] == '\n') end -= 1;
        body_len = end;
    }

    return .{ .captured = captured, .status = status, .body_len = body_len };
}

pub fn handleRemote(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const repo = getStr(args, "repo") orelse {
        out.appendSlice(alloc, "error: missing 'repo' (e.g. justrach/merjs)") catch {};
        return;
    };
    const action = getStr(args, "action") orelse {
        out.appendSlice(alloc, "error: missing 'action' (actions, tree, outline, search, read, symbol, policy, deps, score, cves, commits, branches, dep-history)") catch {};
        return;
    };

    // api.wiki.codes is the remote backend. Keep backend=wiki as a tolerated
    // compatibility arg, but never route elsewhere.
    if (getStr(args, "backend")) |backend| {
        if (!std.mem.eql(u8, backend, "wiki")) {
            out.appendSlice(alloc, "error: invalid backend, only 'wiki' / api.wiki.codes is supported") catch {};
            return;
        }
    }

    const wiki_actions = [_][]const u8{
        "tree",
        "outline",
        "search",
        "read",
        "symbol",
        "policy",
        "deps",
        "score",
        "cves",
        "commits",
        "branches",
        "dep-history",
        "actions",
    };
    var action_valid = false;
    for (&wiki_actions) |va| {
        if (std.mem.eql(u8, action, va)) {
            action_valid = true;
            break;
        }
    }
    if (!action_valid) {
        out.appendSlice(alloc, "error: action '") catch {};
        out.appendSlice(alloc, action) catch {};
        out.appendSlice(alloc, "' not supported by api.wiki.codes (supports: tree, outline, search, read, symbol, policy, deps, score, cves, commits, branches, dep-history, actions)") catch {};
        return;
    }

    var wiki_slug_buf: [256]u8 = undefined;
    const wiki_slug = wikiSlugForRepo(repo, wiki_slug_buf[0..]) orelse {
        out.appendSlice(alloc, "error: invalid wiki repo, use owner/repo or raw wiki slug (e.g. vercel/next.js or chromium)") catch {};
        return;
    };

    const query = getStr(args, "query");

    // Require a non-empty 'query' for actions that consume it. Sending an
    // empty value silently masked real user mistakes.
    const needs_query = std.mem.eql(u8, action, "search") or
        std.mem.eql(u8, action, "symbol") or
        std.mem.eql(u8, action, "outline");
    if (needs_query and (query == null or query.?.len == 0)) {
        out.appendSlice(alloc, "error: action '") catch {};
        out.appendSlice(alloc, action) catch {};
        if (std.mem.eql(u8, action, "search")) {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the search text)") catch {};
        } else if (std.mem.eql(u8, action, "symbol")) {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the identifier name to look up)") catch {};
        } else {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the file path to outline)") catch {};
        }
        return;
    }

    // 'read' takes the file path via a dedicated `path` arg so the schema is
    // explicit; outline keeps the legacy `query`-as-path overload.
    const path_arg = getStr(args, "path");
    if (std.mem.eql(u8, action, "read") and (path_arg == null or path_arg.?.len == 0)) {
        out.appendSlice(alloc, "error: action 'read' requires a non-empty 'path' (the file path to fetch)") catch {};
        return;
    }

    var scope_value: []const u8 = "runtime";
    if (std.mem.eql(u8, action, "score") or std.mem.eql(u8, action, "cves")) {
        scope_value = getStr(args, "scope") orelse query orelse "runtime";
        if (!std.mem.eql(u8, scope_value, "runtime") and !std.mem.eql(u8, scope_value, "all")) {
            out.appendSlice(alloc, "error: scope must be 'runtime' or 'all'") catch {};
            return;
        }
    }

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://api.wiki.codes/api/{s}/{s}", .{ wiki_slug, action }) catch {
        out.appendSlice(alloc, "error: URL too long") catch {};
        return;
    };

    // Build the URL params list. Action-specific arg first, then optional
    // pagination/filter params. Server is free to ignore unknown keys.
    var int_bufs: [4][32]u8 = undefined;
    var int_slot: usize = 0;
    var params: std.ArrayList(RemoteParam) = .empty;
    defer params.deinit(alloc);

    if (std.mem.eql(u8, action, "search")) {
        if (query) |q| params.append(alloc, .{ .name = "q", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "symbol")) {
        if (query) |q| params.append(alloc, .{ .name = "name", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "outline")) {
        if (query) |q| params.append(alloc, .{ .name = "path", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "read")) {
        if (path_arg) |p| params.append(alloc, .{ .name = "path", .value = p }) catch {};
        if (getStr(args, "lines")) |l| {
            if (l.len > 0) params.append(alloc, .{ .name = "lines", .value = l }) catch {};
        }
    } else if (std.mem.eql(u8, action, "score") or std.mem.eql(u8, action, "cves")) {
        params.append(alloc, .{ .name = "scope", .value = scope_value }) catch {};
    }

    // Optional pagination/filter params. Forward them consistently for every
    // action whose wiki endpoint can page or cap large arrays.
    const takes_limit = std.mem.eql(u8, action, "search") or
        std.mem.eql(u8, action, "tree") or
        std.mem.eql(u8, action, "deps") or
        std.mem.eql(u8, action, "commits") or
        std.mem.eql(u8, action, "branches") or
        std.mem.eql(u8, action, "dep-history");
    const takes_offset = std.mem.eql(u8, action, "tree") or
        std.mem.eql(u8, action, "deps") or
        std.mem.eql(u8, action, "commits") or
        std.mem.eql(u8, action, "branches") or
        std.mem.eql(u8, action, "dep-history");

    if (takes_limit) {
        if (getInt(args, "limit")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{@max(0, n)}) catch "0";
            params.append(alloc, .{ .name = "limit", .value = s }) catch {};
            int_slot += 1;
        }
    }
    if (takes_offset) {
        if (getInt(args, "offset")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{@max(0, n)}) catch "0";
            params.append(alloc, .{ .name = "offset", .value = s }) catch {};
            int_slot += 1;
        }
    }

    if (std.mem.eql(u8, action, "tree")) {
        if (getStr(args, "prefix")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "prefix", .value = v }) catch {};
        }
        if (args.get("expand")) |expand_val| {
            switch (expand_val) {
                .bool => |expand| {
                    if (expand) {
                        params.append(alloc, .{ .name = "expand", .value = "true" }) catch {};
                    } else {
                        params.append(alloc, .{ .name = "summary", .value = "true" }) catch {};
                    }
                },
                else => {},
            }
        }
    } else if (std.mem.eql(u8, action, "commits") or std.mem.eql(u8, action, "dep-history")) {
        if (getStr(args, "since")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "since", .value = v }) catch {};
        }
    }

    const remote = fetchRemote(alloc, url, params.items) catch {
        out.appendSlice(alloc, "error: failed to fetch from api.wiki.codes") catch {};
        return;
    };
    defer alloc.free(remote.captured.stdout);
    defer alloc.free(remote.captured.stderr);

    const body = remote.captured.stdout[0..remote.body_len];

    // 2xx = success, anything else gets a status-tagged error so callers can
    // tell 404 (slug missing this artifact) from 5xx (real server bug).
    if (remote.status >= 200 and remote.status < 300) {
        out.appendSlice(alloc, body) catch {};
        return;
    }

    out.appendSlice(alloc, "error: ") catch {};
    out.appendSlice(alloc, "api.wiki.codes") catch {};
    if (remote.status == 0) {
        out.appendSlice(alloc, " transport error for ") catch {};
    } else {
        var status_buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&status_buf, "{d}", .{remote.status}) catch "0";
        out.appendSlice(alloc, " HTTP ") catch {};
        out.appendSlice(alloc, s) catch {};
        out.appendSlice(alloc, " for ") catch {};
    }
    out.appendSlice(alloc, wiki_slug) catch {};
    out.appendSlice(alloc, "/") catch {};
    out.appendSlice(alloc, action) catch {};
    if (body.len > 0) {
        out.appendSlice(alloc, " - ") catch {};
        out.appendSlice(alloc, body[0..@min(body.len, 200)]) catch {};
    } else if (remote.captured.stderr.len > 0) {
        out.appendSlice(alloc, " - ") catch {};
        out.appendSlice(alloc, remote.captured.stderr[0..@min(remote.captured.stderr.len, 200)]) catch {};
    }
}

// ── Local project tools ─────────────────────────────────────────────────────
