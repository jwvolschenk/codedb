const std = @import("std");
const cio = @import("../../cio.zig");
const testing = std.testing;
const io = std.testing.io;

const Store = @import("../../store.zig").Store;
const ChangeEntry = @import("../../store.zig").ChangeEntry;
const AgentRegistry = @import("../../agent.zig").AgentRegistry;
const Explorer = @import("../../explore.zig").Explorer;
const csharp_parser = @import("../../csharp_parser.zig");
const tsql_parser = @import("../../tsql_parser.zig");
const ssrs_parser = @import("../../ssrs_parser.zig");
const SearchResult = @import("../../explore.zig").SearchResult;
const WordIndex = @import("../../index.zig").WordIndex;
const TrigramIndex = @import("../../index.zig").TrigramIndex;
const SparseNgramIndex = @import("../../index.zig").SparseNgramIndex;
const pairWeight = @import("../../index.zig").pairWeight;
const extractSparseNgrams = @import("../../index.zig").extractSparseNgrams;
const buildCoveringSet = @import("../../index.zig").buildCoveringSet;
const setFrequencyTable = @import("../../index.zig").setFrequencyTable;
const resetFrequencyTable = @import("../../index.zig").resetFrequencyTable;
const buildFrequencyTable = @import("../../index.zig").buildFrequencyTable;
const writeFrequencyTable = @import("../../index.zig").writeFrequencyTable;
const readFrequencyTable = @import("../../index.zig").readFrequencyTable;

const WordTokenizer = @import("../../index.zig").WordTokenizer;
const splitIdentifier = @import("../../index.zig").splitIdentifier;

const version = @import("../../version.zig");
const watcher = @import("../../watcher.zig");
const edit_mod = @import("../../edit.zig");
const snapshot_json = @import("../../snapshot_json.zig");
const explore = @import("../../explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("../../mcp.zig");
const main_mod = @import("../../main.zig");
const nuke_mod = @import("../../nuke.zig");
const update_mod = @import("../../update.zig");
const Config = @import("../../config.zig").Config;
// Pull in unit tests that were extracted from implementation files into
// dedicated `*__tests.zig` companions. Zig collects test blocks through
// @import, so referencing them here makes the test runner discover them.
comptime {
    _ = @import("../../config_tests.zig");
    _ = @import("../../hot_cache_tests.zig");
    _ = @import("../../root_policy_tests.zig");
    _ = @import("../../tsql_parser_tests.zig");
}
const snapshot_mod = @import("../../snapshot.zig");
const telemetry_mod = @import("../../telemetry.zig");
const release_info = @import("../../release_info.zig");
// ── Store tests ─────────────────────────────────────────────

const decomposeRegex = @import("../../index.zig").decomposeRegex;

const RegexQuery = @import("../../index.zig").RegexQuery;

const packTrigram = @import("../../index.zig").packTrigram;

const git_mod = @import("../../git.zig");

const regexMatch = explore.regexMatch;

const PostingMask = @import("../../index.zig").PostingMask;

const normalizeChar = @import("../../index.zig").normalizeChar;

const Trigram = @import("../../index.zig").Trigram;

fn buildCliForHelpTests() !void {
    const build = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}

const MmapTrigramIndex = @import("../../index.zig").MmapTrigramIndex;

const AnyTrigramIndex = @import("../../index.zig").AnyTrigramIndex;

const fuzzyScore = @import("../../explore.zig").fuzzyScore;

fn expectOutlineSymbol(outline: *const explore.FileOutline, name: []const u8, kind: SymbolKind) !void {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.kind == kind) return;
    }
    return error.TestUnexpectedResult;
}

fn expectOutlineImport(outline: *const explore.FileOutline, import_path: []const u8) !void {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, import_path)) return;
    }
    return error.TestUnexpectedResult;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "TSQL parser: full outline with symbols and imports" {
    const alloc = testing.allocator;
    var explorer = Explorer.init(alloc);
    defer explorer.deinit();

    try explorer.indexFile("sql/StoredProcedures.sql",
        \\-- TSQL stored procedures and dependencies
        \\CREATE TABLE dbo.Users (
        \\    Id INT PRIMARY KEY,
        \\    Name NVARCHAR(100),
        \\    Email NVARCHAR(255)
        \\);
        \\
        \\CREATE TABLE dbo.Orders (
        \\    Id INT PRIMARY KEY,
        \\    UserId INT,
        \\    Total DECIMAL(18,2)
        \\);
        \\
        \\CREATE PROCEDURE dbo.GetUsersByStatus
        \\    @Status INT
        \\AS
        \\BEGIN
        \\    SELECT u.Id, u.Name
        \\    FROM dbo.Users u
        \\    INNER JOIN dbo.Orders o ON o.UserId = u.Id
        \\    WHERE u.Status = @Status;
        \\END
        \\
        \\CREATE FUNCTION dbo.CalculateTotal(@UserId INT)
        \\RETURNS DECIMAL(18,2)
        \\AS
        \\BEGIN
        \\    DECLARE @Total DECIMAL(18,2);
        \\    SELECT @Total = SUM(Total) FROM dbo.Orders WHERE UserId = @UserId;
        \\    RETURN @Total;
        \\END
        \\
        \\CREATE VIEW dbo.ActiveUsers AS
        \\SELECT u.Id, u.Name, o.Total
        \\FROM dbo.Users u
        \\LEFT JOIN dbo.Orders o ON o.UserId = u.Id;
        \\
        \\CREATE TRIGGER dbo.tr_Users_Audit
        \\ON dbo.Users
        \\AFTER INSERT, UPDATE
        \\AS
        \\BEGIN
        \\    INSERT INTO dbo.AuditLog (TableName, Action)
        \\    VALUES ('Users', 'MODIFY');
        \\END
        \\
        \\CREATE PROCEDURE dbo.ProcessOrder
        \\    @OrderId INT
        \\AS
        \\BEGIN
        \\    EXEC dbo.UpdateInventory @OrderId;
        \\    DELETE FROM dbo.PendingOrders WHERE OrderId = @OrderId;
        \\END
        \\
        \\GO
    );

    var outline = try explorer.getOutline("sql/StoredProcedures.sql", alloc) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(Language.sql, outline.language);

    // Object definitions
    try expectOutlineSymbol(&outline, "dbo.Users", .struct_def);
    try expectOutlineSymbol(&outline, "dbo.Orders", .struct_def);
    try expectOutlineSymbol(&outline, "dbo.GetUsersByStatus", .function);
    try expectOutlineSymbol(&outline, "dbo.CalculateTotal", .function);
    try expectOutlineSymbol(&outline, "dbo.ActiveUsers", .struct_def);
    try expectOutlineSymbol(&outline, "dbo.tr_Users_Audit", .method);
    try expectOutlineSymbol(&outline, "dbo.ProcessOrder", .function);

    // Variables (only DECLARE statements)
    try expectOutlineSymbol(&outline, "@Total", .variable);

    // Dependency tracking - verify imports exist
    try testing.expect(outline.imports.items.len > 0);
}

