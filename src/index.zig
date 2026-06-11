// codedb — search index module.
//
// Implementation split into the `index/` directory by concern:
//   chars.zig          — character classification / normalization helpers
//   word_tokenizer.zig — word tokenizer + identifier splitting
//   word_index.zig     — inverted word index (WordIndex)
//   trigram.zig        — trigram posting lists, mmap variant, regex decomposition
//   frequency.zig      — character-pair frequency table for sparse n-grams
//   sparse_ngram.zig   — sparse n-gram index (SparseNgramIndex)
//
// This file re-exports the public surface so existing `@import("index.zig")`
// callers keep working unchanged.

const chars = @import("index/chars.zig");
const word_tokenizer = @import("index/word_tokenizer.zig");
const word_index = @import("index/word_index.zig");
const trigram = @import("index/trigram.zig");
const frequency = @import("index/frequency.zig");
const sparse_ngram = @import("index/sparse_ngram.zig");
const type_index = @import("index/type_index.zig");
const type_graph = @import("index/type_graph.zig");

// ── chars ──
pub const normalizeChar = chars.normalizeChar;

// ── word index ──
pub const WordHit = word_index.WordHit;
pub const WordIndex = word_index.WordIndex;

// ── tokenizer ──
pub const WordTokenizer = word_tokenizer.WordTokenizer;
pub const splitIdentifier = word_tokenizer.splitIdentifier;

// ── trigram ──
pub const Trigram = trigram.Trigram;
pub const packTrigram = trigram.packTrigram;
pub const PostingMask = trigram.PostingMask;
pub const DocPosting = trigram.DocPosting;
pub const PostingList = trigram.PostingList;
pub const TrigramIndex = trigram.TrigramIndex;
pub const MmapTrigramIndex = trigram.MmapTrigramIndex;
pub const AnyTrigramIndex = trigram.AnyTrigramIndex;
pub const RegexQuery = trigram.RegexQuery;
pub const decomposeRegex = trigram.decomposeRegex;

// ── frequency table ──
pub const MAX_NGRAM_LEN = frequency.MAX_NGRAM_LEN;
pub const default_pair_freq = frequency.default_pair_freq;
pub const pairWeight = frequency.pairWeight;
pub const setFrequencyTable = frequency.setFrequencyTable;
pub const resetFrequencyTable = frequency.resetFrequencyTable;
pub const buildFrequencyTable = frequency.buildFrequencyTable;
pub const buildFrequencyTableFromSlices = frequency.buildFrequencyTableFromSlices;
pub const buildFrequencyTableFromMap = frequency.buildFrequencyTableFromMap;
pub const writeFrequencyTable = frequency.writeFrequencyTable;
pub const readFrequencyTable = frequency.readFrequencyTable;

// ── sparse n-gram ──
pub const SparseNgram = sparse_ngram.SparseNgram;
pub const extractSparseNgrams = sparse_ngram.extractSparseNgrams;
pub const buildCoveringSet = sparse_ngram.buildCoveringSet;
pub const SparseNgramIndex = sparse_ngram.SparseNgramIndex;

// ── type index ──
pub const TypeHit = type_index.TypeHit;
pub const TypeIndex = type_index.TypeIndex;

// ── type graph ──
pub const TypeGraph = type_graph.TypeGraph;
