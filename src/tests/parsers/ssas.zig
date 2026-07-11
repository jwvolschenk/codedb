const std = @import("std");
const testing = std.testing;
const explore = @import("../../explore.zig");
const ssas_security = @import("../../ssas_security.zig");
const mcp_tools = @import("../../mcp/explore_tools.zig");

fn findSymbol(outline: *const explore.FileOutline, name: []const u8) ?explore.Symbol {
    for (outline.symbols.items) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn countKind(outline: *const explore.FileOutline, kind: explore.SymbolKind) usize {
    var count: usize = 0;
    for (outline.symbols.items) |symbol| if (symbol.kind == kind) {
        count += 1;
    };
    return count;
}

test "SSAS language detection covers tabular multidimensional and project sources" {
    try testing.expectEqual(explore.Language.ssas_tabular, explore.detectLanguage("Model.BIM"));
    try testing.expectEqual(explore.Language.tmdl, explore.detectLanguage("model.TMDL"));
    try testing.expectEqual(explore.Language.dax, explore.detectLanguage("query.DAX"));
    try testing.expectEqual(explore.Language.mdx, explore.detectLanguage("query.MDX"));
    try testing.expectEqual(explore.Language.ssas_cube, explore.detectLanguage("Sales.CUBE"));
    try testing.expectEqual(explore.Language.ssas_cube, explore.detectLanguage("deploy.XMLA"));
    try testing.expectEqual(explore.Language.ssas_project, explore.detectLanguage("Sales.SMPROJ"));
    try testing.expectEqual(explore.Language.ssas_project, explore.detectLanguage("Warehouse.DWPROJ"));
}

test "BIM and TMSL parse tabular objects expression arrays and minified JSON" {
    const source =
        \\{"createOrReplace":{"database":{"name":"Db","model":{"tables":[{"name":"Sales","columns":[{"name":"Id","dataType":"int64","sourceColumn":"Id"},{"name":"Margin","dataType":"double","expression":["VAR x = [Revenue]","RETURN x - [Cost]"]}],"measures":[{"name":"Revenue","expression":"SUM('Sales'[Amount])"}],"hierarchies":[{"name":"Calendar"}],"partitions":[{"name":"Sales Partition","source":{"type":"m","expression":["let Source = Sql.Database(\\\"server\\\", \\\"db\\\")","in Source"]}}],"calculationGroup":{"calculationItems":[{"name":"Current","expression":"SELECTEDMEASURE()"}]}}],"relationships":[{"name":"Sales Customer","fromTable":"Sales","fromColumn":"CustomerId","toTable":"Customer","toColumn":"Id"}],"perspectives":[{"name":"Executive"}],"roles":[{"name":"Readers"}]}}}}
    ;
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "model.bim", source);
    defer outline.deinit();

    try testing.expectEqual(explore.Language.ssas_tabular, outline.language);
    try testing.expectEqual(explore.SymbolKind.class_def, findSymbol(&outline, "Sales").?.kind);
    try testing.expectEqual(explore.SymbolKind.variable, findSymbol(&outline, "Id").?.kind);
    const calculated = findSymbol(&outline, "Margin").?;
    try testing.expectEqual(explore.SymbolKind.variable, calculated.kind);
    try testing.expect(std.mem.indexOf(u8, calculated.detail.?, "subtype=calculated_column") != null);
    try testing.expect(std.mem.indexOf(u8, calculated.detail.?, "RETURN x - [Cost]") != null);
    try testing.expectEqual(explore.SymbolKind.function, findSymbol(&outline, "Revenue").?.kind);
    try testing.expectEqual(explore.SymbolKind.struct_def, findSymbol(&outline, "Calendar").?.kind);
    try testing.expectEqual(explore.SymbolKind.type_alias, findSymbol(&outline, "Sales Partition").?.kind);
    try testing.expectEqual(explore.SymbolKind.function, findSymbol(&outline, "Current").?.kind);
    const relationship = findSymbol(&outline, "Sales Customer").?;
    try testing.expect(std.mem.indexOf(u8, relationship.detail.?, "from=Sales[CustomerId]") != null);
    try testing.expect(findSymbol(&outline, "Executive") != null);
    try testing.expect(findSymbol(&outline, "Readers") != null);
    try testing.expectEqual(@as(u32, 1), relationship.line_start);
}

