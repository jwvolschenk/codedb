const std = @import("std");
const ContentCache = @import("../hot_cache.zig").ContentCache;

pub const MAX_NGRAM_LEN: usize = 16;

/// Comptime character-pair frequency table for source code.
/// Common pairs → LOW weight (they stay interior to n-grams).
/// Rare pairs   → HIGH weight (they become n-gram boundaries).
/// All unspecified pairs default to 0xFE00 (rare = high weight).
pub const default_pair_freq: [256][256]u16 = blk: {
    var table: [256][256]u16 = .{.{0xFE00} ** 256} ** 256;
    // English bigrams (lowercase) — common in identifiers and prose
    table['t']['h'] = 0x1000;
    table['h']['e'] = 0x1000;
    table['i']['n'] = 0x1000;
    table['e']['r'] = 0x1000;
    table['a']['n'] = 0x1000;
    table['r']['e'] = 0x1000;
    table['o']['n'] = 0x1000;
    table['e']['n'] = 0x1000;
    table['s']['t'] = 0x1000;
    table['e']['s'] = 0x1000;
    table['a']['t'] = 0x1000;
    table['i']['o'] = 0x1000;
    table['t']['e'] = 0x1000;
    table['o']['r'] = 0x1000;
    table['t']['i'] = 0x1000;
    table['a']['r'] = 0x1000;
    table['a']['l'] = 0x1000;
    table['l']['e'] = 0x1000;
    table['n']['t'] = 0x1000;
    table['e']['d'] = 0x1000;
    table['n']['d'] = 0x1000;
    table['o']['u'] = 0x1000;
    table['e']['a'] = 0x1000;
    table['f']['o'] = 0x1000;
    // Common code keyword fragments
    table['f']['n'] = 0x1000;
    table['i']['f'] = 0x1000;
    table['r']['n'] = 0x1000;
    table['t']['u'] = 0x1000;
    table['p']['u'] = 0x1000;
    table['b']['l'] = 0x1000;
    table['c']['o'] = 0x1000;
    table['n']['s'] = 0x1000;
    table['t']['r'] = 0x1000;
    table['u']['e'] = 0x1000;
    // Common operator / punctuation pairs
    table['('][')'] = 0x0800;
    table['{']['}'] = 0x0800;
    table['['][']'] = 0x0800;
    table['/']['/'] = 0x0800;
    table['-']['>'] = 0x0800;
    table['=']['>'] = 0x0800;
    table[':'][':'] = 0x0800;
    table['!']['='] = 0x0800;
    table['=']['='] = 0x0800;
    table['<']['='] = 0x0800;
    table['>']['='] = 0x0800;
    table['&']['&'] = 0x0800;
    table['|']['|'] = 0x0800;
    // Whitespace / structural pairs
    table[' '][' '] = 0x0800;
    table['\t'][' '] = 0x0800;
    table[' ']['('] = 0x0800;
    table[' ']['{'] = 0x0800;
    table[';'][' '] = 0x0800;
    table[':'][' '] = 0x0800;
    table['='][' '] = 0x0800;
    table[' ']['='] = 0x0800;
    table[','][' '] = 0x0800;
    table['.']['.'] = 0x0800;
    table['\n'][' '] = 0x0800;
    table['\n']['\t'] = 0x0800;
    break :blk table;
};

/// Active frequency table — points to the comptime default or a runtime
/// per-project table.  Swap only before indexing starts (not thread-safe).
pub var active_pair_freq: *const [256][256]u16 = &default_pair_freq;
var loaded_freq_table: [256][256]u16 = undefined;

/// Deterministic weight for a character pair, used to place content-defined
/// boundaries between n-grams.  Frequency-weighted: common source-code pairs
/// get LOW weight (they stay interior to n-grams); rare pairs get HIGH weight
/// (they become boundaries).  A small hash jitter (0-255) breaks ties
/// deterministically between pairs in the same frequency tier.
pub fn pairWeight(a: u8, b: u8) u16 {
    const freq_weight = active_pair_freq[a][b];
    const pair = [2]u8{ a, b };
    const jitter: u16 = @truncate(std.hash.Wyhash.hash(0, &pair) & 0xFF);
    return freq_weight +| jitter;
}

/// Swap in a custom frequency table.  Call before indexing; not thread-safe.
pub fn setFrequencyTable(table: *const [256][256]u16) void {
    loaded_freq_table = table.*;
    active_pair_freq = &loaded_freq_table;
}

