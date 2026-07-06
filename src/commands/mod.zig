const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../cio.zig");
const shell = @import("../cli/shell.zig");
const disk_cache = @import("../cli/disk_cache.zig");
const scan = @import("../cli/scan.zig");
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const Explorer = @import("../explore.zig").Explorer;
const watcher = @import("../watcher.zig");
const server = @import("../server.zig");
const mcp_server = @import("../mcp.zig");
const sty = @import("../style.zig");
const git_mod = @import("../git.zig");
const TrigramIndex = @import("../index.zig").TrigramIndex;
const MmapTrigramIndex = @import("../index.zig").MmapTrigramIndex;
const WordIndex = @import("../index.zig").WordIndex;
const index_mod = @import("../index.zig");
const snapshot_mod = @import("../snapshot.zig");
const telemetry = @import("../telemetry.zig");
const root_policy = @import("../root_policy.zig");
const nuke_mod = @import("../nuke.zig");
const update_mod = @import("../update.zig");
const release_info = @import("../release_info.zig");
const Config = @import("../config.zig").Config;

const Out = shell.Out;
const CommandContext = @import("context.zig").Context;
const tree_cmd = @import("tree.zig");
const outline_cmd = @import("outline.zig");
const find_cmd = @import("find.zig");
const search_cmd = @import("search.zig");
const word_cmd = @import("word.zig");
const hot_cmd = @import("hot.zig");
const snapshot_cmd = @import("snapshot.zig");
const serve_cmd = @import("serve.zig");
const mcp_cmd = @import("mcp.zig");

