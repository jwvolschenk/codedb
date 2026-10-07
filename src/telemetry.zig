const std = @import("std");
const cio = @import("cio.zig");
const builtin = @import("builtin");
const explore = @import("explore.zig");
const index = @import("index.zig");

const RING_SIZE = 256;
// This fork has no inherited analytics destination. Upload needs an explicit URL.
const VERSION = @import("release_info.zig").semver;
const PLATFORM = std.fmt.comptimePrint("{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });

pub const Event = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        tool_call: struct {
            tool: [32]u8 = .{0} ** 32,
            tool_len: u8 = 0,
            latency_ns: i128,
            err: bool,
            response_bytes: u32,
        },
        session_start: void,
        codebase_stats: struct {
            file_count: u32,
            total_lines: u64,
            language_mask: u32,
            index_size_bytes: u64,
            startup_time_ms: u64,
        },
    };
};

pub const Telemetry = struct {
    ring: [RING_SIZE]Event = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    write_offset: u64 = 0,
    enabled: bool = false,
    upload_url: ?[]const u8 = null,
    buf: [4096]u8 = undefined,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    call_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    write_lock: cio.Mutex = .{},

    pub fn init(io: std.Io, data_dir: []const u8, allocator: std.mem.Allocator, disabled: bool) Telemetry {
        var self = Telemetry{};
        self.io = io;

        // Telemetry is OPT-IN: only enabled when CODEDB_TELEMETRY=1 is set
        if (!telemetryEnabled(disabled, cio.posixGetenv("CODEDB_TELEMETRY"), cio.posixGetenv("CODEDB_NO_TELEMETRY"))) {
            self.enabled = false;
            return self;
        }

        self.enabled = true;
        self.upload_url = cio.posixGetenv("CODEDB_TELEMETRY_URL");
        const path = std.fmt.allocPrint(allocator, "{s}/telemetry-{x}.ndjson", .{data_dir, cio.randU64()}) catch return self;
        defer allocator.free(path);
        if (path.len <= self.path_buf.len) {
            @memcpy(self.path_buf[0..path.len], path);
            self.path_len = path.len;
        }
        self.file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch return self;
        if (self.file) |f| {
            self.write_offset = f.length(io) catch 0;
        }
        return self;
    }

    pub fn deinit(self: *Telemetry) void {
        if (self.enabled) self.flush();
        if (self.file) |f| f.close(self.io);
        self.file = null;
        if (self.enabled) self.syncToCloud();
    }

    pub fn record(self: *Telemetry, kind: Event.Kind) void {
        if (!self.enabled) return;

        self.write_lock.lock();
        const next = self.head.fetchAdd(1, .monotonic);
        const slot = next % RING_SIZE;
        self.ring[slot] = .{
            .kind = kind,
        };
        const tail = self.tail.load(.monotonic);
        if ((next + 1) -% tail > RING_SIZE) {
            self.tail.store((next + 1) -% RING_SIZE, .monotonic);
        }
        self.write_lock.unlock();

        const count = self.call_count.fetchAdd(1, .monotonic) + 1;
        if (count % 3 == 0) {
            self.flush();
        }

    }

    pub fn recordSessionStart(self: *Telemetry) void {
        self.record(.{ .session_start = {} });
    }

    pub fn recordToolCall(self: *Telemetry, tool_name: []const u8, latency_ns: i128, is_error: bool, response_bytes: usize) void {
        if (!self.enabled) return;
        var tc: Event.Kind = .{ .tool_call = .{
            .latency_ns = latency_ns,
            .err = is_error,
            .response_bytes = @intCast(@min(response_bytes, std.math.maxInt(u32))),
        } };
        var len: u8 = @intCast(@min(tool_name.len, 32));
        while (len > 0 and !std.unicode.utf8ValidateSlice(tool_name[0..len])) : (len -= 1) {}
        @memcpy(tc.tool_call.tool[0..len], tool_name[0..len]);
        tc.tool_call.tool_len = len;
        self.record(tc);
    }

    pub fn recordCodebaseStats(self: *Telemetry, explorer: *explore.Explorer, startup_time_ms: u64) void {
        if (!self.enabled) return;

        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var file_count: u32 = 0;
        var total_lines: u64 = 0;
        var language_mask: u32 = 0;

        var outline_iter = explorer.outlines.iterator();
        while (outline_iter.next()) |entry| {
            file_count +|= 1;
            total_lines +|= entry.value_ptr.line_count;
            const lang_enum = @intFromEnum(entry.value_ptr.language);
            if (lang_enum < 32) {
                const bit_index: u5 = @intCast(lang_enum);
                language_mask |= @as(u32, 1) << bit_index;
            }
        }

        self.record(.{ .codebase_stats = .{
            .file_count = file_count,
            .total_lines = total_lines,
            .language_mask = language_mask,
            .index_size_bytes = approxIndexSizeBytes(explorer),
            .startup_time_ms = startup_time_ms,
        } });
    }

    pub fn flush(self: *Telemetry) void {
        const f = self.file orelse return;

        self.write_lock.lock();
        defer self.write_lock.unlock();

        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.monotonic);
        if (tail == head) return;

        var i = tail;
        while (i != head) : (i +%= 1) {
            const ev = self.ring[i % RING_SIZE];
            const len = self.formatEvent(&ev) catch continue;
            f.writePositionalAll(self.io, self.buf[0..len], self.write_offset) catch {
                self.tail.store(i, .monotonic);
                return;
            };
            self.write_offset += len;
        }
        self.tail.store(head, .monotonic);
    }

    fn syncToCloud(self: *Telemetry) void {
        if (!self.enabled or self.path_len == 0) return;
        const url = self.upload_url orelse return;
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://127.0.0.1:") and !std.mem.startsWith(u8, url, "http://localhost:")) return;
        self.write_lock.lock();
        defer self.write_lock.unlock();
        const path = self.path_buf[0..self.path_len];

        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
        if (stat.size == 0) return;

        // Use argv-based exec (no shell interpolation) to avoid injection
        var data_arg_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{path}) catch return;

        const result = cio.runCapture(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "curl", "-sf", "-X", "POST", url, "-H", "Content-Type: application/x-ndjson", "--data-binary", data_arg, "--max-time", "5" },
            .max_output_bytes = 4096,
        }) catch return;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);

        switch (result.term) { .Exited => |code| if (code != 0) return, else => return, }

        // Truncate the file only after a successful HTTP/process response.
        if (std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true })) |f| {
            f.close(self.io);
            self.write_offset = 0;
        } else |_| {}
    }

    pub fn syncWalToCloud(self: *Telemetry, wal_path: ?[]const u8) void {
        _ = wal_path;
        self.flush(); // Never block a query on network I/O.
    }

    fn formatEvent(self: *Telemetry, ev: *const Event) !usize {
        var stream = std.Io.Writer.fixed(&self.buf);
        const w = &stream;
        try w.print("{{\"timestamp_ms\":{d}", .{cio.milliTimestamp()});
        switch (ev.kind) {
            .tool_call => |tc| {
                const name = tc.tool[0..tc.tool_len];
                try w.writeAll(",\"event_type\":\"tool_call\",\"tool\":");
                try std.json.Stringify.value(name, .{}, w);
                try w.print(",\"latency_ns\":{d},\"error\":{s},\"response_bytes\":{d}", .{
                    @as(i64, @intCast(@min(tc.latency_ns, std.math.maxInt(i64)))),
                    if (tc.err) "true" else "false",
                    tc.response_bytes,
                });
            },
            .session_start => {
                try w.print(",\"event_type\":\"session_start\",\"version\":\"{s}\",\"platform\":\"{s}\"", .{ VERSION, PLATFORM });
            },
            .codebase_stats => |stats| {
                try w.print(",\"event_type\":\"codebase_stats\",\"file_count\":{d},\"total_lines\":{d},\"languages\":[", .{
                    stats.file_count,
                    stats.total_lines,
                });
                try writeLanguages(w, stats.language_mask);
                try w.print("],\"index_size_bytes\":{d},\"startup_time_ms\":{d}", .{
                    stats.index_size_bytes,
                    stats.startup_time_ms,
                });
            },
        }
        try w.writeAll("}\n");
        return w.end;
    }
};

