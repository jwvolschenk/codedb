const std = @import("std");

// Import types directly from explore/types.zig to avoid a circular import
// through explore.zig (which imports this module).
const types = @import("explore/types.zig");
const Symbol = types.Symbol;
const SymbolKind = types.SymbolKind;
const FileOutline = types.FileOutline;

/// SSRS-specific symbol kinds for .rdl, .rsd, .rds, .rptproj files.
pub const Kind = enum {
    report_parameter, // .rdl: <ReportParameter Name="...">
    dataset, // .rdl/.rsd: <DataSet Name="...">
    datasource, // .rdl/.rds: <DataSource Name="...">
    variable, // .rdl: <Variable Name="...">
    subreport, // .rdl: <Subreport Name="...">
    shared_dataset_ref, // .rdl: <SharedDataSetReference> (dependency)
    datasource_ref, // .rdl: <DataSourceReference> (dependency)
    command_text, // .rdl/.rsd: <CommandText> (SQL/SP call)
    report_item, // .rptproj: <Report Include="...">
    dataset_item, // .rptproj: <DataSet Include="...">
    datasource_item, // .rptproj: <DataSource Include="...">
    report_metadata, // Author, Language, Description, rd:ReportID, etc.
    rptproj_property, // TargetReportFolder, TargetServerURL, TargetServerVersion
    axys_macro, // Synthesized AXYS macro reference (e.g. "rp_test.mac")
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    import: struct {
        path: []const u8,
    },
};

/// Extract the value of an XML attribute from a line.
/// Returns the substring between attr_name=" and the next quote.
pub fn extractXmlAttribute(line: []const u8, attr_name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (attr_name.len + 2 > buf.len) return null;
    @memcpy(buf[0..attr_name.len], attr_name);
    buf[attr_name.len] = '=';
    buf[attr_name.len + 1] = '"';
    const needle = buf[0 .. attr_name.len + 2];

    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    const value_start = start + needle.len;
    const remaining = line[value_start..];
    const value_end = std.mem.indexOf(u8, remaining, "\"") orelse return null;
    return remaining[0..value_end];
}

/// Extract text content between two XML tags on the same line.
/// e.g. `<CommandText>SELECT * FROM Foo</CommandText>` → `SELECT * FROM Foo`
pub fn extractXmlTagContent(line: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    if (tag.len + 2 > open_buf.len) return null;
    open_buf[0] = '<';
    @memcpy(open_buf[1 .. tag.len + 1], tag);
    open_buf[tag.len + 1] = '>';
    const open_tag = open_buf[0 .. tag.len + 2];

    var close_buf: [64]u8 = undefined;
    if (tag.len + 3 > close_buf.len) return null;
    close_buf[0] = '<';
    close_buf[1] = '/';
    @memcpy(close_buf[2 .. tag.len + 2], tag);
    close_buf[tag.len + 2] = '>';
    const close_tag = close_buf[0 .. tag.len + 3];

    const open_pos = std.mem.indexOf(u8, line, open_tag) orelse return null;
    const content_start = open_pos + open_tag.len;
    const close_pos = std.mem.indexOf(u8, line[content_start..], close_tag) orelse return null;
    return line[content_start .. content_start + close_pos];
}

