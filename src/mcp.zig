// codedb MCP server — JSON-RPC 2.0 over stdio
const cio = @import("cio.zig");
//
// Exposes codedb's exploration + edit engine as MCP tools.
// Uses mcp-zig for protocol utilities; adds roots support for workspace awareness.

const std = @import("std");
const testing = std.testing;
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
pub const Root = mcp_lib.mcp.Root;
const Store = @import("store.zig").Store;
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const idx = @import("index.zig");
const snapshot_mod = @import("snapshot.zig");
const telemetry_mod = @import("telemetry.zig");
const git_mod = @import("git.zig");
const root_policy = @import("root_policy.zig");
const release_info = @import("release_info.zig");

// Pull in extracted unit tests (issue-258, issue-353, snapshot cache).
comptime {
    _ = @import("mcp/tests.zig");
}
pub const DeferredScan = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    scan_done: *std.atomic.Value(bool),
    shutdown: *std.atomic.Value(bool),
    telem: *telemetry_mod.Telemetry,
    queue: *watcher.EventQueue,
    startup_t0: i64,
    triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_thread: ?std.Thread = null,
    resolved_root: []const u8 = "",
    fallback_cwd: []const u8 = "",
    triggerFn: *const fn (ctx: *DeferredScan, abs_root: []const u8) void,
};

/// Resolve which path to scan from (first indexable root, or cwd fallback) and
/// fire the deferred scan exactly once. Returns true when this call actually
/// fired the trigger; false if it had already fired or no usable path is
/// available. Callers must filter denied paths out of `indexable_roots` first;
/// the `fallback_cwd` path is policy-checked here.
pub fn triggerDeferredScanWithFallback(
    ds: *DeferredScan,
    indexable_roots: []const Root,
    fallback_cwd: []const u8,
) bool {
    var path: []const u8 = "";
    if (indexable_roots.len > 0) {
        const uri_raw = indexable_roots[0].uri;
        path = if (std.mem.startsWith(u8, uri_raw, "file://")) uri_raw[7..] else uri_raw;
    }
    if (path.len == 0 and fallback_cwd.len > 0 and root_policy.isIndexableRoot(fallback_cwd)) {
        path = fallback_cwd;
    }
    if (path.len == 0) return false;
    if (ds.triggered.swap(true, .acq_rel)) return false;
    ds.triggerFn(ds, path);
    return true;
}

// ── Project cache ────────────────────────────────────────────────────────────

const SnapshotCache = struct {
    const MAX_CACHED_BYTES = 16 * 1024 * 1024;

    seq: u64 = std.math.maxInt(u64),
    bytes: ?[]u8 = null,
    mu: cio.Mutex = .{},

    fn deinit(self: *SnapshotCache, alloc: std.mem.Allocator) void {
        if (self.bytes) |bytes| {
            alloc.free(bytes);
            self.bytes = null;
        }
    }

    fn appendIfFresh(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const bytes = self.bytes orelse return false;
        if (self.seq != seq) return false;
        out.appendSlice(alloc, bytes) catch return false;
        return true;
    }

    /// Takes ownership of `fresh` if it becomes the cache entry. If another
    /// caller filled the same seq first, frees `fresh` and appends the winner.
    fn putAndAppend(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64, fresh: []u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (fresh.len > MAX_CACHED_BYTES) {
            if (self.bytes) |bytes| {
                alloc.free(bytes);
                self.bytes = null;
            }
            self.seq = std.math.maxInt(u64);
            out.appendSlice(alloc, fresh) catch {};
            alloc.free(fresh);
            return;
        }

        if (self.bytes) |bytes| {
            if (self.seq == seq) {
                alloc.free(fresh);
                out.appendSlice(alloc, bytes) catch {};
                return;
            }
            alloc.free(bytes);
        }

        self.seq = seq;
        self.bytes = fresh;
        out.appendSlice(alloc, fresh) catch {};
    }
};

const ProjectCtx = struct {
    explorer: *Explorer,
    store: *Store,
    snapshot_cache: *SnapshotCache,
};

pub fn getProjectDataDir(allocator: std.mem.Allocator, project_path: []const u8) ?[]u8 {
    const hash = std.hash.Wyhash.hash(0, project_path);
    const home = cio.getHomeDir() orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{project_path}) catch null;
    };

    return std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch null;
}

fn loadProjectTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const already_loaded = explorer.trigram_index.fileCount() > 0;
    explorer.mu.unlockShared();
    if (already_loaded) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse return;
    defer allocator.free(data_dir);

    if (idx.MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
    } else if (idx.TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
    }
}

fn loadProjectWordIndexFromDiskIfPresent(io: std.Io, explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };
    defer allocator.free(data_dir);

    const header = idx.WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    const current_git_head = git_mod.getGitHead(project_path, allocator) catch null;
    const heads_match = blk: {
        if (current_git_head == null and header.git_head == null) break :blk true;
        if (current_git_head == null or header.git_head == null) break :blk false;
        break :blk std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
    };
    if (!heads_match) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    if (idx.WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn shouldLoadWordIndexForSearch(args: *const std.json.ObjectMap) bool {
    if (getBool(args, "regex")) return false;
    const query = getStr(args, "query") orelse return false;
    if (query.len < 2 or query.len > 256) return false;

    var saw_word_char = false;
    for (query) |c| {
        const is_word_char =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!is_word_char) return false;
        if (c != '_') saw_word_char = true;
    }
    return saw_word_char;
}

pub const ProjectCache = struct {
    const MAX_CACHED = 5;

    const Entry = struct {
        path: []u8,
        explorer: Explorer,
        store: Store,
        snapshot_cache: SnapshotCache,
        last_used: i64,
    };

    mu: cio.RwLock,
    alloc: std.mem.Allocator,
    entries: [MAX_CACHED]?*Entry,
    default_path: []const u8,
    default_snapshot_cache: SnapshotCache,

    pub fn init(alloc_: std.mem.Allocator, default_path_: []const u8) ProjectCache {
        return .{
            .mu = .{},
            .alloc = alloc_,
            .entries = [_]?*Entry{null} ** MAX_CACHED,
            .default_path = default_path_,
            .default_snapshot_cache = .{},
        };
    }

    pub fn deinit(self: *ProjectCache) void {
        self.default_snapshot_cache.deinit(self.alloc);
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                self.destroyEntry(entry);
                slot.* = null;
            }
        }
    }

    fn destroyEntry(self: *ProjectCache, entry: *Entry) void {
        entry.snapshot_cache.deinit(self.alloc);
        entry.explorer.deinit();
        entry.store.deinit();
        self.alloc.free(entry.path);
        self.alloc.destroy(entry);
    }

    pub fn invalidate(self: *ProjectCache, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    self.destroyEntry(entry);
                    slot.* = null;
                    return;
                }
            }
        }
    }

    pub fn get(
        self: *ProjectCache,
        io: std.Io,
        path: ?[]const u8,
        default_exp: *Explorer,
        default_store: *Store,
    ) !ProjectCtx {
        const p = path orelse return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache };
        if (!root_policy.isIndexableRoot(p))
            return error.PathNotAllowed;

        self.mu.lock();
        defer self.mu.unlock();

        const now = cio.milliTimestamp();
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, p)) {
                    entry.last_used = now;
                    return ProjectCtx{ .explorer = &entry.explorer, .store = &entry.store, .snapshot_cache = &entry.snapshot_cache };
                }
            }
        }

        // Cache miss — load from snapshot
        const new_entry = self.alloc.create(Entry) catch return error.OutOfMemory;
        new_entry.path = self.alloc.dupe(u8, p) catch {
            self.alloc.destroy(new_entry);
            return error.OutOfMemory;
        };
        new_entry.explorer = Explorer.init(self.alloc);
        new_entry.explorer.setRoot(io, p);
        new_entry.store = Store.init(self.alloc);
        new_entry.snapshot_cache = .{};
        new_entry.last_used = now;

        var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{p}) catch {
            new_entry.store.deinit();
            new_entry.explorer.deinit();
            self.alloc.free(new_entry.path);
            self.alloc.destroy(new_entry);
            return error.PathTooLong;
        };

        if (!snapshot_mod.loadSnapshot(io, snap_path, &new_entry.explorer, &new_entry.store, self.alloc)) {
            // Fallback: try central store at ~/.codedb/projects/{hash}/codedb.snapshot
            const hash = std.hash.Wyhash.hash(0, p);
            var central_buf: [std.fs.max_path_bytes]u8 = undefined;
            const loaded_central = blk: {
                const home = cio.getHomeDir() orelse break :blk false;
                const central = std.fmt.bufPrint(&central_buf, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch break :blk false;
                break :blk snapshot_mod.loadSnapshot(io, central, &new_entry.explorer, &new_entry.store, self.alloc);
            };
            if (!loaded_central) {
                new_entry.store.deinit();
                new_entry.explorer.deinit();
                self.alloc.free(new_entry.path);
                self.alloc.destroy(new_entry);
                if (std.mem.eql(u8, p, self.default_path) and default_store.currentSeq() > 0) {
                    return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache };
                }
                return error.SnapshotLoadFailed;
            }
        }

        loadProjectTrigramFromDiskIfPresent(io, &new_entry.explorer, p, self.alloc);

        // Rebuild TypeIndex and TypeGraph from loaded outlines
        new_entry.explorer.rebuildTypeIndexes();

        // Release raw file contents retained by the snapshot load — outlines,
        // trigram index, and word index are sufficient for all query tools.
        const fc = new_entry.explorer.outlines.count();
        if (fc > 1000) {
            new_entry.explorer.releaseContents();
            new_entry.explorer.releaseSecondaryIndexes();
        }

        // Find free slot or evict LRU
        var target_slot: usize = 0;
        var found_free = false;
        for (self.entries, 0..) |slot, i| {
            if (slot == null) {
                target_slot = i;
                found_free = true;
                break;
            }
        }
        if (!found_free) {
            var oldest_i: usize = 0;
            var oldest_t: i64 = self.entries[0].?.last_used;
            for (self.entries[1..], 0..) |slot_opt, j| {
                if (slot_opt.?.last_used < oldest_t) {
                    oldest_t = slot_opt.?.last_used;
                    oldest_i = j + 1;
                }
            }
            const evict = self.entries[oldest_i].?;
            self.destroyEntry(evict);
            target_slot = oldest_i;
        }

        self.entries[target_slot] = new_entry;
        return ProjectCtx{ .explorer = &new_entry.explorer, .store = &new_entry.store, .snapshot_cache = &new_entry.snapshot_cache };
    }
};

