// codedb MCP server — JSON-RPC 2.0 over stdio
const cio = @import("../cio.zig");
//
// Exposes codedb's exploration + edit engine as MCP tools.
// Uses mcp-zig for protocol utilities; adds roots support for workspace awareness.

const std = @import("std");
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
pub const Root = mcp_lib.mcp.Root;
const Store = @import("../store.zig").Store;
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const snapshot_json = @import("../snapshot_json.zig");
const watcher = @import("../watcher.zig");
const idx = @import("../index.zig");
const snapshot_mod = @import("../snapshot.zig");
const telemetry_mod = @import("../telemetry.zig");
const git_mod = @import("../git.zig");
const root_policy = @import("../root_policy.zig");
const release_info = @import("../release_info.zig");

const mcp = @import("../mcp.zig");

const wal = @import("wal.zig");
const logQuery = wal.logQuery;
const logFileAccess = wal.logFileAccess;

const jsonio = @import("jsonio.zig");
const writeResult = jsonio.writeResult;
const writeError = jsonio.writeError;
const writeEscaped = jsonio.writeEscaped;

const format = @import("format.zig");
const MCP_RESET = format.MCP_RESET;
const MCP_GREEN = format.MCP_GREEN;
const MCP_RED = format.MCP_RED;
const MCP_CHECK = format.MCP_CHECK;
const MCP_CROSS = format.MCP_CROSS;
const mcpToolIcon = format.mcpToolIcon;
const mcpFormatDuration = format.mcpFormatDuration;
const mcpGenerateSummary = format.mcpGenerateSummary;
const mcpGenerateGuidance = format.mcpGenerateGuidance;

const getStr = mcpj.getStr;
const getBool = mcpj.getBool;
const eql = mcpj.eql;

// ── ASP.NET tools (mcp/aspnet.zig) ──
const aspnet = @import("aspnet.zig");
const handleRoutes = aspnet.handleRoutes;
const handleConfigXref = aspnet.handleConfigXref;

// ── explore tool handlers (mcp/explore_tools.zig) ──
const explore_tools = @import("explore_tools.zig");
const handleTree = explore_tools.handleTree;
const handleOutline = explore_tools.handleOutline;
const handleSymbol = explore_tools.handleSymbol;
const handleHierarchy = explore_tools.handleHierarchy;
const handleSearch = explore_tools.handleSearch;
const handleWord = explore_tools.handleWord;
const handleCallers = explore_tools.handleCallers;
const handleRelations = explore_tools.handleRelations;
const handleHot = explore_tools.handleHot;
const handleDeps = explore_tools.handleDeps;

// ── mutation tool handlers (mcp/mutation_tools.zig) ──
const mutation_tools = @import("mutation_tools.zig");
const handleRead = mutation_tools.handleRead;
const handleEdit = mutation_tools.handleEdit;
const handleChanges = mutation_tools.handleChanges;
const handleStatus = mutation_tools.handleStatus;
const handleSnapshot = mutation_tools.handleSnapshot;

// ── composite + filesystem tools (mcp/composite_tools.zig) ──
const composite_tools = @import("composite_tools.zig");
const stripAnsiCodes = composite_tools.stripAnsiCodes;
const handleTypes = composite_tools.handleTypes;
const handleBundle = composite_tools.handleBundle;
const handleRemote = composite_tools.handleRemote;
const handleProjects = composite_tools.handleProjects;
const handleIndex = composite_tools.handleIndex;
const handleFind = composite_tools.handleFind;
const handleGlob = composite_tools.handleGlob;
const handleLs = composite_tools.handleLs;

const query_mod = @import("query.zig");
const handleQuery = query_mod.handleQuery;

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

