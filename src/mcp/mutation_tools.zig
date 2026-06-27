// codedb MCP — mutation tool handlers.
//
// Extracted from mcp.zig. Each handler takes args + explorer/store/etc. and
// appends a text response to `out`. mcp.zig re-imports them so the dispatch
// table keeps resolving.

const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const edit_mod = @import("../edit.zig");
const snapshot_json = @import("../snapshot_json.zig");
const watcher = @import("../watcher.zig");
const telemetry_mod = @import("../telemetry.zig");
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const eql = mcpj.eql;

const mcp = @import("../mcp.zig");
const SnapshotCache = mcp.SnapshotCache;
const appendBundleArgKeysDiagnostic = mcp.appendBundleArgKeysDiagnostic;
const appendFuzzyPathSuggestions = mcp.appendFuzzyPathSuggestions;
const getScanState = mcp.getScanState;

const pathglob = @import("pathglob.zig");
const isPathSafe = pathglob.isPathSafe;

pub fn handleRead(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
        return;
    }
    if (watcher.isSensitivePath(path)) {
        out.appendSlice(alloc, "error: access to sensitive file blocked") catch {};
        return;
    }
    // Try indexed content first (faster, consistent with indexed view)
    const cached = explorer.getContent(path, alloc) catch {
        out.appendSlice(alloc, "error: read failed") catch {};
        return;
    };
    const content = if (cached) |owned_content|
        owned_content
    else blk: {
        // Fall back to disk read
        break :blk std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024)) catch {
            out.appendSlice(alloc, "error: failed to read file: ") catch {};
            out.appendSlice(alloc, path) catch {};
            // Issue #356-p3: fuzzy fallback so a mistyped path is recoverable
            // without a separate codedb_find round-trip — same shape as
            // codedb_outline already does.
            appendFuzzyPathSuggestions(alloc, out, explorer, path);
            return;
        };
    };
    defer alloc.free(content);

    // Bug 5: detect binary content (NUL byte in first 8KB) and stub the
    // response — dumping raw bytes corrupts JSON consumers and leaks tokens
    // for files that are never useful to a model.
    const probe_len = @min(content.len, 8 * 1024);
    if (std.mem.indexOfScalar(u8, content[0..probe_len], 0) != null) {
        const w0 = cio.listWriter(out, alloc);
        const hash_b = std.hash.Wyhash.hash(0, content);
        w0.print("binary file: {d} bytes  hash:{x}\n", .{ content.len, hash_b }) catch {};
        return;
    }

    // Content-hash ETag
    const hash = std.hash.Wyhash.hash(0, content);
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch "";
    const if_hash = getStr(args, "if_hash");
    if (if_hash) |prev| {
        if (std.mem.eql(u8, prev, hash_str)) {
            out.appendSlice(alloc, "unchanged:") catch {};
            out.appendSlice(alloc, hash_str) catch {};
            return;
        }
    }

    // Line range params
    const line_start_raw = getInt(args, "line_start");
    const line_end_raw = getInt(args, "line_end");
    const compact = getBool(args, "compact");
    const has_range = line_start_raw != null or line_end_raw != null;

    // Bug 6: validate line range explicitly. Pre-fix: invalid ranges silently
    // returned an empty body (just the hash line) — agents read that as "file
    // is empty in that range" instead of "you passed nonsense".
    if (line_start_raw) |ls| {
        if (ls < 1) {
            out.appendSlice(alloc, "error: line_start must be >= 1") catch {};
            return;
        }
    }
    if (line_end_raw) |le| {
        if (le < 1) {
            out.appendSlice(alloc, "error: line_end must be >= 1") catch {};
            return;
        }
    }
    if (line_start_raw != null and line_end_raw != null) {
        if (line_start_raw.? > line_end_raw.?) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: line_start ({d}) > line_end ({d})", .{ line_start_raw.?, line_end_raw.? }) catch {};
            return;
        }
    }

    // Always prepend hash
    const w = cio.listWriter(out, alloc);
    w.print("hash:{s}\n", .{hash_str}) catch {};

    if (has_range or compact) {
        const start: u32 = if (line_start_raw) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else 1;
        const end: u32 = if (line_end_raw) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else std.math.maxInt(u32);
        const lang = explore_mod.detectLanguage(path);
        const extracted = explore_mod.extractLines(content, start, end, true, compact, lang, alloc) catch {
            out.appendSlice(alloc, "error: line extraction failed") catch {};
            return;
        };
        defer alloc.free(extracted);
        out.appendSlice(alloc, extracted) catch {};
    } else {
        out.appendSlice(alloc, content) catch {};
    }
}