pub const BenchContext = struct {
    cache: ProjectCache,

    pub fn init(alloc: std.mem.Allocator, default_path: []const u8) BenchContext {
        return .{
            .cache = ProjectCache.init(alloc, default_path),
        };
    }

    pub fn deinit(self: *BenchContext) void {
        self.cache.deinit();
    }

    pub fn runDispatch(
        self: *BenchContext,
        io: std.Io,
        alloc: std.mem.Allocator,
        tool: Tool,
        args: *const std.json.ObjectMap,
        out: *std.ArrayList(u8),
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
    ) void {
        dispatch(io, alloc, tool, args, out, store, explorer, agents, &self.cache, null);
    }

    pub fn runToolCall(
        self: *BenchContext,
        io: std.Io,
        alloc: std.mem.Allocator,
        name: []const u8,
        tool: Tool,
        args: *const std.json.ObjectMap,
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
        telem: *telemetry_mod.Telemetry,
    ) struct { dispatch_ns: u64, response_bytes: usize } {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        const t0 = cio.nanoTimestamp();
        dispatch(io, alloc, tool, args, &out, store, explorer, agents, &self.cache, null);
        const elapsed = cio.nanoTimestamp() - t0;

        const is_error = std.mem.startsWith(u8, out.items, "error:");
        telem.recordToolCall(name, elapsed, is_error, out.items.len);

        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(alloc);
        summary.ensureTotalCapacity(alloc, 256) catch {};
        summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
        summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
        mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
        var dur_buf: [96]u8 = undefined;
        summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

        var guidance: std.ArrayList(u8) = .empty;
        defer guidance.deinit(alloc);
        mcpGenerateGuidance(alloc, name, args, out.items, is_error, &guidance);

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(alloc);
        result.ensureTotalCapacity(alloc, out.items.len + summary.items.len + guidance.items.len + 256) catch {};
        result.appendSlice(alloc, "{\"content\":[") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = 0 };

        if (summary.items.len > 0) {
            const clean_summary = stripAnsiCodes(alloc, summary.items);
            defer alloc.free(clean_summary);
            result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
            mcpj.writeEscaped(alloc, &result, clean_summary);
            result.appendSlice(alloc, "\"},") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        }

        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        mcpj.writeEscaped(alloc, &result, out.items);
        result.appendSlice(alloc, "\"}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };

        if (guidance.items.len > 0) {
            const clean_guidance = stripAnsiCodes(alloc, guidance.items);
            defer alloc.free(clean_guidance);
            result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
            mcpj.writeEscaped(alloc, &result, clean_guidance);
            result.appendSlice(alloc, "\"}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        }

        result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
    }
};

// ── Tool definitions ────────────────────────────────────────────────────────

pub const Tool = enum {
    codedb_tree,
    codedb_outline,
    codedb_symbol,
    codedb_hierarchy,
    codedb_routes,
    codedb_config_xref,
    codedb_search,
    codedb_word,
    codedb_callers,
    codedb_hot,
    codedb_deps,
    codedb_read,
    codedb_edit,
    codedb_changes,
    codedb_status,
    codedb_snapshot,
    codedb_types,
    codedb_bundle,
    codedb_remote,
    codedb_projects,
    codedb_index,
    codedb_find,
    codedb_query,
    codedb_glob,
    codedb_ls,
};

pub const tools_list =
    \\{"tools":[
    \\{"name":"codedb_tree","description":"Whole-repo file tree with per-file language, line counts, and symbol counts. Use to orient in an unfamiliar project.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_outline","description":"Symbol outline of one file: functions, structs, enums, imports, consts with line numbers. Set grouped=true for sectioned output by symbol kind. Run before codedb_read to find the lines you actually need.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"},"grouped":{"type":"boolean","description":"Group symbols into sections with line ranges and counts (default: false)."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find where a named symbol is defined across the index. Returns file, line, kind, detail, and decorators when captured. Pass body=true for source. Pick this over codedb_search when you have an exact identifier.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name to search for (exact match)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"},"decorator_filter":{"type":"string","description":"Only return symbols whose captured decorator/attribute contains this text, e.g. HttpPost or [Authorize]."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_hierarchy","description":"Class/interface hierarchy lookup. For a class-like symbol, reports direct bases and indexed direct derived/implementing types inferred from declaration detail.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Class, interface, trait, or type symbol name"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_routes","description":"Framework route map. v1 extracts ASP.NET Core MVC routes from C# controller/action attributes captured in the index.","inputSchema":{"type":"object","properties":{"framework":{"type":"string","enum":["aspnet"],"description":"Route extractor to use. Currently only aspnet is supported."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_config_xref","description":"Framework config key cross-reference. v1 compares ASP.NET appsettings*.json keys against IConfiguration reads in C# files.","inputSchema":{"type":"object","properties":{"framework":{"type":"string","enum":["aspnet"],"description":"Config extractor to use. Currently only aspnet is supported."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_search","description":"Substring full-text search across the index (regex if regex=true). For one identifier prefer codedb_word; for a definition prefer codedb_symbol. Scope with path_glob to filter by language.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Maximum results to return (default: 50, start with 10 for broad queries)"},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"},"path_glob":{"type":"string","description":"Filter results to paths matching this glob, e.g. '*.zig' or 'src/**/*.zig'. Bare patterns like '*.zig' are auto-promoted to '**/*.zig' to match nested files."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"Exact-identifier lookup via inverted index — every occurrence of one word, O(1). Use for single identifiers; use codedb_search for substrings or phrases. For common identifiers (50+ hits), pass path_glob to scope results. Results are capped at 50 \\u2014 use path_glob to narrow.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"},"path_glob":{"type":"string","description":"Filter results to paths matching this glob, e.g. **/*.cs or src/Controllers/*.cs. Auto-promotes bare patterns."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["word"]}},
    \\{"name":"codedb_callers","description":"Find every call site of a named symbol — fuses word-index occurrences with outline scope info. One round-trip vs codedb_word + codedb_outline-per-file. Returns {path, line, snippet, scope_name, scope_kind, scope_lines}. Excludes the symbol's own definition site.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (exact identifier match)"},"max_results":{"type":"integer","description":"Maximum call sites to return (default: 50)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_hot","description":"Most recently modified files in the project, newest first.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Dependency graph: who imports a file (default) or what a file imports (direction=depends_on). Set transitive=true for the full BFS blast radius.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"},"direction":{"type":"string","enum":["imported_by","depends_on"],"description":"imported_by (default): who imports this file. depends_on: what this file imports."},"transitive":{"type":"boolean","description":"Follow dependency chain transitively (default: false)"},"max_depth":{"type":"integer","description":"Max traversal depth for transitive queries (default: unlimited)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_read","description":"Read file contents, optionally a line range. Run codedb_outline first to pick the range — large files burn tokens fast. Pass if_hash to skip re-reads when the file is unchanged.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"line_start":{"type":"integer","description":"Start line (1-indexed, inclusive). Omit for full file."},"line_end":{"type":"integer","description":"End line (1-indexed, inclusive). Omit to read to EOF."},"if_hash":{"type":"string","description":"Previous content hash. If unchanged, returns short 'unchanged:HASH' response."},"compact":{"type":"boolean","description":"Skip comment and blank lines (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_edit","description":"Line-based file edit: replace (range), insert (after line), or delete (range). Pass if_hash from the latest codedb_read to reject stale-line edits. Set dry_run=true for a diff preview.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"op":{"type":"string","enum":["replace","insert","delete"],"description":"Edit operation type"},"content":{"type":"string","description":"New content (for replace/insert)"},"range_start":{"type":"integer","description":"Start line number (for replace/delete, 1-indexed)"},"range_end":{"type":"integer","description":"End line number (for replace/delete, 1-indexed)"},"after":{"type":"integer","description":"Insert after this line number (for insert)"},"if_hash":{"type":"string","description":"Hex hash from codedb_read's 'hash:' line. Edit is rejected with HashMismatch if the file has changed since."},"dry_run":{"type":"boolean","description":"If true, return a diff preview without writing. Disk and store are untouched. Default: false."}},"required":["path","op"]}},
    \\{"name":"codedb_changes","description":"Files changed since a given sequence number. Pair with codedb_status to poll for updates.","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to get changes since (default: 0)"}},"required":[]}},
    \\{"name":"codedb_status","description":"Current indexed-file count, sequence number, scan phase, and active ignore/skip rules.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_snapshot","description":"Pre-rendered JSON snapshot of the entire index — tree, outlines, symbols, deps. For caching or shipping to edge workers.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_types","description":"Type-based queries. return_type: find all functions returning a type. param_type: find all functions accepting a type. Both are exact match. Returns symbol name, file, line, and the matched type.","inputSchema":{"type":"object","properties":{"return_type":{"type":"string","description":"Find all symbols with this return type (exact match, e.g. 'Task<UserDto>')"},"param_type":{"type":"string","description":"Find all symbols accepting this param type (exact match, e.g. 'ILogger')"},"max_results":{"type":"integer","description":"Maximum results (default: 50)"},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":[]}},
    \\{"name":"codedb_bundle","description":"Run up to 20 codedb_* calls in one round-trip. Each op is either MCP-style {\"tool\":\"codedb_search\",\"arguments\":{\"query\":\"Agent\"}} or inline {\"tool\":\"codedb_search\",\"query\":\"Agent\"} — both are accepted. Example: {\"ops\":[{\"tool\":\"codedb_search\",\"arguments\":{\"query\":\"Agent\"}},{\"tool\":\"codedb_outline\",\"arguments\":{\"path\":\"src/main.zig\"}}]}. Best for parallel outline/symbol/search; avoid bundling large codedb_read calls — responses are not size-capped. If a sub-op reports `received keys: []`, the wrapper field is misnamed: use `arguments` (MCP spec), not `args`.","inputSchema":{"type":"object","properties":{"ops":{"type":"array","description":"Sub-tool calls to dispatch (max 20). Each item must have `tool` AND `arguments` (pass `{}` if the sub-tool takes none). Inline args alongside `tool` are still accepted as a fallback.","items":{"type":"object","properties":{"tool":{"type":"string","description":"codedb_* tool name to invoke (e.g. codedb_outline, codedb_symbol, codedb_search, codedb_word, codedb_callers, codedb_read, codedb_deps, codedb_tree, codedb_hot, codedb_status, codedb_changes). Required."},"arguments":{"type":"object","description":"Per-call args matching that tool's inputSchema. Field MUST be named `arguments` (MCP `tools/call` convention) — `args` is silently ignored. Pass `{}` only if the sub-tool takes no arguments. Required."}},"required":["tool","arguments"]}},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["ops"]}},
    \\{"name":"codedb_remote","description":"Query indexed public repos via api.wiki.codes. Pass action= one of: tree, outline, search, read, symbol, deps, score, cves, commits, branches, dep-history, policy, actions. Use action=actions first if unsure what a repo supports.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"GitHub repo in owner/repo format (e.g. vercel/next.js) or a raw wiki slug such as chromium."},"action":{"type":"string","enum":["tree","outline","search","read","actions","symbol","policy","deps","score","cves","commits","branches","dep-history"],"description":"What to query from api.wiki.codes: actions, tree, search, outline, read, symbol, policy, deps, score, cves, commits, branches, dep-history."},"query":{"type":"string","description":"Action-specific argument. search: text query. symbol: identifier name. outline: file path."},"path":{"type":"string","description":"For action=read: the file path to fetch."},"lines":{"type":"string","description":"For action=read: line range like '10-60' (1-indexed, inclusive). Omit for full file."},"limit":{"type":"integer","description":"For search/tree/deps/commits/branches/dep-history: cap the number of items returned (server may enforce its own ceiling)."},"offset":{"type":"integer","description":"For tree/deps/commits/branches/dep-history: skip the first N items (pagination)."},"prefix":{"type":"string","description":"For tree: only return paths starting with this prefix (e.g. 'src/')."},"expand":{"type":"boolean","description":"For tree: when true, return the full file list. When false returns a compact directory summary when supported."},"since":{"type":"string","description":"For commits/dep-history: ISO timestamp or commit SHA to start from."},"scope":{"type":"string","enum":["runtime","all"],"description":"For score/cves only. Defaults to runtime; use all to include dev/tooling dependencies."},"backend":{"type":"string","enum":["wiki"],"description":"Deprecated compatibility field. Only 'wiki' is accepted; requests always use api.wiki.codes."}},"required":["repo","action"]}},
    \\{"name":"codedb_projects","description":"List every locally indexed project on this machine: path, data-dir hash, snapshot presence.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_index","description":"Index a local FOLDER (not a file). Builds outlines, trigrams, word index, and writes codedb.snapshot. After indexing, query it via the project= param on any other tool. Pass force=true to delete existing snapshots (in-repo and central cache) and do a full re-index — use when parsers are updated or .codedbignore changed.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the FOLDER (not a file) to index, e.g. /Users/you/myproject"},"force":{"type":"boolean","description":"Delete existing snapshots and force a full re-index (default: false). Use after updating parsers, changing .codedbignore, or when the index seems stale."}},"required":["path"]}},
    \\{"name":"codedb_find","description":"Fuzzy FILE-NAME search ONLY — typo-tolerant subsequence match against indexed file paths. NOT a content/symbol search: 'rerank' will NOT find files containing rerankSignalScore unless the filename itself contains 'rerank'. For symbol lookups use codedb_word/codedb_symbol; for content use codedb_search.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Fuzzy filename query (e.g. 'authmidlware' for auth_middleware.go, 'test_auth', 'main.zig'). Matched against path basenames, not file contents."},"max_results":{"type":"integer","description":"Maximum results to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_query","description":"Composable pipeline — chain ops where each step feeds the next. Ops: find, search, filter, deps, outline, read, sort, limit, word, symbol, callers, type_search, type_compat. Replaces multi-call workflows with one request. search/word/callers steps track hit line numbers; the read step's context_lines param reads N lines of context around those tracked hits instead of reading from the start. type_search finds symbols by return_type or param_type (exact match). type_compat finds all types that implement/extend a given base type via the type graph. Example: [{\"op\":\"search\",\"query\":\"TODO\"},{\"op\":\"read\",\"context_lines\":3}] shows 3 lines around each TODO hit. [{\"op\":\"callers\",\"name\":\"handleRequest\"},{\"op\":\"read\",\"context_lines\":5}] finds all callers and reads 5 lines of context around each call site. callers op: filters to real call sites (excludes definitions, non-call languages); use standalone or after a filter step to scope to specific files.","inputSchema":{"type":"object","properties":{"pipeline":{"type":"array","items":{"type":"object"},"description":"Array of pipeline steps. Each step has 'op' (find/search/filter/deps/outline/read/sort/limit/word/symbol/callers) and op-specific params. Steps execute in order, each filtering/transforming the file set from the previous step. deps op: {\"op\":\"deps\",\"direction\":\"imported_by|depends_on\",\"transitive\":true,\"max_depth\":3}"},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":["pipeline"]}},
    \\{"name":"codedb_glob","description":"Match indexed paths against a glob: * (no /), ** (across /), ? (one char). Sorted lexicographically. Use when you know the path shape; codedb_find for fuzzy names.","inputSchema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. 'src/**/*.zig', '*.md', 'tests/test_*.py')"},"max_results":{"type":"integer","description":"Maximum results to return (default: 200)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["pattern"]}},
    \\{"name":"codedb_ls","description":"List immediate children of a directory with deterministic file descriptors. Set ranked=true to sort by hotspot score and annotate dependents/symbol centrality.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory prefix relative to project root. Omit or pass empty string for root."},"ranked":{"type":"boolean","description":"Sort by hotspot score instead of alphabetically, and include score/dependent counts (default: false)."},"no_descriptor":{"type":"boolean","description":"Suppress deterministic descriptor text in file rows (default: false)."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}}
    \\]}
;

/// Build the augmented `tools/list` payload with a discriminated `oneOf` on
/// the codedb_bundle ops items. Each branch pins `tool` to a const sub-tool
/// name and `arguments` to that sub-tool's actual `inputSchema`, so a model
/// emitting a bundle call is forced to populate `arguments` with the right
/// keys for whichever sub-tool it picked. (Stage 2 of issue #437; Stage 1 in
/// #434 added `arguments` to items.required.)
///
/// codedb_bundle (recursive — rejected at handleBundle) and codedb_edit
/// (write op — rejected at handleBundle) are excluded from the oneOf.
///
/// Caller owns returned slice. The intermediate parse and the slices it
/// references are freed before return.
pub const ToolsListOpts = struct {
    bundle_enabled: bool = false,
    discriminated_opt_in: bool = false,
};

/// Build the runtime `tools/list` response. Honors the bundle and
/// discriminated-schema env-var gates that run() reads. Always returns an
/// allocator-owned slice the caller must free.
pub fn buildToolsListResponse(alloc: std.mem.Allocator, opts: ToolsListOpts) ![]u8 {
    if (opts.bundle_enabled and opts.discriminated_opt_in) {
        return buildAugmentedToolsList(alloc);
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, tools_list, .{});

    const root_obj = &parsed.value.object;
    const tools_val = root_obj.getPtr("tools") orelse return error.MalformedToolsList;
    if (tools_val.* != .array) return error.MalformedToolsList;

    if (!opts.bundle_enabled) {
        var filtered: std.json.Array = .init(a);
        for (tools_val.array.items) |t| {
            if (t == .object) {
                if (t.object.get("name")) |n| {
                    if (n == .string and std.mem.eql(u8, n.string, "codedb_bundle")) continue;
                }
            }
            try filtered.append(t);
        }
        tools_val.* = .{ .array = filtered };
    }

    const out_in_arena = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    return try alloc.dupe(u8, out_in_arena);
}

pub fn buildAugmentedToolsList(alloc: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, tools_list, .{});

    const root_obj = &parsed.value.object;
    const tools_val = root_obj.getPtr("tools") orelse return error.MalformedToolsList;
    if (tools_val.* != .array) return error.MalformedToolsList;
    const tools_arr = &tools_val.array;

    // Locate codedb_bundle items, and collect (name, inputSchema) for every
    // other tool to use as oneOf branches.
    var bundle_items_ptr: ?*std.json.Value = null;
    for (tools_arr.items) |*t| {
        if (t.* != .object) continue;
        const name_v = t.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (!std.mem.eql(u8, name_v.string, "codedb_bundle")) continue;

        const schema = t.object.getPtr("inputSchema") orelse continue;
        if (schema.* != .object) continue;
        const props = schema.object.getPtr("properties") orelse continue;
        if (props.* != .object) continue;
        const ops = props.object.getPtr("ops") orelse continue;
        if (ops.* != .object) continue;
        bundle_items_ptr = ops.object.getPtr("items") orelse continue;
        break;
    }
    if (bundle_items_ptr == null) return error.BundleNotFound;
    const bundle_items = bundle_items_ptr.?;
    if (bundle_items.* != .object) return error.MalformedToolsList;

    var one_of: std.json.Array = .init(a);

    for (tools_arr.items) |t| {
        if (t != .object) continue;
        const sub_name_v = t.object.get("name") orelse continue;
        if (sub_name_v != .string) continue;
        const sub_name = sub_name_v.string;
        if (std.mem.eql(u8, sub_name, "codedb_bundle")) continue;
        if (std.mem.eql(u8, sub_name, "codedb_edit")) continue;
        // issue #441: codedb_projects is dispatcher-rejected in bundle; don't advertise it.
        if (std.mem.eql(u8, sub_name, "codedb_projects")) continue;
        const sub_schema = t.object.get("inputSchema") orelse continue;

        var tool_const: std.json.ObjectMap = .{};
        try tool_const.put(a, "const", .{ .string = sub_name });

        var branch_props: std.json.ObjectMap = .{};
        try branch_props.put(a, "tool", .{ .object = tool_const });
        try branch_props.put(a, "arguments", sub_schema);

        var branch: std.json.ObjectMap = .{};
        try branch.put(a, "properties", .{ .object = branch_props });

        try one_of.append(.{ .object = branch });
    }

    try bundle_items.object.put(a, "oneOf", .{ .array = one_of });
    const augmented_in_arena = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    return try alloc.dupe(u8, augmented_in_arena);
}


// ── MCP Server ──────────────────────────────────────────────────────────────

/// Monotonic timestamp of last MCP request, used for activity accounting.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// How often the watchdog checks whether the MCP client disconnected.
pub const dead_client_poll_ms: u64 = 1000;

// ── Serve-first scan state (issue #207) ─────────────────────────────────────
//
// MCP serves immediately on startup; the file walk + index build runs in a
// background thread. Tools that query the explorer during this window may see
// partial results, so we expose the current scan phase via codedb_status so
// callers can decide whether to retry or proceed with what's available.

pub const ScanState = enum(u8) {
    loading_snapshot = 0,
    walking = 1,
    indexing = 2,
    ready = 3,

    pub fn name(self: ScanState) []const u8 {
        return switch (self) {
            .loading_snapshot => "loading_snapshot",
            .walking => "walking",
            .indexing => "indexing",
            .ready => "ready",
        };
    }
};

var scan_state_atomic: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ScanState.ready));

pub fn setScanState(s: ScanState) void {
    scan_state_atomic.store(@intFromEnum(s), .release);
}

pub fn getScanState() ScanState {
    return @enumFromInt(scan_state_atomic.load(.acquire));
}

pub var scan_wait_timeout_ms: u64 = 2000;

fn waitForScanReady(timeout_ms: u64) void {
    if (getScanState() == .ready) return;
    const deadline = cio.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (getScanState() != .ready) {
        if (cio.milliTimestamp() >= deadline) return;
        cio.sleepMs(25);
    }
}

// ── Session state for MCP protocol ──────────────────────────────────────────

const Session = struct {
    alloc: std.mem.Allocator,
    stdout: cio.File,
    next_id: i64 = 100,
    client_supports_roots: bool = false,
    client_roots_list_changed: bool = false,
    client_name: ?[]const u8 = null,
    pending_roots_id: ?i64 = null,
    roots_requested_at: i64 = 0,
    roots: std.ArrayList(Root) = .empty,
    deferred_scan: ?*DeferredScan = null,

    fn freeRoots(self: *Session) void {
        for (self.roots.items) |r| {
            self.alloc.free(r.uri);
            self.alloc.free(r.name);
        }
        self.roots.clearRetainingCapacity();
    }

    fn deinit(self: *Session) void {
        self.freeRoots();
        self.roots.deinit(self.alloc);
    }
};

pub fn run(
    io: std.Io,
    alloc: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    default_path: []const u8,
    telem: *telemetry_mod.Telemetry,
    deferred_scan: ?*DeferredScan,
) void {
    const stdout = cio.File.stdout();
    const stdin = std.Io.File.stdin();
    last_activity.store(cio.milliTimestamp(), .release);

    var cache = ProjectCache.init(alloc, default_path);
    defer cache.deinit();

    // Build the `tools/list` payload. The discriminated `oneOf` on the
    // codedb_bundle ops items (issue #437) is incompatible with OpenAI's
    // strict-mode tool-schema validator, which rejects `oneOf` outright with
    // "'oneOf' is not permitted" — breaking codex/forgecode and any other
    // OpenAI-Responses-API-backed MCP client. Default to the raw schema (which
    // still has Stage 1's required: ["tool", "arguments"] from #434). Set
    // CODEDB_DISCRIMINATED_SCHEMA=1 to opt back into the augmented oneOf for
    // Anthropic-backed clients that benefit from it.
    //
    // Issue #443: even with all the above, OpenAI clients still emit empty
    // `arguments: {}` for bundle sub-ops because the schema can't bind
    // sub-tool argument shape without `oneOf`. Disable the bundle entirely
    // by default — the dispatcher handler stays so cached-schema clients
    // don't crash, but tools/list no longer advertises it. Set
    // CODEDB_BUNDLE_ENABLED=1 to re-advertise.
    const discriminated_opt_in = blk_opt: {
        const v = cio.posixGetenv("CODEDB_DISCRIMINATED_SCHEMA") orelse break :blk_opt false;
        break :blk_opt std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    };
    const bundle_enabled = blk_be: {
        const v = cio.posixGetenv("CODEDB_BUNDLE_ENABLED") orelse break :blk_be false;
        break :blk_be std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    };
    const tools_list_response: []const u8 = buildToolsListResponse(alloc, .{
        .bundle_enabled = bundle_enabled,
        .discriminated_opt_in = discriminated_opt_in,
    }) catch tools_list;
    defer if (tools_list_response.ptr != tools_list.ptr) alloc.free(tools_list_response);
    var session = Session{
        .alloc = alloc,
        .stdout = stdout,
        .deferred_scan = deferred_scan,
    };
    defer session.deinit();

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &read_buf);

    while (true) {
        const msg = mcpj.readLineBuf(alloc, &stdin_reader.interface) orelse break;
        last_activity.store(cio.milliTimestamp(), .release);
        defer alloc.free(msg);

        const input = std.mem.trim(u8, msg, " \t\r");
        if (input.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch {
            writeError(alloc, stdout, null, -32700, "Parse error");
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            writeError(alloc, stdout, null, -32600, "Invalid Request");
            continue;
        }

        const root = &parsed.value.object;
        const method_opt = mcpj.getStr(root, "method");
        const has_id = root.contains("id");
        const id = root.get("id");
        const is_notification = !has_id;

        if (method_opt == null) {
            if (has_id) {
                handleResponse(&session, root);
            }
            continue;
        }
        const method = method_opt.?;

        if (mcpj.eql(method, "initialize")) {
            handleInitialize(&session, root, id);
        } else if (mcpj.eql(method, "notifications/initialized")) {
            if (session.client_supports_roots) {
                requestRoots(&session);
            } else if (session.deferred_scan) |ds| {
                // Client won't be sending workspace roots — fire the deferred
                // scan now with the cwd fallback so we don't sit in
                // loading_snapshot waiting for a roots/list reply that never
                // comes.
                const empty_roots: []const Root = &.{};
                _ = triggerDeferredScanWithFallback(ds, empty_roots, ds.fallback_cwd);
            }
        } else if (mcpj.eql(method, "notifications/roots/list_changed")) {
            if (session.client_supports_roots) {
                requestRoots(&session);
            }
        } else if (mcpj.eql(method, "tools/list")) {
            if (!is_notification) writeResult(alloc, stdout, id, tools_list_response);
        } else if (mcpj.eql(method, "tools/call")) {
            // If we requested roots but the client never replied, timeout and
            // fire the deferred scan with cwd fallback after 3 seconds.
            if (session.pending_roots_id != null and session.deferred_scan != null) {
                const elapsed = cio.milliTimestamp() - session.roots_requested_at;
                if (elapsed > 3000) {
                    session.pending_roots_id = null;
                    if (session.deferred_scan) |ds| {
                        const empty_roots: []const Root = &.{};
                        _ = triggerDeferredScanWithFallback(ds, empty_roots, ds.fallback_cwd);
                    }
                }
            }
            handleCall(io, alloc, root, stdout, id, store, explorer, agents, &cache, telem, session.deferred_scan);
        } else if (mcpj.eql(method, "ping")) {
            if (!is_notification) writeResult(alloc, stdout, id, "{}");
        } else {
            if (!is_notification) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

fn handleInitialize(s: *Session, root: *const std.json.ObjectMap, id: ?std.json.Value) void {
    caps: {
        const p = root.get("params") orelse break :caps;
        if (p != .object) break :caps;
        const c = p.object.get("capabilities") orelse break :caps;
        if (c != .object) break :caps;
        const r = c.object.get("roots") orelse break :caps;
        if (r != .object) break :caps;
        s.client_supports_roots = true;
        s.client_roots_list_changed = mcpj.getBool(&r.object, "listChanged");
    }
    // Extract client identity for agent registration (#37)
    client_name: {
        const p = root.get("params") orelse break :client_name;
        if (p != .object) break :client_name;
        const ci = p.object.get("clientInfo") orelse break :client_name;
        if (ci != .object) break :client_name;
        if (mcpj.getStr(&ci.object, "name")) |name| {
            s.client_name = name;
        }
    }
    const init_result = std.fmt.allocPrint(s.alloc,
        \\{{"protocolVersion":"2025-06-18","capabilities":{{"tools":{{"listChanged":false}}}},"serverInfo":{{"name":"codedb","version":"{s}"}}}}
    , .{release_info.semver}) catch return;
    defer s.alloc.free(init_result);
    writeResult(s.alloc, s.stdout, id, init_result);
}

fn requestRoots(s: *Session) void {
    const rid = s.next_id;
    s.next_id += 1;
    s.pending_roots_id = rid;
    s.roots_requested_at = cio.milliTimestamp();
    writeRequest(s.alloc, s.stdout, rid, "roots/list", "{}");
}

fn handleResponse(s: *Session, root: *const std.json.ObjectMap) void {
    const resp_id_val = root.get("id") orelse return;
    const resp_id: i64 = switch (resp_id_val) {
        .integer => |n| n,
        else => return,
    };
    if (s.pending_roots_id) |pid| {
        if (resp_id == pid) {
            s.pending_roots_id = null;
            if (root.get("error") != null) return;
            const result_val = root.get("result") orelse return;
            if (result_val != .object) return;
            parseRoots(s, &result_val.object);
        }
    }
}

fn parseRoots(s: *Session, result: *const std.json.ObjectMap) void {
    s.freeRoots();
    const roots_val = result.get("roots") orelse return;
    if (roots_val != .array) return;
    for (roots_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const uri_raw = mcpj.getStr(&obj, "uri") orelse continue;
        const name_raw = mcpj.getStr(&obj, "name") orelse "";
        // Strip file:// prefix for policy check
        const path = if (std.mem.startsWith(u8, uri_raw, "file://")) uri_raw[7..] else uri_raw;
        if (!root_policy.isIndexableRoot(path)) {
            std.log.info("codedb mcp: rejected root \"{s}\" (denied by policy)", .{uri_raw});
            continue;
        }
        const uri = s.alloc.dupe(u8, uri_raw) catch continue;
        const name = s.alloc.dupe(u8, name_raw) catch {
            s.alloc.free(uri);
            continue;
        };
        s.roots.append(s.alloc, .{ .uri = uri, .name = name }) catch {
            s.alloc.free(uri);
            s.alloc.free(name);
            continue;
        };
    }
    if (s.deferred_scan) |ds| {
        _ = triggerDeferredScanWithFallback(ds, s.roots.items, ds.fallback_cwd);
    }
}

fn writeRequest(alloc: std.mem.Allocator, stdout: cio.File, id: i64, method: []const u8, params: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    var tmp: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&tmp, "{d}", .{id}) catch return;
    buf.appendSlice(alloc, id_str) catch return;
    buf.appendSlice(alloc, ",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    buf.appendSlice(alloc, params) catch return;
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch {};
}

fn handleCall(
    io: std.Io,
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: cio.File,
    id: ?std.json.Value,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    telem: *telemetry_mod.Telemetry,
    deferred_scan: ?*DeferredScan,
) void {
    const is_notification = id == null;

    const params_val = root.get("params") orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Missing params");
        return;
    };
    if (params_val != .object) {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "params must be object");
        return;
    }
    const params = &params_val.object;

    const name = getStr(params, "name") orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Missing tool name");
        return;
    };
    var args_value = params.get("arguments") orelse std.json.Value{ .object = .empty };
    if (args_value != .object) {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "arguments must be object");
        return;
    }
    const args = &args_value.object;

    const tool = std.meta.stringToEnum(Tool, name) orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const t0 = cio.nanoTimestamp();
    dispatch(io, alloc, tool, args, &out, store, explorer, agents, cache, deferred_scan);
    const elapsed = cio.nanoTimestamp() - t0;

    const is_error = std.mem.startsWith(u8, out.items, "error:");
    telem.recordToolCall(name, elapsed, is_error, out.items.len);

    // Query + file access tracking WAL
    if (!is_error) {
        if (std.mem.eql(u8, name, "codedb_search") or std.mem.eql(u8, name, "codedb_find") or std.mem.eql(u8, name, "codedb_word")) {
            if (getStr(args, "query") orelse getStr(args, "word")) |q| {
                logQuery(io, name, q, out.items.len, elapsed);
            }
        } else if (std.mem.eql(u8, name, "codedb_read") or std.mem.eql(u8, name, "codedb_outline")) {
            if (getStr(args, "path")) |p| {
                logFileAccess(io, name, p, elapsed);
            }
        }
    }
    if (is_notification) return;

    // Block 1: Human-readable colored summary (ANSI — preview pane always renders it)
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(alloc);
    summary.ensureTotalCapacity(alloc, 256) catch {};
    summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
    summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
    mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
    var dur_buf: [96]u8 = undefined;
    summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

    // Block 3: Guidance hints
    var guidance: std.ArrayList(u8) = .empty;
    defer guidance.deinit(alloc);
    mcpGenerateGuidance(alloc, name, args, out.items, is_error, &guidance);

    // Assemble 3-block MCP content envelope
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.ensureTotalCapacity(alloc, out.items.len + summary.items.len + guidance.items.len + 256) catch {};
    result.appendSlice(alloc, "{\"content\":[") catch return;

    // Block 1 (summary — stripped of ANSI codes for agent consumption)
    if (summary.items.len > 0) {
        const clean_summary = stripAnsiCodes(alloc, summary.items);
        defer alloc.free(clean_summary);
        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, clean_summary);
        result.appendSlice(alloc, "\"},") catch return;
    }

    // Block 2 (raw data — no colors, zero extra tokens to model)
    result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
    mcpj.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}") catch return;

    // Block 3 (guidance — stripped of ANSI codes for agent consumption)
    if (guidance.items.len > 0) {
        const clean_guidance = stripAnsiCodes(alloc, guidance.items);
        defer alloc.free(clean_guidance);
        result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, clean_guidance);
        result.appendSlice(alloc, "\"}") catch return;
    }

    result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return;
    writeResult(alloc, stdout, id, result.items);
}