/// Convert an SSRS shared dataset reference path to a filename.
/// "/Datasets/GetReportEntity" → "GetReportEntity.rsd"
fn sharedDatasetRefToFilename(ref_path: []const u8) ?[]const u8 {
    // Strip leading /Datasets/ prefix
    const prefix = "/Datasets/";
    const trimmed = if (std.mem.startsWith(u8, ref_path, prefix))
        ref_path[prefix.len..]
    else
        ref_path;
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Convert an SSRS datasource reference path to a filename.
/// "/Data Sources/Autumn" → "Autumn"
fn datasourceRefToFilename(ref_path: []const u8) ?[]const u8 {
    const prefix = "/Data Sources/";
    const trimmed = if (std.mem.startsWith(u8, ref_path, prefix))
        ref_path[prefix.len..]
    else
        ref_path;
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Extension suffixes for SSRS file types — used to build proper dependency paths.
const rsd_ext = ".rsd";
const rds_ext = ".rds";
const rdl_ext = ".rdl";

// ── .rdl (Report Definition Language) ──────────────────────────────

pub fn parseRdlLine(line: []const u8) ParsedLine {
    // <ReportParameter Name="pvc_UserId">
    if (std.mem.indexOf(u8, line, "<ReportParameter ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .report_parameter } };
    }

    // <DataSet Name="GetReportEntity">
    if (std.mem.indexOf(u8, line, "<DataSet ") != null and
        std.mem.indexOf(u8, line, "Name=") != null and
        std.mem.indexOf(u8, line, "<DataSetParameter") == null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .dataset } };
    }

    // <DataSource Name="Autumn">
    if (std.mem.indexOf(u8, line, "<DataSource ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .datasource } };
    }

    // <Variable Name="Expense">
    if (std.mem.indexOf(u8, line, "<Variable ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable } };
    }

    // <Subreport Name="PortfolioSummary">
    if (std.mem.indexOf(u8, line, "<Subreport ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .subreport } };
    }

    // <SharedDataSetReference>/Datasets/GetReportEntity</SharedDataSetReference>
    if (std.mem.indexOf(u8, line, "<SharedDataSetReference>") != null) {
        const content = extractXmlTagContent(line, "SharedDataSetReference") orelse return .none;
        const basename = sharedDatasetRefToFilename(content) orelse return .none;
        return .{ .import = .{ .path = basename } };
    }

    // <DataSourceReference>/Data Sources/Autumn</DataSourceReference>
    if (std.mem.indexOf(u8, line, "<DataSourceReference>") != null) {
        const content = extractXmlTagContent(line, "DataSourceReference") orelse return .none;
        const basename = datasourceRefToFilename(content) orelse return .none;
        return .{ .import = .{ .path = basename } };
    }

    // <Field Name="ReportEntity"> (also emitted by .rsd parser)
    if (std.mem.indexOf(u8, line, "<Field ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable } };
    }

    // Report metadata: <Author>, <Language>, <rd:ReportID>, <rd:ReportServerUrl>, <Description>
    if (detectMetadataTagName(line)) |meta_name| {
        return .{ .symbol = .{ .name = meta_name, .kind = .report_metadata } };
    }

    // <CommandText>Reporting.ReportExPost</CommandText>
    if (std.mem.indexOf(u8, line, "<CommandText>") != null) {
        const content = extractXmlTagContent(line, "CommandText") orelse return .none;
        if (content.len == 0) return .none;
        return .{ .symbol = .{ .name = content, .kind = .command_text } };
    }

    return .none;
}

/// Parse a <ReportName> line inside a <Subreport> block — this is a dependency
/// link from a parent report to a subreport .rdl file.
pub fn parseSubreportRef(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "<ReportName>") != null) {
        return extractXmlTagContent(line, "ReportName");
    }
    return null;
}

// ── .rsd (Shared DataSet Definition) ───────────────────────────────

pub fn parseRsdLine(line: []const u8) ParsedLine {
    // <DataSourceReference>Autumn</DataSourceReference>
    if (std.mem.indexOf(u8, line, "<DataSourceReference>") != null) {
        const content = extractXmlTagContent(line, "DataSourceReference") orelse return .none;
        return .{ .import = .{ .path = content } };
    }

    // <CommandType>StoredProcedure</CommandType>
    if (std.mem.indexOf(u8, line, "<CommandType>") != null) {
        const content = extractXmlTagContent(line, "CommandType") orelse return .none;
        if (content.len == 0) return .none;
        return .{ .symbol = .{ .name = "CommandType", .kind = .report_metadata } };
    }

    // <CommandText>SELECT [Common].[GetReportEntity](...) AS ReportEntity</CommandText>
    if (std.mem.indexOf(u8, line, "<CommandText>") != null) {
        const content = extractXmlTagContent(line, "CommandText") orelse return .none;
        if (content.len == 0) return .none;
        return .{ .symbol = .{ .name = content, .kind = .command_text } };
    }

    // <DataSetParameter Name="@pvc_ReportEntity">
    if (std.mem.indexOf(u8, line, "<DataSetParameter ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .report_parameter } };
    }

    // <QueryParameter Name="@pvc_FromDate"> — canonical SSRS query parameter,
    // used inside <Query> blocks in both .rdl DataSets and .rsd shared datasets.
    if (std.mem.indexOf(u8, line, "<QueryParameter ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .report_parameter } };
    }

    // <Field Name="ReportEntity">
    if (std.mem.indexOf(u8, line, "<Field ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable } };
    }

    return .none;
}

// ── .rds (RptDataSource) ──────────────────────────────────────────

pub fn parseRdsLine(line: []const u8) ParsedLine {
    // <RptDataSource ... Name="Autumn">
    if (std.mem.indexOf(u8, line, "<RptDataSource ") != null and
        std.mem.indexOf(u8, line, "Name=") != null)
    {
        const name = extractXmlAttribute(line, "Name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .datasource } };
    }

    // <Extension>SQL</Extension>
    if (std.mem.indexOf(u8, line, "<Extension>") != null) {
        const content = extractXmlTagContent(line, "Extension") orelse return .none;
        if (content.len == 0) return .none;
        return .{ .symbol = .{ .name = "Extension", .kind = .report_metadata } };
    }

    // <ConnectString>Data Source=sql-dbc1;Initial Catalog=Autumn</ConnectString>
    if (std.mem.indexOf(u8, line, "<ConnectString>") != null) {
        const content = extractXmlTagContent(line, "ConnectString") orelse return .none;
        if (content.len == 0) return .none;
        return .{ .symbol = .{ .name = content, .kind = .datasource } };
    }

    return .none;
}

// ── .rptproj (MSBuild Project) ─────────────────────────────────────

pub fn parseRptprojLine(line: []const u8) ParsedLine {
    // <Report Include="CGIX Tax Certificates.rdl" />
    if (std.mem.indexOf(u8, line, "<Report Include=") != null) {
        const name = extractXmlAttribute(line, "Include") orelse return .none;
        return .{ .import = .{ .path = name } };
    }

    // <DataSet Include="GetDate.rsd" />
    if (std.mem.indexOf(u8, line, "<DataSet Include=") != null) {
        const name = extractXmlAttribute(line, "Include") orelse return .none;
        return .{ .import = .{ .path = name } };
    }

    // <DataSource Include="Autumn.rds" />
    if (std.mem.indexOf(u8, line, "<DataSource Include=") != null) {
        const name = extractXmlAttribute(line, "Include") orelse return .none;
        return .{ .import = .{ .path = name } };
    }

    // PropertyGroup metadata: <TargetReportFolder>, <TargetServerURL>, <TargetServerVersion>
    if (detectRptprojPropertyName(line)) |prop_name| {
        return .{ .symbol = .{ .name = prop_name, .kind = .rptproj_property } };
    }

    return .none;
}

// ── Detail extraction (called from explore.zig) ────────────────────

/// Build a structured detail string from the raw XML line and symbol kind.
/// Caller provides the output buffer. Returns the populated slice.
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    switch (kind) {
        .report_parameter => {
            // Show data type if available
            return extractXmlTagContentDetail(line, "DataType", buf);
        },
        .dataset => {
            // Show whether it's a shared dataset or inline query
            if (std.mem.indexOf(u8, line, "<SharedDataSet>") != null or
                std.mem.indexOf(u8, line, "<SharedDataSetReference>") != null)
            {
                return writeBuf(buf, "shared");
            }
            return "";
        },
        .datasource => {
            return "";
        },
        .variable => {
            // Show the value expression if this is a <Variable> line with <Value>
            if (std.mem.indexOf(u8, line, "<Value>") != null) {
                return extractXmlTagContentDetail(line, "Value", buf);
            }
            return "";
        },
        .subreport => {
            return "";
        },
        .shared_dataset_ref => {
            return "";
        },
        .datasource_ref => {
            return "";
        },
        .command_text => {
            // The name IS the command text; detail is empty since name already has it
            return "";
        },
        .report_item => {
            return "";
        },
        .dataset_item => {
            return "";
        },
        .datasource_item => {
            return "";
        },
        .report_metadata => {
            // Description gets special pipe-parsing; others use generic content extraction.
            if (std.mem.indexOf(u8, line, "<Description>") != null) {
                return extractDescriptionDetail(line, buf);
            }
            return extractGenericMetadataDetail(line, buf);
        },
        .rptproj_property => {
            return extractGenericMetadataDetail(line, buf);
        },
        .axys_macro => {
            // Detail is set by the post-pass when synthesizing the symbol; nothing
            // to extract from the originating line at parse time.
            return "";
        },
    }
}

fn writeBuf(buf: []u8, text: []const u8) []const u8 {
    const copy = @min(text.len, buf.len);
    @memcpy(buf[0..copy], text[0..copy]);
    return buf[0..copy];
}

fn extractXmlTagContentDetail(line: []const u8, tag: []const u8, buf: []u8) []const u8 {
    const content = extractXmlTagContent(line, tag) orelse return "";
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return "";
    const copy = @min(trimmed.len, buf.len);
    @memcpy(buf[0..copy], trimmed[0..copy]);
    return buf[0..copy];
}

/// Detect which report metadata tag a line contains. Returns the canonical
/// metadata field name (e.g. "Author", "Language", "Description") or null.
fn detectMetadataTagName(line: []const u8) ?[]const u8 {
    // Order matters: longer/more-specific tags first.
    if (std.mem.indexOf(u8, line, "<rd:ReportServerUrl>") != null) return "ReportServerUrl";
    if (std.mem.indexOf(u8, line, "<rd:ReportID>") != null) return "ReportID";
    if (std.mem.indexOf(u8, line, "<Description>") != null) return "Description";
    if (std.mem.indexOf(u8, line, "<Author>") != null) return "Author";
    if (std.mem.indexOf(u8, line, "<Language>") != null) return "Language";
    return null;
}

/// Detect which rptproj PropertyGroup tag a line contains.
fn detectRptprojPropertyName(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "<TargetReportFolder>") != null) return "TargetReportFolder";
    if (std.mem.indexOf(u8, line, "<TargetServerURL>") != null) return "TargetServerURL";
    if (std.mem.indexOf(u8, line, "<TargetServerVersion>") != null) return "TargetServerVersion";
    return null;
}

/// Extract metadata value generically by returning text between the first `>`
/// and the first subsequent `</`. Used for <Author>, <Language>, <Extension>,
/// <CommandType>, <TargetReportFolder>, etc. — anything with a simple
/// `<Tag>value</Tag>` shape that we don't special-case elsewhere.
fn extractGenericMetadataDetail(line: []const u8, buf: []u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, line, '>') orelse return "";
    const after_open = line[open + 1 ..];
    const close = std.mem.indexOf(u8, after_open, "</") orelse return "";
    const trimmed = std.mem.trim(u8, after_open[0..close], " \t\r\n");
    if (trimmed.len == 0) return "";
    const copy = @min(trimmed.len, buf.len);
    @memcpy(buf[0..copy], trimmed[0..copy]);
    return buf[0..copy];
}

/// Parse a <Description> tag's content for the pipe-delimited metadata schema.
/// Produces a compact summary like "section=Portfolio desc=Periodic report... orientation=Portrait".
/// Falls back to raw text when the content is plain (no `|` characters).
fn extractDescriptionDetail(line: []const u8, buf: []u8) []const u8 {
    const content = extractXmlTagContent(line, "Description") orelse return "";
    return formatPipeDescription(content, buf);
}

/// Format the pipe-delimited description content into a summary string.
/// Schema: Key1|Value1|Key2|Value2|... (trailing | optional).
fn formatPipeDescription(content: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return "";
    // Plain-text descriptions (no pipes) are returned as-is.
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) {
        return writeBuf(buf, trimmed);
    }
    // Walk pairs and emit known keys compactly.
    var written: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    while (it.next()) |key| {
        const value = it.next() orelse break;
        if (key.len == 0 or value.len == 0) continue;
        // Only emit a focused subset to stay within the detail buffer budget.
        const emit = std.mem.eql(u8, key, "Section") or
            std.mem.eql(u8, key, "Group") or
            std.mem.eql(u8, key, "Description") or
            std.mem.eql(u8, key, "Orientation") or
            std.mem.eql(u8, key, "Image");
        if (!emit) continue;
        const remaining = buf.len - written;
        // Need space for: lowercased key + '=' + value + ' ' separator.
        if (remaining < key.len + value.len + 2) break;
        if (written > 0) {
            buf[written] = ' ';
            written += 1;
        }
        // Lowercase the key directly into the output buffer.
        for (key) |c| {
            buf[written] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            written += 1;
        }
        buf[written] = '=';
        written += 1;
        const v_copy = @min(value.len, buf.len - written);
        @memcpy(buf[written .. written + v_copy], value[0..v_copy]);
        written += v_copy;
    }
    if (written == 0) return writeBuf(buf, trimmed);
    return buf[0..written];
}

// ── Post-pass: multi-line construct enrichment ─────────────────────
//
// The line parser is stateless and per-line; it cannot see multi-line
// constructs (Description, AXYS ConnectString with VB.NET concatenation,
// <Code> blocks, ReportParameter with child elements). This post-pass
// runs once per SSRS file after the line parser, scans raw content, and
// mutates the outline: it patches existing symbol details and synthesizes
// new symbols (VB functions, AXYS macro references).
//
// Activation: only for .rdl/.rsd/.rds (see enrichOutline dispatch).
// Risk surface: zero for non-SSRS files.

const Range = struct { start: usize, end: usize };

/// Find the content between `open_tag` and `close_tag` in `content`,
/// allowing the content to span newlines. Returns byte offsets relative
/// to `content` (exclusive of the tags themselves).
fn extractMultilineTag(content: []const u8, open_tag: []const u8, close_tag: []const u8) ?Range {
    const start_pos = std.mem.indexOf(u8, content, open_tag) orelse return null;
    const inner_start = start_pos + open_tag.len;
    const end_pos = std.mem.indexOf(u8, content[inner_start..], close_tag) orelse return null;
    return .{ .start = inner_start, .end = inner_start + end_pos };
}

/// Convert a byte offset in `content` to a 1-indexed line number using
/// a precomputed line-offsets table (built by `enrichOutline`).
fn offsetToLine(line_offsets: []const usize, offset: usize) u32 {
    // Linear walk; SSRS files are small and call sites are few.
    var line: u32 = 1;
    for (line_offsets, 0..) |off, i| {
        if (off > offset) {
            return @intCast(i); // line N (1-indexed) starts at offsets[N-1]
        }
        line = @intCast(i + 1);
    }
    return line;
}

/// Top-level entry point called from explore/lifecycle.zig. Builds a
/// line-offsets table and dispatches by language.
pub fn enrichOutline(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
) void {
    var line_offsets: std.ArrayList(usize) = .empty;
    defer line_offsets.deinit(allocator);
    line_offsets.append(allocator, 0) catch return;
    for (content, 0..) |c, i| {
        if (c == '\n') line_offsets.append(allocator, i + 1) catch return;
    }

    switch (outline.language) {
        .ssrs_report => enrichRdl(allocator, outline, content, line_offsets.items),
        .ssrs_dataset => enrichRsd(allocator, outline, content),
        .ssrs_datasource => enrichRdsPost(allocator, outline, content, line_offsets.items),
        else => {},
    }
}

/// Find a symbol in the outline by name. Returns a mutable pointer to
/// the first match, or null.
fn findSymbolByName(outline: *FileOutline, name: []const u8) ?*Symbol {
    for (outline.symbols.items) |*sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym;
    }
    return null;
}

/// Replace a symbol's detail string. Frees the previous detail (if any)
/// and dupes the new one. Failure is silent (detail stays null/unchanged).
fn setSymbolDetail(allocator: std.mem.Allocator, sym: *Symbol, new_detail: []const u8) void {
    const copy = allocator.dupe(u8, new_detail) catch return;
    if (sym.detail) |old| allocator.free(old);
    sym.detail = copy;
}

/// Append a synthesized symbol to the outline. Caller must still set
/// line_end explicitly if it should differ from line_start (which it
/// should for any symbol with a fetchable body — see enrichCodeBlock).
fn appendSynthesizedSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    detail: []const u8,
) void {
    const name_copy = allocator.dupe(u8, name) catch return;
    errdefer allocator.free(name_copy);
    const detail_copy = allocator.dupe(u8, detail) catch {
        allocator.free(name_copy);
        return;
    };
    outline.symbols.append(allocator, .{
        .name = name_copy,
        .kind = kind,
        .line_start = line_start,
        .line_end = line_end,
        .detail = detail_copy,
    }) catch {
        allocator.free(name_copy);
        allocator.free(detail_copy);
    };
}

