const std = @import("std");
const cio = @import("../cio.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const FileOutline = explore_mod.FileOutline;
const Symbol = explore_mod.Symbol;
const SymbolKind = explore_mod.SymbolKind;
const Language = explore_mod.Language;
const git_mod = @import("../git.zig");
const json_utils = @import("../json_utils.zig");
const format = @import("format.zig");
const sensitive = @import("sensitive.zig");
const root_resolve = @import("../root_resolve.zig");
const MAGIC = format.MAGIC;
const FORMAT_VERSION = format.FORMAT_VERSION;
const SectionId = format.SectionId;
const SectionEntry = format.SectionEntry;
const isSensitivePath = sensitive.isSensitivePath;

pub fn writeSnapshot(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const rand_suffix = cio.randU64();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ output_path, rand_suffix });
    defer allocator.free(tmp_path);

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});

    var sections: std.ArrayList(SectionEntry) = .empty;
    defer sections.deinit(allocator);

    var fw_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &fw_buf);
    const fw = &file_writer.interface;

    // Reserve space for header + section table (rewritten at end)
    // Header: 52 bytes.  Section table: up to 5 sections × 20 = 100.
    // Round to 256 for alignment.
    const header_reserve: u64 = 256;
    try file_writer.seekTo(header_reserve);

    // Capture the working tree's dirty list BEFORE taking the explorer lock —
    // it is a git subprocess (~10ms) and must not extend lock hold time. The
    // list lands in META as `dirty_paths` so a warm start can reconcile files
    // that were dirty at write time but are clean at load time (the revert
    // case — see watcher/reconcile.zig). Snapshot writes are cold-path only
    // (scan completion / CLI `snapshot`), never the query hot path.
    const dirty_paths: ?[][]u8 = git_mod.getDirtyPaths(root_path, allocator);
    defer if (dirty_paths) |d| git_mod.freePathList(d, allocator);

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    // ── Section: META ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);
        var total_bytes: u64 = 0;
        var outline_size_iter = explorer.outlines.valueIterator();
        while (outline_size_iter.next()) |outline| {
            total_bytes += outline.byte_size;
        }
        var file_count_meta: u32 = 0;
        var fc_iter = explorer.outlines.keyIterator();
        while (fc_iter.next()) |k| {
            if (!isSensitivePath(k.*)) file_count_meta += 1;
        }

        const root_hash = root_resolve.cacheKey(root_path);
        const cbi_hash = explorer.codedbignore_hash orelse @as(u64, 0);
        try writer.print(
            \\{{"file_count":{d},"total_bytes":{d},"indexed_at":{d},"format_version":{d},"root_hash":{d},"codedbignore_hash":{d}
        , .{
            file_count_meta,
            total_bytes,
            @divTrunc(cio.nanoTimestamp(), 1_000_000_000),
            FORMAT_VERSION,
            root_hash,
            cbi_hash,
        });
        // Optional dirty_paths array — absent for clean trees and non-git
        // projects (META parsing is key-lookup, so absent == empty; no format
        // version bump). Sensitive path NAMES are filtered too: the snapshot
        // must not even reveal that a .env/.pem exists.
        if (dirty_paths) |dp| {
            var wrote_any = false;
            for (dp) |p| {
                if (isSensitivePath(p)) continue;
                if (!wrote_any) {
                    try writer.writeAll(",\"dirty_paths\":[");
                } else {
                    try writer.writeByte(',');
                }
                wrote_any = true;
                try writer.writeByte('"');
                try json_utils.writeEscapedToWriter(writer, p);
                try writer.writeByte('"');
            }
            if (wrote_any) try writer.writeByte(']');
        }
        try writer.writeByte('}');
        try fw.writeAll(buf.items);
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.meta), .offset = offset, .length = buf.items.len });
    }

    // ── Section: TREE ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);
        try writer.writeByte('[');
        var first = true;
        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            if (isSensitivePath(entry.key_ptr.*)) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            const outline = entry.value_ptr;
            try writer.writeAll("{\"path\":\"");
            try json_utils.writeEscapedToWriter(writer, entry.key_ptr.*);
            try writer.print(
                \\","language":"{s}","line_count":{d},"byte_size":{d},"symbol_count":{d}}}
            , .{
                @tagName(outline.language),
                outline.line_count,
                outline.byte_size,
                outline.symbols.items.len,
            });
        }
        try writer.writeByte(']');
        try fw.writeAll(buf.items);
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.tree), .offset = offset, .length = buf.items.len });
    }

    // ── Section: OUTLINE_STATE ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);

        var file_count_buf: [4]u8 = undefined;
        var file_count: u32 = 0;
        var count_iter = explorer.outlines.keyIterator();
        while (count_iter.next()) |key_ptr| {
            if (!isSensitivePath(key_ptr.*)) file_count += 1;
        }
        std.mem.writeInt(u32, &file_count_buf, file_count, .little);
        try writer.writeAll(&file_count_buf);

        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            if (isSensitivePath(entry.key_ptr.*)) continue;

            const path = entry.key_ptr.*;
            const outline = entry.value_ptr;

            var path_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &path_len_buf, @intCast(path.len), .little);
            try writer.writeAll(&path_len_buf);
            try writer.writeAll(path);

            try writer.writeByte(@intFromEnum(outline.language));

            var line_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &line_count_buf, outline.line_count, .little);
            try writer.writeAll(&line_count_buf);

            var byte_size_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &byte_size_buf, outline.byte_size, .little);
            try writer.writeAll(&byte_size_buf);

            var import_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &import_count_buf, @intCast(outline.imports.items.len), .little);
            try writer.writeAll(&import_count_buf);
            for (outline.imports.items) |imp| {
                const write_len = @min(imp.len, std.math.maxInt(u16));
                var import_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &import_len_buf, @intCast(write_len), .little);
                try writer.writeAll(&import_len_buf);
                try writer.writeAll(imp[0..write_len]);
            }

            var symbol_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &symbol_count_buf, @intCast(outline.symbols.items.len), .little);
            try writer.writeAll(&symbol_count_buf);
            for (outline.symbols.items) |sym| {
                const write_name_len = @min(sym.name.len, std.math.maxInt(u16));
                var name_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &name_len_buf, @intCast(write_name_len), .little);
                try writer.writeAll(&name_len_buf);
                try writer.writeAll(sym.name[0..write_name_len]);

                try writer.writeByte(@intFromEnum(sym.kind));

                var line_start_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_start_buf, sym.line_start, .little);
                try writer.writeAll(&line_start_buf);

                var line_end_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_end_buf, sym.line_end, .little);
                try writer.writeAll(&line_end_buf);

                if (sym.detail) |detail| {
                    if (detail.len > std.math.maxInt(u16)) {
                        // Detail too large to be useful — skip it
                        try writer.writeByte(0);
                    } else {
                        try writer.writeByte(1);
                        var detail_len_buf: [2]u8 = undefined;
                        std.mem.writeInt(u16, &detail_len_buf, @intCast(detail.len), .little);
                        try writer.writeAll(&detail_len_buf);
                        try writer.writeAll(detail);
                    }
                } else {
                    try writer.writeByte(0);
                }

                // ── v3: return_type ──
                if (sym.return_type) |rt| {
                    if (rt.len > std.math.maxInt(u16)) {
                        try writer.writeByte(0);
                    } else {
                        try writer.writeByte(1);
                        var rt_len_buf: [2]u8 = undefined;
                        std.mem.writeInt(u16, &rt_len_buf, @intCast(rt.len), .little);
                        try writer.writeAll(&rt_len_buf);
                        try writer.writeAll(rt);
                    }
                } else {
                    try writer.writeByte(0);
                }

                // ── v3: param_types ──
                var pt_count_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &pt_count_buf, @intCast(sym.param_types.len), .little);
                try writer.writeAll(&pt_count_buf);
                for (sym.param_types) |pt| {
                    const write_pt_len = @min(pt.len, std.math.maxInt(u16));
                    var pt_len_buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &pt_len_buf, @intCast(write_pt_len), .little);
                    try writer.writeAll(&pt_len_buf);
                    try writer.writeAll(pt[0..write_pt_len]);
                }
            }
        }

        try fw.writeAll(buf.items);
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.outline_state), .offset = offset, .length = end - offset });
    }

    // ── Section: CONTENT ──
    {
        const offset = file_writer.logicalPos();
        var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch null;
        defer if (root_dir) |*dir| dir.close(io);

        var path_iter = explorer.outlines.keyIterator();
        while (path_iter.next()) |path_ptr| {
            const path = path_ptr.*;
            // Skip sensitive files that may contain secrets
            if (isSensitivePath(path)) continue;
            const cached_content = explorer.contents.get(path);
            if (cached_content) |content| {
                var pl_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
                try fw.writeAll(&pl_buf);
                try fw.writeAll(path);
                var cl_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &cl_buf, @intCast(content.len), .little);
                try fw.writeAll(&cl_buf);
                try fw.writeAll(content);
            } else if (root_dir) |*dir| {
                const disk_content = dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch continue;
                errdefer allocator.free(disk_content);

                var pl_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
                try fw.writeAll(&pl_buf);
                try fw.writeAll(path);
                var cl_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &cl_buf, @intCast(disk_content.len), .little);
                try fw.writeAll(&cl_buf);
                try fw.writeAll(disk_content);
                allocator.free(disk_content);
            }
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.content), .offset = offset, .length = end - offset });
    }

    // ── Section: FREQ TABLE ──
    {
        const offset = file_writer.logicalPos();
        const table = @import("../index/frequency.zig").active_pair_freq;
        var row_buf: [256 * 2]u8 = undefined;
        for (table) |row| {
            for (row, 0..) |val, j| {
                std.mem.writeInt(u16, row_buf[j * 2 ..][0..2], val, .little);
            }
            try fw.writeAll(&row_buf);
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.freq_table), .offset = offset, .length = end - offset });
    }

    // ── Write header + section table at file start ──
    try file_writer.seekTo(0);

    try fw.writeAll(&MAGIC);
    var ver_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &ver_buf, FORMAT_VERSION, .little);
    try fw.writeAll(&ver_buf);
    try fw.writeAll(&[2]u8{ 0, 0 }); // flags

    const git_head = git_mod.getGitHead(root_path, allocator) catch null;
    if (git_head) |head| {
        try fw.writeAll(&head);
    } else {
        try fw.writeAll(&([_]u8{0x00} ** 40));
    }

    var sc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sc_buf, @intCast(sections.items.len), .little);
    try fw.writeAll(&sc_buf);

    for (sections.items) |sec| {
        var id_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_buf, sec.id, .little);
        try fw.writeAll(&id_buf);
        var off_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &off_buf, sec.offset, .little);
        try fw.writeAll(&off_buf);
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, sec.length, .little);
        try fw.writeAll(&len_buf);
    }

    try fw.flush();
    file.close(io);
    file = undefined;
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), output_path, io) catch |err| {
        // If rename fails (e.g. output_path is a directory), clean up tmp
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };

    // #625: the snapshot lives inside the project tree — make sure git ignores
    // it so it never pollutes `git status` or gets committed by accident.
    if (isRootSnapshot(output_path, root_path)) {
        ensureGitIgnoresSnapshot(io, root_path, allocator);
    }
}

