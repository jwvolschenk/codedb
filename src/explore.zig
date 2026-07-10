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
    /// Incremented (under mu) whenever the trigram index is structurally
    /// replaced (adopt*) or rebuilt, so cached search results can invalidate.
    /// Mirrors the word_index_generation pattern. Phase 2 (#615).
    search_gen: u32 = 0,
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
            // #586: the map owns its keys (duped on insert), so free them here.
            self.allocator.free(entry.key_ptr.*);
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

    pub const releaseContents = @import("explore/lifecycle.zig").releaseContents;
    pub const releaseSecondaryIndexes = @import("explore/lifecycle.zig").releaseSecondaryIndexes;
    pub const indexFile = @import("explore/lifecycle.zig").indexFile;
    pub const indexFileOutlineOnly = @import("explore/lifecycle.zig").indexFileOutlineOnly;
    pub const indexFileSkipTrigram = @import("explore/lifecycle.zig").indexFileSkipTrigram;
    pub const commitParsedFileOwnedOutline = @import("explore/lifecycle.zig").commitParsedFileOwnedOutline;
    pub const computeSymbolEnds = @import("explore/lifecycle.zig").computeSymbolEnds;
    pub const adoptTrigramIndex = @import("explore/lifecycle.zig").adoptTrigramIndex;
    pub const adoptTrigramBase = @import("explore/lifecycle.zig").adoptTrigramBase;
    pub const findBraceEnd = @import("explore/lifecycle.zig").findBraceEnd;
    pub const findPythonEnd = @import("explore/lifecycle.zig").findPythonEnd;
    pub const findRubyEnd = @import("explore/lifecycle.zig").findRubyEnd;
    pub const countIndent = @import("explore/lifecycle.zig").countIndent;
    pub const parseOutlineWithParser = @import("explore/lifecycle.zig").parseOutlineWithParser;
    pub const parseContentForIndexing = @import("explore/lifecycle.zig").parseContentForIndexing;
    pub const collectCSharpDecorators = @import("explore/lifecycle.zig").collectCSharpDecorators;
    pub const findCSharpDecoratorClose = @import("explore/lifecycle.zig").findCSharpDecoratorClose;
    pub const attachDecoratorsToSymbols = @import("explore/lifecycle.zig").attachDecoratorsToSymbols;
    pub const clearDecoratorList = @import("explore/lifecycle.zig").clearDecoratorList;
    pub const indexFileInner = @import("explore/lifecycle.zig").indexFileInner;
    pub const rebuildTrigrams = @import("explore/lifecycle.zig").rebuildTrigrams;
    pub const rebuildWordIndex = @import("explore/lifecycle.zig").rebuildWordIndex;
    pub const markWordIndexIncomplete = @import("explore/lifecycle.zig").markWordIndexIncomplete;
    pub const markWordIndexAsComplete = @import("explore/lifecycle.zig").markWordIndexAsComplete;
    pub const disableWordIndexDiskLoad = @import("explore/lifecycle.zig").disableWordIndexDiskLoad;
    pub const wordIndexCanLoadFromDisk = @import("explore/lifecycle.zig").wordIndexCanLoadFromDisk;
    pub const wordIndexIsComplete = @import("explore/lifecycle.zig").wordIndexIsComplete;
    pub const wordIndexNeedsPersist = @import("explore/lifecycle.zig").wordIndexNeedsPersist;
    pub const wordIndexGenerationToPersist = @import("explore/lifecycle.zig").wordIndexGenerationToPersist;
    pub const markWordIndexPersisted = @import("explore/lifecycle.zig").markWordIndexPersisted;
    pub const replaceWordIndex = @import("explore/lifecycle.zig").replaceWordIndex;
    pub const removeFile = @import("explore/lifecycle.zig").removeFile;
    pub const ContentRef = @import("explore/lifecycle.zig").ContentRef;
    pub const readContentForSearch = @import("explore/lifecycle.zig").readContentForSearch;
    pub const cloneOutline = @import("explore/lifecycle.zig").cloneOutline;
    pub const cloneDecorators = @import("explore/lifecycle.zig").cloneDecorators;
    pub const freeDecorators = @import("explore/lifecycle.zig").freeDecorators;
    pub const cloneParamTypes = @import("explore/lifecycle.zig").cloneParamTypes;
    pub const freeParamTypes = @import("explore/lifecycle.zig").freeParamTypes;

    pub fn getOutline(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?FileOutline {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return null;
        return try Explorer.cloneOutline(outline, allocator);
    }

    /// Return a caller-owned copy of cached file content.
    pub fn getContent(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        if (ref.owned) return @constCast(ref.data);
        return try allocator.dupe(u8, ref.data);
    }

    pub const getTree = @import("explore/tree.zig").getTree;

    pub const findSymbol = @import("explore/deps.zig").findSymbol;

    pub const findAllSymbols = @import("explore/deps.zig").findAllSymbols;

    pub const searchContent = @import("explore/search.zig").searchContent;

    pub const rerankAndFinalize = @import("explore/search.zig").rerankAndFinalize;

    pub const rerankSignalScore = @import("explore/search.zig").rerankSignalScore;

    pub const appendRerankTrace = @import("explore/search.zig").appendRerankTrace;

    pub const searchContentRanked = @import("explore/search.zig").searchContentRanked;

    pub const searchContentRegex = @import("explore/search.zig").searchContentRegex;

    pub const searchWord = @import("explore/search.zig").searchWord;

    pub const FuzzyMatch = @import("explore/search.zig").FuzzyMatch;

    pub const fuzzyFindFiles = @import("explore/search.zig").fuzzyFindFiles;

    pub const LsEntry = @import("explore/tree.zig").LsEntry;
    pub const globPaths = @import("explore/tree.zig").globPaths;
    pub const lsDir = @import("explore/tree.zig").lsDir;
    pub const lsDirHotspotScore = @import("explore/tree.zig").lsDirHotspotScore;
    pub const isStubLikeOutline = @import("explore/tree.zig").isStubLikeOutline;
    pub const buildOutlineDescriptor = @import("explore/tree.zig").buildOutlineDescriptor;
    pub const appendFmt = @import("explore/tree.zig").appendFmt;
    pub const decoratorsContainText = @import("explore/tree.zig").decoratorsContainText;
    pub const extractBaseDescriptor = @import("explore/tree.zig").extractBaseDescriptor;
    pub const isStubCandidateLanguage = @import("explore/tree.zig").isStubCandidateLanguage;

    pub const getImportedBy = @import("explore/deps.zig").getImportedBy;

    pub const getTransitiveDependents = @import("explore/deps.zig").getTransitiveDependents;

    pub const getTransitiveDependencies = @import("explore/deps.zig").getTransitiveDependencies;

    pub const getHotFiles = @import("explore/deps.zig").getHotFiles;

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

    pub const parseZigLine = @import("explore/parsers/systems.zig").parseZigLine;

    pub const parsePythonLine = @import("explore/parsers/scripting.zig").parsePythonLine;

    pub const parseTsLine = @import("explore/parsers/web.zig").parseTsLine;

    pub const parseJavaLine = @import("explore/parsers/jvm.zig").parseJavaLine;

    pub const parseKotlinLine = @import("explore/parsers/jvm.zig").parseKotlinLine;

    pub const parseCSharpLine = @import("explore/parsers/csharp_family.zig").parseCSharpLine;
    pub const parseCSharpLineWithOptions = @import("explore/parsers/csharp_family.zig").parseCSharpLineWithOptions;

    pub const extractCSharpEnumValue = @import("explore/parsers/csharp_family.zig").extractCSharpEnumValue;

    pub const parseFSharpLine = @import("explore/parsers/csharp_family.zig").parseFSharpLine;

    pub const parseRazorLine = @import("explore/parsers/csharp_family.zig").parseRazorLine;

    pub const razorIsControlFlow = @import("explore/parsers/csharp_family.zig").razorIsControlFlow;

    pub const extractRazorInjectType = @import("explore/parsers/csharp_family.zig").extractRazorInjectType;

    pub const parseSwiftLine = @import("explore/parsers/clang.zig").parseSwiftLine;

    pub const parseComponentLine = @import("explore/parsers/web.zig").parseComponentLine;

    pub const parseShellLine = @import("explore/parsers/web.zig").parseShellLine;

    pub const parseStyleLine = @import("explore/parsers/web.zig").parseStyleLine;

    pub const parseSqlLine = @import("explore/parsers/declarative.zig").parseSqlLine;

    pub const parseProtoLine = @import("explore/parsers/declarative.zig").parseProtoLine;

    pub const parseFortranLine = @import("explore/parsers/declarative.zig").parseFortranLine;

    pub const parseLlvmIrLine = @import("explore/parsers/declarative.zig").parseLlvmIrLine;

    pub const parseMlirLine = @import("explore/parsers/declarative.zig").parseMlirLine;

    pub const parseTableGenLine = @import("explore/parsers/declarative.zig").parseTableGenLine;

    pub const parseCLine = @import("explore/parsers/clang.zig").parseCLine;

    pub const parseRustLine = @import("explore/parsers/systems.zig").parseRustLine;

    pub const parsePhpLine = @import("explore/parsers/scripting.zig").parsePhpLine;

    pub const parsePhpUseImport = @import("explore/parsers/scripting.zig").parsePhpUseImport;

    pub const phpStripAlias = @import("explore/parsers/scripting.zig").phpStripAlias;

    pub const phpMatchConstant = @import("explore/parsers/scripting.zig").phpMatchConstant;

    pub const PhpClassMatch = @import("explore/parsers/scripting.zig").PhpClassMatch;

    pub const phpMatchClassLike = @import("explore/parsers/scripting.zig").phpMatchClassLike;

    pub const parseGoLine = @import("explore/parsers/systems.zig").parseGoLine;

    pub const parseDartLine = @import("explore/parsers/declarative.zig").parseDartLine;

    pub const parseRubyLine = @import("explore/parsers/scripting.zig").parseRubyLine;

    pub const parseHclLine = @import("explore/parsers/declarative.zig").parseHclLine;

    pub const parseRLine = @import("explore/parsers/declarative.zig").parseRLine;

    pub const rebuildDepsFor = @import("explore/deps.zig").rebuildDepsFor;

    pub const resolveSqlDepKey = @import("explore/deps.zig").resolveSqlDepKey;

    pub const DependencyKey = @import("explore/deps.zig").DependencyKey;

    pub const resolveDependencyKey = @import("explore/deps.zig").resolveDependencyKey;

    pub const rebuildSymbolIndexFor = @import("explore/deps.zig").rebuildSymbolIndexFor;

    pub const rebuildTypeIndexes = @import("explore/deps.zig").rebuildTypeIndexes;

    pub const rebuildTypeIndexesLocked = @import("explore/deps.zig").rebuildTypeIndexesLocked;

    pub const rebuildTypeUsageDeps = @import("explore/deps.zig").rebuildTypeUsageDeps;

    pub const rebuildTypeUsageDepsLocked = @import("explore/deps.zig").rebuildTypeUsageDepsLocked;

    pub const buildTypeGraphForFile = @import("explore/deps.zig").buildTypeGraphForFile;

    pub const extractAndRecordBases = @import("explore/deps.zig").extractAndRecordBases;

    pub const findBasePortion = @import("explore/deps.zig").findBasePortion;

    pub const symbolNameMatches = @import("explore/deps.zig").symbolNameMatches;

    pub const isHierarchyKeyword = @import("explore/deps.zig").isHierarchyKeyword;

    pub const removeSymbolIndexFor = @import("explore/deps.zig").removeSymbolIndexFor;

    pub const getSymbolBody = @import("explore/deps.zig").getSymbolBody;

    pub const findEnclosingSymbolLocked = @import("explore/deps.zig").findEnclosingSymbolLocked;

    pub const ScopedSearchResult = @import("explore/search.zig").ScopedSearchResult;

    pub const searchContentWithScope = @import("explore/search.zig").searchContentWithScope;

    pub const findTypeReferences = @import("explore/search.zig").findTypeReferences;

    pub const searchReferencesWithScope = @import("explore/search.zig").searchReferencesWithScope;

    pub const searchContentRegexWithScope = @import("explore/search.zig").searchContentRegexWithScope;

    pub const searchInContentWithScope = @import("explore/search.zig").searchInContentWithScope;

    pub const searchInContentRegexWithScope = @import("explore/search.zig").searchInContentRegexWithScope;
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
