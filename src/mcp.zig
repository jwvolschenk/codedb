// codedb MCP server — thin aggregator.
//
// The implementation lives in src/mcp/: server.zig (protocol session loop,
// scan-state machine, project cache, tool registry, dispatch) plus the
// extracted tool-handler modules (explore_tools, mutation_tools,
// composite_tools, query, aspnet, ...). This file re-exports the public
// surface so existing callers (main.zig, bench.zig, tests.zig, and the
// mcp/*.zig submodules) keep resolving.

const std = @import("std");

/// Monotonic timestamp of last MCP request, used for activity accounting.
/// Lives here (not mcp/server.zig) because Zig cannot alias another file's
/// `pub var` as a container-level `const`; mcp/server.zig reaches it via
/// `mcp.last_activity`.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

// Pull in extracted unit tests (issue-258, issue-353, snapshot cache).
comptime {
    _ = @import("mcp/tests.zig");
}

// ── core server (extracted to mcp/server.zig) ──
const server = @import("mcp/server.zig");
pub const Root = server.Root;
pub const DeferredScan = server.DeferredScan;
pub const triggerDeferredScanWithFallback = server.triggerDeferredScanWithFallback;
pub const SnapshotCache = server.SnapshotCache;
pub const getProjectDataDir = server.getProjectDataDir;
pub const loadProjectTrigramFromDiskIfPresent = server.loadProjectTrigramFromDiskIfPresent;
pub const ProjectCache = server.ProjectCache;
pub const BenchContext = server.BenchContext;
pub const Tool = server.Tool;
pub const tools_list = server.tools_list;
pub const ToolsListOpts = server.ToolsListOpts;
pub const buildToolsListResponse = server.buildToolsListResponse;
pub const buildAugmentedToolsList = server.buildAugmentedToolsList;
pub const dead_client_poll_ms = server.dead_client_poll_ms;
pub const ScanState = server.ScanState;
pub const setScanState = server.setScanState;
pub const getScanState = server.getScanState;
pub const run = server.run;
pub const dispatch = server.dispatch;

// ── explore tool handlers (extracted to mcp/explore_tools.zig) ──
const explore_tools = @import("mcp/explore_tools.zig");
pub const hasWholeWordMatch = explore_tools.hasWholeWordMatch;
pub const langHasCallSites = explore_tools.langHasCallSites;
pub const callerLineMatches = explore_tools.callerLineMatches;
pub const effectiveMatchMode = explore_tools.effectiveMatchMode;

// ── mutation tool handlers (extracted to mcp/mutation_tools.zig) ──
const mutation_tools = @import("mcp/mutation_tools.zig");
pub const handleRead = mutation_tools.handleRead;

// ── composite + filesystem tools (extracted to mcp/composite_tools.zig) ──
const composite_tools = @import("mcp/composite_tools.zig");
pub const stripAnsiCodes = composite_tools.stripAnsiCodes;
pub const appendBundleArgKeysDiagnostic = composite_tools.appendBundleArgKeysDiagnostic;
pub const finishQueryWithFailure = composite_tools.finishQueryWithFailure;
pub const appendFuzzyPathSuggestions = composite_tools.appendFuzzyPathSuggestions;

// ── Split-out helper modules (see src/mcp/) ──
const wal = @import("mcp/wal.zig");
const pathglob = @import("mcp/pathglob.zig");
const jsonio = @import("mcp/jsonio.zig");
const format = @import("mcp/format.zig");
const mcp_lib = @import("mcp");

pub const setQueryLogPath = wal.setQueryLogPath;
pub const globMatch = pathglob.globMatch;
pub const isPathSafe = pathglob.isPathSafe;
pub const appendId = jsonio.appendId;
pub const getBool = mcp_lib.json.getBool;
pub const mcpGenerateSummary = format.mcpGenerateSummary;
pub const mcpGenerateGuidance = format.mcpGenerateGuidance;
