const std = @import("std");

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