// ── Tablix structure enrichment ────────────────────────────────────
//
// Extracts the TablixRowHierarchy, TablixColumnHierarchy, and
// TablixRows from RDL files so agents can see the full report layout
// from the outline without reading thousands of lines of XML.

/// Count occurrences of a needle in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= haystack.len) {
        const found = std.mem.indexOfPos(u8, haystack, pos, needle) orelse break;
        count += 1;
        pos = found + needle.len;
    }
    return count;
}

/// Find the position of the Nth occurrence of `needle` in `haystack` (0-indexed).
fn findNthOccurrence(haystack: []const u8, needle: []const u8, n: usize) ?usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (pos <= haystack.len) {
        const found = std.mem.indexOfPos(u8, haystack, pos, needle) orelse return null;
        if (i == n) return found;
        i += 1;
        pos = found + needle.len;
    }
    return null;
}

/// Extract column widths from <TablixColumn><Width>...</Width></TablixColumn>
/// elements. Returns the count and writes a comma-separated summary into buf.
fn extractColumnWidths(content: []const u8, col_hierarchy_range: struct { start: usize, end: usize }, buf: []u8) struct { count: usize, written: usize } {
    const block = content[col_hierarchy_range.start..col_hierarchy_range.end];
    var written: usize = 0;
    var count: usize = 0;
    var search_from: usize = 0;
    while (search_from <= block.len) {
        const col_start = std.mem.indexOfPos(u8, block, search_from, "<TablixColumn>") orelse break;
        const col_end = std.mem.indexOfPos(u8, block, col_start, "</TablixColumn>") orelse break;
        const col_block = block[col_start..col_end];
        if (extractMultilineTag(col_block, "<Width>", "</Width>")) |w| {
            const width = std.mem.trim(u8, col_block[w.start..w.end], " \t\r\n");
            if (width.len > 0) {
                if (count > 0 and written < buf.len) {
                    buf[written] = ',';
                    written += 1;
                    if (written < buf.len) {
                        buf[written] = ' ';
                        written += 1;
                    }
                }
                const copy = @min(width.len, buf.len - written);
                @memcpy(buf[written .. written + copy], width[0..copy]);
                written += copy;
            }
        }
        count += 1;
        search_from = col_end + 1;
    }
    return .{ .count = count, .written = written };
}

