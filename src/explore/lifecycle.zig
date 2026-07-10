const std = @import("std");
const Explorer = @import("../explore.zig").Explorer;
const FileOutline = @import("../explore.zig").FileOutline;
const Language = @import("../explore.zig").Language;
const Symbol = @import("../explore.zig").Symbol;
const SymbolKind = @import("../explore.zig").SymbolKind;
const PhpParseState = @import("../explore.zig").PhpParseState;
const ParsedFile = @import("../explore.zig").ParsedFile;
const idx = @import("../index.zig");
const WordIndex = idx.WordIndex;
const SparseNgramIndex = idx.SparseNgramIndex;
const csharp_parser = @import("../csharp_parser.zig");
const fsharp_parser = @import("../fsharp_parser.zig");
const autumn_parser = @import("../autumn_parser.zig");
const t4_parser = @import("../t4_parser.zig");
const tsql_parser = @import("../tsql_parser.zig");
const ssrs_parser = @import("../ssrs_parser.zig");
const godot_parser = @import("../godot_parser.zig");
const parse_utils = @import("parse_utils.zig");
const skip_rules = @import("../watcher/skip_rules.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendImportSymbol = parse_utils.appendImportSymbol;
const extractStringLiteral = parse_utils.extractStringLiteral;

pub fn releaseContents(self: *Explorer) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.contents.clear();
}

pub fn releaseSecondaryIndexes(self: *Explorer) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.sparse_ngram_index.deinit();
    self.sparse_ngram_index = SparseNgramIndex.init(self.allocator);
}

pub fn indexFile(self: *Explorer, path: []const u8, content: []const u8) !void {
    return self.indexFileInner(path, content, true, false);
}

/// Fast path: index outline + content storage only, skip word/trigram indexes.
pub fn indexFileOutlineOnly(self: *Explorer, path: []const u8, content: []const u8) !void {
    return self.indexFileInner(path, content, false, false);
}

/// Index outline + word index but skip trigram construction (used when trigram is loaded from disk cache).
pub fn indexFileSkipTrigram(self: *Explorer, path: []const u8, content: []const u8) !void {
    return self.indexFileInner(path, content, true, true);
}

pub fn commitParsedFileOwnedOutline(self: *Explorer, path: []const u8, content: []const u8, outline: FileOutline, full_index: bool, skip_trigram: bool) !void {
    var owned_outline = outline;
    // #594: one deinit only. Stacking an errdefer here with the defer below
    // would double-free the parsed outline (every symbol name) on any post-
    // clone error. Clean up owned_outline by hand on the clone-failure path.
    var persistent_outline = cloneOutline(&owned_outline, self.allocator) catch |err| {
        owned_outline.deinit();
        return err;
    };
    defer owned_outline.deinit();
    errdefer persistent_outline.deinit();
    if (persistent_outline.owns_path) {
        self.allocator.free(persistent_outline.path);
        persistent_outline.owns_path = false;
    }

    self.mu.lock();
    defer self.mu.unlock();

    const outline_gop = try self.outlines.getOrPut(path);
    const is_new = !outline_gop.found_existing;
    var prior_outline: ?FileOutline = if (outline_gop.found_existing)
        outline_gop.value_ptr.*
    else
        null;
    const stable_path = if (outline_gop.found_existing) blk: {
        break :blk outline_gop.key_ptr.*;
    } else blk: {
        const duped = try self.allocator.dupe(u8, path);
        outline_gop.key_ptr.* = duped;
        break :blk duped;
    };
    errdefer if (is_new) {
        _ = self.outlines.remove(stable_path);
        self.allocator.free(stable_path);
    };

    persistent_outline.path = stable_path;

    try self.contents.put(stable_path, content);
    const prior_content: ?[]const u8 = null;

    if (full_index) {
        if (!self.word_index_complete) {
            self.word_index_can_load_from_disk = false;
        }
        try self.word_index.indexFile(stable_path, content);
        // If trigram indexing fails below, restore word_index to its previous state
        // to prevent word_index and trigram_index from diverging.
        errdefer if (prior_content) |old| {
            self.word_index.indexFile(stable_path, old) catch {};
        } else {
            self.word_index.removeFile(stable_path);
        };
        if (self.word_index_complete) {
            self.word_index_generation +%= 1;
        }
        if (!skip_trigram) {
            try self.trigram_index.indexFile(stable_path, content);
            try self.sparse_ngram_index.indexFile(stable_path, content);
            _ = self.skip_trigram_files.remove(stable_path);
        } else {
            self.trigram_index.removeFile(stable_path);
            self.sparse_ngram_index.removeFile(stable_path);
            try self.skip_trigram_files.put(stable_path, {});
        }
    }

    try self.rebuildDepsFor(stable_path, &persistent_outline);
    self.rebuildSymbolIndexFor(stable_path, &persistent_outline);
    self.type_index.indexFileSymbols(stable_path, persistent_outline.symbols.items) catch {};
    self.buildTypeGraphForFile(stable_path, &persistent_outline);

    outline_gop.value_ptr.* = persistent_outline;
    if (prior_outline) |*old_outline| old_outline.deinit();
}

pub fn computeSymbolEnds(content: []const u8, outline: *FileOutline) void {
    if (outline.symbols.items.len == 0) return;

    // Build a line offset table for O(1) line lookups
    var line_offsets: std.ArrayList(usize) = .empty;
    defer line_offsets.deinit(outline.allocator);
    line_offsets.append(outline.allocator, 0) catch return; // line 1 starts at offset 0
    for (content, 0..) |c, i| {
        if (c == '\n' and i + 1 <= content.len) {
            line_offsets.append(outline.allocator, i + 1) catch return;
        }
    }
    const total_lines: u32 = @intCast(line_offsets.items.len);

    const is_brace_lang = outline.language == .zig or outline.language == .c or
        outline.language == .cpp or outline.language == .typescript or
        outline.language == .javascript or outline.language == .rust or
        outline.language == .go_lang or outline.language == .php or
        outline.language == .dart or outline.language == .java or outline.language == .c_sharp or
        outline.language == .kotlin or outline.language == .svelte or
        outline.language == .vue or outline.language == .astro or
        outline.language == .css or outline.language == .scss or
        outline.language == .protobuf or outline.language == .mlir or
        outline.language == .tablegen or outline.language == .razor;

    for (outline.symbols.items) |*sym| {
        // Skip single-line kinds
        switch (sym.kind) {
            .import, .variable, .constant, .comment_block, .type_alias, .macro_def => continue,
            else => {},
        }

        if (sym.line_start == 0 or sym.line_start > total_lines) continue;

        if (is_brace_lang) {
            sym.line_end = findBraceEnd(content, line_offsets.items, sym.line_start, total_lines, outline.language);
        } else if (outline.language == .python) {
            sym.line_end = findPythonEnd(content, line_offsets.items, sym.line_start, total_lines);
        } else if (outline.language == .ruby) {
            sym.line_end = findRubyEnd(content, line_offsets.items, sym.line_start, total_lines);
        }
    }
}