/// True when `output_path` is the in-tree project-root snapshot
/// (`{root_path}/codedb.snapshot`), as opposed to the central ~/.codedb store.
pub fn isRootSnapshot(output_path: []const u8, root_path: []const u8) bool {
    if (root_path.len == 0) return false;
    if (!std.mem.startsWith(u8, output_path, root_path)) return false;
    return std.mem.eql(u8, output_path[root_path.len..], "/codedb.snapshot");
}

/// Append `codedb.snapshot` to the repo's `.git/info/exclude` — a local,
/// untracked ignore file — so the in-tree index is invisible to git without
/// touching the user's own `.gitignore`. Best-effort: not-a-git-repo, a git
/// worktree where `.git` is a file, permissions, or any I/O error is silently
/// skipped. Indexing must never fail because of this. Idempotent.
pub fn ensureGitIgnoresSnapshot(io: std.Io, root_path: []const u8, allocator: std.mem.Allocator) void {
    var info_buf: [std.fs.max_path_bytes]u8 = undefined;
    const info_path = std.fmt.bufPrint(&info_buf, "{s}/.git/info", .{root_path}) catch return;
    var info_dir = std.Io.Dir.cwd().openDir(io, info_path, .{}) catch return;
    defer info_dir.close(io);

    const needle = "codedb.snapshot";
    const existing: ?[]u8 = info_dir.readFileAlloc(io, "exclude", allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        // Any other failure (permissions, oversized file) means an exclude
        // file may exist that we couldn't read — rewriting it now would
        // clobber the user's rules.
        else => return,
    };
    defer if (existing) |e| allocator.free(e);

    if (existing) |content| {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, t, needle) or std.mem.eql(u8, t, "/codedb.snapshot")) return;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (existing) |content| {
        buf.appendSlice(allocator, content) catch return;
        if (content.len > 0 and content[content.len - 1] != '\n') buf.append(allocator, '\n') catch return;
    }
    buf.appendSlice(allocator, needle) catch return;
    buf.append(allocator, '\n') catch return;

    var file = info_dir.createFile(io, "exclude", .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, buf.items) catch return;
}

/// Read section table from a `.codedb` file.
pub fn writeSnapshotDual(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try writeSnapshot(io, explorer, root_path, output_path, allocator);
    writeProjectCacheSnapshot(io, explorer, root_path, allocator) catch {};
}

pub fn writeProjectCacheSnapshot(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // cacheKey, not raw Wyhash — must agree with disk_cache.getDataDir or the
    // central snapshot lands in a dir the loader never looks in (#591; the
    // divergence is only visible on macOS/Windows where cacheKey case-folds).
    const hash = root_resolve.cacheKey(root_path);
    const home_raw = cio.getHomeDir() orelse return;
    const home = allocator.dupe(u8, home_raw) catch return;
    defer allocator.free(home);
    const secondary = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch return;
    defer allocator.free(secondary);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const proj_txt = std.fmt.allocPrint(allocator, "{s}/project.txt", .{dir_path}) catch return;
    defer allocator.free(proj_txt);
    var f = try std.Io.Dir.cwd().createFile(io, proj_txt, .{ .truncate = true });
    f.writeStreamingAll(io, root_path) catch {};
    f.close(io);

    try writeSnapshot(io, explorer, root_path, secondary, allocator);
}