/// Walk the TablixRowHierarchy's nested <TablixMembers> and emit symbols
/// for groups, visibility expressions, and the overall structure summary.
fn walkHierarchyMembers(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
    block: []const u8,
    block_base_offset: usize,
    depth: usize,
    row_index: *usize,
    summary_buf: []u8,
    summary_written: *usize,
) void {
    // Find all <TablixMember> elements in this block (not nested).
    var search_from: usize = 0;
    while (search_from <= block.len) {
        const member_start = std.mem.indexOfPos(u8, block, search_from, "<TablixMember>") orelse break;
        // Find the matching closing tag, accounting for nesting.
        const member_end = findMatchingCloseTag(block, member_start, "<TablixMember>", "</TablixMember>") orelse break;
        const member_block = block[member_start..member_end];
        const member_abs_start = block_base_offset + member_start;

        // Check for <Group Name="..."> inside this member.
        // Only check the direct content before any nested <TablixMembers>,
        // since nested children may also contain Group/Visibility elements.
        const nested_members_pos = std.mem.indexOf(u8, member_block, "<TablixMembers>");
        const direct_content = if (nested_members_pos) |np| member_block[0..np] else member_block;

        // Handle both <Group Name="X">...</Group> and <Group Name="X" /> (self-closing).
        const has_group_open = std.mem.indexOf(u8, direct_content, "<Group") != null;
        const has_group_close = std.mem.indexOf(u8, direct_content, "</Group>") != null;
        const has_group_selfclose = !has_group_close and std.mem.indexOf(u8, direct_content, "/>") != null and has_group_open;

        if (has_group_open and (has_group_close or has_group_selfclose)) {
            // Extract group name from <Group Name="...">.
            var group_name: ?[]const u8 = null;
            if (std.mem.indexOf(u8, direct_content, "<Group")) |gpos| {
                if (extractXmlAttribute(direct_content[gpos..], "Name")) |name| {
                    group_name = name;
                }
            }

            // Check for GroupExpression (only in non-self-closing groups).
            var group_expr: ?[]const u8 = null;
            if (has_group_close) {
                if (extractMultilineTag(direct_content, "<Group", "</Group>")) |g| {
                    const group_block = direct_content[g.start..g.end];
                    if (extractMultilineTag(group_block, "<GroupExpression>", "</GroupExpression>")) |ge| {
                        group_expr = std.mem.trim(u8, group_block[ge.start..ge.end], " \t\r\n");
                    }
                }
            }

            // Check for PageBreak.
            const has_page_break = std.mem.indexOf(u8, direct_content, "<PageBreak>") != null;
            var break_location: ?[]const u8 = null;
            if (has_page_break) {
                if (extractMultilineTag(direct_content, "<BreakLocation>", "</BreakLocation>")) |bl| {
                    break_location = std.mem.trim(u8, direct_content[bl.start..bl.end], " \t\r\n");
                }
            }

            // Build detail and emit symbol.
            const gname = group_name orelse "unnamed";
            var detail_buf: [512]u8 = undefined;
            var dw: usize = 0;

            // group name
            const prefix = "group ";
            @memcpy(detail_buf[0..prefix.len], prefix);
            dw += prefix.len;
            const gn_copy = @min(gname.len, detail_buf.len - dw);
            @memcpy(detail_buf[dw .. dw + gn_copy], gname[0..gn_copy]);
            dw += gn_copy;

            if (group_expr) |ge| {
                if (dw + 3 < detail_buf.len) {
                    detail_buf[dw] = ',';
                    detail_buf[dw + 1] = ' ';
                    dw += 2;
                }
                const ge_copy = @min(ge.len, detail_buf.len - dw);
                @memcpy(detail_buf[dw .. dw + ge_copy], ge[0..ge_copy]);
                dw += ge_copy;
            }

            if (has_page_break) {
                const pb_text = if (break_location) |bl| blk: {
                    break :blk bl;
                } else "Between";
                const pb_prefix = ", PageBreak ";
                if (dw + pb_prefix.len < detail_buf.len) {
                    @memcpy(detail_buf[dw .. dw + pb_prefix.len], pb_prefix);
                    dw += pb_prefix.len;
                    const pb_copy = @min(pb_text.len, detail_buf.len - dw);
                    @memcpy(detail_buf[dw .. dw + pb_copy], pb_text[0..pb_copy]);
                    dw += pb_copy;
                }
            }

            const line = offsetToLine(line_offsets, member_abs_start);
            appendSynthesizedSymbol(allocator, outline, gname, .variable, line, line, detail_buf[0..dw]);

            // Add to summary.
            const sep = if (summary_written.* > 0) ", " else "";
            addSummaryText(summary_buf, summary_written, sep);
            addSummaryText(summary_buf, summary_written, gname);
            if (has_page_break) {
                addSummaryText(summary_buf, summary_written, " [PB]");
            }
        }

        // Check for <Visibility><Hidden>...</Hidden></Visibility>.
        // Only check direct content (not nested children).
        if (extractMultilineTag(direct_content, "<Visibility>", "</Visibility>")) |v| {
            const vis_block = direct_content[v.start..v.end];
            if (extractMultilineTag(vis_block, "<Hidden>", "</Hidden>")) |h| {
                const hidden_expr = std.mem.trim(u8, vis_block[h.start..h.end], " \t\r\n");
                if (hidden_expr.len > 0) {
                    var vis_detail_buf: [256]u8 = undefined;
                    const vis_prefix = "hidden when ";
                    @memcpy(vis_detail_buf[0..vis_prefix.len], vis_prefix);
                    const he_copy = @min(hidden_expr.len, vis_detail_buf.len - vis_prefix.len);
                    @memcpy(vis_detail_buf[vis_prefix.len .. vis_prefix.len + he_copy], hidden_expr[0..he_copy]);

                    const vis_line = offsetToLine(line_offsets, member_abs_start);
                    appendSynthesizedSymbol(
                        allocator,
                        outline,
                        "visibility",
                        .variable,
                        vis_line,
                        vis_line,
                        vis_detail_buf[0 .. vis_prefix.len + he_copy],
                    );

                    // Extract RecordType value for summary (e.g. "S", "C", "T", "F").
                    if (std.mem.indexOf(u8, hidden_expr, "RecordType")) |rt_pos| {
                        if (std.mem.indexOfScalarPos(u8, hidden_expr, rt_pos, '"')) |q1| {
                            if (q1 + 2 < hidden_expr.len) {
                                if (std.mem.indexOfScalarPos(u8, hidden_expr, q1 + 1, '"')) |q2| {
                                    const rt_val = hidden_expr[q1 + 1 .. q2];
                                    addSummaryText(summary_buf, summary_written, ", RT=");
                                    addSummaryText(summary_buf, summary_written, rt_val);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Check for <KeepWithGroup> to classify as header/footer.
        if (extractMultilineTag(member_block, "<KeepWithGroup>", "</KeepWithGroup>")) |kwg| {
            const kwg_val = std.mem.trim(u8, member_block[kwg.start..kwg.end], " \t\r\n");
            if (std.mem.eql(u8, kwg_val, "After")) {
                // This is a header/separator row.
                addSummaryText(summary_buf, summary_written, if (summary_written.* > 0) ", header" else "header");
            } else if (std.mem.eql(u8, kwg_val, "Before")) {
                addSummaryText(summary_buf, summary_written, ", footer");
            }
        }

        // Recurse into nested <TablixMembers> if present.
        // Use depth-aware matching since TablixMembers can nest.
        if (findNestedBlock(member_block, "<TablixMembers>", "</TablixMembers>")) |nested_range| {
            const nested_block = member_block[nested_range.start..nested_range.end];
            const nested_abs = block_base_offset + member_start + nested_range.start;
            walkHierarchyMembers(allocator, outline, content, line_offsets, nested_block, nested_abs, depth + 1, row_index, summary_buf, summary_written);
        } else {
            // Leaf member — this corresponds to a TablixRow.
            row_index.* += 1;
        }

        search_from = member_end + 1;
    }
}

/// Find a nested block with depth-aware matching. Unlike extractMultilineTag,
/// this handles cases where the same tag type appears nested inside itself.
/// Returns the range of content between the FIRST open_tag and the MATCHING
/// close_tag (accounting for nesting depth).
fn findNestedBlock(content: []const u8, open_tag: []const u8, close_tag: []const u8) ?struct { start: usize, end: usize } {
    const open_pos = std.mem.indexOf(u8, content, open_tag) orelse return null;
    const inner_start = open_pos + open_tag.len;
    var depth: usize = 1;
    var pos = inner_start;
    while (pos < content.len) {
        // Find next open and next close from current position.
        const next_open = std.mem.indexOfPos(u8, content, pos, open_tag);
        const next_close = std.mem.indexOfPos(u8, content, pos, close_tag);
        if (next_close == null) return null; // unmatched
        if (next_open != null and next_open.? < next_close.?) {
            // Found a nested open before the next close.
            depth += 1;
            pos = next_open.? + open_tag.len;
        } else {
            // Found a close.
            depth -= 1;
            if (depth == 0) {
                return .{ .start = inner_start, .end = next_close.? };
            }
            pos = next_close.? + close_tag.len;
        }
    }
    return null;
}

/// Find the matching closing tag for an opening tag, accounting for nesting.
/// Returns the position after the closing tag.
fn findMatchingCloseTag(content: []const u8, open_pos: usize, open_tag: []const u8, close_tag: []const u8) ?usize {
    var depth: usize = 1;
    var pos = open_pos + open_tag.len;
    while (pos < content.len) {
        // Check for nested open.
        if (std.mem.indexOfPos(u8, content, pos, open_tag)) |next_open| {
            // Check for close before this open.
            var search_pos = pos;
            while (search_pos < content.len) {
                if (std.mem.indexOfPos(u8, content, search_pos, close_tag)) |next_close| {
                    if (next_close < next_open) {
                        depth -= 1;
                        if (depth == 0) return next_close + close_tag.len;
                        search_pos = next_close + close_tag.len;
                        continue;
                    }
                    break;
                }
                break;
            }
            depth += 1;
            pos = next_open + open_tag.len;
        } else {
            // No more opens — find the next close.
            if (std.mem.indexOfPos(u8, content, pos, close_tag)) |next_close| {
                depth -= 1;
                if (depth == 0) return next_close + close_tag.len;
                pos = next_close + close_tag.len;
            } else return null;
        }
    }
    return null;
}

/// Append text to the summary buffer.
fn addSummaryText(buf: []u8, written: *usize, text: []const u8) void {
    const copy = @min(text.len, buf.len - written.*);
    if (copy == 0) return;
    @memcpy(buf[written.* .. written.* + copy], text[0..copy]);
    written.* += copy;
}

/// Extract field references from TablixRows (Fields!X.Value patterns).
fn extractFieldRefsFromRows(content: []const u8, rows_range: struct { start: usize, end: usize }, buf: []u8) usize {
    const block = content[rows_range.start..rows_range.end];
    var written: usize = 0;
    var seen: [128][]const u8 = undefined;
    var seen_count: usize = 0;
    var search_from: usize = 0;
    while (search_from < block.len) {
        const field_pos = std.mem.indexOfPos(u8, block, search_from, "Fields!") orelse break;
        // Read until non-identifier char.
        var end = field_pos + 7; // skip "Fields!"
        while (end < block.len) {
            const c = block[end];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.') {
                end += 1;
            } else break;
        }
        const field_ref = block[field_pos..end];
        // Check if already seen.
        var dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, field_ref)) {
                dup = true;
                break;
            }
        }
        if (!dup and seen_count < seen.len) {
            seen[seen_count] = field_ref;
            seen_count += 1;
            if (written > 0 and written < buf.len) {
                buf[written] = ',';
                written += 1;
                if (written < buf.len) {
                    buf[written] = ' ';
                    written += 1;
                }
            }
            // Strip "Fields!" prefix for compactness.
            const short = if (field_ref.len > 7) field_ref[7..] else field_ref;
            const copy = @min(short.len, buf.len - written);
            @memcpy(buf[written .. written + copy], short[0..copy]);
            written += copy;
        }
        search_from = end;
    }
    return written;
}

/// Main entry point: extract tablix structure from an RDL file and
/// emit synthesized symbols for the hierarchy, columns, rows, and fields.
fn enrichTablixStructure(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    // Find the main <Tablix> element.
    const tablix_start = std.mem.indexOf(u8, content, "<Tablix") orelse return;
    const tablix_end = std.mem.indexOfPos(u8, content, tablix_start, "</Tablix>") orelse return;
    const tablix_block = content[tablix_start..tablix_end];

    // ── Column hierarchy ──
    var col_count: usize = 0;
    if (extractMultilineTag(tablix_block, "<TablixColumnHierarchy>", "</TablixColumnHierarchy>")) |ch| {
        const ch_block = tablix_block[ch.start..ch.end];
        col_count = countOccurrences(ch_block, "<TablixMember");
        // Extract column widths from TablixBody/TablixColumns.
        if (extractMultilineTag(tablix_block, "<TablixColumns>", "</TablixColumns>")) |tc| {
            var width_buf: [512]u8 = undefined;
            const widths = extractColumnWidths(tablix_block, .{ .start = tc.start, .end = tc.end }, &width_buf);
            var col_detail_buf: [640]u8 = undefined;
            const col_prefix = "columns=";
            @memcpy(col_detail_buf[0..col_prefix.len], col_prefix);
            var dw: usize = col_prefix.len;
            // Write column count.
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{}", .{col_count}) catch "?";
            const cs_copy = @min(count_str.len, col_detail_buf.len - dw);
            @memcpy(col_detail_buf[dw .. dw + cs_copy], count_str[0..cs_copy]);
            dw += cs_copy;
            if (widths.written > 0 and dw + 2 < col_detail_buf.len) {
                col_detail_buf[dw] = ' ';
                dw += 1;
                col_detail_buf[dw] = '(';
                dw += 1;
                const w_copy = @min(widths.written, col_detail_buf.len - dw);
                @memcpy(col_detail_buf[dw .. dw + w_copy], width_buf[0..w_copy]);
                dw += w_copy;
                if (dw < col_detail_buf.len) {
                    col_detail_buf[dw] = ')';
                    dw += 1;
                }
            }
            const col_line = offsetToLine(line_offsets, tablix_start + ch.start);
            appendSynthesizedSymbol(allocator, outline, "TablixColumnHierarchy", .variable, col_line, col_line, col_detail_buf[0..dw]);
        }
    }

    // ── Row hierarchy ──
    if (extractMultilineTag(tablix_block, "<TablixRowHierarchy>", "</TablixRowHierarchy>")) |rh| {
        const rh_block = tablix_block[rh.start..rh.end];
        const rh_abs = tablix_start + rh.start;
        var summary_buf: [512]u8 = undefined;
        var summary_written: usize = 0;
        var row_index: usize = 0;
        walkHierarchyMembers(allocator, outline, content, line_offsets, rh_block, rh_abs, 0, &row_index, &summary_buf, &summary_written);
        // Emit the summary symbol.
        const rh_line = offsetToLine(line_offsets, rh_abs);
        appendSynthesizedSymbol(allocator, outline, "TablixRowHierarchy", .variable, rh_line, rh_line, summary_buf[0..summary_written]);
    }

    // ── TablixRows — field references ──
    if (extractMultilineTag(tablix_block, "<TablixRows>", "</TablixRows>")) |tr| {
        var field_buf: [2048]u8 = undefined;
        const field_written = extractFieldRefsFromRows(tablix_block, .{ .start = tr.start, .end = tr.end }, &field_buf);
        if (field_written > 0) {
            const tr_line = offsetToLine(line_offsets, tablix_start + tr.start);
            appendSynthesizedSymbol(allocator, outline, "TablixFields", .variable, tr_line, tr_line, field_buf[0..field_written]);
        }
    }

    // ── DataSetName ──
    if (extractMultilineTag(tablix_block, "<DataSetName>", "</DataSetName>")) |dsn| {
        const dsname = std.mem.trim(u8, tablix_block[dsn.start..dsn.end], " \t\r\n");
        if (dsname.len > 0) {
            var ds_detail_buf: [128]u8 = undefined;
            const ds_prefix = "dataset=";
            @memcpy(ds_detail_buf[0..ds_prefix.len], ds_prefix);
            const ds_copy = @min(dsname.len, ds_detail_buf.len - ds_prefix.len);
            @memcpy(ds_detail_buf[ds_prefix.len .. ds_prefix.len + ds_copy], dsname[0..ds_copy]);
            const dsn_line = offsetToLine(line_offsets, tablix_start + dsn.start);
            appendSynthesizedSymbol(allocator, outline, "TablixDataSetName", .variable, dsn_line, dsn_line, ds_detail_buf[0 .. ds_prefix.len + ds_copy]);
        }
    }
}

/// Extract ReportItems! references from the PageHeader and emit them
/// as a synthesized symbol so agents can see the invisible-textbox
/// anchoring pattern without reading the page header XML.
fn enrichPageHeaderRefs(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    const ph_range = extractMultilineTag(content, "<PageHeader>", "</PageHeader>") orelse return;
    const ph_block = content[ph_range.start..ph_range.end];
    const ph_abs = ph_range.start;

    var ref_buf: [512]u8 = undefined;
    var written: usize = 0;
    var seen: [64][]const u8 = undefined;
    var seen_count: usize = 0;
    var search_from: usize = 0;
    while (search_from < ph_block.len) {
        const ref_pos = std.mem.indexOfPos(u8, ph_block, search_from, "ReportItems!") orelse break;
        // Read until non-identifier char.
        var end = ref_pos + 12; // skip "ReportItems!"
        while (end < ph_block.len) {
            const c = ph_block[end];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                end += 1;
            } else break;
        }
        const ref = ph_block[ref_pos..end];
        // Deduplicate.
        var dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, ref)) {
                dup = true;
                break;
            }
        }
        if (!dup and seen_count < seen.len) {
            seen[seen_count] = ref;
            seen_count += 1;
            if (written > 0 and written < ref_buf.len) {
                ref_buf[written] = ',';
                written += 1;
                if (written < ref_buf.len) {
                    ref_buf[written] = ' ';
                    written += 1;
                }
            }
            const copy = @min(ref.len, ref_buf.len - written);
            @memcpy(ref_buf[written .. written + copy], ref[0..copy]);
            written += copy;
        }
        search_from = end;
    }

    if (written > 0) {
        const ph_line = offsetToLine(line_offsets, ph_abs);
        appendSynthesizedSymbol(allocator, outline, "PageHeaderRefs", .variable, ph_line, ph_line, ref_buf[0..written]);
    }
}

