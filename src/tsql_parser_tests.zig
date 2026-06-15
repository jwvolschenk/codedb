// Tests for src/tsql_parser.zig.
//
// Extracted from src/tsql_parser.zig to keep the parser file focused on
// implementation. Tests are picked up by the test runner via
// `@import("tests.zig")` which re-imports this file.

const std = @import("std");
const testing = std.testing;
const tsql_parser = @import("tsql_parser.zig");

test "parseLine: CREATE PROCEDURE" {
    const result = tsql_parser.parseLine("CREATE PROCEDURE dbo.GetUsers");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.GetUsers", result.symbol.name);
    try testing.expect(result.symbol.kind == .procedure);
}

test "parseLine: CREATE OR ALTER PROCEDURE" {
    const result = tsql_parser.parseLine("CREATE OR ALTER PROCEDURE [dbo].[GetUsers]");
    try testing.expect(result == .symbol);
    try testing.expect(result.symbol.kind == .procedure);
}

test "parseLine: ALTER FUNCTION" {
    const result = tsql_parser.parseLine("ALTER FUNCTION dbo.CalculateTotal");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.CalculateTotal", result.symbol.name);
    try testing.expect(result.symbol.kind == .function_def);
}

test "parseLine: CREATE VIEW" {
    const result = tsql_parser.parseLine("CREATE VIEW dbo.ActiveUsers AS");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.ActiveUsers", result.symbol.name);
    try testing.expect(result.symbol.kind == .view);
}

test "parseLine: CREATE TABLE" {
    const result = tsql_parser.parseLine("CREATE TABLE dbo.Users (");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.Users", result.symbol.name);
    try testing.expect(result.symbol.kind == .table_def);
}

test "parseLine: CREATE TRIGGER" {
    const result = tsql_parser.parseLine("CREATE TRIGGER dbo.tr_Users_Insert ON dbo.Users");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.tr_Users_Insert", result.symbol.name);
    try testing.expect(result.symbol.kind == .trigger);
}

test "parseLine: CREATE SCHEMA" {
    const result = tsql_parser.parseLine("CREATE SCHEMA Sales");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Sales", result.symbol.name);
    try testing.expect(result.symbol.kind == .schema);
}

test "parseLine: CREATE INDEX" {
    const result = tsql_parser.parseLine("CREATE INDEX IX_Users_Email ON dbo.Users (Email)");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("IX_Users_Email", result.symbol.name);
    try testing.expect(result.symbol.kind == .index_def);
}

test "parseLine: DECLARE @variable" {
    const result = tsql_parser.parseLine("DECLARE @UserId INT = 0");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("@UserId", result.symbol.name);
    try testing.expect(result.symbol.kind == .variable);
}

test "parseLine: EXEC procedure" {
    const result = tsql_parser.parseLine("EXEC dbo.GetUsers @Status = 1");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.GetUsers", result.import.path);
}

test "parseLine: EXECUTE procedure" {
    const result = tsql_parser.parseLine("EXECUTE dbo.UpdateUser @Id = 1");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.UpdateUser", result.import.path);
}

