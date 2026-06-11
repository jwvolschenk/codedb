const std = @import("std");

/// Autumn-specific symbol kinds for .adm, .acfg, .adpt, .arc files.
pub const Kind = enum {
    entity_schema, // .adm: <entitySchema>
    entity, // .adm: <entity>
    entity_attribute, // .adm: <entityAttribute>
    domain_definition, // .adm: <domainListDefinition>
    configuration, // .acfg: <configuration>
    database_catalog, // .acfg: <databaseCatalog>
    message_queue, // .acfg: <messageQueueCatalog>
    component, // .adpt: <component>
    transition, // .adpt: <transition>
    terminate, // .adpt: <terminate>
    rule_set, // .arc: <ruleSet>
    rule_reference, // .arc: <ruleReference>
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
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

// ── .adm (Autumn Data Model) ──────────────────────────────────────────

pub fn parseAdmLine(line: []const u8) ParsedLine {
    // <entitySchema isSystemEntity="True" entitySchemaName="Audit" />
    if (std.mem.indexOf(u8, line, "<entitySchema ") != null) {
        const name = extractXmlAttribute(line, "entitySchemaName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .entity_schema } };
    }

    // <entity schema="SCH|Audit" entityName="CommandLog" entityTypeId="Table" ...>
    if (std.mem.indexOf(u8, line, "<entity ") != null and
        std.mem.indexOf(u8, line, "<entityAttributes") == null and
        std.mem.indexOf(u8, line, "<entityAttribute ") == null)
    {
        const name = extractXmlAttribute(line, "entityName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .entity } };
    }

    // <entityAttribute ... entityAttributeName="ID" attributeTypeId="INT" isPrimaryKey="True" ...>
    if (std.mem.indexOf(u8, line, "<entityAttribute ") != null) {
        const name = extractXmlAttribute(line, "entityAttributeName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .entity_attribute } };
    }

    // <domainListDefinition domainType="Standard" description="..." name="Rule Type" isSystemEntity="True" value="12">
    if (std.mem.indexOf(u8, line, "<domainListDefinition ") != null) {
        const name = extractXmlAttribute(line, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .domain_definition } };
    }

    return .none;
}

// ── .acfg (Autumn Configuration) ──────────────────────────────────────

pub fn parseAcfgLine(line: []const u8) ParsedLine {
    // <configuration configurationName="Debug">
    if (std.mem.indexOf(u8, line, "<configuration ") != null and
        std.mem.indexOf(u8, line, "configurationName") != null)
    {
        const name = extractXmlAttribute(line, "configurationName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .configuration } };
    }

    // <databaseCatalog ... key="AutumnDotNet" ...>
    if (std.mem.indexOf(u8, line, "<databaseCatalog ") != null) {
        const name = extractXmlAttribute(line, "key") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .database_catalog } };
    }

    // <messageQueueCatalog ... messageQueueName="..." messageQueueType="...">
    if (std.mem.indexOf(u8, line, "<messageQueueCatalog ") != null and
        std.mem.indexOf(u8, line, "messageQueueCatalogSetting") == null)
    {
        const name = extractXmlAttribute(line, "messageQueueName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .message_queue } };
    }

    return .none;
}

// ── .adpt (Autumn Adapter) ────────────────────────────────────────────

pub fn parseAdptLine(line: []const u8) ParsedLine {
    // <component ... stateName="BcpTableToWork" name="BcpTableToWork" componentType="1" ...>
    if (std.mem.indexOf(u8, line, "<component ") != null and
        std.mem.indexOf(u8, line, "stateName") != null)
    {
        const name = extractXmlAttribute(line, "stateName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .component } };
    }

    // <transition toState="Create Process" />
    // <transition toState="Email Error" condition="ERROR-COUNT != 0" />
    if (std.mem.indexOf(u8, line, "<transition ") != null) {
        const to_state = extractXmlAttribute(line, "toState") orelse return .none;
        return .{ .symbol = .{ .name = to_state, .kind = .transition } };
    }

    // <terminate isError="true" name="Failure" />
    // <terminate isError="false" name="Done" />
    if (std.mem.indexOf(u8, line, "<terminate ") != null) {
        const name = extractXmlAttribute(line, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .terminate } };
    }

    return .none;
}

// ── .arc (Autumn Rule Collection) ─────────────────────────────────────

pub fn parseArcLine(line: []const u8) ParsedLine {
    // <ruleSet ... ruleSetName="AxysEtlToAutumn" ruleSetDescription="..." ...>
    if (std.mem.indexOf(u8, line, "<ruleSet ") != null and
        std.mem.indexOf(u8, line, "ruleSetName") != null)
    {
        const name = extractXmlAttribute(line, "ruleSetName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .rule_set } };
    }

    // <ruleReference entityRule="RUL|MapAxysTransactions" ruleOrder="1" ruleName="MapAxysTransactions" />
    if (std.mem.indexOf(u8, line, "<ruleReference ") != null) {
        const name = extractXmlAttribute(line, "ruleName") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .rule_reference } };
    }

    return .none;
}

// ── Detail extraction (called from explore.zig) ───────────────────────

/// Build a structured detail string from the raw XML line and symbol kind.
/// Caller provides the output buffer. Returns the populated slice.
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    switch (kind) {
        .entity => {
            // Extract entityTypeId + schema
            var len: usize = 0;
            if (extractXmlAttribute(line, "entityTypeId")) |t| {
                const copy = @min(t.len, buf.len);
                @memcpy(buf[0..copy], t[0..copy]);
                len = copy;
            }
            if (extractXmlAttribute(line, "schema")) |s| {
                const clean = if (std.mem.startsWith(u8, s, "SCH|")) s[4..] else s;
                if (len > 0 and len < buf.len) {
                    buf[len] = ' ';
                    len += 1;
                }
                const space = @min(clean.len, buf.len - len);
                @memcpy(buf[len .. len + space], clean[0..space]);
                len += space;
            }
            if (extractXmlAttribute(line, "isTemporal")) |t| {
                if (std.mem.eql(u8, t, "True")) {
                    const suffix = " temporal";
                    if (len + suffix.len <= buf.len) {
                        @memcpy(buf[len .. len + suffix.len], suffix);
                        len += suffix.len;
                    }
                }
            }
            return buf[0..len];
        },
        .entity_attribute => {
            var len: usize = 0;
            if (extractXmlAttribute(line, "attributeTypeId")) |t| {
                const copy = @min(t.len, buf.len);
                @memcpy(buf[0..copy], t[0..copy]);
                len = copy;
            }
            if (extractXmlAttribute(line, "isPrimaryKey")) |pk| {
                if (std.mem.eql(u8, pk, "True")) {
                    const suffix = " PK";
                    if (len + suffix.len <= buf.len) {
                        @memcpy(buf[len .. len + suffix.len], suffix);
                        len += suffix.len;
                    }
                }
            }
            if (extractXmlAttribute(line, "isNullable")) |n| {
                if (std.mem.eql(u8, n, "False")) {
                    const suffix = " NOT NULL";
                    if (len + suffix.len <= buf.len) {
                        @memcpy(buf[len .. len + suffix.len], suffix);
                        len += suffix.len;
                    }
                }
            }
            return buf[0..len];
        },
        .domain_definition => {
            var len: usize = 0;
            if (extractXmlAttribute(line, "domainType")) |t| {
                const copy = @min(t.len, buf.len);
                @memcpy(buf[0..copy], t[0..copy]);
                len = copy;
            }
            if (extractXmlAttribute(line, "value")) |v| {
                if (len > 0 and len < buf.len) {
                    buf[len] = ' ';
                    len += 1;
                }
                const space = @min(v.len, buf.len - len);
                @memcpy(buf[len .. len + space], v[0..space]);
                len += space;
            }
            return buf[0..len];
        },
        .entity_schema => {
            if (extractXmlAttribute(line, "isSystemEntity")) |sys| {
                const prefix = "isSystem=";
                if (prefix.len + sys.len <= buf.len) {
                    @memcpy(buf[0..prefix.len], prefix);
                    @memcpy(buf[prefix.len .. prefix.len + sys.len], sys);
                    return buf[0 .. prefix.len + sys.len];
                }
            }
            return "";
        },
        .database_catalog => {
            var len: usize = 0;
            if (extractXmlAttribute(line, "server")) |s| {
                const copy = @min(s.len, buf.len);
                @memcpy(buf[0..copy], s[0..copy]);
                len = copy;
            }
            if (extractXmlAttribute(line, "database")) |d| {
                if (len > 0 and len < buf.len) {
                    buf[len] = '/';
                    len += 1;
                }
                const space = @min(d.len, buf.len - len);
                @memcpy(buf[len .. len + space], d[0..space]);
                len += space;
            }
            return buf[0..len];
        },
        .message_queue => {
            if (extractXmlAttribute(line, "messageQueueType")) |t| {
                const copy = @min(t.len, buf.len);
                @memcpy(buf[0..copy], t[0..copy]);
                return buf[0..copy];
            }
            return "";
        },
        .component => {
            var len: usize = 0;
            if (extractXmlAttribute(line, "componentType")) |t| {
                const type_name = componentTypeName(t) orelse t;
                const copy = @min(type_name.len, buf.len);
                @memcpy(buf[0..copy], type_name[0..copy]);
                len = copy;
            }
            if (extractXmlAttribute(line, "isBranchCondition")) |b| {
                if (std.mem.eql(u8, b, "true")) {
                    const suffix = " branch";
                    if (len + suffix.len <= buf.len) {
                        @memcpy(buf[len .. len + suffix.len], suffix);
                        len += suffix.len;
                    }
                }
            }
            return buf[0..len];
        },
        .transition => {
            var len: usize = 0;
            const prefix = "-> ";
            @memcpy(buf[0..prefix.len], prefix);
            len = prefix.len;
            if (extractXmlAttribute(line, "toState")) |ts| {
                const copy = @min(ts.len, buf.len - len);
                @memcpy(buf[len .. len + copy], ts[0..copy]);
                len += copy;
            }
            if (extractXmlAttribute(line, "condition")) |c| {
                const cond_prefix = " when ";
                if (len + cond_prefix.len + c.len <= buf.len) {
                    @memcpy(buf[len .. len + cond_prefix.len], cond_prefix);
                    len += cond_prefix.len;
                    @memcpy(buf[len .. len + c.len], c);
                    len += c.len;
                }
            }
            return buf[0..len];
        },
        .terminate => {
            if (extractXmlAttribute(line, "isError")) |e| {
                if (std.mem.eql(u8, e, "true")) {
                    const s = "error";
                    @memcpy(buf[0..s.len], s);
                    return buf[0..s.len];
                } else {
                    const s = "success";
                    @memcpy(buf[0..s.len], s);
                    return buf[0..s.len];
                }
            }
            return "";
        },
        .rule_set => {
            if (extractXmlAttribute(line, "ruleSetDescription")) |d| {
                const max_len: usize = 120;
                const copy = @min(d.len, max_len);
                @memcpy(buf[0..copy], d[0..copy]);
                if (d.len > max_len) {
                    const ellipsis = "...";
                    if (copy + ellipsis.len <= buf.len) {
                        @memcpy(buf[copy .. copy + ellipsis.len], ellipsis);
                        return buf[0 .. copy + ellipsis.len];
                    }
                }
                return buf[0..copy];
            }
            return "";
        },
        .rule_reference => {
            var len: usize = 0;
            if (extractXmlAttribute(line, "ruleOrder")) |o| {
                const prefix = "order=";
                @memcpy(buf[0..prefix.len], prefix);
                len = prefix.len;
                const copy = @min(o.len, buf.len - len);
                @memcpy(buf[len .. len + copy], o[0..copy]);
                len += copy;
            }
            return buf[0..len];
        },
        .configuration => return "",
    }
}

/// Map componentType numeric ID to a human-readable name.
fn componentTypeName(type_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, type_id, "1")) return "SQL";
    if (std.mem.eql(u8, type_id, "2")) return "ErrorTrap";
    if (std.mem.eql(u8, type_id, "4")) return "FileListener";
    if (std.mem.eql(u8, type_id, "5")) return "OAuth";
    return null;
}
