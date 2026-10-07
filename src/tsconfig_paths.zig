//! Bounded local tsconfig paths. Does not execute JS, fetch packages or follow extends.
const std = @import("std");
const files = @import("project_file.zig");
const normalize = @import("explore/parse_utils.zig").normalizePath;
pub const Aliases = struct {
    const Rule = struct { pattern: []const u8, target: []const u8 };
    rules: std.ArrayList(Rule) = .empty,
    pub fn deinit(self: *Aliases, a: std.mem.Allocator) void {
        for (self.rules.items) |r| { a.free(r.pattern); a.free(r.target); }
        self.rules.deinit(a);
        self.* = .{};
    }
    pub fn load(self: *Aliases, io: std.Io, root: std.Io.Dir, a: std.mem.Allocator) void {
        self.deinit(a);
        const source = files.readAlloc(io, root, "tsconfig.json", a, .limited(128 * 1024)) catch return;
        defer a.free(source);
        // Keep JSON strings intact while blanking // and /* */ comments.
        var i: usize = 0;
        while (i < source.len) {
            if (source[i] == '"') {
                i += 1;
                while (i < source.len) {
                    if (source[i] == '\\') { i += @min(@as(usize, 2), source.len - i); continue; }
                    if (source[i] == '"') { i += 1; break; }
                    i += 1;
                }
            } else if (std.mem.startsWith(u8, source[i..], "//")) {
                while (i < source.len and source[i] != '\n') : (i += 1) source[i] = ' ';
            } else if (std.mem.startsWith(u8, source[i..], "/*")) {
                source[i] = ' '; source[i + 1] = ' '; i += 2;
                while (i < source.len and !std.mem.startsWith(u8, source[i..], "*/")) : (i += 1) source[i] = ' ';
                if (i + 1 < source.len) { source[i] = ' '; source[i + 1] = ' '; i += 2; }
            } else i += 1;
        }
        const json = std.json.parseFromSlice(std.json.Value, a, source, .{ .allocate = .alloc_always, .max_value_len = 4096 }) catch return;
        defer json.deinit();
        if (json.value != .object) return;
        const options = json.value.object.get("compilerOptions") orelse return;
        if (options != .object) return;
        const base_val = options.object.get("baseUrl");
        const base = if (base_val) |v| (if (v == .string) v.string else ".") else ".";
        const paths = options.object.get("paths") orelse return;
        if (paths != .object or paths.object.count() > 128) return;
        var it = paths.object.iterator();
        while (it.next()) |entry| {
            const pattern = entry.key_ptr.*;
            if (pattern.len == 0 or std.mem.count(u8, pattern, "*") > 1) continue;
            // Multiple targets express fallback/ambiguity. Keep the import
            // unresolved rather than select a target without compiler context.
            if (entry.value_ptr.* != .array or entry.value_ptr.array.items.len != 1) continue;
            const value = entry.value_ptr.array.items[0];
            if (value != .string or std.mem.count(u8, value.string, "*") > 1) continue;
            const target = std.fmt.allocPrint(a, "{s}/{s}", .{base, value.string}) catch return;
            const key = a.dupe(u8, pattern) catch { a.free(target); return; };
            self.rules.append(a, .{ .pattern = key, .target = target }) catch { a.free(key); a.free(target); return; };
        }
    }
    pub fn resolve(self: *const Aliases, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
        var best: ?Rule = null;
        var capture: []const u8 = "";
        var best_prefix: usize = 0;
        for (self.rules.items) |r| {
            if (std.mem.indexOfScalar(u8, r.pattern, '*')) |star| {
                const suffix = r.pattern[star + 1..];
                if (name.len < star + suffix.len or !std.mem.startsWith(u8, name, r.pattern[0..star]) or !std.mem.endsWith(u8, name, suffix)) continue;
                if (best != null and star <= best_prefix) continue;
                best = r; best_prefix = star; capture = name[star..name.len - suffix.len];
            } else if (std.mem.eql(u8, r.pattern, name)) { best = r; capture = ""; break; }
        }
        const rule = best orelse return null;
        const expanded = if (std.mem.indexOfScalar(u8, rule.target, '*')) |star|
            std.fmt.allocPrint(a, "{s}{s}{s}", .{rule.target[0..star], capture, rule.target[star + 1..]}) catch return null
        else a.dupe(u8, rule.target) catch return null;
        defer a.free(expanded);
        const path = normalize(expanded, a) orelse return null;
        defer a.free(path);
        if (!files.isAllowedPath(path)) return null;
        return std.fmt.allocPrint(a, "local:{s}", .{path}) catch null;
    }
};