test "TSQL parser: stripLineComment respects string literals" {
    const result = tsql_parser.stripLineComment("SELECT 'hello--world' FROM t -- comment");
    try testing.expectEqualStrings("SELECT 'hello--world' FROM t", result);
}

test "TSQL parser: escaped quotes in strings" {
    const result = tsql_parser.stripLineComment("SELECT 'it''s a test' -- comment");
    try testing.expectEqualStrings("SELECT 'it''s a test'", result);
}

test "TSQL parser: CREATE OR ALTER PROCEDURE" {
    const result = tsql_parser.parseLine("CREATE OR ALTER PROCEDURE dbo.GetUsers");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.GetUsers", result.symbol.name);
    try testing.expect(result.symbol.kind == .procedure);
}

test "TSQL parser: ALTER FUNCTION" {
    const result = tsql_parser.parseLine("ALTER FUNCTION dbo.CalculateTotal");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.CalculateTotal", result.symbol.name);
    try testing.expect(result.symbol.kind == .function_def);
}

test "TSQL parser: EXEC procedure dependency" {
    const result = tsql_parser.parseLine("EXEC dbo.UpdateInventory @OrderId = 1");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.UpdateInventory", result.import.path);
}

test "TSQL parser: FROM table dependency" {
    const result = tsql_parser.parseLine("SELECT * FROM dbo.Users u");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "TSQL parser: INNER JOIN dependency" {
    const result = tsql_parser.parseLine("INNER JOIN dbo.Orders o ON o.UserId = u.Id");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Orders", result.import.path);
}

test "TSQL parser: INSERT INTO dependency" {
    const result = tsql_parser.parseLine("INSERT INTO dbo.AuditLog (TableName) VALUES ('test')");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.AuditLog", result.import.path);
}

test "TSQL parser: DELETE FROM dependency" {
    const result = tsql_parser.parseLine("DELETE FROM dbo.PendingOrders WHERE Id = 1");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.PendingOrders", result.import.path);
}

test "TSQL parser: DECLARE variable" {
    const result = tsql_parser.parseLine("DECLARE @UserId INT = 0");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("@UserId", result.symbol.name);
    try testing.expect(result.symbol.kind == .variable);
}

test "TSQL parser: GO separator is none" {
    const result = tsql_parser.parseLine("GO");
    try testing.expect(result == .none);
}

test "TSQL parser: skip @table_variable in FROM" {
    const result = tsql_parser.parseLine("SELECT * FROM @TempTable");
    try testing.expect(result == .none);
}

test "TSQL parser: skip EXEC dynamic SQL" {
    const result = tsql_parser.parseLine("EXEC('SELECT 1')");
    try testing.expect(result == .none);
}

test "TSQL parser: skip EXEC @variable assignment" {
    const result = tsql_parser.parseLine("EXEC @ret = dbo.MyProc");
    try testing.expect(result == .none);
}

test "TSQL parser: LEFT OUTER JOIN dependency" {
    const result = tsql_parser.parseLine("LEFT OUTER JOIN dbo.UserProfiles up ON up.UserId = u.Id");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.UserProfiles", result.import.path);
}

test "TSQL parser: CREATE SEQUENCE" {
    const result = tsql_parser.parseLine("CREATE SEQUENCE dbo.OrderNumbers START WITH 1");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.OrderNumbers", result.symbol.name);
    try testing.expect(result.symbol.kind == .sequence);
}

test "TSQL parser: CREATE SYNONYM" {
    const result = tsql_parser.parseLine("CREATE SYNONYM dbo.RemoteUsers FOR Server2.Database1.dbo.Users");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.RemoteUsers", result.symbol.name);
    try testing.expect(result.symbol.kind == .synonym);
}

test "TSQL parser: bracketed name" {
    const result = tsql_parser.parseLine("CREATE TABLE [dbo].[User Accounts] (");
    try testing.expect(result == .symbol);
    try testing.expect(result.symbol.kind == .table_def);
}

test "TSQL parser: CREATE INDEX" {
    const result = tsql_parser.parseLine("CREATE INDEX IX_Users_Email ON dbo.Users (Email)");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("IX_Users_Email", result.symbol.name);
    try testing.expect(result.symbol.kind == .index_def);
}

test "TSQL parser: UPDATE dependency" {
    const result = tsql_parser.parseLine("UPDATE dbo.Users SET Name = 'test'");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

// ── SSRS parser tests ────────────────────────────────────────────