// ── .rdl enrichment ────────────────────────────────────────────────

fn enrichRdl(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    enrichDescriptionBlock(allocator, outline, content, line_offsets);
    enrichDataSourcesAxys(allocator, outline, content, line_offsets);
    enrichCodeBlock(allocator, outline, content, line_offsets);
    enrichReportParameterBlocks(allocator, outline, content);
    enrichTablixStructure(allocator, outline, content, line_offsets);
    enrichPageHeaderRefs(allocator, outline, content, line_offsets);
}

/// Extract <Description>…</Description> across newlines and patch the
/// existing Description symbol's detail (or emit one if missing).
fn enrichDescriptionBlock(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    const range = extractMultilineTag(content, "<Description>", "</Description>") orelse return;
    const inner = content[range.start..range.end];
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len == 0) return;

    var buf: [512]u8 = undefined;
    const formatted = formatPipeDescription(trimmed, &buf);

    // Patch existing Description symbol if the line parser emitted one.
    if (findSymbolByName(outline, "Description")) |sym| {
        setSymbolDetail(allocator, sym, formatted);
        return;
    }

    // Otherwise synthesize one at the line where <Description> opens.
    const open_pos = std.mem.indexOf(u8, content, "<Description>") orelse return;
    const line = offsetToLine(line_offsets, open_pos);
    appendSynthesizedSymbol(allocator, outline, "Description", .variable, line, line, formatted);
}

