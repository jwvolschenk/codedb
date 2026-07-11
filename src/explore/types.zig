// codedb — core data types for code exploration (symbols, outlines, languages).
const std = @import("std");

pub const SymbolKind = enum(u8) {
    function,
    struct_def,
    enum_def,
    union_def,
    constant,
    variable,
    import,
    test_decl,
    comment_block,
    trait_def,
    impl_block,
    type_alias,
    macro_def,
    method,
    class_def,
    interface_def,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    detail: ?[]const u8 = null,
    decorators: []const []const u8 = &.{},
    return_type: ?[]const u8 = null,
    param_types: []const []const u8 = &.{},
};

pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: u32,
    byte_size: u64,
    symbols: std.ArrayList(Symbol) = .empty,
    imports: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    owns_path: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) FileOutline {
        return .{
            .path = path,
            .language = detectLanguage(path),
            .line_count = 0,
            .byte_size = 0,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *FileOutline) void {
        if (self.owns_path) self.allocator.free(self.path);
        for (self.symbols.items) |sym| {
            self.allocator.free(sym.name);
            if (sym.detail) |d| self.allocator.free(d);
            for (sym.decorators) |decorator| self.allocator.free(decorator);
            if (sym.decorators.len > 0) self.allocator.free(sym.decorators);
            if (sym.return_type) |rt| self.allocator.free(rt);
            for (sym.param_types) |pt| self.allocator.free(pt);
            if (sym.param_types.len > 0) self.allocator.free(sym.param_types);
        }
        self.symbols.deinit(self.allocator);
        for (self.imports.items) |imp| self.allocator.free(imp);
        self.imports.deinit(self.allocator);
    }
};

pub const ParsedFile = struct {
    content: []const u8,
    outline: FileOutline,

    pub fn deinit(self: *ParsedFile) void {
        self.outline.deinit();
    }
};

pub const PhpParseState = struct {
    in_class: bool = false,
    brace_depth: i32 = 0,
    class_brace_depth: i32 = 0,
    in_block_comment: bool = false,
};

pub const Language = enum(u8) {
    zig,
    c,
    cpp,
    python,
    javascript,
    typescript,
    rust,
    go_lang,
    php,
    ruby,
    hcl,
    r,
    markdown,
    json,
    yaml,
    unknown,
    dart,
    java,
    kotlin,
    swift,
    svelte,
    vue,
    astro,
    shell,
    css,
    scss,
    sql,
    protobuf,
    fortran,
    llvm_ir,
    mlir,
    tablegen,
    c_sharp,
    f_sharp,
    razor,
    autumn_adm,
    autumn_acfg,
    autumn_adpt,
    autumn_arc,
    t4_template,
    ssrs_report,
    ssrs_dataset,
    ssrs_datasource,
    ssrs_project,
    gdscript,
    godot_scene,
    godot_resource,
    godot_project,
    dax,
    mdx,
    tmdl,
    ssas_tabular,
    ssas_cube,
    ssas_project,
};