pub fn findBraceEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32, language: Language) u32 {
    const start_idx = line_offsets[line_start - 1];
    var depth: i32 = 0;
    var found_open = false;
    var in_string: u8 = 0; // 0=none, '"', '\''
    var in_verbatim_string = false;
    var csharp_raw_string_quotes: usize = 0;
    var in_triple_quote: u8 = 0; // 0=none, '"', '\''
    var interp_depth: i32 = 0;
    var in_line_comment = false;
    var in_block_comment = false;
    var i = start_idx;
    var current_line = line_start;

    while (i < content.len) : (i += 1) {
        const c = content[i];

        if (c == '\n') {
            current_line += 1;
            in_line_comment = false;
            // Multiline C# constructors and methods commonly have long DI
            // parameter lists. Keep the tighter cap for other brace languages.
            const brace_search_lines: u32 = if (language == .c_sharp) 128 else 10;
            if (!found_open and current_line > line_start + brace_search_lines) return line_start;
            continue;
        }

        if (in_line_comment) continue;

        if (in_block_comment) {
            if (c == '*' and i + 1 < content.len and content[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }

        if (csharp_raw_string_quotes != 0) {
            if (c == '"') {
                if (csharp_parser.rawStringDelimiterLength(content, i)) |count| {
                    if (count >= csharp_raw_string_quotes) {
                        i += csharp_raw_string_quotes - 1;
                        csharp_raw_string_quotes = 0;
                    }
                }
            }
            continue;
        }

        if (in_triple_quote != 0) {
            if (c == in_triple_quote and i + 2 < content.len and
                content[i + 1] == in_triple_quote and content[i + 2] == in_triple_quote)
            {
                in_triple_quote = 0;
                i += 2;
            }
            continue;
        }

        if (in_string != 0) {
            if (in_verbatim_string and c == in_string and i + 1 < content.len and content[i + 1] == in_string) {
                i += 1;
            } else if (!in_verbatim_string and c == '\\') {
                i += 1;
            } else if (language == .dart and interp_depth > 0) {
                if (c == '{') {
                    interp_depth += 1;
                } else if (c == '}') {
                    interp_depth -= 1;
                    if (interp_depth == 0) continue;
                }
            } else if (c == in_string) {
                in_string = 0;
                in_verbatim_string = false;
            } else if (language == .dart and c == '$' and i + 1 < content.len and content[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            }
            continue;
        }

        // Check for comments
        if (c == '/' and i + 1 < content.len) {
            if (content[i + 1] == '/') {
                in_line_comment = true;
                continue;
            } else if (content[i + 1] == '*') {
                in_block_comment = true;
                i += 1;
                continue;
            }
        }

        // Check for triple-quoted strings (Dart: ''' or """)
        if (language == .dart and (c == '"' or c == '\'')) {
            if (i + 2 < content.len and content[i + 1] == c and content[i + 2] == c) {
                in_triple_quote = c;
                i += 2;
                continue;
            }
        }

        if (language == .c_sharp and c == '"') {
            if (csharp_parser.rawStringDelimiterLength(content, i)) |count| {
                csharp_raw_string_quotes = count;
                i += count - 1;
                continue;
            }
        }

        // Check for strings
        if (c == '"' or c == '\'') {
            in_string = c;
            in_verbatim_string = language == .c_sharp and c == '"' and csharp_parser.isVerbatimStringStart(content, i);
            continue;
        }

        if (c == '{') {
            depth += 1;
            found_open = true;
        } else if (c == '}') {
            depth -= 1;
            if (found_open and depth == 0) {
                return @min(current_line, total_lines);
            }
        }
    }

    return if (found_open) total_lines else line_start;
}

pub fn findPythonEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
    if (line_start >= total_lines) return line_start;

    // Get the indent of the signature line
    const sig_offset = line_offsets[line_start - 1];
    const sig_indent = countIndent(content, sig_offset);

    // Find the colon-terminated signature (may span multiple lines)
    var body_start = line_start + 1;
    // Check if signature line itself has the colon
    {
        const line_end_offset = if (line_start < total_lines) line_offsets[line_start] else content.len;
        const sig_line = content[sig_offset..line_end_offset];
        if (std.mem.indexOf(u8, sig_line, ":") == null) {
            // Multi-line signature — skip ahead to find the colon
            var ln = line_start + 1;
            while (ln <= total_lines) : (ln += 1) {
                const lo = line_offsets[ln - 1];
                const le = if (ln < total_lines) line_offsets[ln] else content.len;
                const line = content[lo..le];
                if (std.mem.indexOf(u8, line, ":") != null) {
                    body_start = ln + 1;
                    break;
                }
            }
        }
    }

    var last_body_line = line_start;
    var ln = body_start;
    while (ln <= total_lines) : (ln += 1) {
        const lo = line_offsets[ln - 1];
        const le = if (ln < total_lines) line_offsets[ln] else content.len;
        const line = content[lo..le];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        // Blank lines and comments don't end the body
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }

        const indent = countIndent(content, lo);
        if (indent <= sig_indent) break;
        last_body_line = ln;
    }

    return if (last_body_line > line_start) last_body_line else line_start;
}

pub fn findRubyEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
    if (line_start >= total_lines) return line_start;

    const sig_offset = line_offsets[line_start - 1];
    const sig_indent = countIndent(content, sig_offset);

    var ln = line_start + 1;
    while (ln <= total_lines) : (ln += 1) {
        const lo = line_offsets[ln - 1];
        const le = if (ln < total_lines) line_offsets[ln] else content.len;
        const line = content[lo..le];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.eql(u8, trimmed, "end")) {
            const indent = countIndent(content, lo);
            if (indent <= sig_indent) return ln;
        }
    }

    return line_start;
}

pub fn countIndent(content: []const u8, offset: usize) usize {
    var count: usize = 0;
    var i = offset;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {
        count += if (content[i] == '\t') 4 else 1;
    }
    return count;
}

