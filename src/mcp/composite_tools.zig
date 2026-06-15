// codedb MCP — composite / filesystem tool handlers + diagnostic helpers.
//
// Extracted from mcp.zig. Contains:
//   - diagnostic helpers (stripAnsiCodes, appendBundleArgKeysDiagnostic,
//     appendFuzzyPathSuggestions, finishQueryWithFailure)
//   - composite tools (handleTypes, handleBundle)
//   - filesystem tools (handleProjects, handleIndex, handleFind,
//     handleGlob, handleLs)
//
// mcp.zig re-imports them so dispatch + tests keep resolving.

const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const snapshot_mod = @import("../snapshot.zig");
const root_policy = @import("../root_policy.zig");
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;

const mcp = @import("../mcp.zig");
const Tool = mcp.Tool;
const dispatch = mcp.dispatch;
const ProjectCache = mcp.ProjectCache;
const DeferredScan = mcp.DeferredScan;
const getScanState = mcp.getScanState;
const setScanState = mcp.setScanState;
const loadProjectTrigramFromDiskIfPresent = mcp.loadProjectTrigramFromDiskIfPresent;

const query_mod = @import("query.zig");
const applyComboBoosts = query_mod.applyComboBoosts;

pub fn stripAnsiCodes(alloc: std.mem.Allocator, input: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.ensureTotalCapacity(alloc, input.len) catch return input;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            // Skip until we hit a letter (the terminator)
            i += 2;
            while (i < input.len and !std.ascii.isAlphabetic(input[i])) : (i += 1) {}
            if (i < input.len) i += 1; // skip the terminator letter
        } else {
            out.append(alloc, input[i]) catch return input;
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc) catch input;
}

/// tell whether codedb dropped a field or the client sent it under the
/// wrong name. See issue #357.
pub fn appendBundleArgKeysDiagnostic(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    args: *const std.json.ObjectMap,
) void {
    out.appendSlice(alloc, "\nreceived keys: [") catch return;
    var it = args.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) out.appendSlice(alloc, ", ") catch return;
        first = false;
        out.appendSlice(alloc, entry.key_ptr.*) catch return;
    }
    out.appendSlice(alloc, "]") catch return;
    // Issue #424: if the args we saw contain ONLY administrative keys
    // (`tool`, `arguments`) — or are empty entirely — there were no real
    // sub-op fields at all. That's almost always a client wrapper bug.
    // Suggest the inline shape so the caller can route around it.
    var has_real_arg = false;
    var it2 = args.iterator();
    while (it2.next()) |entry| {
        const k = entry.key_ptr.*;
        if (!std.mem.eql(u8, k, "tool") and !std.mem.eql(u8, k, "arguments")) {
            has_real_arg = true;
            break;
        }
    }
    if (!has_real_arg) {
        out.appendSlice(alloc, "\nhint: no sub-op args reached the handler — your client may be stripping fields. Try inline shape: {\"tool\":\"...\",\"path\":\"...\"} (no `arguments` wrapper)") catch return;
    }
}

/// Append up to 3 fuzzy-matched indexed paths so callers can recover from a
/// non-indexed-path error without a separate codedb_find round-trip.
/// See issue #356.
pub fn appendFuzzyPathSuggestions(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    bad_path: []const u8,
) void {
    const matches = explorer.fuzzyFindFiles(bad_path, alloc, 3) catch return;
    defer alloc.free(matches);
    if (matches.len == 0) return;
    out.appendSlice(alloc, "\ndid you mean:\n") catch return;
    for (matches) |m| {
        out.appendSlice(alloc, "  ") catch return;
        out.appendSlice(alloc, m.path) catch return;
        out.appendSlice(alloc, "\n") catch return;
    }
}

/// Mark a codedb_query pipeline as having failed at a given step, append the
/// `received keys: [...]` diagnostic when a missing-arg error fired, and
/// emit a `--- partial ---` tail naming the failing step. Prior-step output
/// in `out` is preserved unchanged. See issue #356.
pub fn finishQueryWithFailure(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    step_i: usize,
    reason: []const u8,
    step_args: ?*const std.json.ObjectMap,
) void {
    if (step_args) |sa| {
        appendBundleArgKeysDiagnostic(alloc, out, sa);
    }
    const w = cio.listWriter(out, alloc);
    w.print("\n--- partial ---\nfailed_at: {d}\nreason: {s}\n", .{ step_i, reason }) catch {};
}

