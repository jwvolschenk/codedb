const std = @import("std");
const testing = std.testing;
const Explorer = @import("../../explore.zig").Explorer;
const FileOutline = @import("../../explore.zig").FileOutline;
const SymbolKind = @import("../../explore.zig").SymbolKind;

fn find(outline: *const FileOutline, name: []const u8) ?@import("../../explore.zig").Symbol {
    for (outline.symbols.items) |symbol| if (std.mem.eql(u8, symbol.name, name)) return symbol;
    return null;
}

fn expectMissing(outline: *const FileOutline, name: []const u8) !void {
    try testing.expect(find(outline, name) == null);
}

fn hasImport(outline: *const FileOutline, path: []const u8) bool {
    for (outline.imports.items) |item| if (std.mem.eql(u8, item, path)) return true;
    return false;
}

test "javascript parser: module declarations and multiline imports" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("module.ts",
        \\import {
        \\  first,
        \\  second,
        \\} from "mycredopro.common";
        \\export { third } from './third';
        \\const legacy = require(
        \\  'legacy-package'
        \\);
        \\const PORT = 3000;
        \\let mutable = {};
        \\var { left, source: renamed } = input;
        \\export async function handle(
        \\  id: number,
        \\): Promise<User> {
        \\  const hidden = 1;
        \\}
        \\const arrow = (value: string): boolean => { return true; };
        \\let assigned = function named() { return 1; };
        \\type Result = User | null;
        \\enum State { ready }
    );
    var outline = (try explorer.getOutline("module.ts", testing.allocator)).?;
    defer outline.deinit();
    try testing.expect(hasImport(&outline, "mycredopro.common"));
    try testing.expect(hasImport(&outline, "./third"));
    try testing.expect(hasImport(&outline, "legacy-package"));
    const import_symbol = outline.symbols.items[0];
    try testing.expect(std.mem.indexOf(u8, import_symbol.detail.?, "import { first, second, } from \"mycredopro.common\";") != null);
    try testing.expectEqual(SymbolKind.function, find(&outline, "handle").?.kind);
    try testing.expectEqual(SymbolKind.function, find(&outline, "arrow").?.kind);
    try testing.expectEqual(SymbolKind.function, find(&outline, "assigned").?.kind);
    try testing.expect(find(&outline, "left") != null);
    try testing.expect(find(&outline, "renamed") != null);
    try testing.expect(find(&outline, "Result") != null);
    try testing.expect(find(&outline, "State") != null);
    try expectMissing(&outline, "hidden");
}

test "javascript parser: class and interface members have exact ranges" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("members.ts",
        \\class Service {
        \\  readonly endpoint: string = '/api';
        \\  value = 1;
        \\  constructor() {}
        \\  async load() {
        \\    const local = { brace: '}' };
        \\    return /[{}]/.test(local.brace);
        \\  }
        \\  static *items() { yield 1; }
        \\  get current() { return this.value; }
        \\  set current(value: number) { this.value = value; }
        \\  callback = (value: number) => {
        \\    return value + 1;
        \\  };
        \\}
        \\interface Contract {
        \\  run(value: string): Promise<void>;
        \\  readonly name: string;
        \\  handler?: (event: Event) => void;
        \\}
    );
    var outline = (try explorer.getOutline("members.ts", testing.allocator)).?;
    defer outline.deinit();
    try testing.expectEqual(SymbolKind.constant, find(&outline, "endpoint").?.kind);
    try testing.expectEqual(SymbolKind.variable, find(&outline, "value").?.kind);
    try testing.expectEqual(SymbolKind.method, find(&outline, "constructor").?.kind);
    try testing.expectEqual(@as(u32, 5), find(&outline, "load").?.line_start);
    try testing.expectEqual(@as(u32, 8), find(&outline, "load").?.line_end);
    try testing.expectEqual(SymbolKind.method, find(&outline, "items").?.kind);
    try testing.expectEqual(SymbolKind.method, find(&outline, "current").?.kind);
    try testing.expectEqual(SymbolKind.method, find(&outline, "callback").?.kind);
    try testing.expectEqual(SymbolKind.method, find(&outline, "run").?.kind);
    try testing.expectEqual(SymbolKind.constant, find(&outline, "name").?.kind);
    try testing.expectEqual(SymbolKind.method, find(&outline, "handler").?.kind);
    try expectMissing(&outline, "local");
}

