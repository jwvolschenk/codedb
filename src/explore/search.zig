const std = @import("std");
const Explorer = @import("../explore.zig").Explorer;
const SearchResult = @import("../explore.zig").SearchResult;
const SymbolKind = @import("../explore.zig").SymbolKind;
const Symbol = @import("../explore.zig").Symbol;
const isDocLanguage = @import("../explore.zig").isDocLanguage;
const detectLanguage = @import("../explore.zig").detectLanguage;
const ContentCache = @import("../hot_cache.zig").ContentCache;
const nanoregex = @import("nanoregex");
const cio = @import("../cio.zig");
const idx = @import("../index.zig");
const parse_utils = @import("parse_utils.zig");
const isIdentChar = parse_utils.isIdentChar;
const searchInContent = parse_utils.searchInContent;
const searchInContentRegex = parse_utils.searchInContentRegex;
const extractLineByNumber = parse_utils.extractLineByNumber;
const indexOfCaseInsensitive = parse_utils.indexOfCaseInsensitive;
const countOccurrences = parse_utils.countOccurrences;
const writeJsonEscaped = parse_utils.writeJsonEscaped;
const asciiEqlIgnoreCase = parse_utils.asciiEqlIgnoreCase;
const asciiContainsIgnoreCase = parse_utils.asciiContainsIgnoreCase;
const pathHasSegment = parse_utils.pathHasSegment;
const pathHasSegmentIgnoreCase = parse_utils.pathHasSegmentIgnoreCase;
const fuzzyScore = parse_utils.fuzzyScore;

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

    // Refill: Tiers 0/1 cap hits per file to spread the budget across files.
    // When budget remains after every tier, those caps dropped real matches —
    // re-scan the same files uncapped so an under-budget result is COMPLETE.
    // A result set below max_results with no truncation marker reads as
    // "that's everything"; silently dropping a hit to a per-file cap breaks
    // that contract (issue-bug5).
    if (result_list.items.len < max_results) {
        refillCappedFiles(self, &searched, query, allocator, max_results, &result_list) catch {};
    }

    return self.rerankAndFinalize(&result_list, query, allocator);
}

fn refillCappedFiles(
    self: *Explorer,
    searched: *const std.StringHashMap(void),
    query: []const u8,
    allocator: std.mem.Allocator,
    max_results: usize,
    result_list: *std.ArrayList(SearchResult),
) !void {
    var have = std.StringHashMap(void).init(allocator);
    defer {
        var it = have.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        have.deinit();
    }
    for (result_list.items) |r| {
        const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ r.path, r.line_num });
        const gop = try have.getOrPut(key);
        if (gop.found_existing) allocator.free(key);
    }

    var s_iter = searched.keyIterator();
    while (s_iter.next()) |key_ptr| {
        if (result_list.items.len >= max_results) return;
        const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
        defer ref.deinit();

        var refill: std.ArrayList(SearchResult) = .empty;
        searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &refill) catch {
            for (refill.items) |r| {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
            refill.deinit(allocator);
            continue;
        };
        // Consume: move unseen hits into result_list, free the rest.
        for (refill.items) |r| {
            var keep = false;
            if (result_list.items.len < max_results) blk: {
                const key = std.fmt.allocPrint(allocator, "{s}:{d}", .{ r.path, r.line_num }) catch break :blk;
                const gop = have.getOrPut(key) catch {
                    allocator.free(key);
                    break :blk;
                };
                if (gop.found_existing) {
                    allocator.free(key);
                    break :blk;
                }
                keep = true;
            }
            if (keep) {
                result_list.append(allocator, r) catch {
                    allocator.free(r.path);
                    allocator.free(r.line_text);
                };
            } else {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
        }
        refill.deinit(allocator);
    }
}