pub fn parseOutlineWithParser(parser: *Explorer, path: []const u8, content: []const u8) !FileOutline {
    var outline = FileOutline.init(parser.allocator, path);
    errdefer outline.deinit();
    outline.byte_size = content.len;

    var line_num: u32 = 0;
    var prev_line_trimmed: []const u8 = "";
    var php_state: PhpParseState = .{};
    var in_py_docstring = false;
    var in_block_comment = false;
    var fsharp_comment_depth: usize = 0;
    var in_csharp_attribute_block = false;
    var csharp_pending_decorators: std.ArrayList([]const u8) = .empty;
    defer {
        clearDecoratorList(parser.allocator, &csharp_pending_decorators);
        csharp_pending_decorators.deinit(parser.allocator);
    }
    var in_fsharp_attribute_block = false;
    var csharp_raw_string_quotes: usize = 0;
    var csharp_brace_depth: i32 = 0;
    var csharp_enum_depth: ?i32 = null;
    var csharp_enum_pending = false;
    var csharp_type_depths: [32]i32 = undefined;
    var csharp_type_depth_count: usize = 0;
    var csharp_type_pending = false;
    var in_go_import_block = false;
    var c_brace_depth: u32 = 0;
    var in_razor_code_block: bool = false;
    var razor_brace_depth: u32 = 0;
    var gd_state: godot_parser.GdState = .{};
    var godot_project_section: godot_parser.ProjectSection = .none;
    var gd_pending_decorators: std.ArrayList([]const u8) = .empty;
    defer {
        clearDecoratorList(parser.allocator, &gd_pending_decorators);
        gd_pending_decorators.deinit(parser.allocator);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        var trimmed = std.mem.trim(u8, line, " \t");

        if (outline.language == .f_sharp) {
            if (fsharp_comment_depth != 0) {
                const was_in_comment = fsharp_comment_depth != 0;
                fsharp_parser.updateFSharpState(trimmed, &fsharp_comment_depth);
                if (was_in_comment and fsharp_comment_depth == 0) {
                    if (std.mem.lastIndexOf(u8, trimmed, "*)")) |close_pos| {
                        const after = std.mem.trimStart(u8, trimmed[close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after;
                    } else continue;
                } else continue;
            }
        }

        if (outline.language == .python) {
            const has_dq = std.mem.indexOf(u8, trimmed, "\"\"\"");
            const has_sq = std.mem.indexOf(u8, trimmed, "'''");
            const has_triple = has_dq != null or has_sq != null;
            if (in_py_docstring) {
                if (has_triple) in_py_docstring = false;
                continue;
            }
            if (has_triple) {
                // Check if triple quote appears twice (single-line docstring like """text""")
                const marker = if (has_dq != null) "\"\"\"" else "'''";
                const first_pos = if (has_dq) |p| p else has_sq.?;
                if (std.mem.indexOf(u8, trimmed[first_pos + 3 ..], marker) != null) {
                    // Opens and closes on same line — skip as a single-line docstring
                    continue;
                }
                in_py_docstring = true;
                continue;
            }
        }

        if (outline.language == .ruby) {
            if (in_py_docstring) {
                if (startsWith(line, "=end")) in_py_docstring = false;
                continue;
            }
            if (startsWith(line, "=begin")) {
                in_py_docstring = true;
                continue;
            }
        }

        if (outline.language == .typescript or outline.language == .javascript or
            outline.language == .go_lang or outline.language == .c or
            outline.language == .cpp or outline.language == .rust or
            outline.language == .zig or outline.language == .hcl or
            outline.language == .dart or outline.language == .java or
            outline.language == .kotlin or outline.language == .svelte or
            outline.language == .vue or outline.language == .astro or
            outline.language == .css or outline.language == .scss or
            outline.language == .protobuf or outline.language == .mlir or
            outline.language == .tablegen or outline.language == .c_sharp or
            outline.language == .razor or outline.language == .sql)
        {
            if (in_block_comment) {
                if (std.mem.indexOf(u8, trimmed, "*/")) |close_pos| {
                    in_block_comment = false;
                    const after = std.mem.trimStart(u8, trimmed[close_pos + 2 ..], " \t");
                    if (after.len == 0) continue;
                    trimmed = after;
                } else continue;
            }
            if (std.mem.startsWith(u8, trimmed, "/*")) {
                if (std.mem.indexOf(u8, trimmed[2..], "*/")) |close_pos| {
                    const after = std.mem.trimStart(u8, trimmed[2 + close_pos + 2 ..], " \t");
                    if (after.len == 0) continue;
                    trimmed = after;
                } else {
                    in_block_comment = true;
                    continue;
                }
            }
        }

        if (outline.language == .zig) {
            try parser.parseZigLine(trimmed, line_num, &outline);
        } else if (outline.language == .python) {
            try parser.parsePythonLine(trimmed, line_num, &outline);
        } else if (outline.language == .typescript or outline.language == .javascript) {
            try parser.parseTsLine(trimmed, line_num, &outline);
        } else if (outline.language == .c or outline.language == .cpp) {
            try parser.parseCLine(line, trimmed, line_num, &outline, prev_line_trimmed, &c_brace_depth);
        } else if (outline.language == .rust) {
            try parser.parseRustLine(trimmed, line_num, &outline, prev_line_trimmed);
        } else if (outline.language == .php) {
            try parser.parsePhpLine(trimmed, line_num, &outline, &php_state);
        } else if (outline.language == .go_lang) {
            if (in_go_import_block) {
                if (startsWith(trimmed, ")")) {
                    in_go_import_block = false;
                } else if (extractStringLiteral(trimmed)) |imp_path| {
                    const import_copy = try parser.allocator.dupe(u8, imp_path);
                    errdefer parser.allocator.free(import_copy);
                    try outline.imports.append(parser.allocator, import_copy);
                    const symbol_copy = try parser.allocator.dupe(u8, trimmed);
                    errdefer parser.allocator.free(symbol_copy);
                    try outline.symbols.append(parser.allocator, .{
                        .name = symbol_copy,
                        .kind = .import,
                        .line_start = line_num,
                        .line_end = line_num,
                    });
                }
            } else if (std.mem.eql(u8, trimmed, "import (")) {
                in_go_import_block = true;
            } else {
                try parser.parseGoLine(trimmed, line_num, &outline);
            }
        } else if (outline.language == .dart) {
            try parser.parseDartLine(trimmed, line_num, &outline);
        } else if (outline.language == .ruby) {
            try parser.parseRubyLine(trimmed, line_num, &outline);
        } else if (outline.language == .hcl) {
            try parser.parseHclLine(trimmed, line_num, &outline);
        } else if (outline.language == .r) {
            try parser.parseRLine(trimmed, line_num, &outline);
        } else if (outline.language == .java) {
            try parser.parseJavaLine(trimmed, line_num, &outline);
        } else if (outline.language == .kotlin) {
            try parser.parseKotlinLine(trimmed, line_num, &outline);
        } else if (outline.language == .swift) {
            try parser.parseSwiftLine(trimmed, line_num, &outline);
        } else if (outline.language == .svelte or outline.language == .vue or outline.language == .astro) {
            try parser.parseComponentLine(trimmed, line_num, &outline);
        } else if (outline.language == .shell) {
            try parser.parseShellLine(trimmed, line_num, &outline);
        } else if (outline.language == .css or outline.language == .scss) {
            try parser.parseStyleLine(trimmed, line_num, &outline);
        } else if (outline.language == .sql) {
            const result = tsql_parser.parseLine(trimmed);
            switch (result) {
                .none => {},
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .procedure => .function,
                        .function_def => .function,
                        .view => .struct_def,
                        .table_def => .struct_def,
                        .trigger => .method,
                        .schema => .type_alias,
                        .type_def => .type_alias,
                        .sequence => .constant,
                        .synonym => .type_alias,
                        .index_def => .constant,
                        .variable => .variable,
                        .exec_ref => unreachable,
                        .table_ref => unreachable,
                    };
                    var detail_buf: [256]u8 = undefined;
                    const structured = tsql_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    // Normalize SQL names: strip brackets [dbo].[Table] -> dbo.Table
                    var name_buf: [256]u8 = undefined;
                    const normalized_name = tsql_parser.normalizeSqlName(sym.name, &name_buf);
                    try appendOutlineSymbol(parser.allocator, &outline, normalized_name, sk, line_num, detail);
                },
                .import => |imp| {
                    // Normalize SQL import names: strip brackets
                    var imp_buf: [256]u8 = undefined;
                    const normalized_imp = tsql_parser.normalizeSqlName(imp.path, &imp_buf);
                    try appendImportSymbol(parser.allocator, &outline, normalized_imp, line_num, trimmed);
                },
            }
        } else if (outline.language == .protobuf) {
            try parser.parseProtoLine(trimmed, line_num, &outline);
        } else if (outline.language == .fortran) {
            try parser.parseFortranLine(trimmed, line_num, &outline);
        } else if (outline.language == .llvm_ir) {
            try parser.parseLlvmIrLine(trimmed, line_num, &outline);
        } else if (outline.language == .mlir) {
            try parser.parseMlirLine(trimmed, line_num, &outline);
        } else if (outline.language == .tablegen) {
            try parser.parseTableGenLine(trimmed, line_num, &outline);
        } else if (outline.language == .c_sharp) {
            if (csharp_raw_string_quotes != 0) {
                csharp_parser.updateRawStringState(trimmed, &csharp_raw_string_quotes);
                continue;
            }
            if (csharp_parser.findBlockCommentStart(trimmed)) |comment_start| {
                const after_open = trimmed[comment_start + 2 ..];
                if (std.mem.indexOf(u8, after_open, "*/") == null) in_block_comment = true;
                trimmed = std.mem.trimEnd(u8, trimmed[0..comment_start], " \t");
                if (trimmed.len == 0) continue;
            }
            try collectCSharpDecorators(parser.allocator, trimmed, &csharp_pending_decorators);
            if (csharp_parser.stripAttributeLine(trimmed, &in_csharp_attribute_block)) |after_attrs| {
                const inside_enum = if (csharp_enum_depth) |depth| csharp_brace_depth >= depth else false;
                const declares_type = csharp_parser.lineDeclaresType(after_attrs);
                const declares_enum = declares_type and csharp_parser.lineDeclaresEnum(after_attrs);
                const at_type_member_scope = if (csharp_type_depth_count > 0)
                    csharp_brace_depth == csharp_type_depths[csharp_type_depth_count - 1]
                else
                    true;
                const before_count = outline.symbols.items.len;
                try parser.parseCSharpLineWithOptions(after_attrs, line_num, &outline, .{
                    .allow_enum_member = inside_enum,
                    .allow_field_declarations = at_type_member_scope,
                });
                if (outline.symbols.items.len > before_count) {
                    try attachDecoratorsToSymbols(parser.allocator, &outline, before_count, csharp_pending_decorators.items);
                    clearDecoratorList(parser.allocator, &csharp_pending_decorators);
                }
                csharp_parser.updateRawStringState(after_attrs, &csharp_raw_string_quotes);

                const braces = csharp_parser.countStructuralBraces(after_attrs);
                const depth_before = csharp_brace_depth;
                csharp_brace_depth += @as(i32, @intCast(braces.opens));
                csharp_brace_depth -= @as(i32, @intCast(braces.closes));
                if (csharp_brace_depth < 0) csharp_brace_depth = 0;

                if (declares_enum) {
                    if (braces.opens > braces.closes) {
                        csharp_enum_depth = depth_before + 1;
                        csharp_enum_pending = false;
                    } else if (braces.opens == 0) {
                        csharp_enum_pending = true;
                    }
                } else if (csharp_enum_pending and braces.opens > 0) {
                    csharp_enum_depth = depth_before + 1;
                    csharp_enum_pending = false;
                }
                if (declares_type) {
                    if (braces.opens > braces.closes) {
                        if (csharp_type_depth_count < csharp_type_depths.len) {
                            csharp_type_depths[csharp_type_depth_count] = depth_before + 1;
                            csharp_type_depth_count += 1;
                        }
                        csharp_type_pending = false;
                    } else if (braces.opens == 0) {
                        csharp_type_pending = true;
                    }
                } else if (csharp_type_pending and braces.opens > 0) {
                    if (csharp_type_depth_count < csharp_type_depths.len) {
                        csharp_type_depths[csharp_type_depth_count] = depth_before + 1;
                        csharp_type_depth_count += 1;
                    }
                    csharp_type_pending = false;
                }
                if (csharp_enum_depth) |depth| {
                    if (csharp_brace_depth < depth) csharp_enum_depth = null;
                }
                while (csharp_type_depth_count > 0 and csharp_brace_depth < csharp_type_depths[csharp_type_depth_count - 1]) {
                    csharp_type_depth_count -= 1;
                }
            }
        } else if (outline.language == .f_sharp) {
            if (fsharp_parser.stripAttributeLine(trimmed, &in_fsharp_attribute_block)) |after_attrs| {
                try parser.parseFSharpLine(after_attrs, line_num, &outline);
                fsharp_parser.updateFSharpState(after_attrs, &fsharp_comment_depth);
            }
        } else if (outline.language == .razor) {
            try parser.parseRazorLine(trimmed, line_num, &outline, &in_razor_code_block, &razor_brace_depth);
        } else if (outline.language == .autumn_adm or outline.language == .autumn_acfg or
            outline.language == .autumn_adpt or outline.language == .autumn_arc)
        {
            const result: autumn_parser.ParsedLine = switch (outline.language) {
                .autumn_adm => autumn_parser.parseAdmLine(trimmed),
                .autumn_acfg => autumn_parser.parseAcfgLine(trimmed),
                .autumn_adpt => autumn_parser.parseAdptLine(trimmed),
                .autumn_arc => autumn_parser.parseArcLine(trimmed),
                else => unreachable,
            };
            switch (result) {
                .none => {},
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .entity_schema => .type_alias,
                        .entity => .class_def,
                        .entity_attribute => .variable,
                        .domain_definition => .type_alias,
                        .configuration => .type_alias,
                        .database_catalog => .variable,
                        .message_queue => .variable,
                        .component => .class_def,
                        .transition => .variable,
                        .terminate => .variable,
                        .rule_set => .class_def,
                        .rule_reference => .variable,
                    };
                    // Build structured detail from the raw XML line using the parser's extractDetail
                    var detail_buf: [256]u8 = undefined;
                    const structured = autumn_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, detail);
                },
            }
        } else if (outline.language == .t4_template) {
            const result = t4_parser.parseT4Line(trimmed);
            switch (result) {
                .none => {},
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .directive_template => .type_alias,
                        .directive_assembly => .import,
                        .directive_output => .variable,
                        .directive_include => .import,
                        .directive_parameter => .variable,
                        .code_block => .type_alias,
                        .expression_block => .variable,
                        .class_feature_block => .type_alias,
                        .helper_class => .class_def,
                        .helper_method => .function,
                        .helper_property => .variable,
                        .directive_import => unreachable, // handled separately
                    };
                    var detail_buf: [256]u8 = undefined;
                    const structured = t4_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, detail);
                },
                .directive_import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.namespace, line_num, trimmed);
                },
            }
        } else if (outline.language == .ssrs_report or outline.language == .ssrs_dataset or
            outline.language == .ssrs_datasource or outline.language == .ssrs_project)
        {
            // SSRS files: .rdl, .rsd, .rds, .rptproj
            const result: ssrs_parser.ParsedLine = switch (outline.language) {
                .ssrs_report => blk: {
                    // Check for <ReportName> inside <Subreport> blocks (dependency link)
                    if (ssrs_parser.parseSubreportRef(trimmed)) |subreport_name| {
                        break :blk .{ .import = .{ .path = subreport_name } };
                    }
                    break :blk ssrs_parser.parseRdlLine(trimmed);
                },
                .ssrs_dataset => ssrs_parser.parseRsdLine(trimmed),
                .ssrs_datasource => ssrs_parser.parseRdsLine(trimmed),
                .ssrs_project => ssrs_parser.parseRptprojLine(trimmed),
                else => unreachable,
            };
            switch (result) {
                .none => {},
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .report_parameter => .variable,
                        .dataset => .variable,
                        .datasource => .variable,
                        .variable => .variable,
                        .subreport => .variable,
                        .shared_dataset_ref => unreachable,
                        .datasource_ref => unreachable,
                        .command_text => .function,
                        .report_item => unreachable,
                        .dataset_item => unreachable,
                        .datasource_item => unreachable,
                        .report_metadata => .variable,
                        .rptproj_property => .variable,
                        .axys_macro => .constant,
                    };
                    var detail_buf: [256]u8 = undefined;
                    const structured = ssrs_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, detail);
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        } else if (outline.language == .gdscript) {
            // preload()/load() references become dependency edges even when
            // they appear on a declaration line (const X = preload(...)).
            // Comments are stripped first so commented-out code adds no edges.
            if (!gd_state.in_multiline_string) {
                if (godot_parser.extractResPath(godot_parser.stripGdComment(trimmed))) |res_path| {
                    try appendImportSymbol(parser.allocator, &outline, res_path, line_num, trimmed);
                }
            }
            const result = godot_parser.parseGdLine(line, trimmed, &gd_state);
            switch (result) {
                .none => {},
                .annotation => |ann| {
                    const copy = try parser.allocator.dupe(u8, ann.name);
                    errdefer parser.allocator.free(copy);
                    try gd_pending_decorators.append(parser.allocator, copy);
                },
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .class_name_decl, .inner_class => .class_def,
                        .function_def => .function,
                        .method_def => .method,
                        .signal_decl => .constant,
                        .variable_decl => .variable,
                        .constant_decl => .constant,
                        .enum_decl => .enum_def,
                        else => unreachable, // scene/project kinds never come from parseGdLine
                    };
                    const before_count = outline.symbols.items.len;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, trimmed);
                    if (gd_pending_decorators.items.len > 0) {
                        try attachDecoratorsToSymbols(parser.allocator, &outline, before_count, gd_pending_decorators.items);
                        clearDecoratorList(parser.allocator, &gd_pending_decorators);
                    }
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        } else if (outline.language == .godot_scene or outline.language == .godot_resource) {
            const result = godot_parser.parseSceneLine(trimmed);
            switch (result) {
                .none => {},
                .annotation => unreachable, // gdscript-only
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .node_def, .resource_def => .class_def,
                        .connection => .variable,
                        else => unreachable,
                    };
                    var detail_buf: [256]u8 = undefined;
                    const structured = godot_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, detail);
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        } else if (outline.language == .godot_project) {
            const result = godot_parser.parseProjectLine(trimmed, &godot_project_section);
            switch (result) {
                .none => {},
                .annotation => unreachable, // gdscript-only
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .section_header => .type_alias,
                        .input_action => .constant,
                        else => unreachable,
                    };
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, trimmed);
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        }

        prev_line_trimmed = trimmed;
    }
    outline.line_count = line_num;
    computeSymbolEnds(content, &outline);
    return outline;
}