pub const SnapshotCache = struct {
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

    pub fn appendIfFresh(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const bytes = self.bytes orelse return false;
        if (self.seq != seq) return false;
        out.appendSlice(alloc, bytes) catch return false;
        return true;
    }

    /// Takes ownership of `fresh` if it becomes the cache entry. If another
    /// caller filled the same seq first, frees `fresh` and appends the winner.
    pub fn putAndAppend(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64, fresh: []u8) void {
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

pub fn loadProjectTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
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
    codedb_relations,
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
    \\{"name":"codedb_outline","description":"Symbol outline of one file: functions, structs, enums, imports, consts with line numbers. Set grouped=true for sectioned output by symbol kind. Run before codedb_read to find the lines you actually need.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"},"grouped":{"type":"boolean","description":"Group symbols into sections with line ranges and counts (default: false)."},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find where a named symbol is defined across the index. Returns file, line, kind, detail, and decorators when captured. Pass body=true for source. Pick this over codedb_search when you have an exact identifier.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name to search for (exact match)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"},"decorator_filter":{"type":"string","description":"Only return symbols whose captured decorator/attribute contains this text, e.g. HttpPost or [Authorize]."},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_hierarchy","description":"Class/interface hierarchy lookup. For a class-like symbol, reports direct bases and indexed direct derived/implementing types inferred from declaration detail.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Class, interface, trait, or type symbol name"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_routes","description":"Framework route map. v1 extracts ASP.NET Core MVC routes from C# controller/action attributes captured in the index.","inputSchema":{"type":"object","properties":{"framework":{"type":"string","enum":["aspnet"],"description":"Route extractor to use. Currently only aspnet is supported."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_config_xref","description":"Framework config key cross-reference. v1 compares ASP.NET appsettings*.json keys against IConfiguration reads in C# files.","inputSchema":{"type":"object","properties":{"framework":{"type":"string","enum":["aspnet"],"description":"Config extractor to use. Currently only aspnet is supported."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_search","description":"Substring full-text search across the index (regex if regex=true). For one identifier prefer codedb_word; for a definition prefer codedb_symbol. Scope with path_glob to filter by language.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Maximum results to return (default: 50, start with 10 for broad queries)"},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"},"path_glob":{"type":"string","description":"Filter results to paths matching this glob, e.g. '*.zig' or 'src/**/*.zig'. Bare patterns like '*.zig' are auto-promoted to '**/*.zig' to match nested files."},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"Exact-identifier lookup via inverted index — every occurrence of one word, O(1). Use for single identifiers; use codedb_search for substrings or phrases. For common identifiers (50+ hits), pass path_glob to scope results. Results are capped at 50 \\u2014 use path_glob to narrow.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"},"path_glob":{"type":"string","description":"Filter results to paths matching this glob, e.g. **/*.cs or src/Controllers/*.cs. Auto-promotes bare patterns."},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["word"]}},
    \\{"name":"codedb_callers","description":"Find call sites of a named symbol. Defaults to heuristic semantic invocation matching; use match_mode=text for broad whole-word mentions.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (exact identifier match)"},"max_results":{"type":"integer","description":"Maximum call sites to return (default: 50)"},"match_mode":{"type":"string","enum":["semantic","text","both"],"description":"semantic (default) keeps invocation-looking sites; text is whole-word mentions; both maximizes recall."},"include_generated":{"type":"boolean","description":"Include generated-file matches (default: false)"},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_relations","description":"First-class relation query for a symbol: definitions, inheritance, type/dependency users, and heuristic callers. Pass output_format=json for machine-friendly grouped JSON with confidence/why_matched metadata.","inputSchema":{"type":"object","properties":{"symbol":{"type":"string","description":"Symbol/type name to inspect"},"name":{"type":"string","description":"Alias for symbol"},"max_results":{"type":"integer","description":"Maximum caller search results to inspect (default: 50)"},"match_mode":{"type":"string","enum":["semantic","text","both"],"description":"Caller matching mode. semantic (default) keeps invocation-looking sites; text is broad whole-word; both maximizes recall."},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_hot","description":"Most recently modified files in the project, newest first.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Dependency graph: who imports a file (default) or what a file imports (direction=depends_on). Includes import edges and supported type-usage edges. Set transitive=true for BFS blast radius.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"},"direction":{"type":"string","enum":["imported_by","depends_on"],"description":"imported_by (default): who imports/uses this file. depends_on: what this file imports/uses."},"transitive":{"type":"boolean","description":"Follow dependency chain transitively (default: false)"},"max_depth":{"type":"integer","description":"Max traversal depth for transitive queries (default: unlimited)"},"output_format":{"type":"string","enum":["text","json"],"description":"text (default) or json with confidence/why_matched metadata"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
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
    mcp.last_activity.store(cio.milliTimestamp(), .release);

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
        mcp.last_activity.store(cio.milliTimestamp(), .release);
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

pub fn dispatch(
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
        .codedb_relations => handleRelations(alloc, args, out, ctx.explorer),
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
        .codedb_search, .codedb_word, .codedb_callers, .codedb_relations, .codedb_outline, .codedb_symbol, .codedb_hierarchy, .codedb_routes, .codedb_config_xref, .codedb_find, .codedb_glob, .codedb_tree, .codedb_ls, .codedb_deps, .codedb_types => true,
        else => false,
    };
}
