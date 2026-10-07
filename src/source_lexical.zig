//! Conservative lexical masking for navigation heuristics (not compiler binding).
const std = @import("std");
const Language = @import("explore/types.zig").Language;

pub fn mask(alloc: std.mem.Allocator, source: []const u8, lang: Language) ![]u8 {
    if (lang == .javascript or lang == .typescript) return @import("javascript_parser.zig").codeMask(alloc, source);
    const out = try alloc.dupe(u8, source);
    var i: usize = 0;
    while (i < source.len) {
        const start = i;
        if (std.mem.startsWith(u8, source[i..], "/*") or (lang == .f_sharp and std.mem.startsWith(u8, source[i..], "(*"))) {
            const fs = source[i] == '(';
            i += 2;
            var depth: usize = 1;
            while (i < source.len and depth > 0) {
                if (fs and std.mem.startsWith(u8, source[i..], "(*")) { depth += 1; i += 2; }
                else if (std.mem.startsWith(u8, source[i..], if (fs) "*)" else "*/")) { depth -= 1; i += 2; }
                else i += 1;
            }
        } else if (std.mem.startsWith(u8, source[i..], "//") or
            ((lang == .sql or lang == .mdx or lang == .dax) and std.mem.startsWith(u8, source[i..], "--")) or
            ((lang == .python or lang == .ruby or lang == .shell) and source[i] == '#')) {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else if (source[i] == '"' or source[i] == '\'' or source[i] == '`') {
            // F# type parameters ('T) are identifiers, not string literals.
            if (lang == .f_sharp and source[i] == '\'' and i + 2 < source.len and std.ascii.isAlphabetic(source[i + 1]) and source[i + 2] != '\'') { i += 1; continue; }
            const quote = source[i];
            const triple = i + 2 < source.len and source[i + 1] == quote and source[i + 2] == quote;
            const verbatim = i > 0 and source[i - 1] == '@';
            i += if (triple) @as(usize, 3) else 1;
            while (i < source.len) {
                if (!verbatim and source[i] == '\\') { i += @min(@as(usize, 2), source.len - i); continue; }
                if (source[i] == quote) {
                    if (triple) {
                        if (i + 2 < source.len and source[i + 1] == quote and source[i + 2] == quote) { i += 3; break; }
                    } else {
                        i += 1;
                        if (verbatim and i < source.len and source[i] == quote) { i += 1; continue; }
                        break;
                    }
                }
                i += 1;
            }
        } else { i += 1; continue; }
        for (out[start..i]) |*ch| if (ch.* != '\n') { ch.* = ' '; };
    }
    return out;
}

test "lexical masking preserves calls after multiline comments and literals" {
    const a = std.testing.allocator;
    const code = try mask(a, "/*\nfake();\n*/ real(); const s = `fake()`; const r = /fake()/; real();", .typescript);
    defer a.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "fake") == null);
    try std.testing.expect(std.mem.count(u8, code, "real") == 2);
    const fs = try mask(a, "(* outer (* fake x *) fake x *) let r = f<int> x |> g", .f_sharp);
    defer a.free(fs);
    try std.testing.expect(std.mem.indexOf(u8, fs, "fake") == null);
    try std.testing.expect(std.mem.indexOf(u8, fs, "f<int>") != null);
}