pub fn handleTypes(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const return_type = getStr(args, "return_type");
    const param_type = getStr(args, "param_type");
    if (return_type == null and param_type == null) {
        out.appendSlice(alloc, "error: provide 'return_type' or 'param_type'") catch {};
        return;
    }
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 1000))) else 50;
    const w = cio.listWriter(out, alloc);
    var shown: usize = 0;

    if (return_type) |rt| {
        const hits = explorer.type_index.findByReturnType(rt);
        w.print("{d} symbols returning '{s}':\n", .{ hits.len, rt }) catch {};
        for (hits) |hit| {
            if (shown >= max_results) break;
            w.print("  {s}:{d} {s}\n", .{ hit.path, hit.line_start, hit.symbol_name }) catch {};
            shown += 1;
        }
    }

    if (param_type) |pt| {
        const hits = explorer.type_index.findByParamType(pt);
        w.print("{d} symbols accepting '{s}':\n", .{ hits.len, pt }) catch {};
        for (hits) |hit| {
            if (shown >= max_results) break;
            w.print("  {s}:{d} {s}\n", .{ hit.path, hit.line_start, hit.symbol_name }) catch {};
            shown += 1;
        }
    }

    if (shown == 0) {
        w.print("no type hits found\n", .{}) catch {};
    }
}