test "javascript parser: ignores implementation noise and lexical decoys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("noise.js",
        \\// function ghostComment() {}
        \\const text = "function ghostString() { class Nope {} }";
        \\const template = `class GhostTemplate { method() {} }`;
        \\const regex = /function ghostRegex\\(\\) \\{\\}/;
        \\if (true) /class GhostAfterParen \\{\\}/.test(text);
        \\class Real {
        \\  method() {
        \\    for (const item of []) {
        \\      const postData = {};
        \\      items.map(selectedItem => ({ nested() {} }));
        \\      await this.work(item);
        \\    }
        \\  }
        \\}
    );
    var outline = (try explorer.getOutline("noise.js", testing.allocator)).?;
    defer outline.deinit();
    try testing.expect(find(&outline, "Real") != null);
    try testing.expect(find(&outline, "method") != null);
    const absent = [_][]const u8{ "ghostComment", "ghostString", "Nope", "GhostTemplate", "ghostRegex", "GhostAfterParen", "for", "this", "await", "item", "postData", "selectedItem", "nested" };
    for (&absent) |name| try expectMissing(&outline, name);
}

test "javascript parser: malformed constructs stay bounded and hide their contents" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("broken.ts",
        \\export function visible() {}
        \\/* class HiddenComment { bad() {} }
        \\function alsoHidden() {}
    );
    var comment_outline = (try explorer.getOutline("broken.ts", testing.allocator)).?;
    defer comment_outline.deinit();
    try testing.expect(find(&comment_outline, "visible") != null);
    try expectMissing(&comment_outline, "HiddenComment");
    try expectMissing(&comment_outline, "alsoHidden");

    try explorer.indexFile("broken-template.ts",
        \\const visible = 1;
        \\const bad = `class HiddenTemplate { nope() {} }
        \\function hiddenToo() {}
    );
    var template_outline = (try explorer.getOutline("broken-template.ts", testing.allocator)).?;
    defer template_outline.deinit();
    try testing.expect(find(&template_outline, "visible") != null);
    try expectMissing(&template_outline, "HiddenTemplate");
    try expectMissing(&template_outline, "hiddenToo");

    try explorer.indexFile("broken-string.ts",
        \\const bad = "class HiddenString { nope() {}
        \\export function recovered() {}
    );
    var string_outline = (try explorer.getOutline("broken-string.ts", testing.allocator)).?;
    defer string_outline.deinit();
    try expectMissing(&string_outline, "HiddenString");
    try testing.expect(find(&string_outline, "recovered") != null);

    try explorer.indexFile("incomplete-class.ts",
        \\class Incomplete {
        \\  method() {
        \\    const hiddenLocal = 1;
        \\    for (const hiddenLoop of values) {
    );
    var class_outline = (try explorer.getOutline("incomplete-class.ts", testing.allocator)).?;
    defer class_outline.deinit();
    try testing.expect(find(&class_outline, "Incomplete") != null);
    try testing.expect(find(&class_outline, "method") != null);
    try expectMissing(&class_outline, "hiddenLocal");
    try expectMissing(&class_outline, "hiddenLoop");
}

test "javascript parser: multi-line + re-export relative imports resolve in the dep graph" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/bus/event-bus.ts", "export class EventBus {}\n");
    try explorer.indexFile("src/role/role-driver.ts",
        \\import {
        \\  existsSync,
        \\  readdirSync,
        \\} from "../bus/event-bus.ts";
        \\
        \\export * from "./re-export.ts";
        \\
        \\// loads config from "config.json" at boot
        \\
        \\export class RoleDriver {}
    );

    // The multi-line import's `from "..."` clause resolves to the actual
    // dependency graph edge, not just the raw outline.imports specifier.
    const importers = try explorer.getImportedBy("src/bus/event-bus.ts", testing.allocator);
    defer {
        for (importers) |p| testing.allocator.free(p);
        testing.allocator.free(importers);
    }
    var found = false;
    for (importers) |p| {
        if (std.mem.eql(u8, p, "src/role/role-driver.ts")) found = true;
    }
    try testing.expect(found);

    // A comment that merely contains `from "..."` must never become a
    // dependency edge.
    var outline = (try explorer.getOutline("src/role/role-driver.ts", testing.allocator)).?;
    defer outline.deinit();
    for (outline.imports.items) |imp| {
        try testing.expect(!std.mem.eql(u8, imp, "config.json"));
    }
}
