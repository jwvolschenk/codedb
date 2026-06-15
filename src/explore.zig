const std = @import("std");
const ContentCache = @import("hot_cache.zig").ContentCache;
const nanoregex = @import("nanoregex");
const cio = @import("cio.zig");
const csharp_parser = @import("csharp_parser.zig");
const fsharp_parser = @import("fsharp_parser.zig");
const autumn_parser = @import("autumn_parser.zig");
const t4_parser = @import("t4_parser.zig");
const tsql_parser = @import("tsql_parser.zig");
const ssrs_parser = @import("ssrs_parser.zig");
const Store = @import("store.zig").Store;
const idx = @import("index.zig");
const WordIndex = idx.WordIndex;
const TrigramIndex = idx.TrigramIndex;
const MmapTrigramIndex = idx.MmapTrigramIndex;
const AnyTrigramIndex = idx.AnyTrigramIndex;
const SparseNgramIndex = idx.SparseNgramIndex;
const TypeIndex = idx.TypeIndex;
const TypeGraph = idx.TypeGraph;

// ── Core types / graph / glob split into explore/ submodules ──
const types = @import("explore/types.zig");
pub const SymbolKind = types.SymbolKind;
pub const Symbol = types.Symbol;
pub const FileOutline = types.FileOutline;
pub const ParsedFile = types.ParsedFile;
pub const PhpParseState = types.PhpParseState;
pub const Language = types.Language;
pub const detectLanguage = types.detectLanguage;
pub const isDocLanguage = types.isDocLanguage;
pub const SymbolResult = types.SymbolResult;
pub const SearchResult = types.SearchResult;
pub const SymbolLocation = types.SymbolLocation;

const dependency_graph = @import("explore/dependency_graph.zig");
pub const DependencyGraph = dependency_graph.DependencyGraph;

const glob = @import("explore/glob.zig");
pub const matchGlob = glob.matchGlob;