fn dispatch(
    io: std.Io,
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    default_store: *Store,
    default_explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    deferred_scan: ?*DeferredScan,
) void {
    const project_path = getStr(args, "project");
    const ctx = cache.get(io, project_path, default_explorer, default_store) catch |err| {
        out.appendSlice(alloc, "error: failed to load project: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        return;
    };

    if (toolDependsOnScannedIndex(tool) and project_path == null) {
        waitForScanReady(scan_wait_timeout_ms);
    }

    if (tool == .codedb_word or (tool == .codedb_search and shouldLoadWordIndexForSearch(args))) {
        const effective_project = project_path orelse cache.default_path;
        loadProjectWordIndexFromDiskIfPresent(io, ctx.explorer, effective_project, alloc);
    }

    switch (tool) {
        .codedb_tree => handleTree(alloc, out, ctx.explorer),
        .codedb_outline => handleOutline(alloc, args, out, ctx.explorer),
        .codedb_symbol => handleSymbol(alloc, args, out, ctx.explorer),
        .codedb_hierarchy => handleHierarchy(alloc, args, out, ctx.explorer),
        .codedb_routes => handleRoutes(alloc, args, out, ctx.explorer),
        .codedb_config_xref => handleConfigXref(alloc, args, out, ctx.explorer),
        .codedb_search => handleSearch(alloc, args, out, ctx.explorer),
        .codedb_word => handleWord(alloc, args, out, ctx.explorer),
        .codedb_callers => handleCallers(alloc, args, out, ctx.explorer),
        .codedb_hot => handleHot(alloc, args, out, ctx.store, ctx.explorer),
        .codedb_deps => handleDeps(alloc, args, out, ctx.explorer),
        .codedb_read => handleRead(io, alloc, args, out, ctx.explorer),
        .codedb_edit => handleEdit(io, alloc, args, out, default_store, default_explorer, agents),
        .codedb_changes => handleChanges(alloc, args, out, default_store),
        .codedb_status => handleStatus(alloc, out, ctx.store, ctx.explorer),
        .codedb_snapshot => handleSnapshot(alloc, out, ctx.explorer, ctx.store, ctx.snapshot_cache),
        .codedb_types => handleTypes(alloc, args, out, ctx.explorer),
        .codedb_bundle => handleBundle(io, alloc, args, out, ctx.store, ctx.explorer, agents, cache, deferred_scan),
        .codedb_remote => handleRemote(alloc, args, out),
        .codedb_projects => handleProjects(io, alloc, out),
        .codedb_index => handleIndex(io, alloc, args, out, cache, default_store, default_explorer, deferred_scan),
        .codedb_find => handleFind(io, alloc, args, out, ctx.explorer),
        .codedb_query => handleQuery(alloc, args, out, ctx.explorer, ctx.store),
        .codedb_glob => handleGlob(alloc, args, out, ctx.explorer),
        .codedb_ls => handleLs(alloc, args, out, ctx.explorer),
    }
    appendScanProgressHint(alloc, out, tool);
}

/// Bug 2: when the initial scan is still running, search/outline/word
/// responses come back as "0 results" or "file not indexed" — agents read
/// these as authoritative. Append a one-line note so the caller knows the
/// result might be incomplete and that retrying is reasonable.
fn appendScanProgressHint(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tool: Tool) void {
    const state = getScanState();
    if (state == .ready) return;
    if (!toolDependsOnScannedIndex(tool)) return;
    const looks_empty =
        std.mem.indexOf(u8, out.items, "0 results for ") != null or
        std.mem.indexOf(u8, out.items, "0 hits for ") != null or
        std.mem.indexOf(u8, out.items, "no results for: ") != null;
    const looks_unindexed = std.mem.indexOf(u8, out.items, "file not indexed") != null;
    if (!(looks_empty or looks_unindexed)) return;
    out.appendSlice(alloc, "\nnote: scan still in progress (state=") catch return;
    out.appendSlice(alloc, state.name()) catch return;
    out.appendSlice(alloc, "); results may be incomplete — retry shortly") catch return;
}

fn toolDependsOnScannedIndex(tool: Tool) bool {
    return switch (tool) {
        .codedb_search, .codedb_word, .codedb_callers, .codedb_outline, .codedb_symbol, .codedb_hierarchy, .codedb_routes, .codedb_config_xref, .codedb_find, .codedb_glob, .codedb_tree, .codedb_ls, .codedb_deps, .codedb_types => true,
        else => false,
    };
}

// ── Tool handlers ───────────────────────────────────────────────────────────

fn handleTree(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const tree = explorer.getTree(alloc, false) catch {
        out.appendSlice(alloc, "error: failed to get tree") catch {};
        return;
    };
    defer alloc.free(tree);
    out.appendSlice(alloc, tree) catch {};
}

fn handleOutline(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const compact = getBool(args, "compact");
    const grouped = getBool(args, "grouped");
    var outline = explorer.getOutline(path, alloc) catch {
        out.appendSlice(alloc, "error: outline retrieval failed") catch {};
        return;
    } orelse {
        out.appendSlice(alloc, "error: file not indexed: ") catch {};
        out.appendSlice(alloc, path) catch {};
        // Issue #356-2: fuzzy path fallback — surface top matches so the
        // caller can self-correct without a separate codedb_find round-trip.
        appendFuzzyPathSuggestions(alloc, out, explorer, path);
        // Issue #356-p3: stale-index recovery hint. The most common cause of
        // 'not indexed' once you've ruled out a typo is a freshly-added file
        // the watcher hasn't seen yet — pointing at codedb_index makes the
        // recovery action explicit.
        out.appendSlice(alloc, "\nhint: try codedb_index if the file was added recently\n") catch {};
        return;
    };
    defer outline.deinit();
    const w = cio.listWriter(out, alloc);
    w.print("{s} ({s}, {d} lines, {d} bytes)", .{
        outline.path, @tagName(outline.language), outline.line_count, outline.byte_size,
    }) catch {};
    if (explore_mod.Explorer.isStubLikeOutline(&outline)) w.writeAll(" [stub]") catch {};
    const descriptor = explore_mod.Explorer.buildOutlineDescriptor(alloc, &outline) catch null;
    defer if (descriptor) |d| alloc.free(d);
    if (descriptor) |d| w.print(" — {s}", .{d}) catch {};
    w.writeAll("\n") catch {};
    if (grouped) {
        writeGroupedOutline(alloc, out, &outline, compact);
        return;
    }
    for (outline.symbols.items) |sym| {
        if (compact) {
            w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
        } else {
            w.print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
            if (sym.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
            if (sym.param_types.len > 0) {
                w.writeAll(" (") catch {};
                for (sym.param_types, 0..) |pt, i| {
                    if (i > 0) w.writeAll(", ") catch {};
                    w.print("{s}", .{pt}) catch {};
                }
                w.writeAll(")") catch {};
            }
            if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
            writeDecoratorsInline(w, sym.decorators);
            w.writeAll("\n") catch {};
        }
    }
}

fn writeGroupedOutline(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outline: *const explore_mod.FileOutline, compact: bool) void {
    const kinds = [_]explore_mod.SymbolKind{
        .class_def,
        .interface_def,
        .trait_def,
        .struct_def,
        .enum_def,
        .union_def,
        .impl_block,
        .method,
        .function,
        .test_decl,
        .constant,
        .variable,
        .type_alias,
        .macro_def,
        .import,
        .comment_block,
    };
    const w = cio.listWriter(out, alloc);
    var emitted_any = false;
    for (kinds) |kind| {
        var count_for_kind: usize = 0;
        var line_start: u32 = std.math.maxInt(u32);
        var line_end: u32 = 0;
        for (outline.symbols.items) |sym| {
            if (sym.kind != kind) continue;
            count_for_kind += 1;
            line_start = @min(line_start, sym.line_start);
            line_end = @max(line_end, sym.line_end);
        }
        if (count_for_kind == 0) continue;
        emitted_any = true;
        w.print("  [{s}] L{d}-L{d} ({d} symbols)\n", .{ @tagName(kind), line_start, line_end, count_for_kind }) catch {};
        for (outline.symbols.items) |sym| {
            if (sym.kind != kind) continue;
            if (compact) {
                w.print("    L{d}: {s}\n", .{ sym.line_start, sym.name }) catch {};
            } else {
                w.print("    L{d}: {s}", .{ sym.line_start, sym.name }) catch {};
                if (sym.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
                if (sym.param_types.len > 0) {
                    w.writeAll(" (") catch {};
                    for (sym.param_types, 0..) |pt, i| {
                        if (i > 0) w.writeAll(", ") catch {};
                        w.print("{s}", .{pt}) catch {};
                    }
                    w.writeAll(")") catch {};
                }
                if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
                writeDecoratorsInline(w, sym.decorators);
                w.writeAll("\n") catch {};
            }
        }
    }
    if (!emitted_any) {
        w.writeAll("  (no symbols)\n") catch {};
    }
}

fn handleSymbol(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const include_body = getBool(args, "body");
    const decorator_filter = getStr(args, "decorator_filter");
    const results = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
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

    var visible_count: usize = 0;
    for (results) |r| {
        if (decorator_filter) |filter| {
            if (!decoratorsContain(r.symbol.decorators, filter)) continue;
        }
        visible_count += 1;
    }

    if (visible_count == 0) {
        out.appendSlice(alloc, "no results for: ") catch {};
        out.appendSlice(alloc, name) catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} results for '{s}':\n", .{ visible_count, name }) catch {};
    for (results) |r| {
        if (decorator_filter) |filter| {
            if (!decoratorsContain(r.symbol.decorators, filter)) continue;
        }
        w.print("  {s}:{d} ({s})", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
        if (r.symbol.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
        if (r.symbol.param_types.len > 0) {
            w.writeAll(" (") catch {};
            for (r.symbol.param_types, 0..) |pt, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.print("{s}", .{pt}) catch {};
            }
            w.writeAll(")") catch {};
        }
        if (r.symbol.detail) |d| w.print("  // {s}", .{d}) catch {};
        writeDecoratorsInline(w, r.symbol.decorators);
        w.writeAll("\n") catch {};
        if (include_body) {
            const body = explorer.getSymbolBody(r.path, r.symbol.line_start, r.symbol.line_end, alloc) catch null;
            if (body) |b| {
                defer alloc.free(b);
                out.appendSlice(alloc, b) catch {};
            }
        }
    }
}

fn writeDecoratorsInline(w: anytype, decorators: []const []const u8) void {
    if (decorators.len == 0) return;
    w.writeAll("  decorators:") catch {};
    for (decorators) |decorator| {
        w.print(" {s}", .{decorator}) catch {};
    }
}

// ── ASP.NET tools (extracted to mcp/aspnet.zig) ──
const aspnet = @import("mcp/aspnet.zig");
const handleRoutes = aspnet.handleRoutes;
const handleConfigXref = aspnet.handleConfigXref;
const decoratorsContain = aspnet.decoratorsContain;

fn handleHierarchy(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (name.len == 0) {
        out.appendSlice(alloc, "error: empty name — pass a non-empty 'name' string") catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var found = false;
    var derived_count: usize = 0;

    w.print("hierarchy for '{s}':\n", .{name}) catch {};
    w.writeAll("  definitions:\n") catch {};
    var iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (!isHierarchySymbolKind(sym.kind)) continue;
            found = true;
            w.print("    {s}:{d} ({s})", .{ entry.key_ptr.*, sym.line_start, @tagName(sym.kind) }) catch {};
            if (sym.detail) |detail| w.print("  // {s}", .{detail}) catch {};
            w.writeAll("\n") catch {};
            if (sym.detail) |detail| {
                w.writeAll("      bases:\n") catch {};
                const before = out.items.len;
                writeHierarchyBaseNames(w, detail, sym.name, "        ");
                if (out.items.len == before) w.writeAll("        (none)\n") catch {};
            }
        }
    }

    if (!found) {
        w.writeAll("    (none)\n") catch {};
    }

    w.writeAll("  direct_derived:\n") catch {};
    iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.symbols.items) |sym| {
            if (!isHierarchySymbolKind(sym.kind)) continue;
            if (std.mem.eql(u8, sym.name, name)) continue;
            const detail = sym.detail orelse continue;
            if (!hierarchyDetailMentionsBase(detail, sym.name, name)) continue;
            derived_count += 1;
            w.print("    {s}:{d} {s} ({s})", .{ entry.key_ptr.*, sym.line_start, sym.name, @tagName(sym.kind) }) catch {};
            w.print("  // {s}\n", .{detail}) catch {};
        }
    }
    if (derived_count == 0) {
        w.writeAll("    (none)\n") catch {};
    }
}

fn isHierarchySymbolKind(kind: explore_mod.SymbolKind) bool {
    return switch (kind) {
        .class_def, .interface_def, .trait_def, .struct_def => true,
        else => false,
    };
}

fn writeHierarchyBaseNames(w: anytype, detail: []const u8, self_name: []const u8, indent: []const u8) void {
    var bases = hierarchyBasePortion(detail, self_name) orelse return;
    bases = trimHierarchyBasePortion(bases);
    var token_start: ?usize = null;
    for (bases, 0..) |c, i| {
        if (isHierarchyTokenChar(c)) {
            if (token_start == null) token_start = i;
        } else if (token_start) |start| {
            writeHierarchyBaseToken(w, bases[start..i], self_name, indent);
            token_start = null;
        }
    }
    if (token_start) |start| {
        writeHierarchyBaseToken(w, bases[start..], self_name, indent);
    }
}

fn writeHierarchyBaseToken(w: anytype, raw_token: []const u8, self_name: []const u8, indent: []const u8) void {
    const token = std.mem.trim(u8, raw_token, " \t\r\n");
    if (token.len == 0) return;
    if (isHierarchyKeyword(token)) return;
    if (std.mem.eql(u8, token, self_name)) return;
    w.print("{s}{s}\n", .{ indent, token }) catch {};
}

fn hierarchyDetailMentionsBase(detail: []const u8, self_name: []const u8, base_name: []const u8) bool {
    var bases = hierarchyBasePortion(detail, self_name) orelse return false;
    bases = trimHierarchyBasePortion(bases);
    var token_start: ?usize = null;
    for (bases, 0..) |c, i| {
        if (isHierarchyTokenChar(c)) {
            if (token_start == null) token_start = i;
        } else if (token_start) |start| {
            if (hierarchyTokenMatches(bases[start..i], base_name)) return true;
            token_start = null;
        }
    }
    if (token_start) |start| {
        if (hierarchyTokenMatches(bases[start..], base_name)) return true;
    }
    return false;
}

fn hierarchyBasePortion(detail: []const u8, self_name: []const u8) ?[]const u8 {
    _ = self_name;
    if (std.mem.indexOf(u8, detail, " extends ")) |pos| return detail[pos + " extends ".len ..];
    if (std.mem.indexOf(u8, detail, " implements ")) |pos| return detail[pos + " implements ".len ..];
    if (std.mem.indexOfScalar(u8, detail, '(')) |open| {
        if (std.mem.indexOfScalarPos(u8, detail, open + 1, ')')) |close| {
            return detail[open + 1 .. close];
        }
    }
    if (std.mem.indexOfScalar(u8, detail, ':')) |colon| {
        return detail[colon + 1 ..];
    }
    return null;
}

fn trimHierarchyBasePortion(bases: []const u8) []const u8 {
    var end = bases.len;
    for (bases, 0..) |c, i| {
        if (c == '{' or c == ';') {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, bases[0..end], " \t\r\n");
}

fn hierarchyTokenMatches(raw_token: []const u8, target: []const u8) bool {
    const token = std.mem.trim(u8, raw_token, " \t\r\n");
    if (token.len == 0 or isHierarchyKeyword(token)) return false;
    if (std.mem.eql(u8, token, target)) return true;
    if (std.mem.endsWith(u8, token, target) and token.len > target.len) {
        const sep = token[token.len - target.len - 1];
        return sep == '.';
    }
    return false;
}

fn isHierarchyTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn isHierarchyKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{ "public", "private", "protected", "internal", "abstract", "sealed", "partial", "class", "interface", "struct", "extends", "implements", "where", "new", "record", "readonly", "static", "final", "open", "data" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, token, kw)) return true;
    }
    return false;
}