pub fn handleBundle(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    default_store: *Store,
    default_explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    deferred_scan: ?*DeferredScan,
) void {
    const ops_val = args.get("ops") orelse {
        out.appendSlice(alloc, "error: missing 'ops' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const ops = switch (ops_val) {
        .array => |a| a.items,
        else => {
            out.appendSlice(alloc, "error: 'ops' must be an array") catch {};
            return;
        },
    };
    if (ops.len == 0) {
        out.appendSlice(alloc, "error: 'ops' array is empty") catch {};
        return;
    }
    if (ops.len > 20) {
        out.appendSlice(alloc, "error: max 20 ops per bundle") catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    // Refresh activity accounting as we start the bundle. Long bundles can
    // include slow sub-ops, many ops, and remote fetches, so each completed
    // sub-op updates the same timestamp. See #278.
    mcp.last_activity.store(cio.milliTimestamp(), .release);
    // Bug 11: track per-op outcome so the top-level envelope can flip
    // isError=true when no op succeeded — agents reading the previous
    // success-with-per-op-errors shape took it as "the call ran fine".
    var ok_count: usize = 0;
    var fail_count: usize = 0;
    for (ops, 0..) |op, i| {
        if (op != .object) {
            w.print("--- [{d}] error ---\nerror: op must be an object\n", .{i}) catch {};
            fail_count += 1;
            continue;
        }
        const op_obj = &op.object;
        const tool_name = getStr(op_obj, "tool") orelse {
            if (op_obj.get("tool")) |_| {
                w.print("--- [{d}] error ---\nerror: 'tool' must be a string\n", .{i}) catch {};
            } else {
                w.print("--- [{d}] error ---\nerror: missing 'tool' field\n", .{i}) catch {};
            }
            fail_count += 1;
            continue;
        };

        const tool = std.meta.stringToEnum(Tool, tool_name) orelse {
            w.print("--- [{d}] {s} ---\nerror: unknown tool\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        };

        // Reject recursive bundle and write operations
        if (tool == .codedb_bundle) {
            w.print("--- [{d}] {s} ---\nerror: recursive bundle not allowed\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }
        if (tool == .codedb_edit) {
            w.print("--- [{d}] {s} ---\nerror: write operations not allowed in bundle\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }
        if (tool == .codedb_projects) {
            // codedb_projects lists every indexed project machine-wide — a
            // global directory enumeration unrelated to the current repo.
            // Planners that see one such call tend to replay the shape (5x
            // codedb_projects in one bundle), so block it at the dispatcher.
            // It is still callable as a standalone tool for cases where a
            // global listing genuinely is what's wanted.
            w.print("--- [{d}] {s} ---\nerror: codedb_projects not allowed in bundle\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }

        // Extract arguments. Two supported formats:
        //   1) {"tool":"outline", "arguments":{"path":"..."}}  — MCP tools/call style
        //   2) {"tool":"outline", "path":"..."}                 — inline args
        // Issue #424: if `arguments` is present but empty (`{}`), fall
        // through to inline-args mode. Some buggy client wrappers emit
        // empty `arguments` alongside inline args; treating the empty
        // object as authoritative would silently drop the real args.
        var sub_args_val: std.json.Value = undefined;
        var sub_args_ptr: ?*const std.json.ObjectMap = null;
        if (op_obj.get("arguments")) |arguments_val| {
            if (arguments_val != .object) {
                w.print("--- [{d}] {s} ---\nerror: arguments must be object\n", .{ i, tool_name }) catch {};
                fail_count += 1;
                continue;
            }
            if (arguments_val.object.count() == 0) {
                // Empty `arguments` — try inline args at the op level.
                sub_args_ptr = op_obj;
            } else {
                sub_args_val = arguments_val;
                sub_args_ptr = &sub_args_val.object;
            }
        } else {
            // No "arguments" key — use op_obj directly (inline arg format)
            sub_args_ptr = op_obj;
        }
        const sub_args = sub_args_ptr.?;

        var sub_out: std.ArrayList(u8) = .empty;
        defer sub_out.deinit(alloc);

        dispatch(io, alloc, tool, sub_args, &sub_out, default_store, default_explorer, agents, cache, deferred_scan);

        // Check size BEFORE appending to prevent blowout
        if (out.items.len + sub_out.items.len > 200 * 1024) {
            w.print("--- [{d}] {s} ---\nTRUNCATED: adding this result would exceed 200KB. Use codedb_outline + targeted reads instead of full file reads.\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            // Issue #413: surface a per-index marker for every op the bundle
            // dropped after truncation, so callers can correlate by index
            // instead of silently losing ops > i.
            var dropped_idx: usize = i + 1;
            while (dropped_idx < ops.len) : (dropped_idx += 1) {
                w.print("--- [{d}] dropped ---\nOPS_DROPPED: response cap reached; this op was not executed.\n", .{dropped_idx}) catch {};
                fail_count += 1;
            }
            break;
        }

        w.print("--- [{d}] {s} ---\n", .{ i, tool_name }) catch {};
        out.appendSlice(alloc, sub_out.items) catch {};
        // Issue #357 / #423: per-tool handlers already append the
        // `received keys` diagnostic on missing-arg errors, so the bundle
        // wrapper does NOT re-append it. Doing so emits the line twice.
        if (std.mem.startsWith(u8, sub_out.items, "error:")) {
            fail_count += 1;
        } else {
            ok_count += 1;
        }
        w.writeAll("\n") catch {};

        // Per-op activity refresh — see top of this fn.
        mcp.last_activity.store(cio.milliTimestamp(), .release);
    }
    // Bug 11: if every op errored, surface that at the envelope level so the
    // outer isError flag flips. Pre-fix the response was "isError:false" with
    // per-op errors buried in the body — agents read it as success.
    if (ok_count == 0 and fail_count > 0) {
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "error: all {d} bundle op(s) failed\n", .{fail_count}) catch "error: all bundle ops failed\n";
        out.insertSlice(alloc, 0, prefix) catch {};
    }
}

const remote = @import("remote.zig");
pub const handleRemote = remote.handleRemote;

pub fn handleProjects(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    const home = cio.getHomeDir() orelse {
        out.appendSlice(alloc, "error: cannot determine home directory (tried HOME, USERPROFILE)") catch {};
        return;
    };

    const projects_dir = std.fmt.allocPrint(alloc, "{s}/.codedb/projects", .{home}) catch {
        out.appendSlice(alloc, "error: alloc failed") catch {};
        return;
    };
    defer alloc.free(projects_dir);

    var dir = std.Io.Dir.cwd().openDir(io, projects_dir, .{ .iterate = true }) catch {
        out.appendSlice(alloc, "no indexed projects found") catch {};
        return;
    };
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Read project.txt to get the project path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&path_buf, "{s}/project.txt", .{entry.name}) catch continue;
        const project_file = dir.openFile(io, sub_path, .{}) catch continue;
        defer project_file.close(io);
        var content_buf: [4096]u8 = undefined;
        const n = project_file.readPositionalAll(io, &content_buf, 0) catch continue;
        if (n == 0) continue;
        const project_path = content_buf[0..n];

        // Check if snapshot exists in the project directory
        var snap_exists = false;
        var snap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_path_buf, "{s}/codedb.snapshot", .{project_path}) catch project_path;
        if (std.Io.Dir.cwd().access(io, snap_path, .{})) |_| {
            snap_exists = true;
        } else |_| {}

        if (count > 0) out.appendSlice(alloc, "\n") catch {};
        out.appendSlice(alloc, project_path) catch {};
        if (snap_exists) {
            out.appendSlice(alloc, "  [snapshot]") catch {};
        }
        count += 1;
    }

    if (count == 0) {
        out.appendSlice(alloc, "no indexed projects found") catch {};
    }
}

pub fn handleIndex(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    cache: *ProjectCache,
    default_store: *Store,
    default_explorer: *Explorer,
    deferred_scan: ?*DeferredScan,
) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };

    // Resolve to absolute path
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, path, &abs_buf) catch {
        out.appendSlice(alloc, "error: cannot resolve path: ") catch {};
        out.appendSlice(alloc, path) catch {};
        return;
    };
    const abs_path = abs_buf[0..abs_len];
    if (!root_policy.isIndexableRoot(abs_path)) {
        out.appendSlice(alloc, "error: refusing to index temporary root: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    }

    // Verify it's a directory
    var check_dir = std.Io.Dir.cwd().openDir(io, abs_path, .{}) catch {
        out.appendSlice(alloc, "error: not a directory: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    };
    check_dir.close(io);

    // Force refresh: delete existing snapshots before re-indexing
    const force = getBool(args, "force");
    if (force) {
        // Delete in-repo snapshot
        const in_repo_snap = std.fmt.allocPrint(alloc, "{s}/codedb.snapshot", .{abs_path}) catch null;
        if (in_repo_snap) |snap| {
            defer alloc.free(snap);
            std.Io.Dir.cwd().deleteFile(io, snap) catch {};
        }
        // Delete central cache snapshot
        if (cio.getHomeDir()) |home_dir| {
            const hash = std.hash.Wyhash.hash(0, abs_path);
            const cache_snap = std.fmt.allocPrint(alloc, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home_dir, hash }) catch null;
            if (cache_snap) |cs| {
                defer alloc.free(cs);
                std.Io.Dir.cwd().deleteFile(io, cs) catch {};
            }
        }
    }

    const exe_path = std.process.executablePathAlloc(io, alloc) catch {
        out.appendSlice(alloc, "error: cannot find codedb binary") catch {};
        return;
    };
    defer alloc.free(exe_path);

    const snapshot_path = std.fmt.allocPrint(alloc, "{s}/codedb.snapshot", .{abs_path}) catch {
        out.appendSlice(alloc, "error: alloc failed") catch {};
        return;
    };
    defer alloc.free(snapshot_path);

    const result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ exe_path, abs_path, "snapshot", snapshot_path },
        .max_output_bytes = 64 * 1024,
    }) catch {
        out.appendSlice(alloc, "error: failed to run indexer") catch {};
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        out.appendSlice(alloc, "error: indexing failed for ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        if (result.stderr.len > 0) {
            out.appendSlice(alloc, " - ") catch {};
            out.appendSlice(alloc, result.stderr[0..@min(result.stderr.len, 300)]) catch {};
        }
        return;
    }

    cache.invalidate(abs_path);
    if (std.mem.eql(u8, abs_path, cache.default_path) and
        default_store.currentSeq() == 0 and
        getScanState() == .loading_snapshot)
    {
        default_explorer.setRoot(io, abs_path);
        if (snapshot_mod.loadSnapshot(io, snapshot_path, default_explorer, default_store, alloc)) {
            loadProjectTrigramFromDiskIfPresent(io, default_explorer, abs_path, alloc);
            default_explorer.rebuildTypeIndexes();
            if (default_explorer.outlines.count() > 1000) {
                default_explorer.releaseContents();
                default_explorer.releaseSecondaryIndexes();
            }
            setScanState(.ready);
            if (deferred_scan) |ds| {
                ds.resolved_root = cache.default_path;
                ds.triggered.store(true, .release);
                ds.scan_done.store(true, .release);
            }
        }
    }

    out.appendSlice(alloc, "indexed: ") catch {};
    out.appendSlice(alloc, abs_path) catch {};
    if (result.stdout.len > 0) {
        out.appendSlice(alloc, "\n") catch {};
        // Strip ANSI escape sequences
        var i: usize = 0;
        while (i < result.stdout.len) {
            if (result.stdout[i] == 0x1b) {
                i += 1;
                if (i < result.stdout.len and result.stdout[i] == '[') {
                    // CSI sequence: skip until final byte (0x40-0x7E per ECMA-48)
                    i += 1;
                    while (i < result.stdout.len) {
                        const ch = result.stdout[i];
                        i += 1;
                        if (ch >= 0x40 and ch <= 0x7E) break;
                    }
                } else if (i < result.stdout.len) {
                    // Fe sequence (ESC + one byte) — skip
                    i += 1;
                }
                // Lone ESC at end — already skipped by i += 1 above
            } else {
                out.append(alloc, result.stdout[i]) catch {};
                i += 1;
            }
        }
    }
}

pub fn handleFind(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const query = getStr(args, "query") orelse {
        out.appendSlice(alloc, "error: missing 'query'") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (query.len == 0) {
        out.appendSlice(alloc, "error: empty query") catch {};
        return;
    }

    const max_results: usize = if (args.get("max_results")) |v| switch (v) {
        .integer => |i| @intCast(@max(1, @min(i, 50))),
        else => 10,
    } else 10;

    var matches = explorer.fuzzyFindFiles(query, alloc, max_results) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer alloc.free(matches);

    // Auto-retry: if no results, try broadening the query
    var broadened_buf: [256]u8 = undefined;
    if (matches.len == 0 and query.len > 3) {
        // Try stripping delimiters: auth_middleware → authmiddleware
        var blen: usize = 0;
        for (query) |c| {
            if (c != '_' and c != '-' and c != '.' and blen < broadened_buf.len) {
                broadened_buf[blen] = c;
                blen += 1;
            }
        }
        if (blen > 0 and blen != query.len) {
            const broadened = broadened_buf[0..blen];
            const retry = explorer.fuzzyFindFiles(broadened, alloc, max_results) catch null;
            if (retry) |r| {
                alloc.free(matches);
                matches = r;
            }
        }
    }
    // Combo-boost: reward files that were previously opened after similar queries
    applyComboBoosts(io, alloc, query, @constCast(matches));

    if (matches.len == 0) {
        out.appendSlice(alloc, "no matches") catch {};
        return;
    }

    for (matches, 1..) |m, rank| {
        var buf: [16]u8 = undefined;
        const rank_str = std.fmt.bufPrint(&buf, "{d}. ", .{rank}) catch continue;
        out.appendSlice(alloc, rank_str) catch {};
        out.appendSlice(alloc, m.path) catch {};
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, " (score: {d:.2})\n", .{m.score}) catch continue;
        out.appendSlice(alloc, score_str) catch {};
    }
}

pub fn handleGlob(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const pattern = getStr(args, "pattern") orelse {
        out.appendSlice(alloc, "error: missing 'pattern'") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (pattern.len == 0) {
        out.appendSlice(alloc, "error: empty pattern") catch {};
        return;
    }

    const max_results: usize = if (args.get("max_results")) |v| switch (v) {
        .integer => |i| @intCast(@max(1, @min(i, 5000))),
        else => 200,
    } else 200;

    const matches = explorer.globPaths(alloc, pattern, max_results) catch {
        out.appendSlice(alloc, "error: glob failed") catch {};
        return;
    };
    defer alloc.free(matches);

    if (matches.len == 0) {
        out.appendSlice(alloc, "no matches") catch {};
        return;
    }

    for (matches) |path| {
        out.appendSlice(alloc, path) catch {};
        out.appendSlice(alloc, "\n") catch {};
    }
}

pub fn handleLs(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const prefix = getStr(args, "path") orelse "";
    const ranked = getBool(args, "ranked");
    const no_descriptor = getBool(args, "no_descriptor");

    const entries = explorer.lsDir(alloc, prefix, ranked) catch {
        out.appendSlice(alloc, "error: ls failed") catch {};
        return;
    };
    defer {
        for (entries) |e| {
            if (!e.is_dir and e.descriptor.len > 0) alloc.free(e.descriptor);
        }
        alloc.free(entries);
    }

    if (entries.len == 0) {
        out.appendSlice(alloc, "no entries") catch {};
        return;
    }

    for (entries) |e| {
        if (e.is_dir) {
            out.appendSlice(alloc, e.name) catch {};
            if (ranked) {
                var buf: [64]u8 = undefined;
                const meta = std.fmt.bufPrint(&buf, "/  (score {d})\n", .{e.hotspot_score}) catch "/\n";
                out.appendSlice(alloc, meta) catch {};
            } else {
                out.appendSlice(alloc, "/\n") catch {};
            }
        } else {
            out.appendSlice(alloc, e.name) catch {};
            var buf: [64]u8 = undefined;
            const meta = if (ranked)
                std.fmt.bufPrint(&buf, "  ({s}, {d}L, {d} sym, {d} deps, score {d}){s}", .{
                    @tagName(e.language),
                    e.line_count,
                    e.sym_count,
                    e.dependent_count,
                    e.hotspot_score,
                    if (e.is_stub) " [stub]" else "",
                }) catch "\n"
            else
                std.fmt.bufPrint(&buf, "  ({s}, {d}L, {d} sym){s}", .{
                @tagName(e.language),
                e.line_count,
                e.sym_count,
                if (e.is_stub) " [stub]" else "",
            }) catch "\n";
            out.appendSlice(alloc, meta) catch {};
            if (!no_descriptor and e.descriptor.len > 0) {
                out.appendSlice(alloc, " - ") catch {};
                out.appendSlice(alloc, e.descriptor) catch {};
            }
            out.appendSlice(alloc, "\n") catch {};
        }
    }
}