/// Walk all <DataSource Name="X"> blocks. For each inline DataSource with
/// an AXYS <ConnectString>, parse the macro name + flags and (1) patch the
/// existing DataSource symbol's detail, (2) emit an axys_macro symbol so
/// `codedb_word`/`codedb_callers` can find reports using that macro.
fn enrichDataSourcesAxys(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    var search_from: usize = 0;
    while (true) {
        const open_marker = "<DataSource ";
        const open_pos = std.mem.indexOfPos(u8, content, search_from, open_marker) orelse break;
        // Must be followed by Name="…"
        const name_attr = extractXmlAttribute(content[open_pos..], "Name") orelse {
            search_from = open_pos + open_marker.len;
            continue;
        };

        // Find the end of this DataSource block (next </DataSource> after open).
        const block_close = std.mem.indexOfPos(u8, content, open_pos, "</DataSource>") orelse {
            search_from = open_pos + open_marker.len;
            continue;
        };
        const block = content[open_pos..block_close];
        search_from = block_close;

        // Skip shared references — only inline ConnectionProperties have AXYS ConnectStrings.
        if (std.mem.indexOf(u8, block, "<DataSourceReference>") != null) continue;
        const cs_range = extractMultilineTag(block, "<ConnectString>", "</ConnectString>") orelse continue;
        const cs_text = block[cs_range.start..cs_range.end];
        const trimmed_cs = std.mem.trim(u8, cs_text, " \t\r\n");
        if (trimmed_cs.len == 0) continue;

        const axys = parseAxysConnectString(trimmed_cs) orelse continue;

        // Patch the existing DataSource symbol's detail.
        if (findSymbolByName(outline, name_attr)) |sym| {
            var detail_buf: [256]u8 = undefined;
            const detail = formatAxysDetail(axys, &detail_buf);
            setSymbolDetail(allocator, sym, detail);
        }

        // Emit an axys_macro symbol so macro references are searchable.
        const ds_line = offsetToLine(line_offsets, open_pos);
        var macro_detail_buf: [128]u8 = undefined;
        const macro_detail = formatAxysFlags(axys, &macro_detail_buf);
        appendSynthesizedSymbol(
            allocator,
            outline,
            axys.macro_name,
            .constant,
            ds_line,
            ds_line,
            macro_detail,
        );
    }
}

const AxysInfo = struct {
    macro_name: []const u8, // slice into the source text
    flags: []const u8, // space-joined flags bag, slice into source text
};

/// Detect whether a ConnectString value is an AXYS REPRUN command. Returns
/// parsed AxysInfo (macro name + flags bag) or null for non-AXYS strings.
/// Slices in the returned struct point into `text` (caller-owned).
fn parseAxysConnectString(text: []const u8) ?AxysInfo {
    // AXYS markers: ".mac" extension or "REPRUN" keyword.
    const mac_pos = std.mem.indexOf(u8, text, ".mac") orelse
        (if (std.mem.indexOf(u8, text, "REPRUN") != null) @as(?usize, 0) else null) orelse return null;

    // Find macro name by walking backwards from ".mac" to a non-identifier boundary.
    var name_start: usize = if (mac_pos == 0) 0 else mac_pos;
    if (mac_pos > 0) {
        var i: usize = mac_pos;
        while (i > 0) {
            i -= 1;
            const c = text[i];
            const is_ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_' or c == '.';
            if (!is_ident) {
                name_start = i + 1;
                break;
            }
            name_start = i;
        }
    }
    const macro_name_raw = text[name_start .. mac_pos + 4]; // include ".mac"
    if (macro_name_raw.len == 4) return null; // just ".mac" alone, no name

    // Strip the leading "m_" macro flag prefix when preceded by "-" (the
    // REPRUN macro marker `-m_FILENAME.mac`). E.g. "-m_rp_test.mac" →
    // macro name "rp_test.mac".
    var macro_name = macro_name_raw;
    if (name_start >= 1 and text[name_start - 1] == '-' and
        macro_name.len >= 2 and macro_name[0] == 'm' and macro_name[1] == '_')
    {
        macro_name = macro_name[2..];
    } else if (name_start >= 1 and text[name_start - 1] == '-' and
        macro_name.len >= 1 and macro_name[0] == 'm')
    {
        // "-mFILENAME.mac" with no underscore separator.
        macro_name = macro_name[1..];
    }

    // Collect flags: scan for " -X" patterns (space-dash-letter).
    // Skip "-m" since that's the macro marker (already captured).
    // We write the joined flags back into a caller-provided pattern: scan
    // and emit into a static buffer would be unsafe across calls, so we
    // instead return a slice that points at the *first* flag's location
    // and rely on the formatter to re-scan. For simplicity we re-scan in
    // the formatter. Here we return the full text as the "flags" slice
    // and let the formatter pick out individual flag tokens.
    return .{ .macro_name = macro_name, .flags = text };
}

