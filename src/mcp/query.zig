// codedb MCP — codedb_query pipeline handler + combo-boost reranking.
const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const eql = mcpj.eql;
const wal = @import("wal.zig");
const globMatch = @import("pathglob.zig").globMatch;
const mcp = @import("../mcp.zig");
const appendBundleArgKeysDiagnostic = mcp.appendBundleArgKeysDiagnostic;
const finishQueryWithFailure = mcp.finishQueryWithFailure;

const COMBO_WINDOW_MS: i64 = 5000; // 5 second window between query and file open
const COMBO_BOOST_PER_HIT: f32 = 5.0; // score boost per historical open

pub fn applyComboBoosts(io: std.Io, alloc: std.mem.Allocator, query: []const u8, matches: []explore_mod.Explorer.FuzzyMatch) void {
    const wal_path = wal.logPath() orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, wal_path, alloc, .limited(512 * 1024)) catch return;
    defer alloc.free(data);

    // Scan WAL for query→access pairs within COMBO_WINDOW_MS
    var boosts = std.StringHashMap(f32).init(alloc);
    defer boosts.deinit();

    var last_query_ts: i64 = 0;
    var last_query_match = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 10) continue;

        if (std.mem.indexOf(u8, line, "\"ev\":\"query\"")) |_| {
            // Check if this query matches the current one (case-insensitive substring)
            var qbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "query", &qbuf)) |logged_query| {
                last_query_match = std.mem.indexOf(u8, logged_query, query) != null or
                    std.mem.indexOf(u8, query, logged_query) != null;
            } else {
                last_query_match = false;
            }
            last_query_ts = extractJsonIntLocal(line, "ts") orelse 0;
        } else if (std.mem.indexOf(u8, line, "\"ev\":\"access\"")) |_| {
            if (!last_query_match) continue;
            const access_ts = extractJsonIntLocal(line, "ts") orelse continue;
            if (access_ts - last_query_ts > COMBO_WINDOW_MS) continue;

            var pbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "path", &pbuf)) |path| {
                const gop = boosts.getOrPut(path) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += COMBO_BOOST_PER_HIT;
            }
        }
    }

    if (boosts.count() == 0) return;

    // Apply boosts to matching results
    var boosted = false;
    for (matches) |*m| {
        if (boosts.get(m.path)) |boost| {
            m.score += boost;
            boosted = true;
        }
    }

    // Re-sort if any scores changed
    if (boosted) {
        std.mem.sort(explore_mod.Explorer.FuzzyMatch, matches, {}, struct {
            fn lt(_: void, a: explore_mod.Explorer.FuzzyMatch, b: explore_mod.Explorer.FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);
    }
}

pub fn extractJsonIntLocal(line: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    var end = start;
    while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, line[start..end], 10) catch null;
}

pub fn extractJsonStrLocal(line: []const u8, key: []const u8, out: *[256]u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    const len = @min(end - start, out.len);
    @memcpy(out[0..len], line[start..][0..len]);
    return out[0..len];
}

/// Record a hit line number for a file in the hit_lines map.
/// Used by search/word/callers pipeline steps to enable context-aware reads.
fn recordHitLine(hit_map: *std.StringHashMap(std.ArrayList(usize)), al: std.mem.Allocator, path: []const u8, line: u32) void {
    if (hit_map.getPtr(path)) |hl| {
        hl.append(al, line) catch {};
    } else {
        const key = al.dupe(u8, path) catch return;
        var new_list: std.ArrayList(usize) = .empty;
        new_list.append(al, line) catch return;
        hit_map.put(key, new_list) catch {
            al.free(key);
            new_list.deinit(al);
            return;
        };
    }
}