/// Run the multi-signal rerank in place, then transfer ownership of
/// result_list to the caller. Centralised so every searchContent return
/// path (Tier 0 / Tier 1 early-return on max_results, fall-through to
/// final return) gets the same ranking — pre-fix only the fall-through
/// path applied multi-signal scoring.
pub fn rerankAndFinalize(
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
pub fn rerankSignalScore(self: *const Explorer, r: SearchResult, query: []const u8) f32 {
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
pub fn appendRerankTrace(self: *const Explorer, query: []const u8, results: []const SearchResult) void {
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

/// Whole-word match of `name` inside a type string (e.g. "Probe" inside
/// "List<Probe>" or "Probe?"). Identifier boundaries prevent matching
/// "Probe" inside "ProbeRepository" or "BaseEntityProperties".
fn typeMentionsName(type_text: []const u8, name: []const u8) bool {
    if (name.len == 0 or type_text.len < name.len) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, type_text, i, name)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(type_text[pos - 1]);
        const after = pos + name.len;
        const after_ok = after >= type_text.len or !isIdentChar(type_text[after]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// True if `sym`'s type signature references `name` (whole-word): via its
/// return type, a parameter type, or — for type declarations — a base clause
/// (`class Foo : Bar<Name>`). This is the precise, structural signal that a
/// type is referenced, independent of content-search ranking.
/// Razor directive aliases (`@model Ns.Type`, `@inherits Ns.Type`,
/// `@inject IService svc`) are indexed as type_alias symbols whose NAME is the
/// referenced type. Semantically they are type USAGES, not definitions: the
/// view breaks when the type is renamed, and reference/blast-radius queries
/// must report them rather than exclude them as declaration lines.
pub fn isRazorDirectiveAlias(sym: Symbol) bool {
    if (sym.kind != .type_alias) return false;
    const detail = sym.detail orelse return false;
    const t = std.mem.trimStart(u8, detail, " \t");
    return std.mem.startsWith(u8, t, "@model") or
        std.mem.startsWith(u8, t, "@inherits") or
        std.mem.startsWith(u8, t, "@inject");
}

fn symbolReferencesType(sym: Symbol, name: []const u8) bool {
    if (sym.return_type) |rt| {
        if (typeMentionsName(rt, name)) return true;
    }
    for (sym.param_types) |pt| {
        if (typeMentionsName(pt, name)) return true;
    }
    if (isRazorDirectiveAlias(sym)) {
        if (typeMentionsName(sym.name, name)) return true;
    }
    switch (sym.kind) {
        .class_def, .interface_def, .struct_def, .trait_def => {
            const detail = sym.detail orelse return false;
            // `findBasePortion` extracts the text after ':' / 'extends' /
            // 'implements' (or the parenthesised base list for Python).
            if (Explorer.findBasePortion(detail, sym.name)) |bases| {
                if (typeMentionsName(bases, name)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Find every structural reference to a type `name` by walking outlines:
/// properties/fields whose declared type mentions it, methods that return
/// or accept it, and types whose base clause mentions it. Returns
/// line-level hits with enclosing-scope annotation, the same shape as
/// `searchContentWithScope` so the two can be merged.
///
/// Unlike content search, this is complete and deterministic — it is not
/// capped or re-ranked — so it guarantees that structural type references
/// surface even for very common identifiers (e.g. an entity name appearing
/// in 600+ content lines).
pub fn findTypeReferences(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const ScopedSearchResult {
    var result_list: std.ArrayList(ScopedSearchResult) = .empty;
    errdefer {
        for (result_list.items) |r| {
            allocator.free(r.line_text);
            allocator.free(r.path);
            if (r.scope_name) |n| allocator.free(n);
        }
        result_list.deinit(allocator);
    }

    self.mu.lockShared();
    defer self.mu.unlockShared();

    var iter = self.outlines.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const outline = entry.value_ptr.*;
        for (outline.symbols.items) |sym| {
            if (!symbolReferencesType(sym, name)) continue;
            // For code files the detail is the raw source line; without it we
            // can't render a useful hit, so skip.
            const detail = sym.detail orelse continue;
            const line_text = try allocator.dupe(u8, detail);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            const scope = self.findEnclosingSymbolLocked(path, sym.line_start);
            const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
            errdefer if (scope_name) |n| allocator.free(n);
            try result_list.append(allocator, .{
                .path = path_copy,
                .line_num = sym.line_start,
                .line_text = line_text,
                .scope_name = scope_name,
                .scope_kind = if (scope) |s| s.kind else null,
                .scope_start = if (scope) |s| s.line_start else 0,
                .scope_end = if (scope) |s| s.line_end else 0,
            });
        }
    }
    return result_list.toOwnedSlice(allocator);
}

fn freeScopedSliceItems(allocator: std.mem.Allocator, slice: []const ScopedSearchResult) void {
    for (slice) |r| {
        allocator.free(r.line_text);
        allocator.free(r.path);
        if (r.scope_name) |n| allocator.free(n);
    }
    allocator.free(slice);
}

/// References-mode search: merge ranked content-search hits with the
/// complete structural type-reference set, deduping by (path, line). This
/// gives high recall for type names — structural references (properties,
/// params, return types, base clauses) always surface even when the token
/// is too common for content search to fully enumerate within its cap.
/// Content hits win on dedup (preserving their ranking/scope). The returned
/// slice owns copies of every kept item's strings; both source slices are
/// fully freed here on all paths.
pub fn searchReferencesWithScope(self: *Explorer, name: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
    const content = try self.searchContentWithScope(name, allocator, max_results);
    defer freeScopedSliceItems(allocator, content);

    const structural = try self.findTypeReferences(name, allocator);
    defer freeScopedSliceItems(allocator, structural);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var merged: std.ArrayList(ScopedSearchResult) = .empty;
    errdefer {
        for (merged.items) |r| {
            allocator.free(r.line_text);
            allocator.free(r.path);
            if (r.scope_name) |n| allocator.free(n);
        }
        merged.deinit(allocator);
    }

    // Append a copy of `r` if (path, line) hasn't been seen yet.
    const append_copy = struct {
        fn run(list: *std.ArrayList(ScopedSearchResult), a: std.mem.Allocator, seen_set: *std.StringHashMap(void), r: ScopedSearchResult) !void {
            var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ r.path, r.line_num }) catch return;
            if (seen_set.contains(key)) return; // duplicate — skip; strings freed by the caller's defer
            const key_dup = try a.dupe(u8, key);
            errdefer a.free(key_dup);
            try seen_set.put(key_dup, {});
            const line_text = try a.dupe(u8, r.line_text);
            errdefer a.free(line_text);
            const path_copy = try a.dupe(u8, r.path);
            errdefer a.free(path_copy);
            const scope_name = if (r.scope_name) |n| try a.dupe(u8, n) else null;
            errdefer if (scope_name) |n| a.free(n);
            try list.append(a, .{
                .path = path_copy,
                .line_num = r.line_num,
                .line_text = line_text,
                .scope_name = scope_name,
                .scope_kind = r.scope_kind,
                .scope_start = r.scope_start,
                .scope_end = r.scope_end,
            });
        }
    }.run;

    for (content) |r| try append_copy(&merged, allocator, &seen, r);
    for (structural) |r| try append_copy(&merged, allocator, &seen, r);

    return merged.toOwnedSlice(allocator);
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

pub fn searchInContentWithScope(self: *Explorer, path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
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

pub fn searchInContentRegexWithScope(self: *Explorer, path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
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