/// Format the AXYS detail for the parent DataSource symbol:
/// e.g. "AXYS → rp_test.mac [flags: -q -u]"
fn formatAxysDetail(info: AxysInfo, buf: []u8) []const u8 {
    var written: usize = 0;
    const prefix = "AXYS -> ";
    if (buf.len < prefix.len + info.macro_name.len) {
        return writeBuf(buf, info.macro_name);
    }
    @memcpy(buf[0..prefix.len], prefix);
    written += prefix.len;
    @memcpy(buf[written .. written + info.macro_name.len], info.macro_name);
    written += info.macro_name.len;

    // Collect flags into the remainder of the buffer.
    var flags_written: usize = 0;
    var flags_buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i + 2 < info.flags.len) : (i += 1) {
        if (info.flags[i] == ' ' and info.flags[i + 1] == '-' and i + 2 < info.flags.len) {
            // Skip the "-m" macro marker (it precedes the macro name).
            if (info.flags[i + 2] == 'm') continue;
            // Read the flag token: dash + word chars.
            var j: usize = i + 1;
            const token_start = j;
            while (j < info.flags.len) {
                const c = info.flags[j];
                if (c == ' ' or c == '"' or c == '&' or c == '\n' or c == '\r') break;
                j += 1;
            }
            const token = info.flags[token_start..j];
            if (token.len < 2) continue; // just "-"
            if (flags_written > 0 and flags_written + 1 < flags_buf.len) {
                flags_buf[flags_written] = ' ';
                flags_written += 1;
            }
            const copy = @min(token.len, flags_buf.len - flags_written);
            @memcpy(flags_buf[flags_written .. flags_written + copy], token[0..copy]);
            flags_written += copy;
            i = j;
        }
    }

    if (flags_written == 0) return buf[0..written];
    const remaining = buf.len - written;
    const sep = " [flags: ";
    if (remaining < sep.len + flags_written + 1) {
        return buf[0..written];
    }
    @memcpy(buf[written .. written + sep.len], sep);
    written += sep.len;
    @memcpy(buf[written .. written + flags_written], flags_buf[0..flags_written]);
    written += flags_written;
    if (written < buf.len) {
        buf[written] = ']';
        written += 1;
    }
    return buf[0..written];
}

/// Format the AXYS flags bag for the synthesized macro symbol's detail.
/// Returns just the flags portion (e.g. "-q -u") or "no flags" if none.
fn formatAxysFlags(info: AxysInfo, buf: []u8) []const u8 {
    var written: usize = 0;
    var i: usize = 0;
    while (i + 2 < info.flags.len) : (i += 1) {
        if (info.flags[i] == ' ' and info.flags[i + 1] == '-' and i + 2 < info.flags.len) {
            if (info.flags[i + 2] == 'm') continue; // skip macro marker
            var j: usize = i + 1;
            const token_start = j;
            while (j < info.flags.len) {
                const c = info.flags[j];
                if (c == ' ' or c == '"' or c == '&' or c == '\n' or c == '\r') break;
                j += 1;
            }
            const token = info.flags[token_start..j];
            if (token.len < 2) continue;
            if (written > 0 and written + 1 < buf.len) {
                buf[written] = ' ';
                written += 1;
            }
            const copy = @min(token.len, buf.len - written);
            @memcpy(buf[written .. written + copy], token[0..copy]);
            written += copy;
            i = j;
        }
    }
    if (written == 0) return writeBuf(buf, "axys macro");
    return buf[0..written];
}

/// Extract <Code>…</Code>, scan for VB.NET function declarations, and
/// emit each as a function symbol with an explicit body line range.
/// Body ranges are required because computeSymbolEnds (lifecycle.zig)
/// only auto-computes line_end for brace/Python/Ruby languages — SSRS
/// is none of those, so we set line_end manually here.
fn enrichCodeBlock(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    const code_range = extractMultilineTag(content, "<Code>", "</Code>") orelse return;
    const code_text = content[code_range.start..code_range.end];
    if (code_text.len == 0) return;

    // Walk lines, tracking Function/Sub start and End Function/Sub.
    var line_num: u32 = offsetToLine(line_offsets, code_range.start);
    var func_start_line: ?u32 = null;
    var func_name_buf: [128]u8 = undefined;
    var func_name_len: usize = 0;

    var line_start: usize = 0;
    while (line_start <= code_text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, code_text, line_start, '\n') orelse code_text.len;
        const raw_line = code_text[line_start..line_end];
        defer line_num += 1;
        const trimmed_line = std.mem.trim(u8, raw_line, " \t\r");

        if (func_start_line == null) {
            if (extractVbFunctionName(trimmed_line, &func_name_buf, &func_name_len)) {
                func_start_line = line_num;
            }
        } else {
            if (isVbEndDecl(trimmed_line)) {
                const name = func_name_buf[0..func_name_len];
                appendSynthesizedSymbol(
                    allocator,
                    outline,
                    name,
                    .function,
                    func_start_line.?,
                    line_num,
                    "vb.net",
                );
                // Patch line_end on the just-appended symbol (already set via append).
                func_start_line = null;
                func_name_len = 0;
            }
        }

        if (line_end == code_text.len) break;
        line_start = line_end + 1;
        line_num += 1;
    }
}

/// Match a VB.NET function or sub declaration line (after stripping
/// optional modifiers). Writes the captured name into `out_buf`/`out_len`
/// and returns true on match.
fn extractVbFunctionName(line: []const u8, out_buf: *[128]u8, out_len: *usize) bool {
    // Skip optional leading modifiers.
    const modifiers = [_][]const u8{
        "Public ", "Private ", "Protected ", "Friend ",
        "Shared ", "Static ", "Overridable ", "Overloads ",
        "Overrides ", "Overridable ",
    };
    var rest = line;
    var changed = true;
    while (changed) {
        changed = false;
        for (modifiers) |mod| {
            if (rest.len > mod.len and std.mem.startsWith(u8, rest, mod)) {
                rest = rest[mod.len..];
                changed = true;
                break;
            }
        }
    }

    // Match "Function NAME(" or "Sub NAME(" (or end-of-line).
    const decls = [_][]const u8{ "Function ", "Sub " };
    for (decls) |decl| {
        if (std.mem.startsWith(u8, rest, decl)) {
            const after = rest[decl.len..];
            // Read identifier chars.
            var name_len: usize = 0;
            for (after) |c| {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or c == '_')
                {
                    if (name_len < out_buf.len) {
                        out_buf[name_len] = c;
                        name_len += 1;
                    }
                } else break;
            }
            if (name_len > 0) {
                out_len.* = name_len;
                return true;
            }
        }
    }
    return false;
}

/// True if line is a VB.NET end declaration: "End Function" or "End Sub".
fn isVbEndDecl(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "End Function")) return true;
    if (std.mem.startsWith(u8, trimmed, "End Sub")) return true;
    return false;
}