pub fn handleEdit(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer, agents: *AgentRegistry) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
        return;
    }
    if (watcher.isSensitivePath(path)) {
        out.appendSlice(alloc, "error: access to sensitive file blocked") catch {};
        return;
    }
    const op_str = getStr(args, "op") orelse "replace";
    const op: @import("../version.zig").Op = if (eql(op_str, "insert"))
        .insert
    else if (eql(op_str, "delete"))
        .delete
    else if (eql(op_str, "replace"))
        .replace
    else {
        out.appendSlice(alloc, "error: unknown op, must be 'replace', 'insert', or 'delete'") catch {};
        return;
    };

    const content = getStr(args, "content");
    const range_start = getInt(args, "range_start");
    const range_end = getInt(args, "range_end");
    const after = getInt(args, "after");

    // Use agent 1 (the __filesystem__ agent registered at startup).
    // TODO: agent_id is hardcoded to 1 — two MCP clients share the same agent_id and
    // could both acquire locks on different files without conflict, but cannot detect
    // concurrent edits to the same file from separate connections.
    var req = edit_mod.EditRequest{
        .path = path,
        .agent_id = 1,
        .op = op,
        .content = content,
        .if_hash = getStr(args, "if_hash"),
        .dry_run = getBool(args, "dry_run"),
    };
    if (range_start != null and range_end != null) {
        if (range_start.? <= 0 or range_end.? <= 0) {
            out.appendSlice(alloc, "error: range values must be >= 1") catch {};
            return;
        }
        req.range = .{ @intCast(range_start.?), @intCast(range_end.?) };
    }
    if (after) |a| {
        if (a < 0) {
            out.appendSlice(alloc, "error: 'after' must be positive") catch {};
            return;
        }
        req.after = @intCast(a);
    }

    const result = edit_mod.applyEdit(io, alloc, store, agents, explorer, req) catch |err| {
        out.appendSlice(alloc, "error: edit failed: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        if (err == error.HashMismatch) {
            // Include the file's current hex hash so the agent can re-read with if_hash
            // to verify it has the latest content, then retry the edit.
            if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024))) |bytes| {
                defer alloc.free(bytes);
                const w = cio.listWriter(out, alloc);
                w.print(" (current hash: {x})", .{std.hash.Wyhash.hash(0, bytes)}) catch {};
            } else |_| {}
        }
        return;
    };
    defer if (result.preview) |p| alloc.free(p);

    const w = cio.listWriter(out, alloc);
    if (req.dry_run) {
        w.print("dry_run: would write size={d}, hash:{x}\n", .{ result.new_size, result.new_hash }) catch {};
        if (result.preview) |p| out.appendSlice(alloc, p) catch {};
    } else {
        w.print("edit applied: seq={d}, size={d}, hash:{x}", .{ result.seq, result.new_size, result.new_hash }) catch {};
    }
}

pub fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@min(@max(0, n), std.math.maxInt(u64))) else 0;
    const changes = store.changesSinceDetailed(since, alloc) catch {
        out.appendSlice(alloc, "error: changes query failed") catch {};
        return;
    };
    defer alloc.free(changes);

    const w = cio.listWriter(out, alloc);
    w.print("seq: {d}, {d} files changed since {d}:\n", .{ store.currentSeq(), changes.len, since }) catch {};
    for (changes) |c| {
        w.print("  {s} (seq={d}, op={s}, size={d})\n", .{ c.path, c.seq, @tagName(c.op), c.size }) catch {};
    }
}

