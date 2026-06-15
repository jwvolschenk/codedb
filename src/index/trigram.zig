// Trigram search indexes — aggregator module.
//
// Split into three implementations, each in its own file under trigram/:
//   heap.zig — TrigramIndex       (mutable, in-memory inverted index)
//   mmap.zig — MmapTrigramIndex   (read-only, mmap-backed variant)
//   any.zig  — AnyTrigramIndex    (union(enum) dispatcher over heap + mmap)
//
// Posting structures live in trigram_posting.zig; regex decomposition in
// regex_query.zig. This file re-exports the public surface so existing
// `@import("trigram.zig")` callers keep working unchanged.

const tg_posting = @import("trigram_posting.zig");
pub const Trigram = tg_posting.Trigram;
pub const packTrigram = tg_posting.packTrigram;
pub const PostingMask = tg_posting.PostingMask;
pub const DocPosting = tg_posting.DocPosting;
pub const PostingList = tg_posting.PostingList;

const regex_query = @import("regex_query.zig");
pub const RegexQuery = regex_query.RegexQuery;
pub const decomposeRegex = regex_query.decomposeRegex;

const heap = @import("trigram/heap.zig");
pub const TrigramIndex = heap.TrigramIndex;

const mmap_mod = @import("trigram/mmap.zig");
pub const MmapTrigramIndex = mmap_mod.MmapTrigramIndex;

const any_mod = @import("trigram/any.zig");
pub const AnyTrigramIndex = any_mod.AnyTrigramIndex;