pub fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return .c;
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".cc") or std.mem.endsWith(u8, path, ".hh") or
        std.mem.endsWith(u8, path, ".cxx") or std.mem.endsWith(u8, path, ".hxx") or
        std.mem.endsWith(u8, path, ".mm"))
        return .cpp;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".go")) return .go_lang;
    if (std.mem.endsWith(u8, path, ".php")) return .php;
    if (std.mem.endsWith(u8, path, ".rb") or std.mem.endsWith(u8, path, ".rake")) return .ruby;
    if (std.mem.endsWith(u8, path, ".tf") or std.mem.endsWith(u8, path, ".tfvars") or std.mem.endsWith(u8, path, ".hcl")) return .hcl;
    if (std.mem.endsWith(u8, path, ".r") or std.mem.endsWith(u8, path, ".R")) return .r;
    if (std.mem.endsWith(u8, path, ".md")) return .markdown;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".dart")) return .dart;
    if (std.mem.endsWith(u8, path, ".java")) return .java;
    if (std.mem.endsWith(u8, path, ".kt")) return .kotlin;
    if (std.mem.endsWith(u8, path, ".swift")) return .swift;
    if (std.mem.endsWith(u8, path, ".svelte")) return .svelte;
    if (std.mem.endsWith(u8, path, ".vue")) return .vue;
    if (std.mem.endsWith(u8, path, ".astro")) return .astro;
    if (std.mem.endsWith(u8, path, ".sh")) return .shell;
    if (std.mem.endsWith(u8, path, ".css")) return .css;
    if (std.mem.endsWith(u8, path, ".scss")) return .scss;
    if (std.mem.endsWith(u8, path, ".sql")) return .sql;
    if (std.mem.endsWith(u8, path, ".proto")) return .protobuf;
    if (std.mem.endsWith(u8, path, ".f90")) return .fortran;
    if (std.mem.endsWith(u8, path, ".ll")) return .llvm_ir;
    if (std.mem.endsWith(u8, path, ".mlir")) return .mlir;
    if (std.mem.endsWith(u8, path, ".td")) return .tablegen;
    if (std.mem.endsWith(u8, path, ".cs") or std.mem.endsWith(u8, path, ".csx")) return .c_sharp;
    if (std.mem.endsWith(u8, path, ".cshtml") or std.mem.endsWith(u8, path, ".razor")) return .razor;
    if (std.mem.endsWith(u8, path, ".fs") or std.mem.endsWith(u8, path, ".fsi") or std.mem.endsWith(u8, path, ".fsx")) return .f_sharp;
    if (std.mem.endsWith(u8, path, ".adm")) return .autumn_adm;
    if (std.mem.endsWith(u8, path, ".acfg")) return .autumn_acfg;
    if (std.mem.endsWith(u8, path, ".adpt")) return .autumn_adpt;
    if (std.mem.endsWith(u8, path, ".arc")) return .autumn_arc;
    if (std.mem.endsWith(u8, path, ".tt") or std.mem.endsWith(u8, path, ".t4")) return .t4_template;
    if (std.mem.endsWith(u8, path, ".rdl")) return .ssrs_report;
    if (std.mem.endsWith(u8, path, ".rsd")) return .ssrs_dataset;
    if (std.mem.endsWith(u8, path, ".rds")) return .ssrs_datasource;
    if (std.mem.endsWith(u8, path, ".rptproj")) return .ssrs_project;
    if (std.mem.endsWith(u8, path, ".gd")) return .gdscript;
    if (std.mem.endsWith(u8, path, ".tscn")) return .godot_scene;
    if (std.mem.endsWith(u8, path, ".tres")) return .godot_resource;
    if (std.mem.endsWith(u8, path, "project.godot")) return .godot_project;
    if (endsWithIgnoreCase(path, ".bim")) return .ssas_tabular;
    if (endsWithIgnoreCase(path, ".tmdl")) return .tmdl;
    if (endsWithIgnoreCase(path, ".dax")) return .dax;
    if (endsWithIgnoreCase(path, ".mdx")) return .mdx;
    if (endsWithIgnoreCase(path, ".cube") or endsWithIgnoreCase(path, ".xmla")) return .ssas_cube;
    if (endsWithIgnoreCase(path, ".smproj") or endsWithIgnoreCase(path, ".dwproj")) return .ssas_project;
    return .unknown;
}

fn endsWithIgnoreCase(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    for (path[path.len - suffix.len ..], suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// Returns true for languages whose content is primarily prose / data /
/// markup rather than executable code. Used to deprioritise these files in
/// content search so a CHANGELOG.md or design doc cannot starve a canonical
/// source-file match (issue #430).
pub fn isDocLanguage(lang: Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .unknown => true,
        else => false,
    };
}

pub const SymbolResult = struct {
    path: []const u8,
    symbol: Symbol,
};

pub const SearchResult = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
    score: f32 = 0.0,
};

pub const SymbolLocation = struct {
    path: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
};