pub fn parseContentForIndexing(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ParsedFile {
    var parser = Explorer.init(allocator);
    defer parser.deinit();
    var parsed_outline = try parseOutlineWithParser(&parser, path, content);
    defer parsed_outline.deinit();

    if (parsed_outline.language == .c_sharp) {
        try enrichCSharpMultilineSignatures(allocator, &parsed_outline, content);
    }

    // NOTE: consecutive-property collapsing previously ran here, but it
    // mutated the stored outline — discarding every collapsed property's
    // name/type and corrupting symbol lookup, type indexing, type-usage
    // dependency edges, and scope attribution. Collapsing is now a
    // display-only transform (see mcp/explore_tools.zig), so the indexed
    // data stays complete while `codedb_outline` stays compact.

    // Post-process: enrich SSRS outlines with multi-line constructs
    // (Description, AXYS ConnectString, <Code> block, ReportParameter children).
    if (parsed_outline.language == .ssrs_report or
        parsed_outline.language == .ssrs_dataset or
        parsed_outline.language == .ssrs_datasource or
        parsed_outline.language == .ssrs_project)
    {
        ssrs_parser.enrichOutline(allocator, &parsed_outline, content);
    }

    return .{
        .content = content,
        .outline = try cloneOutline(&parsed_outline, allocator),
    };
}

/// The fast parser emits a method as soon as it sees the declaration's first
/// line. Enrich signatures that continue on following lines so type queries and
/// outlines expose the full parameter list instead of an empty/truncated one.
fn enrichCSharpMultilineSignatures(allocator: std.mem.Allocator, outline: *FileOutline, content: []const u8) !void {
    var has_multiline_signature = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind != .method and sym.kind != .function) continue;
        const detail = sym.detail orelse continue;
        if (std.mem.indexOfScalar(u8, detail, '(') != null and std.mem.indexOfScalar(u8, detail, ')') == null) {
            has_multiline_signature = true;
            break;
        }
    }
    if (!has_multiline_signature) return;

    var line_offsets: std.ArrayList(usize) = .empty;
    defer line_offsets.deinit(allocator);
    try line_offsets.append(allocator, 0);
    for (content, 0..) |ch, i| {
        if (ch == '\n' and i + 1 < content.len) try line_offsets.append(allocator, i + 1);
    }

    for (outline.symbols.items) |*sym| {
        if (sym.kind != .method and sym.kind != .function) continue;
        const detail = sym.detail orelse continue;
        if (std.mem.indexOfScalar(u8, detail, '(') == null or std.mem.indexOfScalar(u8, detail, ')') != null) continue;
        if (sym.line_start == 0 or sym.line_start > line_offsets.items.len) continue;

        const start = line_offsets.items[sym.line_start - 1];
        const remaining = content[start..@min(content.len, start + 64 * 1024)];
        const close = csharp_parser.findSignatureClose(remaining) orelse continue;

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(allocator);
        var previous_space = false;
        for (remaining[0 .. close + 1]) |ch| {
            const is_space = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
            if (is_space) {
                if (!previous_space) try normalized.append(allocator, ' ');
            } else {
                try normalized.append(allocator, ch);
            }
            previous_space = is_space;
        }
        const joined = std.mem.trim(u8, normalized.items, " \t");
        const parsed = csharp_parser.parseLine(joined);
        const parsed_sym = switch (parsed) {
            .symbol => |candidate| candidate,
            else => continue,
        };
        if (parsed_sym.kind != .method and parsed_sym.kind != .function) continue;
        if (!std.mem.eql(u8, parsed_sym.name, sym.name)) continue;

        const new_detail = try allocator.dupe(u8, joined);
        errdefer allocator.free(new_detail);
        const new_return_type: ?[]const u8 = if (parsed_sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
        errdefer if (new_return_type) |rt| allocator.free(rt);
        const parsed_params = parsed_sym.param_types.slice();
        const new_param_storage: ?[][]const u8 = if (parsed_params.len > 0)
            try allocator.alloc([]const u8, parsed_params.len)
        else
            null;
        const new_param_types: []const []const u8 = new_param_storage orelse &.{};
        var copied: usize = 0;
        errdefer {
            for (new_param_types[0..copied]) |pt| allocator.free(pt);
            if (new_param_storage) |storage| allocator.free(storage);
        }
        for (parsed_params, 0..) |pt, i| {
            new_param_storage.?[i] = try allocator.dupe(u8, pt);
            copied += 1;
        }

        allocator.free(sym.detail.?);
        if (sym.return_type) |rt| allocator.free(rt);
        for (sym.param_types) |pt| allocator.free(pt);
        if (sym.param_types.len > 0) allocator.free(sym.param_types);
        sym.detail = new_detail;
        sym.return_type = new_return_type;
        sym.param_types = new_param_types;
    }
}