/// Append post-search hints: code syntax warnings and cross-pollution detection.
fn appendSearchHints(alloc: std.mem.Allocator, out: *std.ArrayList(u8), query: []const u8, visible_count: usize, dir_count: usize) void {
    const w = cio.listWriter(out, alloc);

    // Hint 1: code syntax characters that break substring search
    if (visible_count == 0) {
        var has_brackets = false;
        var has_slash = false;
        var has_dot_suffix = false;
        for (query) |c| {
            if (c == '[' or c == ']' or c == '(' or c == ')' or c == '{' or c == '}') has_brackets = true;
            if (c == '/') has_slash = true;
        }
        if (query.len > 1 and query[query.len - 1] == '.') has_dot_suffix = true;

        if (has_brackets) {
            w.print("\n  hint: query has brackets [](){{}} which are not indexed \u{2014} try stripping them and searching for the identifier inside, e.g. 'Route' instead of '[Route(\"/mqtt\")'\n", .{}) catch {};
        } else if (has_slash and query.len <= 10) {
            w.print("\n  hint: query contains '/' which is not indexed as part of identifiers \u{2014} try the path segment without slashes\n", .{}) catch {};
        } else if (has_dot_suffix) {
            w.print("\n  hint: trailing '.' is not indexed \u{2014} try without the dot\n", .{}) catch {};
        }
    }

    // Hint 2: cross-pollution warning when results span many directories
    if (visible_count >= 5 and dir_count >= 5) {
        w.print("\n  warning: results span {d} different directories \u{2014} consider using path_glob to scope to a specific feature, e.g. path_glob=\"**/Portfolio*\"\n", .{dir_count}) catch {};
    }
}