pub fn handleStatus(alloc: std.mem.Allocator, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    store.mu.lock();
    const file_count = store.files.count();
    store.mu.unlock();

    const index_bytes = telemetry_mod.approxIndexSizeBytes(explorer);

    explorer.mu.lockShared();
    const outline_count = explorer.outlines.count();
    const content_count = explorer.contents.count();
    const trigram_type: []const u8 = switch (explorer.trigram_index) {
        .heap => "heap",
        .mmap => "mmap",
        .mmap_overlay => "mmap+overlay",
    };
    const trigram_files = explorer.trigram_index.fileCount();
    explorer.mu.unlockShared();

    const ignore_patterns = explorer.getIgnorePatterns(alloc) catch &.{};
    defer {
        for (ignore_patterns) |pattern| alloc.free(pattern);
        alloc.free(ignore_patterns);
    }

    const w = cio.listWriter(out, alloc);
    w.print(
        \\codedb status:
        \\  seq: {d}
        \\  files: {d}
        \\  outlines: {d}
        \\  contents_cached: {d}
        \\  trigram_index: {s} ({d} files)
        \\  index_memory: {d}KB
        \\  scan: {s}
        \\
    , .{
        store.currentSeq(),
        file_count,
        outline_count,
        content_count,
        trigram_type,
        trigram_files,
        index_bytes / 1024,
        getScanState().name(),
    }) catch {};

    w.print("  ignore_patterns: {d}\n", .{ignore_patterns.len}) catch {};
    for (ignore_patterns) |pattern| {
        w.print("    {s}\n", .{pattern}) catch {};
    }
    explorer.mu.lockShared();
    const cbi_hash = explorer.codedbignore_hash;
    explorer.mu.unlockShared();
    if (cbi_hash) |h| {
        w.print("  codedbignore_hash: {d}\n", .{h}) catch {};
    } else {
        w.print("  codedbignore_hash: none\n", .{}) catch {};
    }
    w.print("  built_in_skip_dirs: {d}\n", .{watcher.skip_dirs.len}) catch {};
    for (watcher.skip_dirs) |dir| {
        w.print("    {s}\n", .{dir}) catch {};
    }

    // Generated-code filter state (#6).
    w.print("  generated_filter: {s}\n", .{if (watcher.shouldIncludeGenerated()) "disabled" else "enabled"}) catch {};
    w.print("  generated_skip_events: {d}\n", .{watcher.generatedSkipEvents()}) catch {};

    // Language coverage — files per language across indexed outlines.
    var lang_counts = std.StringHashMap(usize).init(alloc);
    defer lang_counts.deinit();
    explorer.mu.lockShared();
    {
        var oit = explorer.outlines.iterator();
        while (oit.next()) |entry| {
            const lang_name = @tagName(entry.value_ptr.language);
            const gop = lang_counts.getOrPut(lang_name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    explorer.mu.unlockShared();
    w.print("  language_coverage: {d} languages\n", .{lang_counts.count()}) catch {};
    var lang_it = lang_counts.iterator();
    while (lang_it.next()) |entry| {
        w.print("    {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }

    // Stale files — tracked in the store but missing from the index.
    // Snapshot store keys (duped) under the store lock, then check outlines
    // under the explorer lock to avoid nested lock ordering.
    var stale_candidates = std.ArrayList([]const u8).empty;
    defer {
        for (stale_candidates.items) |k| alloc.free(k);
        stale_candidates.deinit(alloc);
    }
    store.mu.lock();
    {
        var sit = store.files.iterator();
        while (sit.next()) |entry| {
            const dup = alloc.dupe(u8, entry.key_ptr.*) catch continue;
            stale_candidates.append(alloc, dup) catch {
                alloc.free(dup);
            };
        }
    }
    store.mu.unlock();
    var stale: usize = 0;
    explorer.mu.lockShared();
    for (stale_candidates.items) |k| {
        if (!explorer.outlines.contains(k)) stale += 1;
    }
    explorer.mu.unlockShared();
    w.print("  stale_files: {d} (tracked in store, not indexed)\n", .{stale}) catch {};
}

pub fn handleSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store, cache: *SnapshotCache) void {
    const seq = store.currentSeq();
    if (cache.appendIfFresh(alloc, out, seq)) return;

    const snap = snapshot_json.buildSnapshot(explorer, store, alloc) catch {
        out.appendSlice(alloc, "error: snapshot build failed") catch {};
        return;
    };
    cache.putAndAppend(alloc, out, seq, snap);
}