pub fn collectCSharpDecorators(allocator: std.mem.Allocator, line: []const u8, pending: *std.ArrayList([]const u8)) !void {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (std.mem.startsWith(u8, rest, "[")) {
        const close = findCSharpDecoratorClose(rest) orelse return;
        const decorator = std.mem.trim(u8, rest[0 .. close + 1], " \t\r\n");
        if (decorator.len > 2) {
            const copied = try allocator.dupe(u8, decorator);
            errdefer allocator.free(copied);
            try pending.append(allocator, copied);
        }
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    }
}

pub fn findCSharpDecoratorClose(s: []const u8) ?usize {
    var quote: u8 = 0;
    var verbatim = false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < s.len and s[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (ch == '\\' and quote != '\'' and !verbatim) {
                i += 1;
                continue;
            }
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and i > 0 and s[i - 1] == '@';
            continue;
        }
        if (ch == ']') return i;
    }
    return null;
}

pub fn attachDecoratorsToSymbols(allocator: std.mem.Allocator, outline: *FileOutline, start_index: usize, decorators: []const []const u8) !void {
    if (decorators.len == 0) return;
    for (outline.symbols.items[start_index..]) |*sym| {
        sym.decorators = try cloneDecorators(allocator, decorators);
    }
}

pub fn clearDecoratorList(allocator: std.mem.Allocator, pending: *std.ArrayList([]const u8)) void {
    for (pending.items) |decorator| allocator.free(decorator);
    pending.clearRetainingCapacity();
}