test "BIM parser locates direct database and malformed roots without panics" {
    const direct = "{\"model\":{\"tables\":[{\"name\":\"A\",\"columns\":[{\"name\":\"Same\"}]},{\"name\":\"B\",\"columns\":[{\"name\":\"Same\"}]}]}}";
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "direct.bim", direct);
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 2), countKind(&outline, .class_def));
    try testing.expectEqual(@as(usize, 2), countKind(&outline, .variable));

    var malformed = try explore.Explorer.parseOutlineWithParser(&parser, "broken.bim", "{\"model\":{\"tables\":[");
    defer malformed.deinit();
    try testing.expectEqual(@as(usize, 0), malformed.symbols.items.len);
}

test "TMDL parses quoted names calculation items relationships and DAX UDFs" {
    const source =
        \\model Model
        \\table 'Sales Facts'
        \\    column 'Order Id'
        \\        dataType: int64
        \\    calculatedColumn Margin = [Revenue] - [Cost]
        \\    measure Revenue = SUM('Sales Facts'[Amount])
        \\    hierarchy Calendar
        \\    partition 'Sales Partition' = m
        \\    calculationItem Current = SELECTEDMEASURE()
        \\relationship SalesToCustomer
        \\role Readers
        \\perspective Executive
        \\expression SharedQuery = ```
        \\function ConvertCurrency = (amount, rate) => amount * rate
        \\/* unterminated comment containing measure Fake = 1
    ;
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "model.tmdl", source);
    defer outline.deinit();
    try testing.expectEqual(.class_def, findSymbol(&outline, "Sales Facts").?.kind);
    try testing.expectEqual(.variable, findSymbol(&outline, "Order Id").?.kind);
    try testing.expect(std.mem.indexOf(u8, findSymbol(&outline, "Margin").?.detail.?, "table=Sales Facts") != null);
    try testing.expectEqual(.function, findSymbol(&outline, "Revenue").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "Current").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "ConvertCurrency").?.kind);
    try testing.expectEqual(.type_alias, findSymbol(&outline, "SalesToCustomer").?.kind);
    try testing.expect(findSymbol(&outline, "Fake") == null);
}

test "standalone DAX parses declarations while ignoring comments and strings" {
    const source =
        \\// MEASURE [Commented] = 1
        \\DEFINE MEASURE 'Sales'[Revenue] = SUM('Sales'[Amount])
        \\DEFINE VAR Threshold = 10
        \\DEFINE TABLE Result = ROW("Text", "MEASURE [Fake] = 1")
        \\DEFINE COLUMN 'Sales'[Band] = "High"
        \\DEFINE FUNCTION ConvertCurrency = (amount, rate) => amount * rate
        \\Legacy := [Revenue]
        \\EVALUATE Result
        \\/* unterminated MEASURE [AlsoFake] = 2
    ;
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "query.dax", source);
    defer outline.deinit();
    try testing.expectEqual(.function, findSymbol(&outline, "Revenue").?.kind);
    try testing.expectEqual(.variable, findSymbol(&outline, "Threshold").?.kind);
    try testing.expectEqual(.class_def, findSymbol(&outline, "Result").?.kind);
    try testing.expectEqual(.variable, findSymbol(&outline, "Band").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "ConvertCurrency").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "Legacy").?.kind);
    try testing.expect(findSymbol(&outline, "EVALUATE") != null);
    try testing.expect(findSymbol(&outline, "Commented") == null);
    try testing.expect(findSymbol(&outline, "Fake") == null);
    try testing.expect(findSymbol(&outline, "AlsoFake") == null);
}

test "MDX and embedded XML scripts parse declarations scopes assignments and queries" {
    const mdx =
        \\-- MEMBER [Measures].[Fake] AS 1
        \\WITH MEMBER [Measures].[Profit] AS [Measures].[Revenue] - [Measures].[Cost]
        \\SET [Top Customers] AS TopCount([Customer].[Customer].Members, 10)
        \\CREATE CALCULATED CELL [Sales Cell] AS 1
        \\SCOPE([Measures].[Profit]);
        \\    THIS = 0;
        \\END SCOPE;
        \\SELECT [Measures].[Profit] ON 0 FROM [Sales]
    ;
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "query.mdx", mdx);
    defer outline.deinit();
    try testing.expectEqual(.function, findSymbol(&outline, "Profit").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "Top Customers").?.kind);
    try testing.expectEqual(.function, findSymbol(&outline, "Sales Cell").?.kind);
    try testing.expect(findSymbol(&outline, "SELECT") != null);
    try testing.expect(findSymbol(&outline, "Fake") == null);

    const xml =
        \\<Cube><MdxScripts><MdxScript><Commands><Command><Text><![CDATA[
        \\CREATE MEMBER CURRENTCUBE.[Measures].[Margin] AS [Measures].[Revenue] - [Measures].[Cost];
        \\]]></Text></Command><Command><Text>CREATE SET CURRENTCUBE.[Core Set] AS {};</Text></Command></Commands></MdxScript></MdxScripts></Cube>
    ;
    var cube = try explore.Explorer.parseOutlineWithParser(&parser, "sales.cube", xml);
    defer cube.deinit();
    try testing.expect(findSymbol(&cube, "Margin") != null);
    try testing.expect(findSymbol(&cube, "Core Set") != null);

    var broken = try explore.Explorer.parseOutlineWithParser(&parser, "broken.xmla", "<MdxScript><![CDATA[CREATE MEMBER [Measures].[Partial] AS 1");
    defer broken.deinit();
    try testing.expect(findSymbol(&broken, "Partial") != null);
}

test "SSAS project emits sanitized identity and model dependencies" {
    const project =
        \\<Project>
        \\  <PropertyGroup><DeploymentServerName>secret-host</DeploymentServerName></PropertyGroup>
        \\  <ItemGroup>
        \\    <Compile Include="Model.bim" />
        \\    <None Include='Queries\Probe.dax' />
        \\    <Content Include="README.md" />
        \\  </ItemGroup>
        \\</Project>
    ;
    var parser = explore.Explorer.init(testing.allocator);
    defer parser.deinit();
    var outline = try explore.Explorer.parseOutlineWithParser(&parser, "Sales/Sales.smproj", project);
    defer outline.deinit();
    const identity = findSymbol(&outline, "Sales").?;
    try testing.expectEqual(.class_def, identity.kind);
    try testing.expect(std.mem.indexOf(u8, identity.detail.?, "secret-host") == null);
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expect(findSymbol(&outline, "Model.bim") != null);
    try testing.expect(findSymbol(&outline, "Queries\\Probe.dax") != null);
    try testing.expect(findSymbol(&outline, "README.md") == null);
}

test "DAX and MDX callers support brackets and reject strings and comments" {
    try testing.expect(mcp_tools.callerLineMatches("RETURN [Revenue]", "Revenue", .dax, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("SUM('Sales Facts'[Amount])", "Amount", .dax, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("SUM('Sales Facts'[Amount])", "Sales Facts", .dax, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("RETURN \"[Revenue]\"", "Revenue", .dax, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("-- [Revenue]", "Revenue", .dax, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("[Measures].[Profit]", "Profit", .mdx, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("'[Measures].[Profit]'", "Profit", .mdx, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("\"expression\":\"[Revenue]\"", "Revenue", .ssas_tabular, "semantic"));
}

test "secret-bearing SSAS content is evicted from every in-memory index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = explore.Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("model.bim", "{\"model\":{\"tables\":[{\"name\":\"VisibleTable\"}]}}");
    try testing.expect(explorer.outlines.contains("model.bim"));
    try testing.expect((try explorer.findAllSymbols("VisibleTable", arena.allocator())).len == 1);

    try explorer.indexFile("model.bim", "{\"password\":\"real-secret\",\"model\":{\"tables\":[{\"name\":\"HiddenTable\"}]}}");
    try testing.expect(!explorer.outlines.contains("model.bim"));
    try testing.expect(explorer.contents.get("model.bim") == null);
    try testing.expect((try explorer.findAllSymbols("VisibleTable", arena.allocator())).len == 0);
    try testing.expect((try explorer.findAllSymbols("HiddenTable", arena.allocator())).len == 0);
}

test "endpoint username and empty credentials remain indexable" {
    const safe = "{\"server\":\"analysis.example\",\"Username\":\"analyst\",\"AuthenticationKind\":\"Windows\",\"client-secret\":\"\",\"password\":null,\"model\":{\"tables\":[{\"name\":\"SafeTable\"}]}}";
    try testing.expect(!ssas_security.containsSensitiveContent("safe.bim", safe));
    var explorer = explore.Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("safe.bim", safe);
    try testing.expect(explorer.outlines.contains("safe.bim"));
}