fn handleSearch(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const query = getStr(args, "query") orelse {
        out.appendSlice(alloc, "error: missing 'query' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    // Bug 7: validate args explicitly. Pre-fix: empty query / non-positive
    // max_results all returned "0 results" and the agent thought the search
    // ran with nothing matching, when really the call was malformed.
    if (query.len == 0) {
        out.appendSlice(alloc, "error: empty query — pass a non-empty 'query' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 50;
    const scope = getBool(args, "scope");
    const compact = getBool(args, "compact");
    const is_regex = getBool(args, "regex");
    const path_glob_raw = getStr(args, "path_glob");
    // Auto-promote basename-only patterns ('*.zig') to '**/*.zig' so they match
    // nested files. Without this the matcher rejects 'src/main.zig' because
    // '*' doesn't cross '/' (see explore.zig:matchGlob). Issue surfaced by the
    // recall eval — agents reach for '*.zig' first.
    var pg_buf: [256]u8 = undefined;
    const path_glob: ?[]const u8 = if (path_glob_raw) |g| blk: {
        if (std.mem.indexOfScalar(u8, g, '/') == null and g.len + 3 < pg_buf.len) {
            const promoted = std.fmt.bufPrint(&pg_buf, "**/{s}", .{g}) catch break :blk g;
            break :blk promoted;
        }
        break :blk g;
    } else null;

    if (scope and is_regex) {
        const results = explorer.searchContentRegexWithScope(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: scoped regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, not the pre-filter explorer count.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else if (scope) {
        const results = explorer.searchContentWithScope(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, and so the "truncated" footer only fires
        // for per-file-cap truncation — not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            // Track unique parent directories for cross-pollution detection
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s} ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else if (is_regex) {
        const results = explorer.searchContentRegex(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    } else {
        const results = explorer.searchContent(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        var dir_set = std.StringHashMap(void).init(alloc);
        defer dir_set.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            // Track unique parent directories for cross-pollution detection
            var dir_end: usize = r.path.len;
            var di: usize = r.path.len;
            while (di > 0) {
                di -= 1;
                if (r.path[di] == '/') { dir_end = di; break; }
            }
            dir_set.put(r.path[0..dir_end], {}) catch {};
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
        appendSearchHints(alloc, out, query, visible_total, dir_set.count());
    }
}

fn handleWord(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const word = getStr(args, "word") orelse {
        out.appendSlice(alloc, "error: missing 'word' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const hits = explorer.searchWord(word, alloc) catch {
        out.appendSlice(alloc, "error: word search failed") catch {};
        return;
    };
    defer alloc.free(hits);

    // Path glob filtering — scope results to matching files
    const path_glob_raw = getStr(args, "path_glob");
    var pg_buf: [256]u8 = undefined;
    const path_glob: ?[]const u8 = if (path_glob_raw) |g| blk: {
        if (std.mem.indexOfScalar(u8, g, '/') == null and g.len + 3 < pg_buf.len) {
            const promoted = std.fmt.bufPrint(&pg_buf, "**/{s}", .{g}) catch break :blk g;
            break :blk promoted;
        }
        break :blk g;
    } else null;

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    // Count visible hits after glob filter
    var visible_total: usize = 0;
    for (hits) |h| {
        const p = explorer.word_index.hitPath(h);
        if (path_glob) |g| if (!globMatch(g, p)) continue;
        visible_total += 1;
    }

    const w = cio.listWriter(out, alloc);
    const WORD_CAP: usize = 50;
    if (visible_total > WORD_CAP) {
        w.print("{d} hits for '{s}' (showing first {d}):\n", .{ visible_total, word, WORD_CAP }) catch {};
    } else {
        w.print("{d} hits for '{s}':\n", .{ visible_total, word }) catch {};
    }
    var shown: usize = 0;
    for (hits) |h| {
        const p = explorer.word_index.hitPath(h);
        if (path_glob) |g| if (!globMatch(g, p)) continue;
        if (shown >= WORD_CAP) break;
        w.print("  {s}:{d}\n", .{ p, h.line_num }) catch {};
        shown += 1;
    }
    if (visible_total > WORD_CAP) {
        w.print("... ({d} more — use path_glob to scope results)\n", .{visible_total - WORD_CAP}) catch {};
    }
}

fn handleCallers(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (name.len == 0) {
        out.appendSlice(alloc, "error: empty name — pass a non-empty 'name' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 50;

    const defs = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: symbol lookup failed") catch {};
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

    const results = explorer.searchContentWithScope(name, alloc, max_results) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer {
        for (results) |r| {
            alloc.free(r.line_text);
            alloc.free(r.path);
            if (r.scope_name) |n2| alloc.free(n2);
        }
        alloc.free(results);
    }

    var shown: usize = 0;
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        shown += 1;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} call sites for '{s}':\n", .{ shown, name }) catch {};
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        if (r.scope_name) |sn| {
            w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
            }) catch {};
        } else {
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
        }
    }
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Returns true iff `needle` appears in `haystack` with non-identifier
/// characters (or string boundary) on both sides — i.e. as a whole-word
/// identifier match, not as a substring inside a longer identifier.
pub fn hasWholeWordMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search_from, needle)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(haystack[pos - 1]);
        const after_idx = pos + needle.len;
        const after_ok = after_idx >= haystack.len or !isIdentChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        search_from = pos + 1;
    }
    return false;
}

/// Languages where the concept of a "call site" is meaningful. Excludes
/// data formats (json, yaml), markup/styling (markdown, css, scss),
/// declarative schemas (protobuf), and unknown files — callers found
/// inside these are mentions in prose or config, not real invocations.
pub fn langHasCallSites(lang: explore_mod.Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
        else => true,
    };
}

fn handleHot(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    const limit: usize = if (getInt(args, "limit")) |n| @intCast(@min(@max(1, n), 1000)) else 10;
    const hot = explorer.getHotFiles(store, alloc, limit) catch {
        out.appendSlice(alloc, "error: hot files failed") catch {};
        return;
    };
    defer {
        for (hot) |path| alloc.free(path);
        alloc.free(hot);
    }

    const w = cio.listWriter(out, alloc);
    for (hot, 0..) |path, i| {
        w.print("{d}. {s}\n", .{ i + 1, path }) catch {};
    }
}

fn handleDeps(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const direction = getStr(args, "direction") orelse "imported_by";
    const transitive = getBool(args, "transitive");
    const max_depth: ?u32 = if (getInt(args, "max_depth")) |n| @intCast(@max(1, n)) else null;

    const is_forward = std.mem.eql(u8, direction, "depends_on");

    var results: []const []const u8 = &.{};
    if (is_forward) {
        if (transitive) {
            results = explorer.getTransitiveDependencies(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            explorer.mu.lockShared();
            const fwd = explorer.dep_graph.getForwardDeps(path);
            explorer.mu.unlockShared();
            if (fwd) |deps| {
                var result_list: std.ArrayList([]const u8) = .empty;
                for (deps) |dep| {
                    const d = alloc.dupe(u8, dep) catch continue;
                    result_list.append(alloc, d) catch {
                        alloc.free(d);
                        continue;
                    };
                }
                results = result_list.toOwnedSlice(alloc) catch &.{};
            }
        }
    } else {
        if (transitive) {
            results = explorer.getTransitiveDependents(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            results = explorer.getImportedBy(path, alloc) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        }
    }
    defer {
        for (results) |dep| alloc.free(dep);
        alloc.free(results);
    }

    const w = cio.listWriter(out, alloc);
    if (is_forward) {
        if (transitive) {
            w.print("{s} transitively depends on:\n", .{path}) catch {};
        } else {
            w.print("{s} depends on:\n", .{path}) catch {};
        }
    } else {
        if (transitive) {
            w.print("{s} is transitively imported by:\n", .{path}) catch {};
        } else {
            w.print("{s} is imported by:\n", .{path}) catch {};
        }
    }
    if (results.len == 0) {
        w.writeAll("  (none)\n") catch {};
        // Bug 4: if the path isn't indexed at all, agents read "(none)" as
        // "file exists but no callers" — which is wrong. Append fuzzy
        // suggestions so a typo is recoverable in one shot.
        explorer.mu.lockShared();
        const known = explorer.outlines.contains(path);
        explorer.mu.unlockShared();
        if (!known) appendFuzzyPathSuggestions(alloc, out, explorer, path);
    } else {
        for (results) |dep| {
            w.print("  {s}\n", .{dep}) catch {};
        }
        w.print("({d} files)\n", .{results.len}) catch {};
    }
}

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

fn handleEdit(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer, agents: *AgentRegistry) void {
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
    const op: @import("version.zig").Op = if (eql(op_str, "insert"))
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

fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
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

fn handleStatus(alloc: std.mem.Allocator, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
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
}

fn handleSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store, cache: *SnapshotCache) void {
    const seq = store.currentSeq();
    if (cache.appendIfFresh(alloc, out, seq)) return;

    const snap = snapshot_json.buildSnapshot(explorer, store, alloc) catch {
        out.appendSlice(alloc, "error: snapshot build failed") catch {};
        return;
    };
    cache.putAndAppend(alloc, out, seq, snap);
}


/// When a bundled op produces a missing-arg error, append a `received keys`
/// line listing the keys actually present in the op's args. Helps callers
/// Strip ANSI escape sequences (\x1b[...m) from a string, returning a
/// plain-text version. Used to clean MCP response blocks so AI agents
/// don't see raw escape codes.
fn stripAnsiCodes(alloc: std.mem.Allocator, input: []const u8) []const u8 {
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
fn appendFuzzyPathSuggestions(
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

fn handleTypes(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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

fn handleBundle(
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
    last_activity.store(cio.milliTimestamp(), .release);
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
        last_activity.store(cio.milliTimestamp(), .release);
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

const remote = @import("mcp/remote.zig");
const handleRemote = remote.handleRemote;

fn handleProjects(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
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

fn handleIndex(
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

fn handleFind(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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

fn handleGlob(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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

fn handleLs(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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

const query_mod = @import("mcp/query.zig");
const handleQuery = query_mod.handleQuery;
const applyComboBoosts = query_mod.applyComboBoosts;

// ── Split-out helper modules (see src/mcp/) ──
const wal = @import("mcp/wal.zig");
const pathglob = @import("mcp/pathglob.zig");
const jsonio = @import("mcp/jsonio.zig");
const format = @import("mcp/format.zig");

pub const setQueryLogPath = wal.setQueryLogPath;
const escapeJsonStr = wal.escapeJsonStr;
const appendToWal = wal.appendToWal;
const logQuery = wal.logQuery;
const logFileAccess = wal.logFileAccess;
pub const globMatch = pathglob.globMatch;
pub const isPathSafe = pathglob.isPathSafe;
const writeResult = jsonio.writeResult;
const writeError = jsonio.writeError;
const writeEscaped = jsonio.writeEscaped;
pub const appendId = jsonio.appendId;
const MCP_RESET = format.MCP_RESET;
const MCP_BOLD = format.MCP_BOLD;
const MCP_DIM = format.MCP_DIM;
const MCP_GREEN = format.MCP_GREEN;
const MCP_RED = format.MCP_RED;
const MCP_CYAN = format.MCP_CYAN;
const MCP_YELLOW = format.MCP_YELLOW;
const MCP_MAGENTA = format.MCP_MAGENTA;
const MCP_BLUE = format.MCP_BLUE;
const MCP_BRIGHT_GREEN = format.MCP_BRIGHT_GREEN;
const MCP_CHECK = format.MCP_CHECK;
const MCP_CROSS = format.MCP_CROSS;
const MCP_DASH = format.MCP_DASH;
const MCP_ARROW = format.MCP_ARROW;
const MCP_DOT = format.MCP_DOT;
const MCP_ZAP = format.MCP_ZAP;
const mcpFormatDuration = format.mcpFormatDuration;
const mcpToolIcon = format.mcpToolIcon;
const mcpPathBasename = format.mcpPathBasename;
const mcpPathParent = format.mcpPathParent;
const mcpAppendPath = format.mcpAppendPath;
pub const mcpGenerateSummary = format.mcpGenerateSummary;
pub const mcpGenerateGuidance = format.mcpGenerateGuidance;

const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
pub const getBool = mcpj.getBool;
const eql = mcpj.eql;