pub fn handleQuery(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store) void {
    _ = store;
    const pipeline_val = args.get("pipeline") orelse {
        out.appendSlice(alloc, "error: missing 'pipeline' array") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const pipeline = switch (pipeline_val) {
        .array => |a| a.items,
        else => {
            out.appendSlice(alloc, "error: 'pipeline' must be an array") catch {};
            return;
        },
    };
    if (pipeline.len == 0 or pipeline.len > 10) {
        out.appendSlice(alloc, "error: pipeline must have 1-10 steps") catch {};
        return;
    }

    var file_set: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_set.items) |p| alloc.free(p);
        file_set.deinit(alloc);
    }
    var have_set = false;

    // Track hit line numbers per file from search/word/callers steps,
    // so the read step can do context-aware reads around those lines.
    var hit_lines = std.StringHashMap(std.ArrayList(usize)).init(alloc);
    defer {
        var hl_iter = hit_lines.iterator();
        while (hl_iter.next()) |entry| {
            entry.value_ptr.deinit(alloc);
            alloc.free(entry.key_ptr.*);
        }
        hit_lines.deinit();
    }

    const w = cio.listWriter(out, alloc);

    // Issue #356-p3: per-stage summary so long pipelines are debuggable
    // without re-parsing the unstructured per-step output above the tail.
    const StageInfo = struct { op: []const u8, files_out: usize };
    var stages: std.ArrayList(StageInfo) = .empty;
    defer stages.deinit(alloc);

    for (pipeline, 0..) |step_val, step_i| {
        if (step_val != .object) {
            w.print("error: step {d} must be object\n", .{step_i}) catch {};
            return;
        }
        const step = &step_val.object;
        const op = getStr(step, "op") orelse blk: {
            // Auto-detect op when 'op' key is missing.
            // query → search, word → word, name → symbol
            if (getStr(step, "query") != null) break :blk "search";
            if (getStr(step, "word") != null)   break :blk "word";
            if (getStr(step, "name") != null)   break :blk "symbol";
            w.print("error: step {d} missing 'op'\n", .{step_i}) catch {};
            finishQueryWithFailure(alloc, out, step_i, "missing 'op'", step);
            return;
        };

        if (std.mem.eql(u8, op, "find")) {
            const query = getStr(step, "query") orelse {
                w.print("error: find needs 'query'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "find needs 'query'", step);
                return;
            };
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            const matches = explorer.fuzzyFindFiles(query, alloc, max) catch {
                w.print("error: find failed\n", .{}) catch {};
                return;
            };
            defer alloc.free(matches);
            if (have_set) {
                // Intersect: keep only files from current set that also appear in find results
                var match_set = std.StringHashMap(void).init(alloc);
                defer match_set.deinit();
                for (matches) |m| match_set.put(m.path, {}) catch {};
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (match_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
                w.print("{d} files after find intersect\n", .{file_set.items.len}) catch {};
            } else {
                file_set.clearRetainingCapacity();
                w.print("{d} files matched:\n", .{matches.len}) catch {};
                for (matches) |m| {
                    w.print("  {s}\n", .{m.path}) catch {};
                    const duped = alloc.dupe(u8, m.path) catch continue;
                    file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "search")) {
            const query = getStr(step, "query") orelse {
                w.print("error: search needs 'query'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "search needs 'query'", step);
                return;
            };
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            const results = explorer.searchContent(query, alloc, max) catch {
                w.print("error: search failed\n", .{}) catch {};
                return;
            };
            defer {
                for (results) |r| {
                    alloc.free(r.line_text);
                    alloc.free(r.path);
                }
                alloc.free(results);
            }
            if (have_set) {
                // Intersect: only keep files from current set that have search hits
                var hit_set = std.StringHashMap(void).init(alloc);
                defer hit_set.deinit();
                var path_set = std.StringHashMap(void).init(alloc);
                defer path_set.deinit();
                for (file_set.items) |p| path_set.put(p, {}) catch {};
                for (results) |r| {
                    if (path_set.contains(r.path)) {
                        w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                        hit_set.put(r.path, {}) catch {};
                        recordHitLine(&hit_lines, alloc, r.path, r.line_num);
                    }
                }
                // Narrow file_set to only files that had hits
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (hit_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
            } else {
                var seen = std.StringHashMap(void).init(alloc);
                defer seen.deinit();
                file_set.clearRetainingCapacity();
                for (results) |r| {
                    w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                    recordHitLine(&hit_lines, alloc, r.path, r.line_num);
                    if (!seen.contains(r.path)) {
                        // Dupe path — search results are freed by the defer above,
                        // but file_set must outlive this step for downstream ops
                        const duped = alloc.dupe(u8, r.path) catch continue;
                        seen.put(duped, {}) catch {
                            alloc.free(duped);
                            continue;
                        };
                        file_set.append(alloc, duped) catch {
                            alloc.free(duped);
                            continue;
                        };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "deps")) {
            // Expand file set by adding dependents/dependencies of current files.
            // Accepts optional 'path' for standalone use without a prior seeding step.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: deps needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            const direction = getStr(step, "direction") orelse "imported_by";
            const transitive = getBool(step, "transitive");
            const max_depth_val: ?u32 = if (getInt(step, "max_depth")) |n| @intCast(@max(1, n)) else null;
            const is_forward = std.mem.eql(u8, direction, "depends_on");

            var expanded = std.StringHashMap(void).init(alloc);
            defer expanded.deinit();
            for (file_set.items) |path| expanded.put(path, {}) catch {};

            // Snapshot current file set since we'll append to it
            const current_len = file_set.items.len;
            for (file_set.items[0..current_len]) |path| {
                var deps_result: []const []const u8 = &.{};
                var needs_free = false;

                if (is_forward) {
                    if (transitive) {
                        deps_result = explorer.getTransitiveDependencies(path, alloc, max_depth_val) catch continue;
                        needs_free = true;
                    } else {
                        explorer.mu.lockShared();
                        const fwd = explorer.dep_graph.getForwardDeps(path);
                        explorer.mu.unlockShared();
                        if (fwd) |deps| {
                            var res: std.ArrayList([]const u8) = .empty;
                            for (deps) |dep| {
                                const d = alloc.dupe(u8, dep) catch continue;
                                res.append(alloc, d) catch {
                                    alloc.free(d);
                                    continue;
                                };
                            }
                            deps_result = res.toOwnedSlice(alloc) catch &.{};
                            needs_free = true;
                        }
                    }
                } else {
                    if (transitive) {
                        deps_result = explorer.getTransitiveDependents(path, alloc, max_depth_val) catch continue;
                    } else {
                        deps_result = explorer.getImportedBy(path, alloc) catch continue;
                    }
                    needs_free = true;
                }

                defer if (needs_free) {
                    for (deps_result) |dep| alloc.free(dep);
                    alloc.free(deps_result);
                };

                for (deps_result) |dep| {
                    if (!expanded.contains(dep)) {
                        expanded.put(dep, {}) catch {};
                        file_set.append(alloc, dep) catch {};
                    }
                }
            }
        } else if (std.mem.eql(u8, op, "filter")) {
            if (!have_set) {
                explorer.mu.lockShared();
                var iter = explorer.outlines.keyIterator();
                while (iter.next()) |k| {
                    const duped = alloc.dupe(u8, k.*) catch continue;
                    file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                }
                explorer.mu.unlockShared();
                have_set = true;
            }
            const ext = getStr(step, "ext");
            const glob_pat = getStr(step, "glob");
            var wr: usize = 0;
            for (file_set.items) |path| {
                var keep = true;
                if (ext) |e| {
                    if (!std.mem.endsWith(u8, path, e)) keep = false;
                }
                if (keep) if (glob_pat) |g| {
                    if (!globMatch(g, path)) keep = false;
                };
                if (keep) {
                    file_set.items[wr] = path;
                    wr += 1;
                }
            }
            file_set.items.len = wr;
        } else if (std.mem.eql(u8, op, "outline")) {
            // Accepts optional 'path' for standalone single-file outline.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: outline needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            for (file_set.items) |path| {
                var outline = explorer.getOutline(path, alloc) catch continue;
                if (outline) |*o| {
                    defer o.deinit();
                    w.print("--- {s} ({s}, {d} sym) ---\n", .{ path, @tagName(o.language), o.symbols.items.len }) catch {};
                    for (o.symbols.items) |sym| w.print("  L{d} {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
                }
                if (out.items.len > 100 * 1024) {
                    w.print("... truncated\n", .{}) catch {};
                    break;
                }
            }
        } else if (std.mem.eql(u8, op, "read")) {
            // Accepts optional 'path' for standalone single-file read.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: read needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            const context_lines: usize = if (getInt(step, "context_lines")) |n| @intCast(@max(1, @min(n, 50))) else 0;
            const max_lines: usize = if (getInt(step, "lines")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            for (file_set.items) |path| {
                const content = explorer.getContent(path, alloc) catch continue;
                if (content) |data| {
                    defer alloc.free(data);
                    w.print("--- {s} ---\n", .{path}) catch {};

                    if (context_lines > 0) {
                        // Context-aware read: show lines around hits from prior steps
                        const hits_opt = hit_lines.get(path);
                        if (hits_opt) |hits_list| {
                            // Sort hit line numbers
                            std.mem.sort(usize, hits_list.items, {}, std.sort.asc(usize));

                            // Build merged windows [hit-ctx, hit+ctx]
                            const Window = struct { start: usize, end: usize };
                            var windows: std.ArrayList(Window) = .empty;
                            defer windows.deinit(alloc);

                            for (hits_list.items) |hit_line| {
                                const win_start: usize = if (hit_line > context_lines) hit_line - context_lines else 1;
                                const win_end: usize = hit_line + context_lines;

                                if (windows.items.len > 0) {
                                    const last = &windows.items[windows.items.len - 1];
                                    if (win_start <= last.end + 1) {
                                        last.end = @max(last.end, win_end);
                                        continue;
                                    }
                                }
                                windows.append(alloc, .{ .start = win_start, .end = win_end }) catch {};
                            }

                            // Output lines within windows, with ... between gaps
                            var ln: usize = 1;
                            var win_idx: usize = 0;
                            var prev_printed = false;
                            var line_it = std.mem.splitScalar(u8, data, '\n');
                            while (line_it.next()) |line| {
                                // Advance past completed windows
                                while (win_idx < windows.items.len and ln > windows.items[win_idx].end) {
                                    win_idx += 1;
                                    prev_printed = false;
                                }
                                if (win_idx >= windows.items.len) break;

                                const win = windows.items[win_idx];
                                if (ln >= win.start and ln <= win.end) {
                                    if (!prev_printed and win_idx > 0) {
                                        w.print("  ...\n", .{}) catch {};
                                    }
                                    w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                                    prev_printed = true;
                                }
                                ln += 1;
                            }
                        } else {
                            // No hits for this file — fall back to reading from start
                            var ln: usize = 1;
                            var line_it = std.mem.splitScalar(u8, data, '\n');
                            while (line_it.next()) |line| {
                                if (ln > max_lines) {
                                    w.print("  ... (truncated)\n", .{}) catch {};
                                    break;
                                }
                                w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                                ln += 1;
                            }
                        }
                    } else {
                        // Original behavior: read from start
                        var ln: usize = 1;
                        var line_it = std.mem.splitScalar(u8, data, '\n');
                        while (line_it.next()) |line| {
                            if (ln > max_lines) {
                                w.print("  ... (truncated)\n", .{}) catch {};
                                break;
                            }
                            w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                            ln += 1;
                        }
                    }
                }
                if (out.items.len > 100 * 1024) {
                    w.print("... truncated\n", .{}) catch {};
                    break;
                }
            }
        } else if (std.mem.eql(u8, op, "sort")) {
            if (!have_set) {
                w.print("error: sort needs prior step\n", .{}) catch {};
                return;
            }
            const by = getStr(step, "by") orelse "path";
            if (std.mem.eql(u8, by, "path")) {
                std.mem.sort([]const u8, file_set.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lt);
            }
            // "score" sorting is implicit from find — no re-sort needed
        } else if (std.mem.eql(u8, op, "word")) {
            const word = getStr(step, "word") orelse {
                w.print("error: word needs 'word'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "word needs 'word'", step);
                return;
            };
            const hits = explorer.searchWord(word, alloc) catch {
                w.print("error: word search failed\n", .{}) catch {};
                return;
            };
            defer alloc.free(hits);
            if (have_set) {
                // Intersect: only show hits from files in current set
                var path_set = std.StringHashMap(void).init(alloc);
                defer path_set.deinit();
                var hit_set = std.StringHashMap(void).init(alloc);
                defer hit_set.deinit();
                for (file_set.items) |p| path_set.put(p, {}) catch {};
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                for (hits) |h| {
                    const hp = explorer.word_index.hitPath(h);
                    if (path_set.contains(hp)) {
                        w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
                        hit_set.put(hp, {}) catch {};
                        recordHitLine(&hit_lines, alloc, hp, h.line_num);
                    }
                }
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (hit_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
            } else {
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                var seen = std.StringHashMap(void).init(alloc);
                defer seen.deinit();
                w.print("{d} word hits for '{s}':\n", .{ hits.len, word }) catch {};
                file_set.clearRetainingCapacity();
                for (hits) |h| {
                    const hp = explorer.word_index.hitPath(h);
                    w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
                    recordHitLine(&hit_lines, alloc, hp, h.line_num);
                    if (!seen.contains(hp)) {
                        const duped = alloc.dupe(u8, hp) catch continue;
                        seen.put(duped, {}) catch { alloc.free(duped); continue; };
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "callers")) {
            const name = getStr(step, "name") orelse {
                w.print("error: callers needs 'name'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "callers needs 'name'", step);
                return;
            };
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;

            // Find definitions to exclude from caller results
            const defs = explorer.findAllSymbols(name, alloc) catch {
                w.print("error: symbol lookup failed\n", .{}) catch {};
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

            // Search for all occurrences with scope info
            const results = explorer.searchContentWithScope(name, alloc, max) catch {
                w.print("error: callers search failed\n", .{}) catch {};
                return;
            };
            defer {
                for (results) |r| {
                    alloc.free(r.line_text);
                    alloc.free(r.path);
                    if (r.scope_name) |sn| alloc.free(sn);
                }
                alloc.free(results);
            }

            // Helper: check if a result is a call site (not a definition)
            const CallSiteFilter = struct {
                fn isCallSite(r: Explorer.ScopedSearchResult, definition_list: []const explore_mod.SymbolResult, nm: []const u8) bool {
                    if (!mcp.langHasCallSites(explore_mod.detectLanguage(r.path))) return false;
                    for (definition_list) |d| {
                        if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path))
                            return false;
                    }
                    return mcp.hasWholeWordMatch(r.line_text, nm);
                }
            };

            if (have_set) {
                // Intersect: only show callers in files from current set
                var path_set = std.StringHashMap(void).init(alloc);
                defer path_set.deinit();
                for (file_set.items) |p| path_set.put(p, {}) catch {};

                var caller_files = std.StringHashMap(void).init(alloc);
                defer caller_files.deinit();

                var shown: usize = 0;
                for (results) |r| {
                    if (!CallSiteFilter.isCallSite(r, defs, name)) continue;
                    if (!path_set.contains(r.path)) continue;
                    shown += 1;
                    if (r.scope_name) |sn| {
                        w.print("  {s}:{d}: {s}  [in {s}]\n", .{ r.path, r.line_num, r.line_text, sn }) catch {};
                    } else {
                        w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                    }
                    caller_files.put(r.path, {}) catch {};
                    recordHitLine(&hit_lines, alloc, r.path, r.line_num);
                }
                // Narrow file_set to only files that had callers
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (caller_files.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
                w.print("{d} callers for '{s}' (within {d} candidate files)\n", .{ shown, name, path_set.count() }) catch {};
            } else {
                // Seed: set file_set to caller files
                var seen = std.StringHashMap(void).init(alloc);
                defer seen.deinit();
                file_set.clearRetainingCapacity();

                var shown: usize = 0;
                for (results) |r| {
                    if (!CallSiteFilter.isCallSite(r, defs, name)) continue;
                    shown += 1;
                    if (r.scope_name) |sn| {
                        w.print("  {s}:{d}: {s}  [in {s}]\n", .{ r.path, r.line_num, r.line_text, sn }) catch {};
                    } else {
                        w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                    }
                    recordHitLine(&hit_lines, alloc, r.path, r.line_num);
                    if (!seen.contains(r.path)) {
                        const duped = alloc.dupe(u8, r.path) catch continue;
                        seen.put(duped, {}) catch { alloc.free(duped); continue; };
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
                w.print("{d} callers for '{s}' across {d} files:\n", .{ shown, name, file_set.items.len }) catch {};
            }
        } else if (std.mem.eql(u8, op, "symbol")) {
            const name = getStr(step, "name") orelse {
                w.print("error: symbol needs 'name'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "symbol needs 'name'", step);
                return;
            };
            const results = explorer.findAllSymbols(name, alloc) catch {
                w.print("error: symbol search failed\n", .{}) catch {};
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
            var seen = std.StringHashMap(void).init(alloc);
            defer seen.deinit();
            w.print("{d} symbols '{s}':\n", .{ results.len, name }) catch {};
            for (results) |r| {
                w.print("  {s}:{d} ({s})\n", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
            }
            if (!have_set) {
                file_set.clearRetainingCapacity();
                for (results) |r| {
                    if (!seen.contains(r.path)) {
                        const duped = alloc.dupe(u8, r.path) catch continue;
                        seen.put(duped, {}) catch { alloc.free(duped); continue; };
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "limit")) {
            if (!have_set) {
                w.print("error: limit needs prior step\n", .{}) catch {};
                return;
            }
            const n: usize = if (getInt(step, "n")) |i| @intCast(@max(1, @min(i, 100))) else 10;
            if (file_set.items.len > n) file_set.items.len = n;
        } else if (std.mem.eql(u8, op, "type_search")) {
            const return_type = getStr(step, "return_type");
            const param_type = getStr(step, "param_type");
            if (return_type == null and param_type == null) {
                w.print("error: type_search needs 'return_type' or 'param_type'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "type_search needs 'return_type' or 'param_type'", step);
                return;
            }
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 1000))) else 50;
            var shown: usize = 0;
            if (return_type) |rt| {
                const hits = explorer.type_index.findByReturnType(rt);
                for (hits) |hit| {
                    if (shown >= max) break;
                    if (have_set) {
                        var in_set = false;
                        for (file_set.items) |p| {
                            if (std.mem.eql(u8, p, hit.path)) { in_set = true; break; }
                        }
                        if (!in_set) continue;
                    }
                    w.print("  {s}:{d} {s} -> {s}\n", .{ hit.path, hit.line_start, hit.symbol_name, rt }) catch {};
                    shown += 1;
                    // Track hit line for context-aware reads
                    recordHitLine(&hit_lines, alloc, hit.path, hit.line_start);
                }
            }
            if (param_type) |pt| {
                const hits = explorer.type_index.findByParamType(pt);
                for (hits) |hit| {
                    if (shown >= max) break;
                    if (have_set) {
                        var in_set = false;
                        for (file_set.items) |p| {
                            if (std.mem.eql(u8, p, hit.path)) { in_set = true; break; }
                        }
                        if (!in_set) continue;
                    }
                    w.print("  {s}:{d} {s} ({s})\n", .{ hit.path, hit.line_start, hit.symbol_name, pt }) catch {};
                    shown += 1;
                    recordHitLine(&hit_lines, alloc, hit.path, hit.line_start);
                }
            }
            // Narrow file_set to files with type hits
            if (have_set) {
                // Already filtered by intersection above
            } else {
                // Build file set from hits
                var seen_types = std.StringHashMap(void).init(alloc);
                defer seen_types.deinit();
                if (return_type) |rt| {
                    for (explorer.type_index.findByReturnType(rt)) |hit| {
                        if (!seen_types.contains(hit.path)) {
                            seen_types.put(hit.path, {}) catch continue;
                            const duped = alloc.dupe(u8, hit.path) catch continue;
                            file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                        }
                    }
                }
                if (param_type) |pt| {
                    for (explorer.type_index.findByParamType(pt)) |hit| {
                        if (!seen_types.contains(hit.path)) {
                            seen_types.put(hit.path, {}) catch continue;
                            const duped = alloc.dupe(u8, hit.path) catch continue;
                            file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                        }
                    }
                }
                have_set = true;
            }
            w.print("{d} type hits\n", .{shown}) catch {};
        } else if (std.mem.eql(u8, op, "type_compat")) {
            // Find all types that implement/extend a given base type
            const base_name = getStr(step, "name") orelse {
                w.print("error: type_compat needs 'name'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "type_compat needs 'name'", step);
                return;
            };
            const derived = explorer.type_graph.getDerived(base_name);
            if (derived.len == 0) {
                w.print("no types implementing '{s}' found\n", .{base_name}) catch {};
            } else {
                w.print("{d} types implementing '{s}':\n", .{ derived.len, base_name }) catch {};
                for (derived) |d| {
                    w.print("  {s}\n", .{d}) catch {};
                }
            }
            // Build file set from derived types' definitions
            if (!have_set) {
                for (derived) |derived_name| {
                    const hits = explorer.type_index.findByReturnType(derived_name);
                    for (hits) |hit| {
                        const duped = alloc.dupe(u8, hit.path) catch continue;
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
            }
        } else {
            w.print("error: unknown op '{s}'\n", .{op}) catch {};
            return;
        }
        // Issue #356-p3: track each successfully-completed step.
        stages.append(alloc, .{ .op = op, .files_out = file_set.items.len }) catch {};
    }

    if (out.items.len == 0 and have_set) {
        w.print("{d} files:\n", .{file_set.items.len}) catch {};
        for (file_set.items) |path| w.print("  {s}\n", .{path}) catch {};
    }

    // Issue #356-p3: per-stage summary tail. Lists each completed step's op
    // and outgoing file count so callers can audit a multi-step pipeline at
    // a glance without re-parsing the unstructured output above.
    if (stages.items.len > 0) {
        w.print("\n--- stages ---\n", .{}) catch {};
        for (stages.items, 0..) |s, i| {
            w.print("{d}: {s} ({d} files)\n", .{ i, s.op, s.files_out }) catch {};
        }
    }
}