pub fn indexFileInner(self: *Explorer, path: []const u8, content: []const u8, full_index: bool, skip_trigram: bool) !void {
    const parsed = try parseContentForIndexing(self.allocator, path, content);
    return self.commitParsedFileOwnedOutline(path, parsed.content, parsed.outline, full_index, skip_trigram);
}
/// Rebuild trigram index from the stored file contents.
/// Used after a cache hit to populate trigrams when they were skipped during the fast scan.
/// Remove every skip_trigram_files entry the current trigram index
/// covers. Caller must hold the EXCLUSIVE lock. Snapshot restore parks
/// every file in the skip set (#507/#537 — it cannot know what a disk
/// trigram index covers), so without this reconciliation tier 3
/// content-scans the ENTIRE project on each fall-through query even
/// though the loaded index already answers for those files. Keys are
/// borrowed from `outlines`, so removal never frees. (#615)
fn pruneSkipTrigramLocked(self: *Explorer) void {
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(self.allocator);
    var it = self.skip_trigram_files.keyIterator();
    while (it.next()) |k| {
        if (self.trigram_index.containsFile(k.*)) to_remove.append(self.allocator, k.*) catch break;
    }
    for (to_remove.items) |k| _ = self.skip_trigram_files.remove(k);
}

/// Swap in a trigram index (disk mmap load / post-scan build) and
/// reconcile the skip set with what it covers. Every external
/// trigram_index replacement must go through here — a bare swap leaves
/// stale skip_trigram_files entries (see pruneSkipTrigramLocked). (#615)
pub fn adoptTrigramIndex(self: *Explorer, new_index: idx.AnyTrigramIndex) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.search_gen +%= 1;
    self.trigram_index.deinit();
    self.trigram_index = new_index;
    pruneSkipTrigramLocked(self);
}