pub fn run() !void {
    // Use c_allocator (libc malloc) — better page reclamation than GPA
    const allocator = std.heap.c_allocator;

    // 0.16: single Threaded I/O instance passed down through every subsystem
    // that touches fs/subprocess. See issue #282. `io` flows into mcp.run,
    // update.run, nuke.run, watcher.initialScan, server.serve, Store, Explorer.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stdout = cio.File.stdout();
    const use_color = stdout.isTty();
    const s = sty.style(use_color);
    var out = Out{ .file = stdout, .alloc = allocator };

    // On Windows, apply any staged .pending update before doing real work.
    if (builtin.os.tag == .windows) {
        const stderr_file = cio.File.stderr();
        var stderr_out = Out{ .file = stderr_file, .alloc = allocator };
        update_mod.applyPendingUpdate(io, &stderr_out);
    }

    const raw_args = try cio.argsAlloc(allocator);
    defer cio.argsFree(allocator, raw_args);

    // Extract --config-file=<path> / --config-file <path> before positional
    // arg parsing so a leading `--config-file=X` isn't misread as the root.
    // See #101, #102.
    var explicit_config: ?[]const u8 = null;
    const args = blk: {
        var filtered: std.ArrayList([]const u8) = .empty;
        errdefer filtered.deinit(allocator);
        try filtered.append(allocator, raw_args[0]);
        var i: usize = 1;
        while (i < raw_args.len) : (i += 1) {
            const a = raw_args[i];
            if (std.mem.startsWith(u8, a, "--config-file=")) {
                explicit_config = a["--config-file=".len..];
                continue;
            } else if (std.mem.eql(u8, a, "--config-file") and i + 1 < raw_args.len) {
                explicit_config = raw_args[i + 1];
                i += 1;
                continue;
            }
            try filtered.append(allocator, a);
        }
        break :blk try filtered.toOwnedSlice(allocator);
    };
    defer allocator.free(args);

    var root: []const u8 = undefined;
    var cmd: []const u8 = undefined;
    var cmd_args_start: usize = undefined;
    var root_is_explicit: bool = false;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--mcp")) {
        root = ".";
        cmd = "mcp";
        cmd_args_start = 2;
    } else if (args.len >= 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        root = ".";
        cmd = "--version";
        cmd_args_start = 2;
    } else if (args.len >= 2 and
        (std.mem.eql(u8, args[1], "--help") or
            std.mem.eql(u8, args[1], "-h") or
            std.mem.eql(u8, args[1], "help")))
    {
        root = ".";
        cmd = args[1];
        cmd_args_start = 2;
    } else if (args.len < 2) {
        shell.printUsage(out, s);
        std.process.exit(1);
    } else if (shell.isCommand(args[1])) {
        root = ".";
        cmd = args[1];
        cmd_args_start = 2;
    } else if (args.len >= 3) {
        root = args[1];
        cmd = args[2];
        cmd_args_start = 3;
        root_is_explicit = true;
        // #639: editors launch codedb with the unexpanded `${workspaceFolder}`
        // placeholder (VS Code etc.). Treat it as an alias for the implicit cwd
        // root, NOT an explicit one — otherwise root_is_explicit stays true and
        // silently disables the deferred-scan handshake, CODEDB_ROOT fallback,
        // and (with the git-repo guard) the lazy→git-gated index path, leaving
        // the agent with an empty index and no error. Normalize here so the
        // downstream gates behave exactly like a bare `codedb mcp`.
        if (std.mem.eql(u8, root, "${workspaceFolder}")) {
            root = ".";
            root_is_explicit = false;
        }
    } else {
        shell.printUsage(out, s);
        std.process.exit(1);
    }

    // CODEDB_ROOT env var lets clients (Claude Code MCP, shell scripts) pin
    // the root without needing to pass a positional arg. Treated as explicit
    // so the MCP scan kicks off at startup instead of waiting for a roots
    // handshake — without this, every fresh `codedb mcp` call against a
    // client that doesn't send roots/list_changed sees an empty index.
    if (shell.mcpRootAcceptsEnvFallback(cmd, root)) {
        if (cio.posixGetenv("CODEDB_ROOT")) |env_root| {
            if (env_root.len > 0) {
                root = env_root;
                root_is_explicit = true;
            }
        }
    }

    // MCP stdio reserves stdout for JSON-RPC — route status/error output to
    // stderr so startup/failure paths don't corrupt the protocol stream.
    // See #304.
    if (std.mem.eql(u8, cmd, "mcp")) {
        out.file = cio.File.stderr();
    }

    // Handle --version early (no root needed)
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        out.p("codedb {s}\n", .{release_info.semver});
        return;
    }

    // Handle --help early (no root needed)
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        shell.printUsage(out, s);
        return;
    }

    // Handle update command early — before root resolution so it works from anywhere.
    if (std.mem.eql(u8, cmd, "update")) {
        update_mod.run(io, stdout, s, allocator);
        return;
    }

    // Handle nuke command early — before root resolution so it works from anywhere
    if (std.mem.eql(u8, cmd, "nuke")) {
        nuke_mod.run(io, stdout, s, allocator);
        return;
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = shell.resolveRoot(io, root, &root_buf) catch {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, root, s.reset,
        });
        std.process.exit(1);
    };
    // For `codedb mcp` from cwd, always go through deferred mode: we need the
    // initialize handshake first to know whether the client is going to send
    // workspace roots. If we eager-load here we'd race the client's roots/list
    // reply and silently ignore an editor's actual workspace path. The trigger
    // path is fast (snapshot load happens in-process when the trigger fires),
    // and clients that don't advertise the roots capability fire the trigger
    // immediately on notifications/initialized — see handleSession.
    const mcp_deferred_root = shell.mcpRootIsImplicitCwd(cmd, root, root_is_explicit);
    if (!mcp_deferred_root and !root_policy.isIndexableRoot(abs_root)) {
        out.p("{s}\xe2\x9c\x97{s} refusing to index temporary root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, abs_root, s.reset,
        });
        std.process.exit(1);
    }

    const data_dir = try disk_cache.getDataDir(io, allocator, abs_root);
    defer allocator.free(data_dir);

    // Load user config (.codedbrc). Resolution: --config-file=<path>, then
    // $CWD/.codedbrc, then <binary_dir>/.codedbrc. Silently falls back to
    // defaults if nothing is found. See #101, #102.
    const cfg = disk_cache.loadUserConfig(io, allocator, explicit_config) catch |err| blk: {
        std.log.warn("config load failed ({s}) — using defaults", .{@errorName(err)});
        break :blk Config.default;
    };

    var store = Store.init(allocator);
    store.max_versions = cfg.max_versions;
    defer store.deinit();

    // Generated-code artifacts (EF migrations, *.Designer.cs, source-generator
    // outputs) are skipped at index time by default. `index_generated_files`
    // lets a user opt back in via .codedbrc.
    watcher.setIncludeGenerated(cfg.index_generated_files);

    // Indexing memory budget (#591 Task 8): config value, overridable by the
    // CODEDB_MAX_MEMORY_MB env var (same precedence as CODEDB_REQUIRE_GIT_REPO).
    // Applied here so every entry point — mcp server, CLI scan, and the
    // `codedb <path> snapshot` subprocess handleIndex spawns — gets the cap.
    watcher.budget.setLimitMb(blk: {
        if (cio.posixGetenv("CODEDB_MAX_MEMORY_MB")) |v| {
            if (std.fmt.parseInt(u32, v, 10) catch null) |mb| break :blk mb;
        }
        break :blk cfg.max_index_memory_mb;
    });

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(io, data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator);
    explorer.content_cache_limit = cfg.max_cached;

    const rerank_trace_path: ?[]u8 = if (cfg.rerank_trace)
        (std.fmt.allocPrint(allocator, "{s}/rerank-traces.jsonl", .{data_dir}) catch null)
    else
        null;
    defer if (rerank_trace_path) |p| allocator.free(p);
    if (rerank_trace_path) |p| explorer.rerank_trace_path = p;

    explorer.setRoot(io, root);
    defer explorer.deinit();

    // Per-project frequency table for sparse n-gram boundary selection.
    // Loaded from disk (if present) before the initial scan so pairWeight
    // uses project-specific frequencies.  Freed and reset at process exit.
    var freq_table_heap: ?*[256][256]u16 = null;
    defer if (freq_table_heap) |ft| {
        index_mod.resetFrequencyTable();
        allocator.destroy(ft);
    };

    if (!std.mem.eql(u8, cmd, "mcp")) {
        const git_head = git_mod.getGitHead(abs_root, allocator) catch null;

        const snapshot_t0 = cio.nanoTimestamp();
        const loaded_snapshot = disk_cache.loadBestSnapshot(io, &explorer, &store, abs_root, data_dir, git_head, allocator);
        defer if (loaded_snapshot) |p| allocator.free(p);
        const snapshot_loaded = loaded_snapshot != null;
        const snapshot_elapsed = cio.nanoTimestamp() - snapshot_t0;

        const needs_word_index = std.mem.eql(u8, cmd, "word");
        if (snapshot_loaded) {
            if (std.mem.eql(u8, cmd, "search")) {
                disk_cache.loadTrigramFromDiskIfPresent(io, &explorer, data_dir, allocator);
            } else if (std.mem.eql(u8, cmd, "word")) {
                disk_cache.loadWordIndexFromDiskIfPresent(io, &explorer, data_dir, git_head, allocator);
            }
            // Heal offline edits AFTER disk-index adoption (ordering note on
            // reconcileAfterLoad) so one-shot CLI queries see current reality.
            disk_cache.reconcileAfterLoad(io, loaded_snapshot.?, &explorer, &store, abs_root, allocator);
            var dur_buf: [64]u8 = undefined;
            out.p("{s}\xe2\x9c\x93{s} {s}loaded snapshot{s}  {s}{d} files{s}  {s}{s}{s}\n", .{
                s.green,                                        s.reset,
                s.bold,                                         s.reset,
                s.dim,                                          explorer.outlines.count(),
                s.reset,                                        sty.durationColor(s, snapshot_elapsed),
                sty.formatDuration(&dur_buf, snapshot_elapsed), s.reset,
            });
        } else {
            const disk_hdr = TrigramIndex.readDiskHeader(io, data_dir, allocator) catch null;
            const heads_match = blk2: {
                const a = git_head orelse break :blk2 false;
                const b = (disk_hdr orelse break :blk2 false).git_head orelse break :blk2 false;
                break :blk2 std.mem.eql(u8, &a, &b);
            };
            // Load per-project freq table before scan so pairWeight is project-aware.
            if (index_mod.readFrequencyTable(io, data_dir, allocator) catch null) |ft| {
                freq_table_heap = ft;
                index_mod.setFrequencyTable(ft);
            }

            const t_scan = cio.nanoTimestamp();
            // Use page_allocator for word index during scan — freed pages
            // return to OS immediately instead of c_allocator retention.
            explorer.mu.lock();
            explorer.word_index.deinit();
            explorer.word_index = WordIndex.init(std.heap.c_allocator);
            explorer.mu.unlock();
            // Skip file_words tracking during bulk scan — saves ~450MB.
            // Only needed for removeFile (incremental re-indexing), not initial scan.
            explorer.word_index.skip_file_words = true;
            if (!needs_word_index) explorer.word_index.enabled = false;
            // For search: single-pass scan + trigram build (no re-reading files).
            // For other commands: outline-only scan, trigrams from disk or rebuild.
            const is_search = std.mem.eql(u8, cmd, "search");
            if (is_search and !heads_match) {
                const tmp_tri = try watcher.initialScanWithTrigrams(io, &store, &explorer, root, allocator, std.heap.c_allocator, true);
                if (tmp_tri) |tri| {
                    tri.writeToDisk(io, data_dir, git_head) catch {};
                    tri.deinit();
                    std.heap.c_allocator.destroy(tri);
                    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.adoptTrigramIndex(.{ .mmap = loaded });
                    }
                }
            } else {
                try watcher.initialScan(io, &store, &explorer, root, allocator, true);
            }
            // Type-usage dependency edges need a complete symbol_index. The
            // per-file pass runs during indexing for incremental freshness;
            // this post-scan pass fixes initial-scan ordering (A can reference
            // B before B was indexed).
            explorer.rebuildTypeUsageDeps();
            const scan_elapsed = cio.nanoTimestamp() - t_scan;
            var dur_buf: [64]u8 = undefined;
            out.p("{s}\xe2\x9c\x93{s} {s}indexed{s}  {s}{s}{s}\n", .{
                s.green,                            s.reset,
                s.dim,                              s.reset,
                sty.durationColor(s, scan_elapsed), sty.formatDuration(&dur_buf, scan_elapsed),
                s.reset,
            });

            var release_contents_after_cache = false;
            if (heads_match) {
                // Verify file count then load trigram from disk via mmap
                const current_count = @as(u32, @intCast(explorer.outlines.count()));
                if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
                    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.adoptTrigramIndex(.{ .mmap = loaded });
                    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.adoptTrigramIndex(.{ .heap = loaded });
                    } else {
                        explorer.rebuildTrigrams() catch {};
                        explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
                            std.log.warn("could not persist trigram index: {}", .{err});
                        };
                    }
                } else {
                    explorer.rebuildTrigrams() catch {};
                    explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                    };
                }
            } else if (!is_search) {
                // Cold run (non-search): persist word index, then build trigrams
                // in parallel from the content already cached in Explorer.contents
                // — no second pass over the filesystem.
                if (needs_word_index) {
                    disk_cache.persistWordIndexToDisk(io, &explorer, data_dir, git_head);
                    explorer.markWordIndexAsComplete();
                }
                const cpu_count = std.Thread.getCpuCount() catch 1;
                const tri_workers: usize = @min(@as(usize, @intCast(cpu_count)), 8);
                const tmp_tri = watcher.buildTrigramsFromCache(&explorer.contents, allocator, std.heap.c_allocator, tri_workers) catch null;
                if (tmp_tri) |tri| {
                    defer {
                        tri.deinit();
                        std.heap.c_allocator.destroy(tri);
                    }
                    tri.writeToDisk(io, data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                    };
                }
                // Load trigrams as mmap (zero heap cost); then we can safely
                // release file contents since mmap serves future searches.
                if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                    explorer.adoptTrigramIndex(.{ .mmap = loaded });
                }
                release_contents_after_cache = true;
            }

            // If no freq table was loaded, build one from indexed content and
            // persist for next run.  Streams file-by-file — zero extra memory.
            if (freq_table_heap == null) {
                if (explorer.contents.count() > 0) {
                    const ft = index_mod.buildFrequencyTableFromMap(&explorer.contents);
                    index_mod.writeFrequencyTable(io, &ft, data_dir) catch |err| {
                        std.log.warn("could not persist frequency table: {}", .{err});
                    };
                }
            }

            if (!std.mem.eql(u8, cmd, "snapshot")) {
                snapshot_mod.writeProjectCacheSnapshot(io, &explorer, abs_root, allocator) catch |err| {
                    std.log.warn("could not persist project-cache snapshot: {}", .{err});
                };
            }
            if (release_contents_after_cache) {
                explorer.releaseContents();
            }
        } // end else (no snapshot)
    }

    var context = CommandContext{
        .io = io,
        .allocator = allocator,
        .out = out,
        .s = s,
        .store = &store,
        .explorer = &explorer,
        .args = args,
        .cmd_args_start = cmd_args_start,
        .root = root,
        .abs_root = abs_root,
        .data_dir = data_dir,
        .use_color = use_color,
        .mcp_deferred_root = mcp_deferred_root,
        .mcp_auto_index = cfg.mcp_auto_index,
        .require_git_repo = cfg.require_git_repo,
    };

    if (std.mem.eql(u8, cmd, "tree")) {
        try tree_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "outline")) {
        try outline_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "find")) {
        try find_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "search")) {
        try search_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "word")) {
        try word_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "hot")) {
        try hot_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        try snapshot_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        try serve_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        try mcp_cmd.run(&context);
    } else if (std.mem.eql(u8, cmd, "index")) {
        // #633: `index` is a first-class command. The cold scan + persist path
        // above already built the on-disk index for this cmd (the project-cache
        // snapshot is written unless cmd == "snapshot"); confirm and exit 0.
        // It used to fall through to "unknown command: index" + exit 1 even
        // though the index had been built.
        const file_count = explorer.outlines.count();
        out.p("{s}\xe2\x9c\x93{s} {s}index ready{s}  {s}{d} files{s}\n", .{
            s.green, s.reset, s.bold, s.reset, s.dim, file_count, s.reset,
        });
        std.process.exit(0);
    } else {
        out.p("{s}\xe2\x9c\x97{s} unknown command: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, cmd, s.reset,
        });
        std.process.exit(1);
    }
}