/// Revert to the built-in comptime frequency table.
pub fn resetFrequencyTable() void {
    active_pair_freq = &default_pair_freq;
}

/// Build a per-project frequency table by counting byte-pair occurrences in
/// `content`, then inverting counts to weights (common → low, rare → high).
pub fn buildFrequencyTable(content: []const u8) [256][256]u16 {
    var counts: [256][256]u64 = .{.{0} ** 256} ** 256;
    if (content.len >= 2) {
        for (0..content.len - 1) |i| {
            counts[content[i]][content[i + 1]] += 1;
        }
    }
    return finishFrequencyTable(&counts);
}

/// Build a frequency table by streaming over multiple content slices.
/// Zero extra memory — counts pairs within each slice, skipping cross-slice
/// boundaries (negligible loss for large corpora).
pub fn buildFrequencyTableFromSlices(slices: []const []const u8) [256][256]u16 {
    var counts: [256][256]u64 = .{.{0} ** 256} ** 256;
    for (slices) |content| {
        if (content.len < 2) continue;
        for (0..content.len - 1) |i| {
            counts[content[i]][content[i + 1]] += 1;
        }
    }
    return finishFrequencyTable(&counts);
}

/// Build a frequency table by streaming over a StringHashMap of content.
/// Iterates file-by-file — no concatenation, zero extra memory.
pub fn buildFrequencyTableFromMap(contents: *ContentCache) [256][256]u16 {
    var counts: [256][256]u64 = .{.{0} ** 256} ** 256;
    var iter = contents.iterator();
    while (iter.next()) |entry| {
        const content = entry.value_ptr.*;
        if (content.len < 2) continue;
        for (0..content.len - 1) |i| {
            counts[content[i]][content[i + 1]] += 1;
        }
    }
    return finishFrequencyTable(&counts);
}

fn finishFrequencyTable(counts: *const [256][256]u64) [256][256]u16 {
    var max_count: u64 = 1;
    for (counts) |row| {
        for (row) |c| {
            if (c > max_count) max_count = c;
        }
    }
    // Invert: count 0 → 0xFE00 (rare, high); max_count → 0x1000 (common, low).
    var table: [256][256]u16 = .{.{0xFE00} ** 256} ** 256;
    for (0..256) |a| {
        for (0..256) |b| {
            const c = counts[a][b];
            if (c == 0) continue;
            const span: u64 = 0xFE00 - 0x1000;
            const w: u64 = 0xFE00 - (c * span / max_count);
            table[a][b] = @intCast(@min(w, 0xFE00));
        }
    }
    return table;
}

/// Persist a frequency table as a raw binary blob to `<dir_path>/pair_freq.bin`.
/// Uses tmp+rename for atomic writes.
pub fn writeFrequencyTable(io: std.Io, table: *const [256][256]u16, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    {
        const tmp = try dir.createFile(io, "pair_freq.bin.tmp", .{});
        defer tmp.close(io);
        var tw_buf: [64 * 1024]u8 = undefined;
        var tw = tmp.writer(io, &tw_buf);
        var row_buf: [256 * 2]u8 = undefined;
        for (table) |row| {
            for (row, 0..) |val, j| {
                std.mem.writeInt(u16, row_buf[j * 2 ..][0..2], val, .little);
            }
            try tw.interface.writeAll(&row_buf);
        }
        try tw.interface.flush();
    }
    try dir.rename("pair_freq.bin.tmp", dir, "pair_freq.bin", io);
}

/// Load a frequency table from `<dir_path>/pair_freq.bin`.
/// Returns null if the file does not exist or has the wrong size.
/// Caller owns the returned allocation.
pub fn readFrequencyTable(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?*[256][256]u16 {
    const path = try std.fmt.allocPrint(allocator, "{s}/pair_freq.bin", .{dir_path});
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const expected_size = 256 * 256 * @sizeOf(u16);
    const size = try file.length(io);
    if (size != expected_size) return null;
    const result = try allocator.create([256][256]u16);
    errdefer allocator.destroy(result);
    var read_pos: u64 = 0;
    var row_buf: [256 * 2]u8 = undefined;
    for (result) |*row| {
        const n = try file.readPositionalAll(io, &row_buf, read_pos);
        if (n != row_buf.len) {
            allocator.destroy(result);
            return null;
        }
        read_pos += row_buf.len;
        for (row, 0..) |*val, j| {
            val.* = std.mem.readInt(u16, row_buf[j * 2 ..][0..2], .little);
        }
    }
    return result;
}