pub const Explorer = struct {
    outlines: std.StringHashMap(FileOutline),
    dep_graph: DependencyGraph,
    contents: ContentCache,
    symbol_index: std.StringHashMap(std.ArrayList(SymbolLocation)),
    word_index: WordIndex,
    trigram_index: AnyTrigramIndex,
    sparse_ngram_index: SparseNgramIndex,
    type_index: TypeIndex,
    type_graph: TypeGraph,
    /// Paths indexed with skip_trigram=true (past 15k cap or excluded).
    /// Used to restrict the searchContent fallback to only these files.
    skip_trigram_files: std.StringHashMap(void),
    ignore_patterns: std.ArrayList([]const u8) = .empty,
    /// Wyhash of .codedbignore file content. Stored in snapshot META so
    /// loadSnapshotIfHeadMatches can detect stale snapshots when only
    /// .codedbignore changed (no git commit).
    codedbignore_hash: ?u64 = null,
    allocator: std.mem.Allocator,
    word_index_complete: bool = true,
    word_index_can_load_from_disk: bool = false,
    word_index_generation: u64 = 0,
    word_index_persisted_generation: u64 = 0,
    mu: cio.RwLock = .{},
    root_dir: ?std.Io.Dir = null,
    io: ?std.Io = null,
    /// Max files kept in the in-memory content cache. Configurable via
    /// .codedbrc (#102). Beyond this threshold, readContentForSearch falls
    /// back to disk reads.
    content_cache_limit: u32 = 1000,
    /// When non-null, append one JSON line per searchContent invocation
    /// to this path (v0 rerank-trace experiment). Borrowed; caller owns
    /// the slice for the Explorer's lifetime.
    rerank_trace_path: ?[]const u8 = null,

    pub fn setRoot(self: *Explorer, io: std.Io, root_path: []const u8) void {
        self.io = io;
        self.root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch null;
    }
    pub fn init(allocator: std.mem.Allocator) Explorer {
        return .{
            .outlines = std.StringHashMap(FileOutline).init(allocator),
            .dep_graph = DependencyGraph.init(allocator),
            .contents = ContentCache.init(allocator, 16384),
            .symbol_index = std.StringHashMap(std.ArrayList(SymbolLocation)).init(allocator),
            .word_index = WordIndex.init(allocator),
            .trigram_index = .{ .heap = TrigramIndex.init(allocator) },
            .sparse_ngram_index = SparseNgramIndex.init(allocator),
            .type_index = TypeIndex.init(allocator),
            .type_graph = TypeGraph.init(allocator),
            .skip_trigram_files = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Explorer) void {
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.outlines.deinit();

        self.dep_graph.deinit();

        var sym_iter = self.symbol_index.iterator();
        while (sym_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.symbol_index.deinit();

        self.contents.deinit();

        self.word_index.deinit();
        self.trigram_index.deinit();
        self.sparse_ngram_index.deinit();
        self.type_index.deinit();
        self.type_graph.deinit();
        self.skip_trigram_files.deinit();
        for (self.ignore_patterns.items) |pattern| self.allocator.free(pattern);
        self.ignore_patterns.deinit(self.allocator);
        if (self.root_dir) |d| {
            if (self.io) |io| d.close(io);
        }
    }

    pub fn setIgnorePatterns(self: *Explorer, patterns: []const []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.ignore_patterns.items) |pattern| self.allocator.free(pattern);
        self.ignore_patterns.clearRetainingCapacity();

        for (patterns) |pattern| {
            const copied = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(copied);
            try self.ignore_patterns.append(self.allocator, copied);
        }
    }

    pub fn getIgnorePatterns(self: *Explorer, allocator: std.mem.Allocator) ![][]const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |pattern| allocator.free(pattern);
            out.deinit(allocator);
        }
        try out.ensureTotalCapacity(allocator, self.ignore_patterns.items.len);
        for (self.ignore_patterns.items) |pattern| {
            const copied = try allocator.dupe(u8, pattern);
            out.appendAssumeCapacity(copied);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Number of slots in the heap trigram index id_to_path array (benchmark helper).
    pub fn trigramIdToPathLen(self: *Explorer) usize {
        return switch (self.trigram_index) {
            .heap => |*h| h.id_to_path.items.len,
            else => 0,
        };
    }

    /// Number of reusable free_ids slots in the heap trigram index (benchmark helper).
    pub fn trigramFreeIdsLen(self: *Explorer) usize {
        return switch (self.trigram_index) {
            .heap => |*h| h.free_ids.items.len,
            else => 0,
        };
    }
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
        errdefer owned_outline.deinit();
        var persistent_outline = try cloneOutline(&owned_outline, self.allocator);
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

    fn computeSymbolEnds(content: []const u8, outline: *FileOutline) void {
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

    fn findBraceEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32, language: Language) u32 {
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
                // Bail out if no opening brace found within 10 lines
                if (!found_open and current_line > line_start + 10) return line_start;
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

    fn findPythonEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
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

    fn findRubyEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
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

    fn countIndent(content: []const u8, offset: usize) usize {
        var count: usize = 0;
        var i = offset;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {
            count += if (content[i] == '\t') 4 else 1;
        }
        return count;
    }

    fn parseOutlineWithParser(parser: *Explorer, path: []const u8, content: []const u8) !FileOutline {
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
        var in_go_import_block = false;
        var c_brace_depth: u32 = 0;
        var in_razor_code_block: bool = false;
        var razor_brace_depth: u32 = 0;
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
                try collectCSharpDecorators(parser.allocator, trimmed, &csharp_pending_decorators);
                if (csharp_parser.stripAttributeLine(trimmed, &in_csharp_attribute_block)) |after_attrs| {
                    const before_count = outline.symbols.items.len;
                    try parser.parseCSharpLine(after_attrs, line_num, &outline);
                    if (outline.symbols.items.len > before_count) {
                        try attachDecoratorsToSymbols(parser.allocator, &outline, before_count, csharp_pending_decorators.items);
                        clearDecoratorList(parser.allocator, &csharp_pending_decorators);
                    }
                    csharp_parser.updateRawStringState(after_attrs, &csharp_raw_string_quotes);
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

        // Post-process: collapse consecutive POCO properties in C# files
        if (parsed_outline.language == .c_sharp) {
            collapseConsecutiveProperties(allocator, &parsed_outline);
        }

        return .{
            .content = content,
            .outline = try cloneOutline(&parsed_outline, allocator),
        };
    }

    /// Collapse consecutive `variable` symbols (POCO properties) into grouped entries.
    /// When 5+ consecutive variables appear between type boundaries, merge them into
    /// a single entry whose detail lists all property names — reducing outline token
    /// waste for T4-generated files like ViewModels.cs.
    fn collapseConsecutiveProperties(allocator: std.mem.Allocator, outline: *FileOutline) void {
        const MIN_GROUP_SIZE: usize = 5;
        var result: std.ArrayList(Symbol) = .empty;
        var i: usize = 0;
        while (i < outline.symbols.items.len) {
            const sym = outline.symbols.items[i];
            if (sym.kind != .variable) {
                result.append(allocator, sym) catch {};
                i += 1;
                continue;
            }
            // Count consecutive variables
            const run_start = i;
            while (i < outline.symbols.items.len and outline.symbols.items[i].kind == .variable) {
                i += 1;
            }
            const run_len = i - run_start;
            if (run_len < MIN_GROUP_SIZE) {
                // Small group — keep individual entries
                for (run_start..i) |j| {
                    result.append(allocator, outline.symbols.items[j]) catch {};
                }
            } else {
                // Large group — collapse into single entry with property list detail
                var detail_buf: std.ArrayList(u8) = .empty;
                defer detail_buf.deinit(allocator);
                detail_buf.appendSlice(allocator, "props: ") catch {};
                for (run_start..i) |j| {
                    if (j > run_start) detail_buf.appendSlice(allocator, ", ") catch {};
                    detail_buf.appendSlice(allocator, outline.symbols.items[j].name) catch {};
                }
                const owned_detail = detail_buf.toOwnedSlice(allocator) catch null;
                result.append(allocator, .{
                    .name = outline.symbols.items[run_start].name,
                    .kind = .variable,
                    .line_start = outline.symbols.items[run_start].line_start,
                    .line_end = outline.symbols.items[i - 1].line_end,
                    .detail = owned_detail,
                }) catch {};
            }
        }
        // Replace the old symbols list with the collapsed one
        outline.symbols.deinit(allocator);
        outline.symbols = result;
    }

    fn collectCSharpDecorators(allocator: std.mem.Allocator, line: []const u8, pending: *std.ArrayList([]const u8)) !void {
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

    fn findCSharpDecoratorClose(s: []const u8) ?usize {
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

    fn attachDecoratorsToSymbols(allocator: std.mem.Allocator, outline: *FileOutline, start_index: usize, decorators: []const []const u8) !void {
        if (decorators.len == 0) return;
        for (outline.symbols.items[start_index..]) |*sym| {
            sym.decorators = try cloneDecorators(allocator, decorators);
        }
    }

    fn clearDecoratorList(allocator: std.mem.Allocator, pending: *std.ArrayList([]const u8)) void {
        for (pending.items) |decorator| allocator.free(decorator);
        pending.clearRetainingCapacity();
    }

    fn indexFileInner(self: *Explorer, path: []const u8, content: []const u8, full_index: bool, skip_trigram: bool) !void {
        const parsed = try parseContentForIndexing(self.allocator, path, content);
        return self.commitParsedFileOwnedOutline(path, parsed.content, parsed.outline, full_index, skip_trigram);
    }
    /// Rebuild trigram index from the stored file contents.
    /// Used after a cache hit to populate trigrams when they were skipped during the fast scan.
    pub fn rebuildTrigrams(self: *Explorer) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var iter = self.contents.iterator();
        while (iter.next()) |entry| {
            // Skip large files to prevent OOM on large repos
            if (entry.value_ptr.*.len > 64 * 1024) continue;
            self.trigram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.warn("trigram OOM, skipping remaining files", .{});
                    return;
                },
            };
            self.sparse_ngram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.warn("sparse ngram OOM, skipping remaining files", .{});
                    return;
                },
            };
        }
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

    pub fn getOutline(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?FileOutline {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return null;
        return try cloneOutline(outline, allocator);
    }

    /// Return a caller-owned copy of cached file content.
    pub fn getContent(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        if (ref.owned) return @constCast(ref.data);
        return try allocator.dupe(u8, ref.data);
    }

    const ContentRef = struct {
        data: []const u8,
        owned: bool, // true = caller must free; false = borrowed from cache
        allocator: std.mem.Allocator,

        fn deinit(self: ContentRef) void {
            if (self.owned) self.allocator.free(self.data);
        }
    };

    /// Get content: zero-copy from cache, or read from disk (caller-owned).
    fn readContentForSearch(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ?ContentRef {
        if (self.contents.get(path)) |cached| {
            return .{ .data = cached, .owned = false, .allocator = allocator };
        }
        const io = self.io orelse return null;
        const dir = self.root_dir orelse std.Io.Dir.cwd();
        const data = dir.readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch return null;
        return .{ .data = data, .owned = true, .allocator = allocator };
    }

    fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
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

    fn cloneDecorators(allocator: std.mem.Allocator, decorators: []const []const u8) ![]const []const u8 {
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

    fn freeDecorators(allocator: std.mem.Allocator, decorators: []const []const u8) void {
        for (decorators) |decorator| allocator.free(decorator);
        if (decorators.len > 0) allocator.free(decorators);
    }

    fn cloneParamTypes(allocator: std.mem.Allocator, param_types: []const []const u8) ![]const []const u8 {
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

    fn freeParamTypes(allocator: std.mem.Allocator, param_types: []const []const u8) void {
        for (param_types) |pt| allocator.free(pt);
        if (param_types.len > 0) allocator.free(param_types);
    }

    pub fn getTree(self: *Explorer, allocator: std.mem.Allocator, use_color: bool) ![]u8 {
        const s = @import("style.zig").style(use_color);

        self.mu.lockShared();
        defer self.mu.unlockShared();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);

        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            try paths.append(allocator, entry.key_ptr.*);
        }

        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        for (paths.items) |path| {
            const outline = self.outlines.get(path) orelse continue;

            // Emit directory nodes we haven't seen yet
            var prefix_end: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
                const dir = path[0 .. sep + 1];
                if (!seen_dirs.contains(dir)) {
                    try seen_dirs.put(dir, {});
                    const depth = std.mem.count(u8, dir[0..sep], "/");
                    for (0..depth) |_| try writer.writeAll("  ");
                    const dir_name = path[if (depth > 0) std.mem.lastIndexOfScalar(u8, dir[0..sep], '/').? + 1 else 0..sep];
                    try writer.print("{s}{s}/{s}\n", .{ s.bold, dir_name, s.reset });
                }
                prefix_end = sep + 1;
            }

            // Emit file leaf
            const depth = std.mem.count(u8, path, "/");
            for (0..depth) |_| try writer.writeAll("  ");
            const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
            const lang = @tagName(outline.language);
            const descriptor = buildOutlineDescriptor(allocator, &outline) catch null;
            defer if (descriptor) |d| allocator.free(d);
            try writer.print("{s}  {s}{s}{s}  {s}{d}L  {d} sym{s}", .{
                basename,
                s.langColor(lang),
                lang,
                s.reset,
                s.dim,
                outline.line_count,
                outline.symbols.items.len,
                s.reset,
            });
            if (descriptor) |d| try writer.print(" - {s}", .{d});
            try writer.writeAll("\n");
        }

        return aw.toOwnedSlice();
    }

    pub fn findSymbol(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) !?struct { path: []const u8, symbol: Symbol } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // O(1) lookup via symbol_index
        if (self.symbol_index.get(name)) |locs| {
            if (locs.items.len > 0) {
                const loc = locs.items[0];
                // Fetch detail from outline
                var detail: ?[]const u8 = null;
                var decorators: []const []const u8 = &.{};
                var return_type: ?[]const u8 = null;
                var param_types: []const []const u8 = &.{};
                if (self.outlines.getPtr(loc.path)) |outline| {
                    for (outline.symbols.items) |sym| {
                        if (sym.line_start == loc.line_start and symbolNameMatches(sym.name, name)) {
                            detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                            decorators = try cloneDecorators(allocator, sym.decorators);
                            return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
                            param_types = try cloneParamTypes(allocator, sym.param_types);
                            break;
                        }
                    }
                }
                errdefer if (detail) |d| allocator.free(d);
                errdefer freeDecorators(allocator, decorators);
                errdefer if (return_type) |rt| allocator.free(rt);
                errdefer freeParamTypes(allocator, param_types);
                return .{
                    .path = try allocator.dupe(u8, loc.path),
                    .symbol = .{
                        .name = try allocator.dupe(u8, name),
                        .kind = loc.kind,
                        .line_start = loc.line_start,
                        .line_end = loc.line_end,
                        .detail = detail,
                        .decorators = decorators,
                        .return_type = return_type,
                        .param_types = param_types,
                    },
                };
            }
        }

        // Fallback: scan outlines (handles edge cases during index build)
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (symbolNameMatches(sym.name, name)) {
                    return .{
                        .path = try allocator.dupe(u8, entry.key_ptr.*),
                        .symbol = .{
                            .name = try allocator.dupe(u8, sym.name),
                            .kind = sym.kind,
                            .line_start = sym.line_start,
                            .line_end = sym.line_end,
                            .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                            .decorators = try cloneDecorators(allocator, sym.decorators),
                            .return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null,
                            .param_types = try cloneParamTypes(allocator, sym.param_types),
                        },
                    };
                }
            }
        }
        return null;
    }

    pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SymbolResult) = .empty;
        errdefer result_list.deinit(allocator);

        // Track (path, line_start) pairs already appended. symbol_index can be
        // incomplete after fast-snapshot restore (outlines are populated before
        // rebuildSymbolIndexFor runs on every file), so we must still fall
        // through to the outline scan — and dedupe against what the index
        // already supplied. Keys are "<path>:<line>" allocated from the caller
        // allocator, freed at end of call.
        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var sit = seen.keyIterator();
            while (sit.next()) |k| allocator.free(k.*);
            seen.deinit();
        }

        if (self.symbol_index.get(name)) |locs| {
            for (locs.items) |loc| {
                var detail: ?[]const u8 = null;
                var decorators: []const []const u8 = &.{};
                var return_type: ?[]const u8 = null;
                var param_types: []const []const u8 = &.{};
                if (self.outlines.getPtr(loc.path)) |outline| {
                    for (outline.symbols.items) |sym| {
                        if (sym.line_start == loc.line_start and symbolNameMatches(sym.name, name)) {
                            detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                            decorators = try cloneDecorators(allocator, sym.decorators);
                            return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null;
                            param_types = try cloneParamTypes(allocator, sym.param_types);
                            break;
                        }
                    }
                }
                errdefer if (detail) |d| allocator.free(d);
                errdefer freeDecorators(allocator, decorators);
                errdefer if (return_type) |rt| allocator.free(rt);
                errdefer freeParamTypes(allocator, param_types);
                try result_list.append(allocator, .{
                    .path = try allocator.dupe(u8, loc.path),
                    .symbol = .{
                        .name = try allocator.dupe(u8, name),
                        .kind = loc.kind,
                        .line_start = loc.line_start,
                        .line_end = loc.line_end,
                        .detail = detail,
                        .decorators = decorators,
                        .return_type = return_type,
                        .param_types = param_types,
                    },
                });
                const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ loc.path, loc.line_start });
                seen.put(key, {}) catch allocator.free(key);
            }
        }

        // Safety scan: append any outline symbols the index missed.
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (!symbolNameMatches(sym.name, name)) continue;
                var key_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ entry.key_ptr.*, sym.line_start }) catch continue;
                if (seen.contains(key)) continue;
                try result_list.append(allocator, .{
                    .path = try allocator.dupe(u8, entry.key_ptr.*),
                    .symbol = .{
                        .name = try allocator.dupe(u8, sym.name),
                        .kind = sym.kind,
                        .line_start = sym.line_start,
                        .line_end = sym.line_end,
                        .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                        .decorators = try cloneDecorators(allocator, sym.decorators),
                        .return_type = if (sym.return_type) |rt| try allocator.dupe(u8, rt) else null,
                        .param_types = try cloneParamTypes(allocator, sym.param_types),
                    },
                });
            }
        }
        return result_list.toOwnedSlice(allocator);
    }

    pub fn searchContent(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (max_results == 0) return try allocator.alloc(SearchResult, 0);

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer result_list.deinit(allocator);

        // searched tracks which paths have been scanned — shared across all tiers.
        var searched = std.StringHashMap(void).init(allocator);
        defer searched.deinit();

        // Tier 0: word index direct lookup — O(1) hash lookup plus bounded
        // content extraction. A per-file cap forces diversity so a single hot
        // file cannot saturate the quota. Code files are considered before
        // docs, and files with more exact word hits are considered first so
        // popular identifiers and skip-trigram canonical files are not hidden
        // behind earlier low-signal posting-list entries.
        const word_hits = self.word_index.search(query);
        if (word_hits.len > 0) {
            const Tier0File = struct {
                path: []const u8,
                count: u32,
                first_seen: usize,
            };

            var tier0_files_by_path = std.StringHashMap(Tier0File).init(allocator);
            defer tier0_files_by_path.deinit();

            for (word_hits, 0..) |hit, ordinal| {
                const hit_path = self.word_index.hitPath(hit);
                if (hit_path.len == 0) continue;
                const gop = tier0_files_by_path.getOrPut(hit_path) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .path = hit_path,
                        .count = 0,
                        .first_seen = ordinal,
                    };
                }
                gop.value_ptr.count +|= 1;
            }

            var tier0_files: std.ArrayList(Tier0File) = .empty;
            defer tier0_files.deinit(allocator);
            try tier0_files.ensureTotalCapacity(allocator, tier0_files_by_path.count());
            var tier0_iter = tier0_files_by_path.valueIterator();
            while (tier0_iter.next()) |stats| {
                tier0_files.appendAssumeCapacity(stats.*);
            }

            if (tier0_files.items.len > 1) {
                std.sort.block(Tier0File, tier0_files.items, {}, struct {
                    pub fn lessThan(_: void, a: Tier0File, b: Tier0File) bool {
                        const a_doc = isDocLanguage(detectLanguage(a.path));
                        const b_doc = isDocLanguage(detectLanguage(b.path));
                        if (a_doc != b_doc) return !a_doc;
                        if (a.count != b.count) return a.count > b.count;
                        if (a.first_seen != b.first_seen) return a.first_seen < b.first_seen;
                        return std.mem.lessThan(u8, a.path, b.path);
                    }
                }.lessThan);
            }

            const tier0_per_file_cap: usize = if (tier0_files.items.len <= 1) max_results else @max(1, max_results / 5);
            for (tier0_files.items) |stats| {
                if (result_list.items.len >= max_results) break;
                const ref = self.readContentForSearch(stats.path, allocator) orelse continue;
                defer ref.deinit();
                searched.put(stats.path, {}) catch {};
                try searchInContent(stats.path, ref.data, query, allocator, tier0_per_file_cap, max_results, &result_list);
            }
            if (result_list.items.len >= max_results)
                return self.rerankAndFinalize(&result_list, query, allocator);
        }

        // Tier 0.5: prefix expansion — find all indexed keys that begin with the query.
        // Activates when Tier 0 found nothing and query is ≥3 chars, catching partial
        // identifier queries like "searchC" that match "searchContent" in the word index.
        if (result_list.items.len == 0 and query.len >= 3) {
            const prefix_hits = try self.word_index.searchPrefix(query, allocator, max_results);
            defer allocator.free(prefix_hits);
            for (prefix_hits) |hit| {
                const hit_path = self.word_index.hitPath(hit);
                if (hit_path.len == 0) continue;
                const ref = self.readContentForSearch(hit_path, allocator) orelse continue;
                defer ref.deinit();
                const line_text = extractLineByNumber(ref.data, hit.line_num) orelse continue;
                if (indexOfCaseInsensitive(line_text, query) == null) continue;
                const duped_text = try allocator.dupe(u8, line_text);
                errdefer allocator.free(duped_text);
                const duped_path = try allocator.dupe(u8, hit_path);
                errdefer allocator.free(duped_path);
                try result_list.append(allocator, .{
                    .path = duped_path,
                    .line_num = hit.line_num,
                    .line_text = duped_text,
                });
                searched.put(hit_path, {}) catch {};
                if (result_list.items.len >= max_results) break;
            }
            if (result_list.items.len >= max_results)
                return self.rerankAndFinalize(&result_list, query, allocator);
        }

        const candidate_paths = self.trigram_index.candidates(query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);

        // Tier 1: trigram candidates — fast path, skips files already found by Tier 0.
        if (candidate_paths) |cp| {
            if (cp.len > 0) {
                // Issue #427: rank candidates by per-file word-index hit count
                // (desc) so the definition-dense file scans first; fall back to
                // file content length (asc) so small files still come before
                // unrelated large files at the same hit count. Pre-fix the
                // sort key was content length alone, which buried the canonical
                // file behind unrelated short files when max_per_file was 1.
                var hits_per_file = std.StringHashMap(u32).init(allocator);
                defer hits_per_file.deinit();
                for (word_hits) |hit| {
                    const hp = self.word_index.hitPath(hit);
                    if (hp.len == 0) continue;
                    const gop_h = try hits_per_file.getOrPut(hp);
                    if (!gop_h.found_existing) gop_h.value_ptr.* = 0;
                    gop_h.value_ptr.* += 1;
                }
                const SortCtx = struct {
                    contents: *ContentCache,
                    counts: *const std.StringHashMap(u32),
                    pub fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                        const a_count = ctx.counts.get(a) orelse 0;
                        const b_count = ctx.counts.get(b) orelse 0;
                        if (a_count != b_count) return a_count > b_count;
                        const a_len = if (ctx.contents.get(a)) |c| c.len else std.math.maxInt(usize);
                        const b_len = if (ctx.contents.get(b)) |c| c.len else std.math.maxInt(usize);
                        return a_len < b_len;
                    }
                };
                std.mem.sort([]const u8, @constCast(cp), SortCtx{ .contents = &self.contents, .counts = &hits_per_file }, SortCtx.lessThan);

                const estimated_total = cp.len + self.skip_trigram_files.count();
                const max_per_file = @max(@as(usize, 1), max_results / @max(@as(usize, 1), estimated_total));
                for (cp) |path| {
                    if (searched.contains(path)) continue;
                    const ref = self.readContentForSearch(path, allocator) orelse continue;
                    defer ref.deinit();
                    try searchInContent(path, ref.data, query, allocator, max_per_file, max_results, &result_list);
                    if (result_list.items.len >= max_results)
                        return self.rerankAndFinalize(&result_list, query, allocator);
                }
            }
        }

        // Mark all Tier 1 candidates as searched.
        if (candidate_paths) |cp| {
            for (cp) |p| searched.put(p, {}) catch {};
        }

        // Tier 2: sparse candidates — LAZY, only computed when Tier 1 found nothing.
        if (result_list.items.len == 0) {
            const sparse_paths = self.sparse_ngram_index.candidates(query, allocator);
            defer if (sparse_paths) |sp| allocator.free(sp);
            if (sparse_paths) |sp| {
                for (sp) |path| {
                    if (searched.contains(path)) continue;
                    const ref = self.readContentForSearch(path, allocator) orelse continue;
                    defer ref.deinit();
                    searched.put(path, {}) catch {};
                    try searchInContent(path, ref.data, query, allocator, max_results, max_results, &result_list);
                    if (result_list.items.len >= max_results) break;
                }
            }
        }

        // Tier 3: skip_trigram_files not already searched.
        if (result_list.items.len < max_results) {
            var skip_iter = self.skip_trigram_files.keyIterator();
            while (skip_iter.next()) |key_ptr| {
                if (searched.contains(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                searched.put(key_ptr.*, {}) catch {};
                try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        // Tier 4: word index scan — for files not yet searched.
        if (result_list.items.len < max_results) {
            const tier4_hits = self.word_index.search(query);
            if (tier4_hits.len > 0) {
                var word_paths = std.StringHashMap(void).init(allocator);
                defer word_paths.deinit();
                for (tier4_hits) |hit| word_paths.put(self.word_index.hitPath(hit), {}) catch {};
                var wp_iter = word_paths.keyIterator();
                while (wp_iter.next()) |key_ptr| {
                    if (searched.contains(key_ptr.*)) continue;
                    const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                    defer ref.deinit();
                    searched.put(key_ptr.*, {}) catch {};
                    try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                    if (result_list.items.len >= max_results) break;
                }
            }
        }

        // Tier 5: full scan fallback — only when NO results from any tier.
        // Avoids 100ms+ scans on large repos when indices already found matches.
        if (result_list.items.len == 0) {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (searched.contains(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }
        return self.rerankAndFinalize(&result_list, query, allocator);
    }

    /// Run the multi-signal rerank in place, then transfer ownership of
    /// result_list to the caller. Centralised so every searchContent return
    /// path (Tier 0 / Tier 1 early-return on max_results, fall-through to
    /// final return) gets the same ranking — pre-fix only the fall-through
    /// path applied multi-signal scoring.
    fn rerankAndFinalize(
        self: *const Explorer,
        result_list: *std.ArrayList(SearchResult),
        query: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const SearchResult {
        for (result_list.items) |*r| {
            r.score = self.rerankSignalScore(r.*, query);
        }
        if (result_list.items.len > 1) {
            std.sort.block(SearchResult, result_list.items, {}, struct {
                pub fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                    if (a.score != b.score) return a.score > b.score;
                    const ord = std.mem.order(u8, a.path, b.path);
                    if (ord != .eq) return ord == .lt;
                    return a.line_num < b.line_num;
                }
            }.lessThan);
        }
        self.appendRerankTrace(query, result_list.items);
        return result_list.toOwnedSlice(allocator);
    }

    /// Compose the rerank signals for one search hit (issue #429).
    fn rerankSignalScore(self: *const Explorer, r: SearchResult, query: []const u8) f32 {
        var score: f32 = countOccurrences(r.line_text, query);

        if (self.outlines.get(r.path)) |outline| {
            for (outline.symbols.items) |sym| {
                if (sym.line_start == r.line_num and asciiEqlIgnoreCase(sym.name, query)) {
                    score += 5.0;
                    break;
                }
            }
        }

        const basename = std.fs.path.basename(r.path);
        const stem_end = std.mem.indexOfScalar(u8, basename, '.') orelse basename.len;
        const stem = basename[0..stem_end];
        const stem_contains_query = asciiContainsIgnoreCase(stem, query);
        const query_contains_stem = asciiContainsIgnoreCase(query, stem);
        const stem_related_to_query = stem_contains_query or query_contains_stem;
        if (asciiEqlIgnoreCase(stem, query)) {
            score += 15.0;
        } else if (stem_related_to_query) {
            score += 8.0;
        }
        // Path-segment match boost: query matches a directory segment in
        // the path (e.g. query="parser" boosts src/parser/foo.zig). Weaker
        // than basename match because the file's own name is a stronger
        // intent signal than the directory it lives in. Skip when basename
        // already matched to avoid double-counting.
        if (!stem_related_to_query and pathHasSegmentIgnoreCase(r.path, query)) {
            score += 6.0;
        }

        if (pathHasSegment(r.path, "tests") or pathHasSegment(r.path, "test")) score *= 0.6;
        if (pathHasSegment(r.path, "examples") or pathHasSegment(r.path, "example")) score *= 0.6;
        if (pathHasSegment(r.path, "vendor") or pathHasSegment(r.path, "node_modules") or
            pathHasSegment(r.path, "third_party")) score *= 0.4;
        // Doc-language penalty: markdown / data files (CHANGELOG.md, design
        // docs, benchmark logs) often mention an identifier many times in a
        // single line, which lets per-line frequency dwarf code call sites.
        // For doc files, more mentions don't reflect more code-relevance —
        // they reflect prose density. Cap at 1.0 then halve so any code hit
        // (score >= 1) outranks any doc hit. Symmetric with path-prior.
        if (isDocLanguage(detectLanguage(r.path))) {
            score = @min(score, 1.0) * 0.5;
        }

        return score;
    }

    /// Append one JSON line per searchContent invocation. v0 logger for the
    /// rerank-tuning experiment — pure observation, never affects ranking.
    /// Silent no-op when path is unset, io is unset, or any I/O step fails.
    /// Caps query at 256 bytes, results at 50 entries, file at 10 MB
    /// (rotates by truncate-clobber).
    fn appendRerankTrace(self: *const Explorer, query: []const u8, results: []const SearchResult) void {
        const path = self.rerank_trace_path orelse return;
        const io_inst = self.io orelse return;

        const max_query: usize = 256;
        const max_results_logged: usize = 50;
        const size_limit: u64 = 10 * 1024 * 1024;

        var buf: [16 * 1024]u8 = undefined;
        var pos: usize = 0;

        const ts = cio.milliTimestamp();
        const head = std.fmt.bufPrint(buf[pos..], "{{\"ts\":{d},\"query\":\"", .{ts}) catch return;
        pos += head.len;

        const q_clamped = query[0..@min(query.len, max_query)];
        pos += writeJsonEscaped(buf[pos..], q_clamped);

        const sep = "\",\"results\":[";
        if (pos + sep.len > buf.len) return;
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;

        var any_emitted = false;
        const n = @min(results.len, max_results_logged);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = results[i];
            const sep_len: usize = if (any_emitted) 1 else 0;
            const tail_reserve: usize = 3; // "]}\n"
            const escaped_path_budget: usize = 2 * r.path.len;
            const fixed_overhead: usize = "{\"path\":\"".len + "\",\"line\":,\"score\":}".len + 32;
            if (pos + sep_len + escaped_path_budget + fixed_overhead + tail_reserve > buf.len) break;

            if (any_emitted) {
                buf[pos] = ',';
                pos += 1;
            }
            const open = "{\"path\":\"";
            @memcpy(buf[pos..][0..open.len], open);
            pos += open.len;
            pos += writeJsonEscaped(buf[pos..], r.path);
            const obj_tail = std.fmt.bufPrint(buf[pos..], "\",\"line\":{d},\"score\":{d:.4}}}", .{ r.line_num, r.score }) catch break;
            pos += obj_tail.len;
            any_emitted = true;
        }

        const close = "]}\n";
        if (pos + close.len > buf.len) return;
        @memcpy(buf[pos..][0..close.len], close);
        pos += close.len;

        var file = std.Io.Dir.cwd().openFile(io_inst, path, .{ .mode = .write_only }) catch blk: {
            break :blk std.Io.Dir.cwd().createFile(io_inst, path, .{ .truncate = false }) catch return;
        };
        var current_size = file.length(io_inst) catch {
            file.close(io_inst);
            return;
        };
        if (current_size >= size_limit) {
            file.close(io_inst);
            file = std.Io.Dir.cwd().createFile(io_inst, path, .{ .truncate = true }) catch return;
            current_size = 0;
        }
        defer file.close(io_inst);

        const locked = blk: {
            file.lock(io_inst, .exclusive) catch break :blk false;
            break :blk true;
        };
        defer if (locked) file.unlock(io_inst);

        if (locked) {
            current_size = file.length(io_inst) catch current_size;
            if (current_size >= size_limit) current_size = 0;
        }

        file.writePositionalAll(io_inst, buf[0..pos], current_size) catch {};
    }

    /// BM25-ranked content search. Tokenizes the query the same way the word
    /// index tokenizes documents, scores each candidate doc with BM25
    /// (k1=1.2, b=0.75), and emits one SearchResult per top-N document with
    /// the best-tf line for any query term in that doc. Existing scan-order
    /// `searchContent` is unaffected.
    pub fn searchContentRanked(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (max_results == 0) return try allocator.alloc(SearchResult, 0);

        // Tokenize the query the same way WordIndex tokenizes documents:
        // lowercase + identifier-split. Dedupe terms so repeated query words
        // don't double-count.
        var term_arena = std.heap.ArenaAllocator.init(allocator);
        defer term_arena.deinit();
        const ta = term_arena.allocator();

        var terms_set = std.StringHashMap(void).init(ta);
        var raw_tok = idx.WordTokenizer{ .buf = query };
        while (raw_tok.next()) |word| {
            if (word.len < 2) continue;
            const lower = try ta.alloc(u8, word.len);
            for (word, 0..) |c, j| lower[j] = idx.normalizeChar(c);
            _ = try terms_set.getOrPut(lower);

            var needs_split: bool = false;
            if (word.len >= 4) {
                for (word) |c| {
                    if (c == '_' or (c >= 'A' and c <= 'Z')) {
                        needs_split = true;
                        break;
                    }
                }
            }
            if (needs_split) {
                var sub_toks: std.ArrayList([]const u8) = .empty;
                defer sub_toks.deinit(ta);
                idx.splitIdentifier(word, &sub_toks, ta) catch continue;
                for (sub_toks.items) |sub| {
                    if (sub.len < 2) continue;
                    _ = try terms_set.getOrPut(sub);
                }
            }
        }
        if (terms_set.count() == 0) return try allocator.alloc(SearchResult, 0);

        // BM25 constants.
        const k1: f32 = 1.2;
        const b: f32 = 0.75;
        const N = self.word_index.rankedDocCount();
        if (N == 0) return try allocator.alloc(SearchResult, 0);
        const avgdl = self.word_index.avgDocLength();

        // Aggregate scores per doc and remember the best line (max term hits)
        // for each candidate.
        const DocAgg = struct {
            score: f32,
            best_line: u32,
            best_line_hits: u32,
        };
        var per_doc = std.AutoHashMap(u32, DocAgg).init(ta);

        // For each unique query term, look up its posting list once,
        // compute df and per-doc tf in a single pass.
        var term_iter = terms_set.keyIterator();
        while (term_iter.next()) |term_ptr| {
            const term = term_ptr.*;
            const hits = self.word_index.search(term);
            if (hits.len == 0) continue;

            // df: distinct doc_ids in this posting list. tf: count of (term,doc)
            // entries (each entry is a distinct line per indexFile dedup).
            // line_hits: per-doc map of line_num → count for best-line picking.
            var doc_tf = std.AutoHashMap(u32, u32).init(ta);
            var doc_best_line = std.AutoHashMap(u32, struct { line: u32, count: u32 }).init(ta);
            for (hits) |h| {
                const tf_gop = try doc_tf.getOrPut(h.doc_id);
                if (!tf_gop.found_existing) tf_gop.value_ptr.* = 0;
                tf_gop.value_ptr.* += 1;

                const ln_gop = try doc_best_line.getOrPut(h.doc_id);
                if (!ln_gop.found_existing) {
                    ln_gop.value_ptr.* = .{ .line = h.line_num, .count = 1 };
                } else {
                    // Each posting is a distinct line; still, prefer the
                    // smallest line_num as a deterministic representative.
                    if (h.line_num < ln_gop.value_ptr.line) {
                        ln_gop.value_ptr.line = h.line_num;
                    }
                    ln_gop.value_ptr.count += 1;
                }
            }
            const df: u32 = @intCast(doc_tf.count());
            // BM25 idf with the +1 smoothing variant: log(1 + (N - df + 0.5)/(df + 0.5))
            const num: f32 = @as(f32, @floatFromInt(N)) - @as(f32, @floatFromInt(df)) + 0.5;
            const den: f32 = @as(f32, @floatFromInt(df)) + 0.5;
            const idf: f32 = @log(1.0 + num / den);

            var tf_iter = doc_tf.iterator();
            while (tf_iter.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const tf: f32 = @floatFromInt(entry.value_ptr.*);
                const dl_raw = self.word_index.docLength(doc_id);
                const dl: f32 = if (dl_raw == 0) 1.0 else @floatFromInt(dl_raw);
                const norm = 1.0 - b + b * (dl / avgdl);
                const term_score = idf * (tf * (k1 + 1.0)) / (tf + k1 * norm);

                const ln_info = doc_best_line.get(doc_id) orelse continue;
                const agg_gop = try per_doc.getOrPut(doc_id);
                if (!agg_gop.found_existing) {
                    agg_gop.value_ptr.* = .{
                        .score = term_score,
                        .best_line = ln_info.line,
                        .best_line_hits = ln_info.count,
                    };
                } else {
                    agg_gop.value_ptr.score += term_score;
                    if (ln_info.count > agg_gop.value_ptr.best_line_hits or
                        (ln_info.count == agg_gop.value_ptr.best_line_hits and ln_info.line < agg_gop.value_ptr.best_line))
                    {
                        agg_gop.value_ptr.best_line = ln_info.line;
                        agg_gop.value_ptr.best_line_hits = ln_info.count;
                    }
                }
            }
        }
        if (per_doc.count() == 0) return try allocator.alloc(SearchResult, 0);

        const Cand = struct { doc_id: u32, score: f32, best_line: u32 };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(ta);
        try cands.ensureTotalCapacity(ta, per_doc.count());
        var pd_iter = per_doc.iterator();
        while (pd_iter.next()) |entry| {
            cands.appendAssumeCapacity(.{
                .doc_id = entry.key_ptr.*,
                .score = entry.value_ptr.score,
                .best_line = entry.value_ptr.best_line,
            });
        }
        std.sort.block(Cand, cands.items, {}, struct {
            pub fn lt(_: void, a: Cand, b_: Cand) bool {
                if (a.score != b_.score) return a.score > b_.score;
                return a.doc_id < b_.doc_id;
            }
        }.lt);

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
            }
            result_list.deinit(allocator);
        }
        try result_list.ensureTotalCapacity(allocator, @min(max_results, cands.items.len));

        for (cands.items) |c| {
            if (result_list.items.len >= max_results) break;
            const path = self.word_index.id_to_path.items[c.doc_id];
            if (path.len == 0) continue;
            const ref = self.readContentForSearch(path, allocator) orelse continue;
            defer ref.deinit();
            const line_text = extractLineByNumber(ref.data, c.best_line) orelse continue;
            const duped_text = try allocator.dupe(u8, line_text);
            errdefer allocator.free(duped_text);
            const duped_path = try allocator.dupe(u8, path);
            errdefer allocator.free(duped_path);
            try result_list.append(allocator, .{
                .path = duped_path,
                .line_num = c.best_line,
                .line_text = duped_text,
                .score = c.score,
            });
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search file contents using a regex pattern with trigram acceleration.
    /// Decomposes the regex to extract literal trigrams for candidate filtering,
    /// then does actual regex matching on candidates.
    pub fn searchContentRegex(self: *Explorer, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer result_list.deinit(allocator);

        var query = idx.decomposeRegex(pattern, self.allocator) catch {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        };
        defer query.deinit();

        const candidate_paths = self.trigram_index.candidatesRegex(&query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);
        const use_trigram = candidate_paths != null and candidate_paths.?.len > 0;

        if (use_trigram) {
            for (candidate_paths.?) |path| {
                const ref = self.readContentForSearch(path, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(path, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        } else {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        }

        if (result_list.items.len < max_results) {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (self.trigram_index.containsFile(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search for a word using the inverted word index. O(1) lookup.
    pub fn searchWord(self: *Explorer, word: []const u8, allocator: std.mem.Allocator) ![]const idx.WordHit {
        self.mu.lockShared();
        const needs_rebuild = !self.word_index_complete and
            (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
        self.mu.unlockShared();
        if (needs_rebuild) {
            try self.rebuildWordIndex();
        }

        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index.searchDeduped(word, allocator);
    }

    pub const FuzzyMatch = struct {
        path: []const u8,
        score: f32,
    };

    pub fn fuzzyFindFiles(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const FuzzyMatch {
        if (query.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Parse query: split on spaces, extract extension constraints (*.py, *.ts)
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var ext_filter: ?[]const u8 = null;

        var tok_iter = std.mem.splitScalar(u8, query, ' ');
        while (tok_iter.next()) |token| {
            if (token.len == 0) continue;
            // Extension constraint: *.py, *.ts, *.zig
            if (token.len >= 2 and token[0] == '*' and token[1] == '.') {
                ext_filter = token[1..]; // ".py", ".ts", etc.
            } else {
                try parts.append(allocator, token);
            }
        }

        if (parts.items.len == 0) return &.{};

        var matches: std.ArrayList(FuzzyMatch) = .empty;
        errdefer matches.deinit(allocator);

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const path = key_ptr.*;

            // Extension filter
            if (ext_filter) |ext| {
                if (!std.mem.endsWith(u8, path, ext)) continue;
            }

            // Multi-part scoring: all parts must match, scores sum
            var total_score: f32 = 0;
            var all_matched = true;
            for (parts.items) |part| {
                if (fuzzyScore(part, path)) |s| {
                    total_score += s;
                } else {
                    all_matched = false;
                    break;
                }
            }

            if (all_matched and total_score > 0) {
                try matches.append(allocator, .{ .path = path, .score = total_score });
            }
        }

        // Sort by score descending
        std.mem.sort(FuzzyMatch, matches.items, {}, struct {
            fn lt(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);

        // Truncate to max_results
        if (matches.items.len > max_results) {
            matches.items.len = max_results;
        }

        return matches.toOwnedSlice(allocator) catch {
            matches.deinit(allocator);
            return &.{};
        };
    }

    pub const LsEntry = struct {
        name: []const u8,
        is_dir: bool,
        line_count: u32 = 0,
        sym_count: u32 = 0,
        language: Language = .unknown,
        dependent_count: u32 = 0,
        hotspot_score: u32 = 0,
        is_stub: bool = false,
        descriptor: []const u8 = "",
    };

    pub fn globPaths(self: *Explorer, allocator: std.mem.Allocator, pattern: []const u8, max_results: usize) ![][]const u8 {
        if (pattern.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();

        var matches: std.ArrayList([]const u8) = .empty;
        errdefer matches.deinit(allocator);
        // Reserve a guess so small/medium glob result sets don't trigger
        // multiple geometric reallocations.
        matches.ensureTotalCapacity(allocator, @min(64, self.outlines.count())) catch {};

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const path = key_ptr.*;
            if (matchGlob(pattern, path)) {
                try matches.append(allocator, path);
            }
        }

        std.mem.sort([]const u8, matches.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        if (matches.items.len > max_results) matches.items.len = max_results;

        return matches.toOwnedSlice(allocator);
    }

    pub fn lsDir(self: *Explorer, allocator: std.mem.Allocator, prefix: []const u8, ranked: bool) ![]LsEntry {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Normalize: trim trailing slash. Empty prefix means root.
        var p = prefix;
        if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];

        var entries: std.ArrayList(LsEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                if (!entry.is_dir and entry.descriptor.len > 0) allocator.free(entry.descriptor);
            }
            entries.deinit(allocator);
        }
        // Most listings produce a small set; a single up-front allocation
        // avoids the geometric-realloc dance for typical directories.
        entries.ensureTotalCapacity(allocator, 32) catch {};

        // Each outline key is unique, so a file `rel` is emitted at most once
        // by construction. We only need a dedup map for directory names since
        // multiple paths can share a parent dir.
        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        var iter = self.outlines.iterator();
        while (iter.next()) |kv| {
            const path = kv.key_ptr.*;

            var rel: []const u8 = undefined;
            if (p.len == 0) {
                rel = path;
            } else {
                if (!std.mem.startsWith(u8, path, p)) continue;
                if (path.len <= p.len + 1 or path[p.len] != '/') continue;
                rel = path[p.len + 1 ..];
            }
            if (rel.len == 0) continue;

            if (std.mem.indexOfScalar(u8, rel, '/')) |sep| {
                const dir_name = rel[0..sep];
                const dir_score = if (ranked) self.lsDirHotspotScore(p, dir_name) else 0;
                if (!seen_dirs.contains(dir_name)) {
                    try seen_dirs.put(dir_name, {});
                    try entries.append(allocator, .{ .name = dir_name, .is_dir = true, .hotspot_score = dir_score });
                }
            } else {
                const fo = kv.value_ptr.*;
                const dependent_count: u32 = if (ranked) @intCast(@min(self.dep_graph.importedByCount(path), std.math.maxInt(u32))) else 0;
                const sym_count: u32 = @intCast(fo.symbols.items.len);
                const descriptor = try buildOutlineDescriptor(allocator, &fo);
                try entries.append(allocator, .{
                    .name = rel,
                    .is_dir = false,
                    .line_count = fo.line_count,
                    .sym_count = sym_count,
                    .language = fo.language,
                    .dependent_count = dependent_count,
                    .hotspot_score = dependent_count +| sym_count,
                    .is_stub = isStubLikeOutline(&fo),
                    .descriptor = descriptor,
                });
            }
        }

        if (ranked) {
            std.mem.sort(LsEntry, entries.items, {}, struct {
                fn lt(_: void, a: LsEntry, b: LsEntry) bool {
                    if (a.hotspot_score != b.hotspot_score) return a.hotspot_score > b.hotspot_score;
                    if (a.is_dir != b.is_dir) return a.is_dir;
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt);
        } else {
            std.mem.sort(LsEntry, entries.items, {}, struct {
                fn lt(_: void, a: LsEntry, b: LsEntry) bool {
                    if (a.is_dir != b.is_dir) return a.is_dir;
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt);
        }

        return entries.toOwnedSlice(allocator);
    }

    fn lsDirHotspotScore(self: *Explorer, prefix: []const u8, dir_name: []const u8) u32 {
        var score: u32 = 0;
        var child_prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
        const child_prefix = if (prefix.len == 0)
            std.fmt.bufPrint(&child_prefix_buf, "{s}/", .{dir_name}) catch return 0
        else
            std.fmt.bufPrint(&child_prefix_buf, "{s}/{s}/", .{ prefix, dir_name }) catch return 0;

        var iter = self.outlines.iterator();
        while (iter.next()) |kv| {
            const path = kv.key_ptr.*;
            if (!std.mem.startsWith(u8, path, child_prefix)) continue;
            const fo = kv.value_ptr.*;
            const dependent_count: u32 = @intCast(@min(self.dep_graph.importedByCount(path), std.math.maxInt(u32)));
            const sym_count: u32 = @intCast(fo.symbols.items.len);
            score +|= dependent_count +| sym_count;
        }
        return score;
    }

    pub fn isStubLikeOutline(outline: *const FileOutline) bool {
        if (!isStubCandidateLanguage(outline.language)) return false;
        const sym_count = outline.symbols.items.len;
        return outline.line_count > 0 and outline.line_count <= 80 and sym_count > 0 and sym_count <= 2;
    }

    pub fn buildOutlineDescriptor(allocator: std.mem.Allocator, outline: *const FileOutline) ![]const u8 {
        var functions: usize = 0;
        var methods: usize = 0;
        var types_count: usize = 0;
        var imports_count: usize = 0;
        var route_actions: usize = 0;
        var post_actions: usize = 0;
        var authorized = false;
        var first_type: ?Symbol = null;

        for (outline.symbols.items) |sym| {
            switch (sym.kind) {
                .function => functions += 1,
                .method => methods += 1,
                .class_def, .interface_def, .trait_def, .struct_def, .enum_def => {
                    types_count += 1;
                    if (first_type == null) first_type = sym;
                },
                .import => imports_count += 1,
                else => {},
            }
            if (sym.decorators.len > 0) {
                if (decoratorsContainText(sym.decorators, "Authorize")) authorized = true;
                if (decoratorsContainText(sym.decorators, "Http")) route_actions += 1;
                if (decoratorsContainText(sym.decorators, "HttpPost")) post_actions += 1;
            }
        }

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (isStubLikeOutline(outline)) {
            try buf.appendSlice(allocator, "Stub");
        } else if (first_type) |sym| {
            try appendFmt(allocator, &buf, "{s} {s}", .{ @tagName(sym.kind), sym.name });
            if (extractBaseDescriptor(sym.detail)) |base| {
                try appendFmt(allocator, &buf, " extends {s}", .{base});
            }
        } else if (functions > 0) {
            try appendFmt(allocator, &buf, "{d} functions", .{functions});
        } else if (methods > 0) {
            try appendFmt(allocator, &buf, "{d} methods", .{methods});
        } else {
            try appendFmt(allocator, &buf, "{s} file", .{@tagName(outline.language)});
        }

        if (route_actions > 0) {
            try appendFmt(allocator, &buf, "; {d} routes", .{route_actions});
            if (post_actions > 0) try appendFmt(allocator, &buf, ", {d} POST", .{post_actions});
        } else if (methods > 0) {
            try appendFmt(allocator, &buf, "; {d} methods", .{methods});
        } else if (functions > 0 and first_type != null) {
            try appendFmt(allocator, &buf, "; {d} functions", .{functions});
        }

        if (types_count > 1) try appendFmt(allocator, &buf, "; {d} types", .{types_count});
        if (imports_count > 0) try appendFmt(allocator, &buf, "; {d} imports", .{imports_count});
        if (authorized) try buf.appendSlice(allocator, "; authorized");

        return buf.toOwnedSlice(allocator);
    }

    fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(text);
        try buf.appendSlice(allocator, text);
    }

    fn decoratorsContainText(decorators: []const []const u8, needle: []const u8) bool {
        for (decorators) |decorator| {
            if (std.mem.indexOf(u8, decorator, needle) != null) return true;
        }
        return false;
    }

    fn extractBaseDescriptor(detail: ?[]const u8) ?[]const u8 {
        const d = detail orelse return null;
        const colon = std.mem.indexOfScalar(u8, d, ':') orelse return null;
        var rest = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n{");
        if (std.mem.indexOfScalar(u8, rest, ',')) |comma| rest = rest[0..comma];
        if (std.mem.indexOfScalar(u8, rest, '{')) |brace| rest = rest[0..brace];
        rest = std.mem.trim(u8, rest, " \t\r\n");
        return if (rest.len > 0) rest else null;
    }

    fn isStubCandidateLanguage(lang: Language) bool {
        return switch (lang) {
            .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
            else => true,
        };
    }

    pub fn getImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getImportedBy(path, allocator);
    }

    pub fn getTransitiveDependents(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getTransitiveDependents(path, allocator, max_depth);
    }

    pub fn getTransitiveDependencies(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getTransitiveDependencies(path, allocator, max_depth);
    }

    pub fn getHotFiles(self: *Explorer, store: *Store, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
        // Collect stable path copies under explorer lock.
        var path_list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (path_list.items) |path| allocator.free(path);
            path_list.deinit(allocator);
        }
        defer path_list.deinit(allocator);
        {
            self.mu.lockShared();
            defer self.mu.unlockShared();
            var iter = self.outlines.iterator();
            while (iter.next()) |kv| {
                const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
                try path_list.append(allocator, path_copy);
            }
        }

        // Query store seqs without holding explorer lock.
        const Entry = struct { path: []u8, seq: u64 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(allocator);
        {
            store.mu.lock();
            defer store.mu.unlock();
            for (path_list.items) |path| {
                const seq = store.getLatestSeqUnlocked(path);
                try entries.append(allocator, .{ .path = path, .seq = seq });
            }
        }

        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.seq > b.seq;
            }
        }.cmp);

        const count = @min(limit, entries.items.len);
        const paths = try allocator.alloc([]const u8, count);
        for (entries.items[0..count], 0..) |e, i| {
            paths[i] = e.path;
        }
        for (entries.items[count..]) |e| {
            allocator.free(e.path);
        }
        return paths;
    }

    // ── Language parsers ──────────────────────────────────────

    pub const extractZigFuncTypes = @import("explore/type_extract.zig").extractZigFuncTypes;
    pub const extractPythonFuncTypes = @import("explore/type_extract.zig").extractPythonFuncTypes;
    pub const extractTsFunctionTypes = @import("explore/type_extract.zig").extractTsFunctionTypes;
    pub const extractTsParamType = @import("explore/type_extract.zig").extractTsParamType;
    pub const stripJavaModifiers = @import("explore/type_extract.zig").stripJavaModifiers;
    pub const extractJvmParamType = @import("explore/type_extract.zig").extractJvmParamType;
    pub const extractJvmFuncTypes = @import("explore/type_extract.zig").extractJvmFuncTypes;
    pub const extractKotlinFuncTypes = @import("explore/type_extract.zig").extractKotlinFuncTypes;
    pub const extractRustFuncTypes = @import("explore/type_extract.zig").extractRustFuncTypes;
    pub const extractGoFuncTypes = @import("explore/type_extract.zig").extractGoFuncTypes;
    pub const extractGoParamType = @import("explore/type_extract.zig").extractGoParamType;

    fn parseZigLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "pub fn ") or startsWith(line, "fn ")) {
            const start: usize = if (startsWith(line, "pub fn ")) 7 else 3;
            if (extractIdent(line[start..])) |name| {
                var zig_param_buf: [16][]const u8 = undefined;
                const zig_types = extractZigFuncTypes(line, &zig_param_buf);
                const zig_params = zig_param_buf[0..zig_types.param_count];
                try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, zig_types.ret, zig_params);
            }
        } else if (startsWith(line, "pub const ") or startsWith(line, "const ")) {
            const start: usize = if (startsWith(line, "pub const ")) 10 else 6;
            if (extractIdent(line[start..])) |name| {
                const kind: SymbolKind = if (std.mem.indexOf(u8, line, "struct {") != null)
                    .struct_def
                else if (std.mem.indexOf(u8, line, "enum {") != null)
                    .enum_def
                else if (std.mem.indexOf(u8, line, "union {") != null or
                    std.mem.indexOf(u8, line, "union(enum) {") != null)
                    .union_def
                else if (std.mem.indexOf(u8, line, "@import") != null)
                    .import
                else
                    .constant;

                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });

                if (kind == .import) {
                    if (extractStringLiteral(line)) |import_path| {
                        const import_copy = try a.dupe(u8, import_path);
                        errdefer a.free(import_copy);
                        try outline.imports.append(a, import_copy);
                    }
                }
            }
        } else if (startsWith(line, "test ")) {
            const name_copy = try a.dupe(u8, line);
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .test_decl,
                .line_start = line_num,
                .line_end = line_num,
            });
        }
    }

    fn parsePythonLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            if (extractIdent(line[4..])) |name| {
                var py_param_buf: [16][]const u8 = undefined;
                const py_types = extractPythonFuncTypes(line, &py_param_buf);
                const py_params = py_param_buf[0..py_types.param_count];
                try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, py_types.ret, py_params);
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "import ") or startsWith(line, "from ")) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            // Extract module path and convert dots to slashes for dep matching.
            // "from mypackage.utils.helpers import X" → "mypackage/utils/helpers.py"
            // "import os.path" → "os/path.py"
            if (extractPythonModulePath(line)) |mod_path| {
                var buf: [512]u8 = undefined;
                var pos: usize = 0;
                for (mod_path) |c| {
                    if (pos >= buf.len - 3) break;
                    buf[pos] = if (c == '.') '/' else c;
                    pos += 1;
                }
                if (pos + 3 <= buf.len) {
                    buf[pos] = '.';
                    buf[pos + 1] = 'p';
                    buf[pos + 2] = 'y';
                    pos += 3;
                }
                const import_copy = try a.dupe(u8, buf[0..pos]);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }

    fn parseTsLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (containsAny(line, &.{ "function ", "const ", "let ", "var ", "class ", "interface ", "enum ", "type " })) {
            const kind: SymbolKind = if (std.mem.indexOf(u8, line, "function") != null)
                .function
            else if (std.mem.indexOf(u8, line, "class ") != null)
                .class_def
            else if (std.mem.indexOf(u8, line, "interface ") != null)
                .interface_def
            else if (std.mem.indexOf(u8, line, "enum ") != null)
                .enum_def
            else if (std.mem.indexOf(u8, line, "type ") != null)
                .type_alias
            else
                .constant;
            const trimmed = skipKeywords(line);
            if (extractIdent(trimmed)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);

                // Extract return type and param types for functions
                var return_type: ?[]const u8 = null;
                var param_types: []const []const u8 = &.{};
                if (kind == .function) {
                    var ts_param_buf: [16][]const u8 = undefined;
                    const ts_types = extractTsFunctionTypes(line, &ts_param_buf);
                    return_type = ts_types.ret;
                    param_types = ts_param_buf[0..ts_types.param_count];
                }

                const rt_copy: ?[]const u8 = if (return_type) |rt| try a.dupe(u8, rt) else null;
                errdefer if (rt_copy) |rt| a.free(rt);
                const pt_copy = try a.dupe([]const u8, param_types);
                errdefer a.free(pt_copy);
                for (param_types, 0..) |pt, i| {
                    pt_copy[i] = try a.dupe(u8, pt);
                    errdefer for (pt_copy[0..i]) |p| a.free(p);
                }

                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                    .return_type = rt_copy,
                    .param_types = pt_copy,
                });
            }
        }
        if (containsAny(line, &.{ "import ", "require(" })) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }

    fn parseJavaLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@")) return;

        if (parseDelimitedImport(line, "import ", ";")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "record ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractJvmMethodName(line)) |name| {
            var java_param_buf: [16][]const u8 = undefined;
            const java_types = extractJvmFuncTypes(line, &java_param_buf);
            const java_params = java_param_buf[0..java_types.param_count];
            try appendOutlineSymbolWithTypes(a, outline, name, .method, line_num, line, java_types.ret, java_params);
        }
    }

    fn parseKotlinLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@")) return;

        if (parseDelimitedImport(line, "import ", "")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "enum class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "object ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "fun ")) |name| {
            var kt_param_buf: [16][]const u8 = undefined;
            const kt_types = extractKotlinFuncTypes(line, &kt_param_buf);
            const kt_params = kt_param_buf[0..kt_types.param_count];
            try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, kt_types.ret, kt_params);
        } else if (extractIdentAfterKeyword(line, "val ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "var ")) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseCSharpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        // Multi-declarator fields (`private int a, b, c;`) emit one symbol per
        // name. Initializer lists bail to the single-field path below.
        var field_names: [csharp_parser.max_field_names][]const u8 = undefined;
        const field_count = csharp_parser.extractFieldNames(raw_line, &field_names);
        if (field_count > 1) {
            for (field_names[0..field_count]) |nm| {
                try appendOutlineSymbol(a, outline, nm, .variable, line_num, raw_line);
            }
            return;
        }
        switch (csharp_parser.parseLine(raw_line)) {
            .none => {},
            .import => |imp| try appendImportSymbol(a, outline, imp, line_num, raw_line),
            .symbol => |sym| {
                const mapped_kind = cSharpSymbolKind(sym.kind);
                // Convert C# parser's ParamTypesResult to a slice for the outline
                const pt_slice = sym.param_types.slice();
                // For enum members (constant kind from C# parser), extract `= value` as detail
                if (mapped_kind == .constant) {
                    const detail = extractCSharpEnumValue(raw_line);
                    try appendOutlineSymbol(a, outline, sym.name, mapped_kind, line_num, detail);
                } else {
                    try appendOutlineSymbolWithTypes(a, outline, sym.name, mapped_kind, line_num, raw_line, sym.return_type, pt_slice);
                }
            },
        }
    }

    /// Extract the `= value` portion from a C# enum member line.
    /// Returns the trimmed value string, or the raw_line if no value found.
    fn extractCSharpEnumValue(raw_line: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, raw_line, " \t");
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const after_eq = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t,");
            if (after_eq.len > 0) return after_eq;
        }
        return raw_line;
    }

    fn parseFSharpLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        switch (fsharp_parser.parseLine(line)) {
            .none => {},
            .import => |imp| try appendImportSymbol(a, outline, imp, line_num, line),
            .symbol => |sym| try appendOutlineSymbol(a, outline, sym.name, fSharpSymbolKind(sym.kind), line_num, line),
        }
    }

    /// Parse a Razor/cshtml line. Tracks @functions/@code blocks and delegates
    /// their contents to the C# parser. Outside code blocks, extracts Razor
    /// directives (@model, @using, @inject, @inherits, @implements, @page,
    /// @namespace, @layout, @typeparam, @section, @attribute).
    fn parseRazorLine(
        self: *Explorer,
        raw_line: []const u8,
        line_num: u32,
        outline: *FileOutline,
        in_code_block: *bool,
        brace_depth: *u32,
    ) !void {
        const a = self.allocator;
        const trimmed = std.mem.trim(u8, raw_line, " \t");

        // Inside a @functions/@code block — delegate to C# parser and track braces
        if (in_code_block.*) {
            // Count braces to know when the block ends
            for (trimmed) |ch| {
                if (ch == '{') brace_depth.* += 1;
                if (ch == '}') {
                    if (brace_depth.* > 0) brace_depth.* -= 1;
                    if (brace_depth.* == 0) {
                        in_code_block.* = false;
                        return;
                    }
                }
            }
            try self.parseCSharpLine(trimmed, line_num, outline);
            return;
        }

        // Not a directive line — skip HTML content
        if (trimmed.len == 0 or trimmed[0] != '@') return;

        // Handle @@escape (literal @) — skip
        if (trimmed.len >= 2 and trimmed[1] == '@') return;

        // Skip @-prefixed control flow that doesn't declare symbols:
        // @if, @else, @for, @foreach, @while, @switch, @case, @default,
        // @try, @catch, @finally, @lock, @using (statement, not directive),
        // @do, @return, @throw, @break, @continue
        if (razorIsControlFlow(trimmed)) return;

        // Skip HTML helper / attribute directives that aren't declarations
        if (startsWith(trimmed, "@rendermode") or startsWith(trimmed, "@ref ") or
            startsWith(trimmed, "@bind") or startsWith(trimmed, "@onclick") or
            startsWith(trimmed, "@onchange") or startsWith(trimmed, "@oninput") or
            startsWith(trimmed, "@onfocus") or startsWith(trimmed, "@onblur") or
            startsWith(trimmed, "@onkeydown") or startsWith(trimmed, "@onkeyup") or
            startsWith(trimmed, "@onmouseover") or startsWith(trimmed, "@onmouseout") or
            startsWith(trimmed, "@ondrop") or startsWith(trimmed, "@ondrag") or
            startsWith(trimmed, "@onsubmit") or startsWith(trimmed, "@onscroll") or
            startsWith(trimmed, "@onpaste") or startsWith(trimmed, "@oncut") or
            startsWith(trimmed, "@oncopy") or startsWith(trimmed, "@oninput"))
            return;

        // @functions { or @code { — enter code block
        if (startsWith(trimmed, "@functions") or startsWith(trimmed, "@code")) {
            in_code_block.* = true;
            brace_depth.* = 1; // the opening { may be on this line or the next
            // If { is on this line, it's already counted
            var found_open = false;
            for (trimmed) |ch| {
                if (ch == '{') found_open = true;
            }
            if (!found_open) brace_depth.* = 0; // will open on next line
            try appendOutlineSymbol(a, outline, if (startsWith(trimmed, "@functions")) "@functions" else "@code", .type_alias, line_num, trimmed);
            return;
        }

        // @model TypeName → type_alias
        if (startsWith(trimmed, "@model ")) {
            const rest = std.mem.trim(u8, trimmed["@model ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
            }
            return;
        }

        // @using Namespace → import
        if (startsWith(trimmed, "@using ")) {
            const rest = std.mem.trim(u8, trimmed["@using ".len..], " \t");
            if (rest.len > 0) {
                try appendImportSymbol(a, outline, rest, line_num, trimmed);
            }
            return;
        }

        // @inject Type Name → import (tracks the type dependency)
        if (startsWith(trimmed, "@inject ")) {
            const rest = std.mem.trim(u8, trimmed["@inject ".len..], " \t");
            if (rest.len > 0) {
                // Extract just the type name (first token, possibly with generics)
                // Syntax: @inject TypeName ParameterName
                const type_name = extractRazorInjectType(rest);
                if (type_name.len > 0) {
                    try appendImportSymbol(a, outline, type_name, line_num, trimmed);
                }
            }
            return;
        }

        // @inherits TypeName → type_alias (base class)
        if (startsWith(trimmed, "@inherits ")) {
            const rest = std.mem.trim(u8, trimmed["@inherits ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
            }
            return;
        }

        // @implements TypeName → interface_def
        if (startsWith(trimmed, "@implements ")) {
            const rest = std.mem.trim(u8, trimmed["@implements ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .interface_def, line_num, trimmed);
            }
            return;
        }

        // @namespace Namespace → type_alias
        if (startsWith(trimmed, "@namespace ")) {
            const rest = std.mem.trim(u8, trimmed["@namespace ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
            }
            return;
        }

        // @page "/route" → variable (route metadata)
        if (startsWith(trimmed, "@page")) {
            const rest = std.mem.trim(u8, trimmed["@page".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .variable, line_num, trimmed);
            }
            return;
        }

        // @layout TypeName → type_alias
        if (startsWith(trimmed, "@layout ")) {
            const rest = std.mem.trim(u8, trimmed["@layout ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
            }
            return;
        }

        // @typeparam T → type_alias
        if (startsWith(trimmed, "@typeparam ")) {
            const rest = std.mem.trim(u8, trimmed["@typeparam ".len..], " \t");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
            }
            return;
        }

        // @section Name { → class_def (structural block)
        if (startsWith(trimmed, "@section ")) {
            const rest = std.mem.trim(u8, trimmed["@section ".len..], " \t{");
            if (rest.len > 0) {
                try appendOutlineSymbol(a, outline, rest, .class_def, line_num, trimmed);
            }
            return;
        }

        // @attribute [Attr] → skip (like C# attributes, metadata only)
        if (startsWith(trimmed, "@attribute ")) return;
    }

    /// Returns true for Razor @-prefixed control flow keywords that don't
    /// declare symbols (if, else, for, foreach, while, switch, etc.).
    fn razorIsControlFlow(line: []const u8) bool {
        const keywords = [_][]const u8{
            "@if",        "@else",     "@for",       "@foreach",
            "@while",     "@switch",   "@case",      "@default",
            "@try",       "@catch",    "@finally",   "@lock",
            "@do",        "@return",   "@throw",     "@break",
            "@continue",  "@using(",   "@{",
        };
        for (keywords) |kw| {
            if (std.mem.startsWith(u8, line, kw)) {
                // Make sure it's a whole-word match (next char is not alphanumeric)
                if (line.len == kw.len) return true;
                const next = line[kw.len];
                if (next == ' ' or next == '\t' or next == '(' or next == '{' or next == ';')
                    return true;
            }
        }
        return false;
    }

    /// Extract the type name from a Razor @inject line.
    /// Syntax: @inject TypeName ParameterName
    /// TypeName may include generics like `ILogger<MyClass>`.
    /// Returns just the type portion, stopping before the parameter name.
    fn extractRazorInjectType(line: []const u8) []const u8 {
        var depth: usize = 0;
        var end: usize = 0;
        for (line, 0..) |ch, i| {
            if (ch == '<') {
                depth += 1;
            } else if (ch == '>') {
                if (depth > 0) depth -= 1;
            } else if (depth == 0 and (ch == ' ' or ch == '\t')) {
                end = i;
                break;
            }
            end = i + 1;
        }
        return std.mem.trim(u8, line[0..end], " \t");
    }

    fn parseSwiftLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@") or startsWith(line, "/*") or startsWith(line, "*")) return;

        if (parseDelimitedImport(line, "import ", "")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "struct ")) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "protocol ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "func ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
    }

    fn parseComponentLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "<!--") or startsWith(line, "<script") or startsWith(line, "</script") or
            startsWith(line, "<style") or startsWith(line, "</style"))
            return;
        if (startsWith(line, ".") or startsWith(line, "#") or startsWith(line, "@keyframes") or startsWith(line, "$") or startsWith(line, "--")) {
            try self.parseStyleLine(line, line_num, outline);
            return;
        }
        try self.parseTsLine(line, line_num, outline);
    }

    fn parseShellLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "#")) return;

        if (startsWith(line, "source ")) {
            const imp = firstShellWord(line["source ".len..]) orelse return;
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }
        if (startsWith(line, ". ")) {
            const imp = firstShellWord(line[2..]) orelse return;
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }
        if (extractIdentAfterKeyword(line, "function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            return;
        }
        if (std.mem.indexOf(u8, line, "()")) |pos| {
            const before = std.mem.trim(u8, line[0..pos], " \t");
            if (extractIdent(before)) |name| {
                if (name.len == before.len) try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
            return;
        }
        if (parseShellAssignment(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseStyleLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "/*") or startsWith(line, "*")) return;

        if (extractIdentAfterKeyword(line, "@keyframes ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeyword(line, "@mixin ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeyword(line, "@function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (parseCssVariable(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (parseCssSelector(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        }
    }

    fn parseSqlLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripSqlLineComment(raw_line);
        if (line.len == 0) return;

        if (parseSqlCreate(line)) |sym| {
            try appendOutlineSymbol(a, outline, sym.name, sym.kind, line_num, line);
        }
    }

    fn parseProtoLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (startsWith(line, "import ")) {
            if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeyword(line, "message ")) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "service ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "rpc ")) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
        }
    }

    fn parseFortranLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripFortranComment(raw_line);
        if (line.len == 0) return;

        if (parseFortranUse(line)) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "module ")) |name| {
            if (!startsWithIgnoreCase(line, "module procedure ")) try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "program ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "subroutine ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (parseFortranTypeName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        }
    }

    fn parseLlvmIrLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, ";")) return;

        if (startsWith(line, "define ") or startsWith(line, "declare ")) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (line[0] == '@') {
            if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        } else if (line[0] == '%' and std.mem.indexOf(u8, line, " = type") != null) {
            if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
        }
    }

    fn parseMlirLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (std.mem.indexOf(u8, line, "module @") != null) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (std.mem.indexOf(u8, line, "func") != null and std.mem.indexOfScalar(u8, line, '@') != null) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
    }

    fn parseTableGenLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (startsWith(line, "include ")) {
            if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeyword(line, "defm ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "def ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "multiclass ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "let ")) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseCLine(self: *Explorer, raw_line: []const u8, trimmed: []const u8, line_num: u32, outline: *FileOutline, prev_trimmed: []const u8, brace_depth: *u32) !void {
        const a = self.allocator;
        const line = stripLineComment(trimmed);
        if (line.len == 0) return;

        if (startsWith(line, "#include") or startsWith(line, "#import")) {
            if (extractCIncludePath(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
            try appendOutlineSymbol(a, outline, line, .import, line_num, line);
            return;
        }

        if (startsWith(line, "#define")) {
            const rest = std.mem.trimStart(u8, line["#define".len..], " \t");
            if (extractIdent(rest)) |name| {
                try appendOutlineSymbol(a, outline, name, .macro_def, line_num, line);
            }
            return;
        }

        if (parseObjCType(line)) |type_sym| {
            try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        if (extractObjCMethodName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        if (parseCNamedType(line)) |type_sym| {
            try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        const at_col0 = raw_line.len > 0 and raw_line[0] != ' ' and raw_line[0] != '\t';
        if (extractCFunctionName(line, at_col0, prev_trimmed, brace_depth.*, outline.language == .cpp)) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }

        applyBraceDelta(brace_depth, countBracesDelta(line));
    }

    fn parseRustLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline, prev_line: []const u8) !void {
        const a = self.allocator;

        // fn / pub fn / pub(crate) fn / async fn / pub async fn / unsafe fn
        if (containsAny(line, &.{"fn "})) {
            const is_decl = startsWith(line, "fn ") or
                startsWith(line, "pub fn ") or
                startsWith(line, "pub(crate) fn ") or
                startsWith(line, "pub(super) fn ") or
                startsWith(line, "async fn ") or
                startsWith(line, "pub async fn ") or
                startsWith(line, "unsafe fn ") or
                startsWith(line, "pub unsafe fn ") or
                startsWith(line, "pub(crate) async fn ") or
                startsWith(line, "pub(crate) unsafe fn ") or
                startsWith(line, "pub unsafe extern ");
            if (is_decl) {
                if (std.mem.indexOf(u8, line, "fn ")) |fn_pos| {
                    if (extractIdent(line[fn_pos + 3 ..])) |name| {
                        const is_test = std.mem.eql(u8, prev_line, "#[test]") or
                            startsWith(prev_line, "#[tokio::test");
                        const kind: SymbolKind = if (is_test) .test_decl else .function;
                        var rust_param_buf: [16][]const u8 = undefined;
                        const rust_types = extractRustFuncTypes(line, &rust_param_buf);
                        const rust_params = rust_param_buf[0..rust_types.param_count];
                        try appendOutlineSymbolWithTypes(a, outline, name, kind, line_num, line, rust_types.ret, rust_params);
                    }
                }
            }
        }

        // struct
        if (startsWith(line, "struct ") or startsWith(line, "pub struct ") or startsWith(line, "pub(crate) struct ")) {
            if (std.mem.indexOf(u8, line, "struct ")) |pos| {
                if (extractIdent(line[pos + 7 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .struct_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // enum
        if (startsWith(line, "enum ") or startsWith(line, "pub enum ") or startsWith(line, "pub(crate) enum ")) {
            if (std.mem.indexOf(u8, line, "enum ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .enum_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // trait
        if (startsWith(line, "trait ") or startsWith(line, "pub trait ") or startsWith(line, "pub(crate) trait ") or startsWith(line, "unsafe trait ") or startsWith(line, "pub unsafe trait ")) {
            if (std.mem.indexOf(u8, line, "trait ")) |pos| {
                if (extractIdent(line[pos + 6 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .trait_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // impl
        if (startsWith(line, "impl ") or startsWith(line, "impl<") or startsWith(line, "unsafe impl ")) {
            const impl_start: usize = if (startsWith(line, "unsafe impl ")) 12 else if (startsWith(line, "impl<")) blk: {
                if (std.mem.indexOf(u8, line, "> ")) |gt| {
                    break :blk gt + 2;
                } else break :blk 5;
            } else 5;
            if (extractIdent(line[impl_start..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .impl_block,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        // type alias
        if (startsWith(line, "type ") or startsWith(line, "pub type ") or startsWith(line, "pub(crate) type ")) {
            if (std.mem.indexOf(u8, line, "type ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .type_alias,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // const / static
        if (startsWith(line, "const ") or startsWith(line, "pub const ") or startsWith(line, "pub(crate) const ") or
            startsWith(line, "static ") or startsWith(line, "pub static ") or startsWith(line, "pub(crate) static "))
        {
            const keyword = if (std.mem.indexOf(u8, line, "static ")) |_| "static " else "const ";
            if (std.mem.indexOf(u8, line, keyword)) |pos| {
                if (extractIdent(line[pos + keyword.len ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .constant,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // macro_rules!
        if (startsWith(line, "macro_rules!")) {
            if (extractIdent(line[13..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .macro_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        // use / mod
        if (startsWith(line, "use ") or startsWith(line, "pub use ") or startsWith(line, "pub(crate) use ")) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            const import_copy = try a.dupe(u8, line);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        } else if (startsWith(line, "mod ") or startsWith(line, "pub mod ") or startsWith(line, "pub(crate) mod ")) {
            if (std.mem.indexOf(u8, line, "mod ")) |pos| {
                if (extractIdent(line[pos + 4 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .import,
                        .line_start = line_num,
                        .line_end = line_num,
                    });
                    const import_copy = try a.dupe(u8, name);
                    errdefer a.free(import_copy);
                    try outline.imports.append(a, import_copy);
                }
            }
        }
    }

    fn parsePhpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline, state: *PhpParseState) !void {
        const a = self.allocator;

        var line = raw_line;
        if (line.len == 0) return;
        if (state.in_block_comment) {
            if (std.mem.indexOf(u8, line, "*/")) |end| {
                state.in_block_comment = false;
                line = std.mem.trim(u8, line[end + 2 ..], " \t");
                if (line.len == 0) return;
            } else return;
        }
        if (startsWith(line, "<?php")) return;
        if (startsWith(line, "//") or startsWith(line, "#")) return;
        if (startsWith(line, "/*")) {
            if (std.mem.indexOf(u8, line, "*/") == null) state.in_block_comment = true;
            return;
        }

        if (startsWith(line, "use ") and std.mem.indexOf(u8, line, "\\") != null) {
            try self.parsePhpUseImport(a, line, line_num, outline);
            return;
        }

        if (self.phpMatchClassLike(line)) |match| {
            const name_copy = try a.dupe(u8, match.name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = match.kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
            state.in_class = true;
            state.class_brace_depth = state.brace_depth;
        } else if (self.phpMatchConstant(line)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .constant,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        } else if (std.mem.indexOf(u8, line, "function ")) |fn_pos| {
            const after_fn = line[fn_pos + 9 ..];
            if (extractIdent(after_fn)) |name| {
                const kind: SymbolKind = if (state.in_class) .method else .function;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        var in_string: u8 = 0;
        var escaped: bool = false;
        for (line) |ch| {
            if (in_string != 0) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == in_string) {
                    in_string = 0;
                }
                continue;
            }
            if (ch == '\'' or ch == '"') {
                in_string = ch;
            } else if (ch == '{') {
                state.brace_depth += 1;
            } else if (ch == '}') {
                state.brace_depth -= 1;
                if (state.in_class and state.brace_depth <= state.class_brace_depth) {
                    state.in_class = false;
                }
            }
        }
    }

    fn parsePhpUseImport(_: *Explorer, a: std.mem.Allocator, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const use_body = std.mem.trim(u8, line[4..semi], " \t");
        if (use_body.len == 0) return;

        if (std.mem.indexOfScalar(u8, use_body, '{')) |brace_start| {
            const brace_end = std.mem.indexOfScalar(u8, use_body, '}') orelse use_body.len;
            const base = use_body[0..brace_start];
            const items_str = use_body[brace_start + 1 .. brace_end];

            const symbol_copy = try a.dupe(u8, line[0..semi]);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });

            var items = std.mem.splitScalar(u8, items_str, ',');
            while (items.next()) |item| {
                const raw_item = std.mem.trim(u8, item, " \t");
                if (raw_item.len == 0) continue;
                const trimmed_item = phpStripAlias(raw_item);
                const full_ns = try a.alloc(u8, base.len + trimmed_item.len);
                defer a.free(full_ns);
                @memcpy(full_ns[0..base.len], base);
                @memcpy(full_ns[base.len..], trimmed_item);
                const path_copy = try phpNamespaceToPath(a, full_ns);
                errdefer a.free(path_copy);
                try outline.imports.append(a, path_copy);
            }
        } else {
            const symbol_copy = try a.dupe(u8, line[0..semi]);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            const ns = phpStripAlias(use_body);
            const path_copy = try phpNamespaceToPath(a, ns);
            errdefer a.free(path_copy);
            try outline.imports.append(a, path_copy);
        }
    }

    fn phpStripAlias(s: []const u8) []const u8 {
        if (s.len < 4) return s;
        for (0..s.len - 3) |i| {
            if (s[i] == ' ' and (s[i + 1] == 'a' or s[i + 1] == 'A') and (s[i + 2] == 's' or s[i + 2] == 'S') and s[i + 3] == ' ') return s[0..i];
        }
        return s;
    }

    fn phpMatchConstant(_: *Explorer, line: []const u8) ?[]const u8 {
        const prefixes = [_][]const u8{
            "const ",
            "public const ",
            "protected const ",
            "private const ",
        };
        for (prefixes) |prefix| {
            if (startsWith(line, prefix)) {
                if (extractIdent(line[prefix.len..])) |name| {
                    if (!std.mem.eql(u8, name, "class")) return name;
                }
            }
        }
        return null;
    }

    const PhpClassMatch = struct {
        name: []const u8,
        kind: SymbolKind,
    };

    fn phpMatchClassLike(_: *Explorer, line: []const u8) ?PhpClassMatch {
        const class_keywords = [_]struct { prefix: []const u8, kind: SymbolKind }{
            .{ .prefix = "interface ", .kind = .interface_def },
            .{ .prefix = "trait ", .kind = .trait_def },
            .{ .prefix = "enum ", .kind = .enum_def },
            .{ .prefix = "class ", .kind = .class_def },
            .{ .prefix = "abstract class ", .kind = .class_def },
            .{ .prefix = "final class ", .kind = .class_def },
            .{ .prefix = "readonly class ", .kind = .class_def },
        };

        for (class_keywords) |kw| {
            if (startsWith(line, kw.prefix)) {
                if (extractIdent(line[kw.prefix.len..])) |name| {
                    return .{ .name = name, .kind = kw.kind };
                }
            }
        }
        return null;
    }

    fn parseGoLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        // func name( or func (receiver) name(
        if (startsWith(line, "func ")) {
            // Skip "func (" for function literals
            const rest = line[5..];
            // Method with receiver: func (r *Type) Name(
            var name_start = rest;
            if (rest.len > 0 and rest[0] == '(') {
                // Skip past receiver: find ") "
                if (std.mem.indexOf(u8, rest, ") ")) |close| {
                    name_start = rest[close + 2 ..];
                }
            }
            if (extractIdent(name_start)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);

                // Extract Go function types
                var go_param_buf: [16][]const u8 = undefined;
                const go_types = extractGoFuncTypes(line, &go_param_buf);
                const rt_copy: ?[]const u8 = if (go_types.ret) |rt| try a.dupe(u8, rt) else null;
                errdefer if (rt_copy) |rt| a.free(rt);
                const go_params = go_param_buf[0..go_types.param_count];
                const pt_copy = try a.dupe([]const u8, go_params);
                errdefer a.free(pt_copy);
                for (go_params, 0..) |pt, i| {
                    pt_copy[i] = try a.dupe(u8, pt);
                    errdefer for (pt_copy[0..i]) |p| a.free(p);
                }

                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                    .return_type = rt_copy,
                    .param_types = pt_copy,
                });
            }
        } else if (startsWith(line, "type ")) {
            const rest = line[5..];
            if (extractIdent(rest)) |name| {
                const kind: SymbolKind = .struct_def;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "import ")) {
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
        } else if (startsWith(line, "const ") or startsWith(line, "var ")) {
            const skip = if (startsWith(line, "const ")) @as(usize, 6) else 4;
            if (extractIdent(line[skip..])) |name| {
                const kind: SymbolKind = if (startsWith(line, "const ")) .constant else .variable;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    fn parseDartLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        if (line.len == 0 or startsWith(line, "@")) return;

        if (startsWith(line, "import ") or startsWith(line, "export ") or
            (startsWith(line, "part ") and !startsWith(line, "part of ")))
        {
            if (extractStringLiteral(line)) |raw_path| {
                if (resolveDartImport(raw_path, outline.path, a)) |resolved| {
                    try outline.imports.append(a, resolved);
                }
            }
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            return;
        }

        if (startsWith(line, "typedef ")) {
            if (extractIdent(line["typedef ".len..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .type_alias,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
            return;
        }

        var type_decl = line;
        const type_modifiers = [_][]const u8{ "abstract ", "base ", "final ", "sealed ", "interface " };
        while (true) {
            var stripped = false;
            for (type_modifiers) |modifier| {
                if (startsWith(type_decl, modifier)) {
                    type_decl = type_decl[modifier.len..];
                    stripped = true;
                    break;
                }
            }
            if (!stripped) break;
        }

        const TypeDecl = struct {
            prefix: []const u8,
            kind: SymbolKind,
        };
        const type_decls = [_]TypeDecl{
            .{ .prefix = "mixin class ", .kind = .class_def },
            .{ .prefix = "class ", .kind = .class_def },
            .{ .prefix = "enum ", .kind = .enum_def },
            .{ .prefix = "mixin ", .kind = .trait_def },
            .{ .prefix = "extension type ", .kind = .class_def },
            .{ .prefix = "extension ", .kind = .impl_block },
        };
        for (type_decls) |decl| {
            if (!startsWith(type_decl, decl.prefix)) continue;

            const after = std.mem.trimStart(u8, type_decl[decl.prefix.len..], " \t");
            if (decl.kind == .impl_block and startsWith(after, "on ")) return;
            if (extractIdent(after)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = decl.kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
            return;
        }

        var var_decl = line;
        var var_kind: ?SymbolKind = null;
        while (true) {
            if (startsWith(var_decl, "static ")) {
                var_decl = std.mem.trimStart(u8, var_decl["static ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "late ")) {
                var_decl = std.mem.trimStart(u8, var_decl["late ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "covariant ")) {
                var_decl = std.mem.trimStart(u8, var_decl["covariant ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "const ")) {
                var_kind = .constant;
                var_decl = std.mem.trimStart(u8, var_decl["const ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "final ") or startsWith(var_decl, "var ")) {
                var_kind = .variable;
                const skip = if (startsWith(var_decl, "final ")) @as(usize, "final ".len) else "var ".len;
                var_decl = std.mem.trimStart(u8, var_decl[skip..], " \t");
                continue;
            }
            break;
        }
        if (var_kind) |kind| {
            const boundary = firstIndexOfAny(var_decl, &.{ '=', ';' }) orelse var_decl.len;
            const prefix = std.mem.trimEnd(u8, var_decl[0..boundary], " \t");
            if (std.mem.indexOfScalar(u8, prefix, '(') == null) {
                if (extractLastIdent(prefix)) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = kind,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
            return;
        }

        if (std.mem.indexOf(u8, line, " get ") != null) {
            const get_pos = std.mem.indexOf(u8, line, " get ").?;
            const after_get = std.mem.trimStart(u8, line[get_pos + " get ".len ..], " \t");
            if (extractIdent(after_get)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
                return;
            }
        }

        if (containsAny(line, &.{ "(", "=>", "{", ";" })) {
            const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return;
            const prefix = std.mem.trimEnd(u8, line[0..open_paren], " \t");
            if (prefix.len == 0) return;
            if (containsAny(prefix, &.{ "=", "." })) return;
            if (startsWith(prefix, "if") or startsWith(prefix, "for") or startsWith(prefix, "while") or
                startsWith(prefix, "switch") or startsWith(prefix, "catch") or startsWith(prefix, "return") or
                startsWith(prefix, "throw") or startsWith(prefix, "assert") or startsWith(prefix, "await") or
                startsWith(prefix, "new ") or startsWith(prefix, "const "))
            {
                return;
            }

            var callable = prefix;
            const callable_modifiers = [_][]const u8{
                "external ",
                "static ",
                "factory ",
                "covariant ",
                "late ",
                "final ",
                "const ",
            };
            while (true) {
                var stripped = false;
                for (callable_modifiers) |modifier| {
                    if (startsWith(callable, modifier)) {
                        callable = std.mem.trimStart(u8, callable[modifier.len..], " \t");
                        stripped = true;
                        break;
                    }
                }
                if (!stripped) break;
            }
            if (startsWith(callable, "operator ")) return;
            var is_setter = false;
            if (startsWith(callable, "set ")) {
                callable = std.mem.trimStart(u8, callable["set ".len..], " \t");
                is_setter = true;
            }
            if (!is_setter and std.mem.indexOfScalar(u8, callable, ' ') == null) return;
            if (extractLastIdent(callable)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    fn parseRubyLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            // Handle "def self.method_name" — skip past "self."
            var name_start = line[4..];
            if (startsWith(name_start, "self.")) {
                name_start = name_start[5..];
            }
            if (extractRubyMethodName(name_start)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "module ")) {
            if (extractIdent(line[7..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "require ") or startsWith(line, "require_relative ")) {
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
        }
    }

    fn parseHclLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        // resource "type" "name" {
        if (startsWith(line, "resource ")) {
            if (extractHclBlockName(line[9..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
            }
        } else if (startsWith(line, "data ")) {
            if (extractHclBlockName(line[5..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
            }
        } else if (startsWith(line, "module ")) {
            if (extractHclQuotedName(line[7..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
            }
        } else if (startsWith(line, "variable ")) {
            if (extractHclQuotedName(line[9..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .variable, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
            }
        } else if (startsWith(line, "output ")) {
            if (extractHclQuotedName(line[7..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .constant, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
            }
        } else if (startsWith(line, "provider ")) {
            if (extractHclQuotedName(line[9..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
            }
        } else if (startsWith(line, "locals ") or startsWith(line, "locals{") or std.mem.eql(u8, line, "locals")) {
            const name_copy = try a.dupe(u8, "locals");
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num });
        } else if (startsWith(line, "terraform ") or startsWith(line, "terraform{") or std.mem.eql(u8, line, "terraform")) {
            const name_copy = try a.dupe(u8, "terraform");
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num });
        }
    }

    fn parseRLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        // library(pkg) or require(pkg)
        if (startsWith(line, "library(") or startsWith(line, "require(")) {
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
            const close = std.mem.indexOfScalar(u8, line[open..], ')') orelse return;
            const pkg = std.mem.trim(u8, line[open + 1 .. open + close], " \t\"'");
            if (pkg.len == 0) return;
            const import_copy = try a.dupe(u8, pkg);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{ .name = symbol_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
            return;
        }

        // setClass("ClassName") or setRefClass("ClassName")
        if (startsWith(line, "setClass(") or startsWith(line, "setRefClass(")) {
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
            if (extractHclQuotedName(line[open + 1 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{ .name = name_copy, .kind = .class_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
            }
            return;
        }

        // name <- function( or name = function(
        if (std.mem.indexOf(u8, line, "<- function(") != null or std.mem.indexOf(u8, line, "= function(") != null) {
            const assign_pos = std.mem.indexOf(u8, line, "<-") orelse std.mem.indexOf(u8, line, "=") orelse return;
            const name = std.mem.trim(u8, line[0..assign_pos], " \t");
            if (name.len == 0) return;
            if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '.') return;
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .function, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
    }

    fn rebuildDepsFor(self: *Explorer, path: []const u8, outline: *FileOutline) !void {
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(self.allocator);

        // Issue #445: outline.imports.items contains one entry per `@import`
        // site, so a file aliasing the same dep multiple times emits dupes.
        // Dedup by path before storing — the reverse index already dedupes
        // naturally via StringHashMap, only forward edges need this.
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        const is_sql = outline.language == .sql;

        for (outline.imports.items) |imp| {
            // For SQL imports, try to resolve object names to file paths.
            // SQL imports are like "dbo.vwHalfCommClients" or "Holding.vPosition".
            // We need to find the actual file path for proper dependency tracking.
            if (is_sql) {
                const resolved = self.resolveSqlDepKey(imp);
                if (resolved) |key| {
                    const gop = try seen.getOrPut(key);
                    if (!gop.found_existing) {
                        try deps.append(self.allocator, key);
                    }
                    continue;
                }
            }

            const dep_key = resolveDependencyKey(path, imp, self.allocator) orelse continue;
            const gop = try seen.getOrPut(dep_key.key);
            if (gop.found_existing) continue;
            try deps.append(self.allocator, dep_key.key);
        }

        try self.dep_graph.setDeps(path, deps);
    }

    /// Resolve a SQL import (e.g., "dbo.vwHalfCommClients") to a file path
    /// by looking up the bare object name in the symbol index.
    /// Returns the file path if found, or the bare object name as fallback.
    fn resolveSqlDepKey(self: *Explorer, imp: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, imp, " \t\r\n\"'");
        if (trimmed.len == 0) return null;

        // Extract bare object name: dbo.vwHalfCommClients -> vwHalfCommClients
        const bare = tsql_parser.extractBareObjectName(trimmed);
        if (bare.len == 0) return null;

        // Look up the bare name in the symbol index
        if (self.symbol_index.get(bare)) |locs| {
            if (locs.items.len > 0) {
                // Return the file path of the first match
                return locs.items[0].path;
            }
        }

        // Fallback: use the bare object name as the dep key.
        // This enables reverse lookup via stem matching in getImportedBy.
        return bare;
    }

    const DependencyKey = struct {
        key: []const u8,
    };

    fn resolveDependencyKey(path: []const u8, imp: []const u8, allocator: std.mem.Allocator) ?DependencyKey {
        const trimmed = std.mem.trim(u8, imp, " \t\r\n\"'");
        if (trimmed.len == 0) return null;

        if (std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "../")) {
            const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[0..sep] else ".";
            const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, trimmed }) catch return null;
            defer allocator.free(joined);

            const normalized = parse_utils.normalizePath(joined, allocator) orelse return null;
            allocator.free(normalized);
            const basename = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |sep| trimmed[sep + 1 ..] else trimmed;
            if (basename.len == 0) return null;
            return .{ .key = basename };
        }

        return .{ .key = trimmed };
    }

    fn rebuildSymbolIndexFor(self: *Explorer, path: []const u8, outline: *FileOutline) void {
        self.removeSymbolIndexFor(path);
        for (outline.symbols.items) |sym| {
            const gop = self.symbol_index.getOrPut(sym.name) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(SymbolLocation).empty;
            }
            gop.value_ptr.append(self.allocator, .{
                .path = path,
                .kind = sym.kind,
                .line_start = sym.line_start,
                .line_end = sym.line_end,
            }) catch {};

            // For SQL files, also register the bare object name as an alias.
            // This enables codedb_symbol(name="vPosition") to find [Holding].[vPosition].
            if (outline.language == .sql and sym.kind != .import and sym.kind != .variable) {
                const bare = tsql_parser.extractBareObjectName(sym.name);
                if (bare.len > 0 and !std.mem.eql(u8, bare, sym.name)) {
                    const alias_gop = self.symbol_index.getOrPut(bare) catch continue;
                    if (!alias_gop.found_existing) {
                        alias_gop.value_ptr.* = std.ArrayList(SymbolLocation).empty;
                    }
                    // Check if this path is already registered for the alias
                    var already = false;
                    for (alias_gop.value_ptr.items) |existing| {
                        if (std.mem.eql(u8, existing.path, path) and existing.line_start == sym.line_start) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        alias_gop.value_ptr.append(self.allocator, .{
                            .path = path,
                            .kind = sym.kind,
                            .line_start = sym.line_start,
                            .line_end = sym.line_end,
                        }) catch {};
                    }
                }
            }
        }
    }

    /// Rebuild TypeIndex and TypeGraph from all loaded outlines.
    /// Called after snapshot loading to populate type query indexes.
    pub fn rebuildTypeIndexes(self: *Explorer) void {
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            self.type_index.indexFileSymbols(entry.key_ptr.*, entry.value_ptr.symbols.items) catch {};
            self.buildTypeGraphForFile(entry.key_ptr.*, entry.value_ptr);
        }
    }

    /// Build type graph from class/interface declarations in a file.
    /// Parses detail text for "extends", "implements", ":" (C#/Kotlin) keywords.
    fn buildTypeGraphForFile(self: *Explorer, path: []const u8, outline: *const FileOutline) void {
        _ = path;
        for (outline.symbols.items) |sym| {
            if (sym.kind != .class_def and sym.kind != .interface_def and
                sym.kind != .struct_def and sym.kind != .enum_def) continue;
            const detail = sym.detail orelse continue;
            extractAndRecordBases(&self.type_graph, sym.name, detail) catch {};
        }
    }

    /// Extract base type names from a declaration detail line and record in TypeGraph.
    fn extractAndRecordBases(graph: *TypeGraph, type_name: []const u8, detail: []const u8) !void {
        // Find the portion after "extends", "implements", or ":" (C#/Kotlin)
        const bases = findBasePortion(detail, type_name) orelse return;
        // Tokenize: split on commas, spaces, angle brackets, etc.
        var token_start: ?usize = null;
        for (bases, 0..) |c, i| {
            if (parse_utils.isIdentChar(c) or c == '.' or c == '_' or c == '<' or c == '>' or c == '[' or c == ']') {
                if (token_start == null) token_start = i;
            } else if (token_start) |start| {
                const token = std.mem.trim(u8, bases[start..i], " \t");
                if (token.len > 0 and !isHierarchyKeyword(token) and !std.mem.eql(u8, token, type_name)) {
                    try graph.addRelationship(type_name, token);
                }
                token_start = null;
            }
        }
        if (token_start) |start| {
            const token = std.mem.trim(u8, bases[start..], " \t");
            if (token.len > 0 and !isHierarchyKeyword(token) and !std.mem.eql(u8, token, type_name)) {
                try graph.addRelationship(type_name, token);
            }
        }
    }

    fn findBasePortion(detail: []const u8, self_name: []const u8) ?[]const u8 {
        _ = self_name;
        if (std.mem.indexOf(u8, detail, " extends ")) |pos| return detail[pos + " extends ".len ..];
        if (std.mem.indexOf(u8, detail, " implements ")) |pos| return detail[pos + " implements ".len ..];
        // C#/Kotlin: "class Foo : IBar, IBaz" — find ':' not inside strings
        if (std.mem.indexOf(u8, detail, " : ")) |pos| return detail[pos + " : ".len ..];
        // Python: "class Foo(Bar, Baz):" — find '('
        if (std.mem.indexOfScalar(u8, detail, '(')) |open| {
            if (std.mem.indexOfScalarPos(u8, detail, open + 1, ')')) |close| {
                return detail[open + 1 .. close];
            }
        }
        return null;
    }

    /// Check if a symbol name matches a query, supporting SQL schema-qualified names.
    /// Exact match first, then checks if sym_name ends with ".query" (e.g. "API_V1.DecomAccount" matches "DecomAccount").
    fn symbolNameMatches(sym_name: []const u8, query: []const u8) bool {
        if (std.mem.eql(u8, sym_name, query)) return true;
        // SQL schema-qualified: "schema.object" matches bare "object"
        if (query.len > 0 and sym_name.len > query.len + 1) {
            const dot_pos = sym_name.len - query.len - 1;
            if (sym_name[dot_pos] == '.' and std.mem.eql(u8, sym_name[dot_pos + 1 ..], query)) {
                return true;
            }
        }
        return false;
    }

    fn isHierarchyKeyword(token: []const u8) bool {
        const keywords = [_][]const u8{ "extends", "implements", "class", "interface", "struct", "enum", "trait", "record", "abstract", "sealed", "final", "static", "public", "private", "protected", "internal", "override", "virtual", "async", "partial", "where", "super", "protocol", ":", ",", "with", "data", "object", "fun", "val", "var" };
        for (keywords) |kw| {
            if (std.mem.eql(u8, token, kw)) return true;
        }
        return false;
    }

    fn removeSymbolIndexFor(self: *Explorer, path: []const u8) void {
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.symbol_index.iterator();
        while (iter.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i].path, path)) {
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            _ = self.symbol_index.remove(key);
        }
    }

    /// Return the source body for a symbol given its file path and line range.
    /// Caller owns the returned slice.
    pub fn getSymbolBody(self: *Explorer, path: []const u8, line_start: u32, line_end: u32, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        defer ref.deinit();
        return try extractLines(ref.data, line_start, line_end, true, false, .unknown, allocator);
    }

    /// Find the smallest enclosing symbol for a given line in a file.
    /// Must be called while holding at least a shared lock.
    fn findEnclosingSymbolLocked(self: *Explorer, path: []const u8, line_num: u32) ?Symbol {
        const outline = self.outlines.getPtr(path) orelse return null;
        const symbols = outline.symbols.items;
        if (symbols.len == 0) return null;

        // Binary search: find rightmost symbol with line_start <= line_num.
        // Symbols are stored in source order (line_start ascending).
        var lo: usize = 0;
        var hi: usize = symbols.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (symbols[mid].line_start <= line_num) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is the insertion point; candidates are symbols[0..lo] with line_start <= line_num.

        // Check candidates in reverse for tightest enclosing block. Zero-span
        // symbols are often call-like parser artifacts, so keep them only as a
        // fallback when no real enclosing scope exists.
        var best: ?Symbol = null;
        var best_span: u32 = std.math.maxInt(u32);
        var fallback: ?Symbol = null;
        var i: usize = lo;
        while (i > 0) {
            i -= 1;
            const sym = symbols[i];
            if (sym.line_end >= line_num) {
                if (sym.line_end == sym.line_start) {
                    if (fallback == null) fallback = sym;
                    continue;
                }
                const span = sym.line_end - sym.line_start;
                if (span < best_span) {
                    best = sym;
                    best_span = span;
                }
            }
            // Once we're past a reasonable gap, stop scanning backwards
            if (line_num - sym.line_start > 500 and best != null) break;
        }
        if (best != null) return best;
        if (fallback != null) return fallback;

        // Fallback: nearest preceding symbol (already at the right position from binary search)
        if (lo > 0) return symbols[lo - 1];
        return null;
    }

    pub const ScopedSearchResult = struct {
        path: []const u8,
        line_num: u32,
        line_text: []const u8,
        scope_name: ?[]const u8 = null,
        scope_kind: ?SymbolKind = null,
        scope_start: u32 = 0,
        scope_end: u32 = 0,
    };

    /// Search content and annotate results with the enclosing symbol scope.
    pub fn searchContentWithScope(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
        const plain_results = try self.searchContent(query, allocator, max_results);
        defer {
            for (plain_results) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
            }
            allocator.free(plain_results);
        }

        var result_list: std.ArrayList(ScopedSearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
                if (r.scope_name) |n| allocator.free(n);
            }
            result_list.deinit(allocator);
        }
        try result_list.ensureTotalCapacity(allocator, plain_results.len);

        self.mu.lockShared();
        defer self.mu.unlockShared();

        for (plain_results) |r| {
            const line_text = try allocator.dupe(u8, r.line_text);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, r.path);
            errdefer allocator.free(path_copy);

            const scope = self.findEnclosingSymbolLocked(r.path, r.line_num);
            const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
            errdefer if (scope_name) |n| allocator.free(n);

            result_list.appendAssumeCapacity(.{
                .path = path_copy,
                .line_num = r.line_num,
                .line_text = line_text,
                .scope_name = scope_name,
                .scope_kind = if (scope) |s| s.kind else null,
                .scope_start = if (scope) |s| s.line_start else 0,
                .scope_end = if (scope) |s| s.line_end else 0,
            });
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Scoped regex search: same as searchContentWithScope but uses regex matching
    /// against each line instead of literal substring. Trigram-accelerated.
    pub fn searchContentRegexWithScope(self: *Explorer, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(ScopedSearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
                if (r.scope_name) |n| allocator.free(n);
            }
            result_list.deinit(allocator);
        }

        var query = idx.decomposeRegex(pattern, self.allocator) catch {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        };
        defer query.deinit();

        const candidate_paths = self.trigram_index.candidatesRegex(&query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);
        const use_trigram = candidate_paths != null and candidate_paths.?.len > 0;

        if (use_trigram) {
            for (candidate_paths.?) |path| {
                const ref = self.readContentForSearch(path, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(path, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        } else {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        }

        if (result_list.items.len < max_results) {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (self.trigram_index.containsFile(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        return result_list.toOwnedSlice(allocator);
    }

    fn searchInContentWithScope(self: *Explorer, path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (indexOfCaseInsensitive(line, query) != null) {
                const line_text = try allocator.dupe(u8, line);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);

                const scope = self.findEnclosingSymbolLocked(path, line_num);
                const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
                errdefer if (scope_name) |n| allocator.free(n);

                try result_list.append(allocator, .{
                    .path = path_copy,
                    .line_num = line_num,
                    .line_text = line_text,
                    .scope_name = scope_name,
                    .scope_kind = if (scope) |s| s.kind else null,
                    .scope_start = if (scope) |s| s.line_start else 0,
                    .scope_end = if (scope) |s| s.line_end else 0,
                });
                if (result_list.items.len >= max_results) return;
            }
        }
    }

    fn searchInContentRegexWithScope(self: *Explorer, path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
        var rx = nanoregex.Regex.compile(allocator, pattern) catch return;
        defer rx.deinit();
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (rx.search(allocator, line) catch null) |m| {
                @constCast(&m).deinit(allocator);
                const line_text = try allocator.dupe(u8, line);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);

                const scope = self.findEnclosingSymbolLocked(path, line_num);
                const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
                errdefer if (scope_name) |n| allocator.free(n);

                try result_list.append(allocator, .{
                    .path = path_copy,
                    .line_num = line_num,
                    .line_text = line_text,
                    .scope_name = scope_name,
                    .scope_kind = if (scope) |s| s.kind else null,
                    .scope_start = if (scope) |s| s.line_start else 0,
                    .scope_end = if (scope) |s| s.line_end else 0,
                });
                if (result_list.items.len >= max_results) return;
            }
        }
    }
};

// ── Helpers split into explore/parse_utils.zig ──
const parse_utils = @import("explore/parse_utils.zig");
const phpNamespaceToPath = parse_utils.phpNamespaceToPath;
pub const extractLines = parse_utils.extractLines;
pub const isCommentOrBlank = parse_utils.isCommentOrBlank;
const searchInContent = parse_utils.searchInContent;
const extractLineByNumber = parse_utils.extractLineByNumber;
const searchInContentRegex = parse_utils.searchInContentRegex;
pub const regexMatch = parse_utils.regexMatch;
const indexOfCaseInsensitive = parse_utils.indexOfCaseInsensitive;
const countOccurrences = parse_utils.countOccurrences;
const writeJsonEscaped = parse_utils.writeJsonEscaped;
const asciiEqlIgnoreCase = parse_utils.asciiEqlIgnoreCase;
const asciiContainsIgnoreCase = parse_utils.asciiContainsIgnoreCase;
const pathHasSegment = parse_utils.pathHasSegment;
const pathHasSegmentIgnoreCase = parse_utils.pathHasSegmentIgnoreCase;
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendOutlineSymbolWithTypes = parse_utils.appendOutlineSymbolWithTypes;
const appendImportSymbol = parse_utils.appendImportSymbol;
const cSharpSymbolKind = parse_utils.cSharpSymbolKind;
const fSharpSymbolKind = parse_utils.fSharpSymbolKind;
const extractIdent = parse_utils.extractIdent;
const extractIdentAfterKeyword = parse_utils.extractIdentAfterKeyword;
const extractIdentAfterKeywordIgnoreCase = parse_utils.extractIdentAfterKeywordIgnoreCase;
const startsWithIgnoreCase = parse_utils.startsWithIgnoreCase;
const parseDelimitedImport = parse_utils.parseDelimitedImport;
const extractJvmMethodName = parse_utils.extractJvmMethodName;
const firstShellWord = parse_utils.firstShellWord;
const parseShellAssignment = parse_utils.parseShellAssignment;
const parseCssVariable = parse_utils.parseCssVariable;
const parseCssSelector = parse_utils.parseCssSelector;
const stripSqlLineComment = parse_utils.stripSqlLineComment;
const parseSqlCreate = parse_utils.parseSqlCreate;
const stripFortranComment = parse_utils.stripFortranComment;
const parseFortranUse = parse_utils.parseFortranUse;
const parseFortranTypeName = parse_utils.parseFortranTypeName;
const extractAtName = parse_utils.extractAtName;
const extractLlvmGlobalName = parse_utils.extractLlvmGlobalName;
const extractLastIdent = parse_utils.extractLastIdent;
const stripLineComment = parse_utils.stripLineComment;
const extractCIncludePath = parse_utils.extractCIncludePath;
const parseCNamedType = parse_utils.parseCNamedType;
const parseObjCType = parse_utils.parseObjCType;
const extractObjCMethodName = parse_utils.extractObjCMethodName;
const extractCFunctionName = parse_utils.extractCFunctionName;
const applyBraceDelta = parse_utils.applyBraceDelta;
const countBracesDelta = parse_utils.countBracesDelta;
const firstIndexOfAny = parse_utils.firstIndexOfAny;
const extractRubyMethodName = parse_utils.extractRubyMethodName;
const extractHclQuotedName = parse_utils.extractHclQuotedName;
const extractHclBlockName = parse_utils.extractHclBlockName;
const extractStringLiteral = parse_utils.extractStringLiteral;
const resolveDartImport = parse_utils.resolveDartImport;
const containsAny = parse_utils.containsAny;
const skipKeywords = parse_utils.skipKeywords;
const extractPythonModulePath = parse_utils.extractPythonModulePath;
pub const fuzzyScore = parse_utils.fuzzyScore;