/// Adopt a disk-loaded mmap trigram as the BASE index, keeping any files
/// already trigram-indexed in the current heap index (snapshot freshness
/// reindex touches changed files BEFORE the disk load runs) as a masked
/// overlay so their newer content wins. Replaces the `fileCount() > 0`
/// early-return that let a single reindexed file block the disk load
/// entirely — leaving tier 3 to content-scan the whole project on every
/// fall-through query. (#615)
pub fn adoptTrigramBase(self: *Explorer, base: idx.MmapTrigramIndex) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.search_gen +%= 1;
    switch (self.trigram_index) {
        .heap => |heap_copy| {
            if (heap_copy.fileCount() == 0) {
                var old = heap_copy;
                old.deinit();
                self.trigram_index = .{ .mmap = base };
            } else {
                const alloc = self.allocator;
                self.trigram_index = .{ .mmap_overlay = .{
                    .base = base,
                    .overlay = heap_copy,
                    .masked = std.StringHashMap(void).init(alloc),
                } };
                var it = self.trigram_index.mmap_overlay.overlay.file_trigrams.keyIterator();
                while (it.next()) |k| self.trigram_index.mmap_overlay.mask(k.*);
            }
        },
        .mmap, .mmap_overlay => {
            // Already disk-backed — nothing to gain from a second base.
            var dupe_base = base;
            dupe_base.deinit();
        },
    }
    pruneSkipTrigramLocked(self);
}

pub fn rebuildTrigrams(self: *Explorer) !void {
    self.mu.lock();
    defer self.mu.unlock();
    self.search_gen +%= 1;
    var iter = self.contents.iterator();
    while (iter.next()) |entry| {
        // Skip large files to prevent OOM on large repos
        if (entry.value_ptr.*.len > 64 * 1024) continue;
        self.trigram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.warn("trigram OOM, skipping remaining files", .{});
                pruneSkipTrigramLocked(self);
                return;
            },
        };
        self.sparse_ngram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.warn("sparse ngram OOM, skipping remaining files", .{});
                pruneSkipTrigramLocked(self);
                return;
            },
        };
    }
    pruneSkipTrigramLocked(self);
}

/// Rebuild the inverted word index from cached contents when complete, or
/// by streaming source files from the project root when the content cache
/// was capped during fast snapshot restore.
pub fn rebuildWordIndex(self: *Explorer) !void {
    const source_paths = blk: {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (self.contents.len() == self.outlines.count()) break :blk null;
        if (self.io == null or self.root_dir == null) return error.WordIndexIncomplete;

        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        try paths.ensureTotalCapacity(self.allocator, self.outlines.count());
        var iter = self.outlines.keyIterator();
        while (iter.next()) |path_ptr| {
            paths.appendAssumeCapacity(try self.allocator.dupe(u8, path_ptr.*));
        }
        break :blk try paths.toOwnedSlice(self.allocator);
    };
    defer if (source_paths) |paths| {
        for (paths) |path| self.allocator.free(path);
        self.allocator.free(paths);
    };

    var rebuilt = WordIndex.init(self.allocator);
    errdefer rebuilt.deinit();

    if (source_paths) |paths| {
        const io = self.io orelse return error.WordIndexIncomplete;
        const dir = self.root_dir orelse return error.WordIndexIncomplete;
        for (paths) |path| {
            const content = try dir.readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024));
            errdefer self.allocator.free(content);
            try rebuilt.indexFile(path, content);
            self.allocator.free(content);
        }
    } else {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        var iter = self.contents.iterator();
        while (iter.next()) |entry| {
            try rebuilt.indexFile(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    self.mu.lock();
    defer self.mu.unlock();
    self.word_index.deinit();
    self.word_index = rebuilt;
    self.word_index_generation +%= 1;
    self.word_index_complete = true;
    self.word_index_can_load_from_disk = false;
}

pub fn markWordIndexIncomplete(self: *Explorer, can_load_from_disk: bool) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.word_index.deinit();
    self.word_index = WordIndex.init(self.allocator);
    self.word_index_complete = false;
    self.word_index_can_load_from_disk = can_load_from_disk;
}

/// Declare that the current in-memory word_index holds the complete,
/// persisted-to-disk state. Warm queries will skip rebuild/reload.
pub fn markWordIndexAsComplete(self: *Explorer) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.word_index_complete = true;
    self.word_index_can_load_from_disk = false;
    self.word_index_persisted_generation = self.word_index_generation;
}

pub fn disableWordIndexDiskLoad(self: *Explorer) void {
    self.mu.lock();
    defer self.mu.unlock();
    if (!self.word_index_complete) {
        self.word_index_can_load_from_disk = false;
    }
}

pub fn wordIndexCanLoadFromDisk(self: *Explorer) bool {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return !self.word_index_complete and self.word_index_can_load_from_disk;
}

