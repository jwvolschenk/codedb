//! Compatibility aggregator for explore parser/search utilities.

const search_utils = @import("search_utils.zig");
const outline_builders = @import("outline_builders.zig");
const ident_utils = @import("ident_utils.zig");
const c_family = @import("parsers/c_family.zig");
const sql = @import("parsers/sql.zig");
const shell_css = @import("parsers/shell_css.zig");
const misc = @import("parsers/misc.zig");

pub const extractLines = search_utils.extractLines;
pub const isCommentOrBlank = search_utils.isCommentOrBlank;
pub const searchInContent = search_utils.searchInContent;
pub const extractLineByNumber = search_utils.extractLineByNumber;
pub const matchAtCaseInsensitive = search_utils.matchAtCaseInsensitive;
pub const searchInContentRegex = search_utils.searchInContentRegex;
pub const regexMatch = search_utils.regexMatch;
pub const indexOfCaseInsensitive = search_utils.indexOfCaseInsensitive;
pub const countOccurrences = search_utils.countOccurrences;
pub const writeJsonEscaped = search_utils.writeJsonEscaped;
pub const asciiEqlIgnoreCase = search_utils.asciiEqlIgnoreCase;
pub const asciiContainsIgnoreCase = search_utils.asciiContainsIgnoreCase;
pub const pathHasSegment = search_utils.pathHasSegment;
pub const pathHasSegmentIgnoreCase = search_utils.pathHasSegmentIgnoreCase;
pub const toLowerByte = search_utils.toLowerByte;
pub const isWordBoundary = search_utils.isWordBoundary;
pub const isSpecialEntryPoint = search_utils.isSpecialEntryPoint;
pub const getFilename = search_utils.getFilename;
pub const fuzzyScore = search_utils.fuzzyScore;

pub const appendOutlineSymbol = outline_builders.appendOutlineSymbol;
pub const appendOutlineSymbolWithTypes = outline_builders.appendOutlineSymbolWithTypes;
pub const appendImportSymbol = outline_builders.appendImportSymbol;
pub const cSharpSymbolKind = outline_builders.cSharpSymbolKind;
pub const fSharpSymbolKind = outline_builders.fSharpSymbolKind;

pub const startsWith = ident_utils.startsWith;
pub const extractIdent = ident_utils.extractIdent;
pub const isIdentChar = ident_utils.isIdentChar;
pub const extractIdentAfterKeyword = ident_utils.extractIdentAfterKeyword;
pub const extractIdentAfterKeywordIgnoreCase = ident_utils.extractIdentAfterKeywordIgnoreCase;
pub const startsWithIgnoreCase = ident_utils.startsWithIgnoreCase;
pub const isControlKeyword = ident_utils.isControlKeyword;
pub const IdentSpan = ident_utils.IdentSpan;
pub const extractLastIdentSpan = ident_utils.extractLastIdentSpan;
pub const extractLastIdent = ident_utils.extractLastIdent;
pub const containsAny = ident_utils.containsAny;
pub const skipKeywords = ident_utils.skipKeywords;

pub const stripLineComment = c_family.stripLineComment;
pub const extractCIncludePath = c_family.extractCIncludePath;
pub const CTypeSymbol = c_family.CTypeSymbol;
pub const parseCNamedType = c_family.parseCNamedType;
pub const parseCBraceType = c_family.parseCBraceType;
pub const parseCTypeAfterKeyword = c_family.parseCTypeAfterKeyword;
pub const parseObjCType = c_family.parseObjCType;
pub const extractObjCMethodName = c_family.extractObjCMethodName;
pub const extractCFunctionName = c_family.extractCFunctionName;
pub const countChar = c_family.countChar;
pub const applyBraceDelta = c_family.applyBraceDelta;
pub const countBracesDelta = c_family.countBracesDelta;
pub const looksLikeCMethodDef = c_family.looksLikeCMethodDef;
pub const stripCAttributesPrefix = c_family.stripCAttributesPrefix;
pub const hasCAssignmentBeforeName = c_family.hasCAssignmentBeforeName;
pub const isCForbiddenFunctionPrefix = c_family.isCForbiddenFunctionPrefix;
pub const isCKeyword = c_family.isCKeyword;
pub const firstIndexOfAny = c_family.firstIndexOfAny;

pub const stripSqlLineComment = sql.stripSqlLineComment;
pub const SqlSymbol = sql.SqlSymbol;
pub const parseSqlCreate = sql.parseSqlCreate;
pub const parseSqlCreateKind = sql.parseSqlCreateKind;
pub const firstSqlIdent = sql.firstSqlIdent;

pub const firstShellWord = shell_css.firstShellWord;
pub const parseShellAssignment = shell_css.parseShellAssignment;
pub const parseCssVariable = shell_css.parseCssVariable;
pub const parseCssSelector = shell_css.parseCssSelector;

pub const phpNamespaceToPath = misc.phpNamespaceToPath;
pub const parseDelimitedImport = misc.parseDelimitedImport;
pub const extractJvmMethodName = misc.extractJvmMethodName;
pub const stripFortranComment = misc.stripFortranComment;
pub const parseFortranUse = misc.parseFortranUse;
pub const parseFortranTypeName = misc.parseFortranTypeName;
pub const extractAtName = misc.extractAtName;
pub const extractLlvmGlobalName = misc.extractLlvmGlobalName;
pub const extractLlvmLikeName = misc.extractLlvmLikeName;
pub const extractRubyMethodName = misc.extractRubyMethodName;
pub const extractHclQuotedName = misc.extractHclQuotedName;
pub const extractHclBlockName = misc.extractHclBlockName;
pub const extractStringLiteral = misc.extractStringLiteral;
pub const normalizePath = misc.normalizePath;
pub const resolveDartImport = misc.resolveDartImport;
pub const extractPythonModulePath = misc.extractPythonModulePath;