fn writeLanguages(writer: anytype, language_mask: u32) !void {
    const names = [_][]const u8{
        "zig",
        "c",
        "cpp",
        "python",
        "javascript",
        "typescript",
        "rust",
        "go_lang",
        "php",
        "ruby",
        "hcl",
        "r",
        "markdown",
        "json",
        "yaml",
        "unknown",
        "dart",
        "java",
        "kotlin",
        "svelte",
        "vue",
        "astro",
        "shell",
        "css",
        "scss",
        "sql",
        "protobuf",
        "fortran",
        "llvm_ir",
        "mlir",
        "tablegen",
        "c_sharp",
        "f_sharp",
        "razor",
        "autumn_adm",
        "autumn_acfg",
        "autumn_adpt",
        "autumn_arc",
        "t4_template",
    };
    var first = true;
    for (names[0..32], 0..) |name, idx| {
        const bit_index: u5 = @intCast(idx);
        if ((language_mask & (@as(u32, 1) << bit_index)) == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\"", .{name});
    }
}

pub fn approxIndexSizeBytes(explorer: *const explore.Explorer) u64 {
    var total: u64 = 0;

    var word_iter = explorer.word_index.index.iterator();
    while (word_iter.next()) |entry| {
        total +|= entry.key_ptr.*.len;
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    var file_words_iter = explorer.word_index.file_words.iterator();
    while (file_words_iter.next()) |entry| {
        total +|= entry.value_ptr.len * @sizeOf(usize);
    }

    switch (explorer.trigram_index) {
        .heap => |heap| {
            var trigram_iter = heap.index.iterator();
            while (trigram_iter.next()) |entry| {
                total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
                total +|= entry.value_ptr.count() * (@sizeOf(usize) + @sizeOf(index.PostingMask));
            }
            var file_trigrams_iter = heap.file_trigrams.iterator();
            while (file_trigrams_iter.next()) |entry| {
                total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
            }
        },
        .mmap, .mmap_overlay => {},
    }

    var sparse_iter = explorer.sparse_ngram_index.index.iterator();
    while (sparse_iter.next()) |entry| {
        total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
        total +|= entry.value_ptr.count() * @sizeOf(usize);
    }

    var file_sparse_iter = explorer.sparse_ngram_index.file_ngrams.iterator();
    while (file_sparse_iter.next()) |entry| {
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    return total;
}

fn truthy(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

pub fn telemetryEnabled(disabled: bool, opt_in: ?[]const u8, opt_out: ?[]const u8) bool {
    return !disabled and !truthy(opt_out) and truthy(opt_in);
}

test "telemetry requires explicit true and disable has precedence" {
    const t = std.testing;
    try t.expect(!telemetryEnabled(false, null, null));
    try t.expect(!telemetryEnabled(false, "0", null));
    try t.expect(!telemetryEnabled(false, "false", null));
    try t.expect(telemetryEnabled(false, "true", null));
    try t.expect(!telemetryEnabled(false, "1", "1"));
    try t.expect(!telemetryEnabled(true, "1", null));
}