/// Walk <ReportParameter Name="X"> blocks. Extract children (DataType,
/// Hidden, DefaultValue, Prompt) and patch the existing parameter symbol's
/// detail to a structured summary like "String, hidden, default=Today()".
fn enrichReportParameterBlocks(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
) void {
    var search_from: usize = 0;
    while (true) {
        const open_marker = "<ReportParameter ";
        const open_pos = std.mem.indexOfPos(u8, content, search_from, open_marker) orelse break;
        const name_attr = extractXmlAttribute(content[open_pos..], "Name") orelse {
            search_from = open_pos + open_marker.len;
            continue;
        };
        const block_close = std.mem.indexOfPos(u8, content, open_pos, "</ReportParameter>") orelse {
            search_from = open_pos + open_marker.len;
            continue;
        };
        const block = content[open_pos..block_close];
        search_from = block_close;

        // Extract children.
        var data_type: ?[]const u8 = null;
        if (extractMultilineTag(block, "<DataType>", "</DataType>")) |r| {
            data_type = std.mem.trim(u8, block[r.start..r.end], " \t\r\n");
        }
        const hidden = std.mem.indexOf(u8, block, "<Hidden>") != null;
        var default_value: ?[]const u8 = null;
        if (extractMultilineTag(block, "<DefaultValue>", "</DefaultValue>")) |r| {
            // DefaultValue contains children like <Values><Value>=expr</Value></Values>.
            const inner = block[r.start..r.end];
            if (extractMultilineTag(inner, "<Value>", "</Value>")) |vr| {
                default_value = std.mem.trim(u8, inner[vr.start..vr.end], " \t\r\n");
            }
        }
        var prompt: ?[]const u8 = null;
        if (extractMultilineTag(block, "<Prompt>", "</Prompt>")) |r| {
            prompt = std.mem.trim(u8, block[r.start..r.end], " \t\r\n");
        }

        // Build detail string.
        var detail_buf: [256]u8 = undefined;
        const detail = formatParameterDetail(data_type, hidden, default_value, prompt, &detail_buf);

        // Patch existing parameter symbol.
        if (findSymbolByName(outline, name_attr)) |sym| {
            setSymbolDetail(allocator, sym, detail);
        }
    }
}

/// Format a structured detail for a report parameter:
/// "String, hidden, default=Today()" (each segment omitted if absent).
fn formatParameterDetail(
    data_type: ?[]const u8,
    hidden: bool,
    default_value: ?[]const u8,
    prompt: ?[]const u8,
    buf: []u8,
) []const u8 {
    var written: usize = 0;
    if (data_type) |dt| {
        const copy = @min(dt.len, buf.len - written);
        @memcpy(buf[written .. written + copy], dt[0..copy]);
        written += copy;
    }
    if (hidden) {
        if (written > 0 and written + 2 < buf.len) {
            buf[written] = ',';
            buf[written + 1] = ' ';
            written += 2;
        }
        const h = "hidden";
        const copy = @min(h.len, buf.len - written);
        @memcpy(buf[written .. written + copy], h[0..copy]);
        written += copy;
    }
    if (default_value) |dv| {
        if (written > 0 and written + 9 < buf.len) {
            buf[written] = ',';
            buf[written + 1] = ' ';
            written += 2;
        }
        const prefix = "default=";
        const remaining = buf.len - written;
        if (remaining > prefix.len) {
            @memcpy(buf[written .. written + prefix.len], prefix);
            written += prefix.len;
            const dv_copy = @min(dv.len, buf.len - written);
            @memcpy(buf[written .. written + dv_copy], dv[0..dv_copy]);
            written += dv_copy;
        }
    }
    if (prompt) |p| {
        if (written > 0 and written + 9 < buf.len) {
            buf[written] = ',';
            buf[written + 1] = ' ';
            written += 2;
        }
        const prefix = "prompt=\"";
        const remaining = buf.len - written;
        if (remaining > prefix.len + 1) {
            @memcpy(buf[written .. written + prefix.len], prefix);
            written += prefix.len;
            const p_copy = @min(p.len, buf.len - written - 1);
            @memcpy(buf[written .. written + p_copy], p[0..p_copy]);
            written += p_copy;
            buf[written] = '"';
            written += 1;
        }
    }
    return buf[0..written];
}

// ── .rsd enrichment ────────────────────────────────────────────────

fn enrichRsd(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
) void {
    // .rsd files don't have <Code> blocks or AXYS data sources, but they
    // may contain a Description-like comment and QueryParameters. For now
    // we apply only the QueryParameter enrichment (parallel to ReportParameter).
    enrichSharedDatasetParameters(allocator, outline, content);
}

/// Patch shared-dataset QueryParameter details with their default values.
fn enrichSharedDatasetParameters(allocator: std.mem.Allocator, outline: *FileOutline, content: []const u8) void {
    var search_from: usize = 0;
    while (true) {
        const open_marker = "<QueryParameter ";
        const open_pos = std.mem.indexOfPos(u8, content, search_from, open_marker) orelse break;
        const name_attr = extractXmlAttribute(content[open_pos..], "Name") orelse {
            search_from = open_pos + open_marker.len;
            continue;
        };
        const block_close = std.mem.indexOfPos(u8, content, open_pos, "</QueryParameter>") orelse {
            // Self-closing or malformed: skip — we can't reliably extract children.
            search_from = open_pos + open_marker.len;
            continue;
        };
        const block = content[open_pos..block_close];
        search_from = block_close;

        var default_value: ?[]const u8 = null;
        if (extractMultilineTag(block, "<Value>", "</Value>")) |r| {
            default_value = std.mem.trim(u8, block[r.start..r.end], " \t\r\n");
        }

        if (default_value) |dv| {
            if (findSymbolByName(outline, name_attr)) |sym| {
                var buf: [128]u8 = undefined;
                const prefix = "default=";
                if (buf.len > prefix.len + dv.len) {
                    @memcpy(buf[0..prefix.len], prefix);
                    const dv_copy = @min(dv.len, buf.len - prefix.len);
                    @memcpy(buf[prefix.len .. prefix.len + dv_copy], dv[0..dv_copy]);
                    setSymbolDetail(allocator, sym, buf[0 .. prefix.len + dv_copy]);
                }
            }
        }
    }
}

// ── .rds enrichment ────────────────────────────────────────────────

fn enrichRdsPost(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    content: []const u8,
    line_offsets: []const usize,
) void {
    // Parse the multiline <ConnectString> if present and patch the existing
    // ConnectString symbol's detail with server/database info.
    const range = extractMultilineTag(content, "<ConnectString>", "</ConnectString>") orelse return;
    const inner = content[range.start..range.end];
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len == 0) return;

    var buf: [256]u8 = undefined;
    const detail = formatSqlServerConnString(trimmed, &buf);

    // Patch existing ConnectString symbol. We can't easily distinguish it
    // from the datasource-name symbol in the outline (both are .variable),
    // so we match by the symbol whose name *is* the connection string text.
    // The line parser emitted the symbol with name == trimmed (single-line)
    // or partial (multi-line). For multi-line, we patch the symbol whose
    // name is a prefix of trimmed.
    for (outline.symbols.items) |*sym| {
        if (sym.kind != .variable) continue;
        if (std.mem.indexOf(u8, trimmed, sym.name) != null and sym.name.len > 0) {
            setSymbolDetail(allocator, sym, detail);
            return;
        }
    }
    // If no match, synthesize one at the line where <ConnectString> opens.
    const open_pos = std.mem.indexOf(u8, content, "<ConnectString>") orelse return;
    const line = offsetToLine(line_offsets, open_pos);
    appendSynthesizedSymbol(allocator, outline, "ConnectString", .variable, line, line, detail);
}

/// Parse a SQL Server connection string for `Data Source=` and
/// `Initial Catalog=` values. Returns a compact summary.
fn formatSqlServerConnString(text: []const u8, buf: []u8) []const u8 {
    var written: usize = 0;
    const segs: [2]struct { key: []const u8, label: []const u8 } = .{
        .{ .key = "Data Source=", .label = "server=" },
        .{ .key = "Initial Catalog=", .label = " db=" },
    };
    for (segs) |seg| {
        if (std.mem.indexOf(u8, text, seg.key)) |pos| {
            const val_start = pos + seg.key.len;
            const val_end = std.mem.indexOfScalarPos(u8, text, val_start, ';') orelse text.len;
            const val = text[val_start..val_end];
            if (written > 0) {
                if (written < buf.len) {
                    buf[written] = ' ';
                    written += 1;
                }
            }
            // Only write the label (no leading space for first segment).
            const label = if (written == 0) seg.label[0..seg.label.len] else seg.label;
            const l_copy = @min(label.len, buf.len - written);
            @memcpy(buf[written .. written + l_copy], label[0..l_copy]);
            written += l_copy;
            const v_copy = @min(val.len, buf.len - written);
            @memcpy(buf[written .. written + v_copy], val[0..v_copy]);
            written += v_copy;
        }
    }
    if (written == 0) return writeBuf(buf, text);
    return buf[0..written];
}