pub fn wordIndexIsComplete(self: *Explorer) bool {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.word_index_complete;
}

pub fn wordIndexNeedsPersist(self: *Explorer) bool {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.word_index_complete and self.word_index_generation != self.word_index_persisted_generation;
}

pub fn wordIndexGenerationToPersist(self: *Explorer) ?u64 {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    if (!self.word_index_complete) return null;
    if (self.word_index_generation == self.word_index_persisted_generation) return null;
    return self.word_index_generation;
}

pub fn markWordIndexPersisted(self: *Explorer, generation: u64) void {
    self.mu.lock();
    defer self.mu.unlock();
    if (self.word_index_complete and self.word_index_generation == generation) {
        self.word_index_persisted_generation = generation;
    }
}

pub fn replaceWordIndex(self: *Explorer, word_index: WordIndex) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.word_index.deinit();
    self.word_index = word_index;
    self.word_index_generation +%= 1;
    self.word_index_complete = true;
    self.word_index_can_load_from_disk = false;
    self.word_index_persisted_generation = self.word_index_generation;
}

pub fn removeFile(self: *Explorer, path: []const u8) void {
    self.mu.lock();
    defer self.mu.unlock();
    if (!self.word_index_complete) {
        self.word_index_can_load_from_disk = false;
    } else {
        self.word_index_generation +%= 1;
    }
    self.dep_graph.remove(path);
    self.removeSymbolIndexFor(path);
    // #587: the skip_trigram_files key aliases the outlines key being freed
    // below; remove it so the tier-3 scan no longer iterates a dangling path.
    // Removal only, no free: the outlines loop owns that allocation.
    _ = self.skip_trigram_files.remove(path);
    self.contents.remove(path);
    self.word_index.removeFile(path);
    self.trigram_index.removeFile(path);
    self.sparse_ngram_index.removeFile(path);
    self.type_index.removeFile(path);

    // Remove type graph entries for symbols in this file
    if (self.outlines.get(path)) |outline| {
        for (outline.symbols.items) |sym| {
            if (sym.kind == .class_def or sym.kind == .interface_def or
                sym.kind == .struct_def or sym.kind == .enum_def)
            {
                self.type_graph.removeType(sym.name);
            }
        }
    }

    if (self.outlines.fetchRemove(path)) |kv| {
        var outline = kv.value;
        outline.deinit();
        self.allocator.free(kv.key);
    }
}

pub const ContentRef = struct {
    data: []const u8,
    owned: bool, // true = caller must free; false = borrowed from cache
    allocator: std.mem.Allocator,

    pub fn deinit(self: ContentRef) void {
        if (self.owned) self.allocator.free(self.data);
    }
};

/// Get content: zero-copy from cache, or read from disk (caller-owned).
pub fn readContentForSearch(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ?ContentRef {
    if (self.contents.get(path)) |cached| {
        return .{ .data = cached, .owned = false, .allocator = allocator };
    }
    const io = self.io orelse return null;
    const dir = self.root_dir orelse std.Io.Dir.cwd();
    const data = dir.readFileAlloc(io, path, allocator, .limited(skip_rules.max_indexed_file_bytes)) catch return null;
    return .{ .data = data, .owned = true, .allocator = allocator };
}

pub fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
    const copied_path = try allocator.dupe(u8, src.path);
    // No errdefer here: dst.deinit() below handles freeing copied_path via owns_path.

    var dst = FileOutline.init(allocator, copied_path);
    dst.owns_path = true;
    errdefer dst.deinit();
    dst.line_count = src.line_count;
    dst.byte_size = src.byte_size;
    for (src.symbols.items) |sym| {
        const copied_name = try allocator.dupe(u8, sym.name);
        errdefer allocator.free(copied_name);

        const copied_detail = if (sym.detail) |d| blk: {
            const detail = try allocator.dupe(u8, d);
            break :blk detail;
        } else null;
        errdefer if (copied_detail) |d| allocator.free(d);
        const copied_decorators = try cloneDecorators(allocator, sym.decorators);
        errdefer freeDecorators(allocator, copied_decorators);
        const copied_return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
        errdefer if (copied_return_type) |rt| allocator.free(rt);
        const copied_param_types = try cloneParamTypes(allocator, sym.param_types);
        errdefer freeParamTypes(allocator, copied_param_types);

        try dst.symbols.append(allocator, .{
            .name = copied_name,
            .kind = sym.kind,
            .line_start = sym.line_start,
            .line_end = sym.line_end,
            .detail = copied_detail,
            .decorators = copied_decorators,
            .return_type = copied_return_type,
            .param_types = copied_param_types,
        });
    }
    for (src.imports.items) |imp| {
        const copied_import = try allocator.dupe(u8, imp);
        errdefer allocator.free(copied_import);
        try dst.imports.append(allocator, copied_import);
    }

    return dst;
}

pub fn cloneDecorators(allocator: std.mem.Allocator, decorators: []const []const u8) ![]const []const u8 {
    if (decorators.len == 0) return &.{};
    var copied = try allocator.alloc([]const u8, decorators.len);
    errdefer allocator.free(copied);
    var copied_count: usize = 0;
    errdefer {
        for (copied[0..copied_count]) |decorator| allocator.free(decorator);
    }
    for (decorators, 0..) |decorator, i| {
        copied[i] = try allocator.dupe(u8, decorator);
        copied_count += 1;
    }
    return copied;
}

pub fn freeDecorators(allocator: std.mem.Allocator, decorators: []const []const u8) void {
    for (decorators) |decorator| allocator.free(decorator);
    if (decorators.len > 0) allocator.free(decorators);
}

pub fn cloneParamTypes(allocator: std.mem.Allocator, param_types: []const []const u8) ![]const []const u8 {
    if (param_types.len == 0) return &.{};
    var copied = try allocator.alloc([]const u8, param_types.len);
    errdefer allocator.free(copied);
    var copied_count: usize = 0;
    errdefer {
        for (copied[0..copied_count]) |pt| allocator.free(pt);
    }
    for (param_types, 0..) |pt, i| {
        copied[i] = try allocator.dupe(u8, pt);
        copied_count += 1;
    }
    return copied;
}

pub fn freeParamTypes(allocator: std.mem.Allocator, param_types: []const []const u8) void {
    for (param_types) |pt| allocator.free(pt);
    if (param_types.len > 0) allocator.free(param_types);
}