test "parseLine: FROM table" {
    const result = tsql_parser.parseLine("SELECT * FROM dbo.Users u");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "parseLine: JOIN table" {
    const result = tsql_parser.parseLine("INNER JOIN dbo.Orders o ON o.UserId = u.Id");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Orders", result.import.path);
}

test "parseLine: INSERT INTO" {
    const result = tsql_parser.parseLine("INSERT INTO dbo.Users (Name) VALUES ('test')");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "parseLine: UPDATE" {
    const result = tsql_parser.parseLine("UPDATE dbo.Users SET Name = 'test'");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "parseLine: DELETE FROM" {
    const result = tsql_parser.parseLine("DELETE FROM dbo.Users WHERE Id = 1");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "parseLine: line comment stripped" {
    const result = tsql_parser.parseLine("SELECT * FROM dbo.Users -- this is a comment");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.Users", result.import.path);
}

test "parseLine: full line comment is none" {
    const result = tsql_parser.parseLine("-- This is a comment");
    try testing.expect(result == .none);
}

test "parseLine: GO separator is none" {
    const result = tsql_parser.parseLine("GO");
    try testing.expect(result == .none);
}

test "parseLine: bracketed name" {
    const result = tsql_parser.parseLine("CREATE TABLE [dbo].[User Accounts] (");
    try testing.expect(result == .symbol);
    try testing.expect(result.symbol.kind == .table_def);
}

test "parseLine: three-part name" {
    const result = tsql_parser.parseLine("SELECT * FROM [MyDB].[dbo].[Users]");
    try testing.expect(result == .import);
}

test "parseLine: skip @table_variable in FROM" {
    const result = tsql_parser.parseLine("SELECT * FROM @TempTable");
    try testing.expect(result == .none);
}

test "parseLine: skip EXEC dynamic SQL" {
    const result = tsql_parser.parseLine("EXEC('SELECT 1')");
    try testing.expect(result == .none);
}

test "parseLine: skip EXEC @variable assignment" {
    const result = tsql_parser.parseLine("EXEC @ret = dbo.MyProc");
    try testing.expect(result == .none);
}

test "stripLineComment: preserves string literals" {
    const result = tsql_parser.stripLineComment("SELECT 'hello--world' FROM t -- comment");
    try testing.expectEqualStrings("SELECT 'hello--world' FROM t", result);
}

test "stripLineComment: handles escaped quotes" {
    const result = tsql_parser.stripLineComment("SELECT 'it''s a test' -- comment");
    try testing.expectEqualStrings("SELECT 'it''s a test'", result);
}

test "parseLine: LEFT OUTER JOIN" {
    const result = tsql_parser.parseLine("LEFT OUTER JOIN dbo.UserProfiles up ON up.UserId = u.Id");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("dbo.UserProfiles", result.import.path);
}

test "parseLine: CREATE SEQUENCE" {
    const result = tsql_parser.parseLine("CREATE SEQUENCE dbo.OrderNumbers START WITH 1");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.OrderNumbers", result.symbol.name);
    try testing.expect(result.symbol.kind == .sequence);
}

test "parseLine: CREATE SYNONYM" {
    const result = tsql_parser.parseLine("CREATE SYNONYM dbo.RemoteUsers FOR Server2.Database1.dbo.Users");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("dbo.RemoteUsers", result.symbol.name);
    try testing.expect(result.symbol.kind == .synonym);
}

// ── normalizeSqlName tests ────────────────────────────────────────────

test "normalizeSqlName: bracketed schema.object" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("[dbo].[Users]", &buf);
    try testing.expectEqualStrings("dbo.Users", result);
}

test "normalizeSqlName: bracketed multi-part" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("[Holding].[vPosition]", &buf);
    try testing.expectEqualStrings("Holding.vPosition", result);
}

test "normalizeSqlName: three-part bracketed" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("[MyDB].[dbo].[Users]", &buf);
    try testing.expectEqualStrings("MyDB.dbo.Users", result);
}

test "normalizeSqlName: already normalized" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("dbo.Users", &buf);
    try testing.expectEqualStrings("dbo.Users", result);
}

test "normalizeSqlName: bare name" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("Users", &buf);
    try testing.expectEqualStrings("Users", result);
}

test "normalizeSqlName: empty string" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("", &buf);
    try testing.expectEqualStrings("", result);
}

test "normalizeSqlName: bracketed with spaces" {
    var buf: [256]u8 = undefined;
    const result = tsql_parser.normalizeSqlName("[dbo].[User Accounts]", &buf);
    try testing.expectEqualStrings("dbo.User Accounts", result);
}

// ── extractBareObjectName tests ───────────────────────────────────────

test "extractBareObjectName: schema.object" {
    const result = tsql_parser.extractBareObjectName("dbo.GetUsers");
    try testing.expectEqualStrings("GetUsers", result);
}

test "extractBareObjectName: bracketed schema.object" {
    const result = tsql_parser.extractBareObjectName("[Holding].[vPosition]");
    try testing.expectEqualStrings("vPosition", result);
}

test "extractBareObjectName: three-part name" {
    const result = tsql_parser.extractBareObjectName("[MyDB].[dbo].[Users]");
    try testing.expectEqualStrings("Users", result);
}

test "extractBareObjectName: bare name" {
    const result = tsql_parser.extractBareObjectName("vPosition");
    try testing.expectEqualStrings("vPosition", result);
}

test "extractBareObjectName: empty string" {
    const result = tsql_parser.extractBareObjectName("");
    try testing.expectEqualStrings("", result);
}

test "extractBareObjectName: unbracketed three-part" {
    const result = tsql_parser.extractBareObjectName("Server2.Database1.dbo.Users");
    try testing.expectEqualStrings("Users", result);
}

test "parseLine: BOM-prefixed CREATE VIEW" {
    // UTF-8 BOM (EF BB BF) followed by CREATE VIEW
    const bom_line = "\xEF\xBB\xBFCREATE VIEW [Portfolio].[vAccount] AS";
    const result = tsql_parser.parseLine(bom_line);
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("[Portfolio].[vAccount]", result.symbol.name);
    try testing.expect(result.symbol.kind == .view);
}

test "parseLine: BOM-prefixed CREATE PROCEDURE" {
    const bom_line = "\xEF\xBB\xBFCREATE PROCEDURE [dbo].[GetUsers]";
    const result = tsql_parser.parseLine(bom_line);
    try testing.expect(result == .symbol);
    try testing.expect(result.symbol.kind == .procedure);
}
