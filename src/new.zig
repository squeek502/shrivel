const std = @import("std");
const common = @import("common.zig");
const Encoded = common.Encoded;
const Match = common.Match;
const min_match_len = common.min_match_len;
const max_match_len = common.max_match_len;
const test_data_plain = common.test_data_plain;
const test_data_compressed = common.test_data_compressed;
const test_data_long_plain = common.test_data_long_plain;
const test_data_long_compressed = common.test_data_long_compressed;

pub const window_len = common.window_len;

pub const Decompress = struct {
    in: *std.Io.Reader,
    reader: std.Io.Reader,
    err: ?Error = null,
    remaining_partial_match: ?Match = null,

    pub const min_buffer_size = window_len + 1;
    pub const recommended_buffer_size = window_len * 2;

    pub const Error = error{
        InvalidMatch,
    };

    const direct_vtable: std.Io.Reader.VTable = .{
        .stream = streamDirect,
        .rebase = rebaseDirect,
        .discard = discardDirect,
        .readVec = readVecDirect,
    };
    const indirect_vtable: std.Io.Reader.VTable = .{
        .stream = streamIndirect,
        .rebase = rebaseIndirect,
        .discard = discardIndirect,
        .readVec = readVecIndirect,
    };

    pub fn init(in: *std.Io.Reader, buffer: []u8) Decompress {
        if (buffer.len != 0) std.debug.assert(buffer.len >= min_buffer_size);
        return .{ .in = in, .reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = if (buffer.len == 0) &direct_vtable else &indirect_vtable,
        } };
    }

    fn readVecIndirect(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        try streamIndirectInner(r);
        return 0;
    }

    fn discardIndirect(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        if (r.buffer.len == r.end) {
            rebaseIndirect(r, r.buffer.len - window_len) catch unreachable;
        }

        var writer: std.Io.Writer = .{
            .buffer = r.buffer,
            .end = r.end,
            .vtable = &.{
                .drain = std.Io.Writer.unreachableDrain,
                .rebase = std.Io.Writer.unreachableRebase,
            },
        };
        {
            defer r.end = writer.end;
            _ = streamDirect(r, &writer, .limited(r.buffer.len - r.end)) catch |err| switch (err) {
                error.WriteFailed => unreachable,
                else => |e| return e,
            };
        }
        const n = limit.minInt(r.end - r.seek);
        r.seek += n;
        return n;
    }

    fn rebaseIndirect(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
        // This is not actually possible to assert, as there's no safe guard in place.
        // https://github.com/ziglang/zig/issues/25103
        // We're supposed to be able to assert this, though.
        //std.debug.assert(capacity <= r.buffer.len - window_len);
        std.debug.assert(r.end + capacity > r.buffer.len);
        const discard_n = @min(r.seek, r.end - window_len);
        const keep = r.buffer[discard_n..r.end];
        @memmove(r.buffer[0..keep.len], keep);
        r.end = keep.len;
        r.seek -= discard_n;
    }

    fn dump(r: *std.Io.Reader) void {
        dumpFallible(r) catch return;
    }

    fn dumpFallible(r: *std.Io.Reader) !void {
        var buf: [64]u8 = undefined;
        const stderr_file = std.fs.File.stderr();
        var stderr = stderr_file.writer(&buf);
        const tty_config: std.Io.tty.Config = .detect(stderr_file);
        try tty_config.setColor(&stderr.interface, .cyan);
        try tty_config.setColor(&stderr.interface, .dim);
        try stderr.interface.writeAll(r.buffer[0..r.seek]);
        try tty_config.setColor(&stderr.interface, .reset);
        try tty_config.setColor(&stderr.interface, .bright_green);
        try stderr.interface.writeAll(r.buffer[r.seek..r.end]);
        try tty_config.setColor(&stderr.interface, .reset);
        try tty_config.setColor(&stderr.interface, .white);
        try tty_config.setColor(&stderr.interface, .dim);
        try stderr.interface.splatBytesAll("\u{2423}", r.buffer.len - r.end);
        try tty_config.setColor(&stderr.interface, .reset);
        try stderr.interface.print(" seek: {} end: {}\n", .{ r.seek, r.end });
        try stderr.interface.flush();
    }

    fn streamIndirect(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        // It might be safe to ignore limit here, since we're just filling the
        // internal buffer and not actually writing to `w`
        // TODO: Need to confirm that's true though
        _ = limit;

        try streamIndirectInner(r);

        return 0;
    }

    /// Only writes into the reader's buffer, so does not return the number of bytes written
    fn streamIndirectInner(r: *std.Io.Reader) std.Io.Reader.Error!void {
        // If there's no room in the buffer, then we need to make room, otherwise
        // there'd be an infinite loop since this implementation relies on being
        // able to write into r.buffer and leave w.buffer untouched.
        //
        // TODO: It might be more efficient to make this condition
        // `r.buffer.len - r.end < window_len` so that we ensure that we always write
        // at least `r.buffer.len - window_len` bytes into the buffer each `stream` call.
        if (r.buffer.len == r.end) {
            rebaseIndirect(r, r.buffer.len - window_len) catch unreachable;
        }

        var writer: std.Io.Writer = .{
            .buffer = r.buffer,
            .end = r.end,
            .vtable = &.{
                .drain = std.Io.Writer.unreachableDrain,
                .rebase = std.Io.Writer.unreachableRebase,
            },
        };
        defer r.end = writer.end;
        // see note/TODO in `streamIndirect`
        //const effective_limit = limit.min(.limited(r.buffer.len - r.end));
        _ = streamDirect(r, &writer, .limited(r.buffer.len - r.end)) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
    }

    fn readVecDirect(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = r;
        _ = data;
        @panic("cannot read into data since a non-zero amount of the output needs to be stored for future reference");
    }

    fn discardDirect(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        _ = r;
        _ = limit;
        @panic("cannot discard since the dicarded output needs to be stored but there's no buffer to store it in");
    }

    fn rebaseDirect(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
        _ = r;
        _ = capacity;
        @panic("nothing to rebase since buffer is length 0");
    }

    fn streamDirect(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const d: *Decompress = @fieldParentPtr("reader", r);

        var remaining = @intFromEnum(limit);
        while (remaining > 0) {
            if (d.remaining_partial_match) |*remaining_partial_match| {
                const written_len = writeMatch(w, remaining_partial_match.*, remaining) catch |err| switch (err) {
                    error.InvalidMatch => unreachable,
                    else => |e| return e,
                };
                remaining -= written_len;
                remaining_partial_match.length -= written_len;
                if (remaining_partial_match.length == 0) {
                    d.remaining_partial_match = null;
                }
                continue;
            }

            const encoded: Encoded = @bitCast(d.in.takeByte() catch |err| switch (err) {
                error.EndOfStream => |e| if (@intFromEnum(limit) == remaining)
                    return e
                else
                    break,
                error.ReadFailed => |e| return e,
            });
            switch (encoded.is_back_reference) {
                false => {
                    try w.writeBytePreserve(window_len, encoded.payload.char);
                    remaining -= 1;
                },
                true => {
                    const match: Match = .fromEncoded(encoded.payload.back_reference);
                    const written_len = writeMatch(w, match, remaining) catch |err| switch (err) {
                        error.WriteFailed => |e| return e,
                        error.InvalidMatch => |e| {
                            d.err = e;
                            return error.ReadFailed;
                        },
                    };
                    remaining -= written_len;
                    if (written_len < match.length) {
                        d.remaining_partial_match = .{
                            .distance = match.distance,
                            .length = match.length - written_len,
                        };
                    }
                },
            }
        }

        return @intFromEnum(limit) - remaining;
    }

    fn writeMatch(w: *std.Io.Writer, match: Match, limit: usize) !u3 {
        const distance = match.distance;
        const length = @min(limit, match.length);

        if (w.end < distance) return error.InvalidMatch;

        const dest = try w.writableSlicePreserve(window_len, length);
        const end = dest.ptr - w.buffer.ptr;
        const src = w.buffer[end - distance ..][0..length];
        // This is not a @memmove; it intentionally repeats patterns caused by
        // iterating one byte at a time.
        for (dest, src) |*d, s| d.* = s;
        return @intCast(length);
    }
};

test Decompress {
    var in: std.Io.Reader = .fixed(test_data_compressed);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var decompress: Decompress = .init(&in, &.{});
    const decompressed_len = try decompress.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqual(test_data_plain.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, test_data_plain, aw.written());
}

test "Decompress indirect" {
    var in: std.Io.Reader = .fixed(test_data_long_compressed);
    var out_buf_exact: [test_data_long_plain.len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf_exact);

    var decompress_buf: [Decompress.recommended_buffer_size]u8 = undefined;
    var decompress: Decompress = .init(&in, &decompress_buf);
    const decompressed_len = try decompress.reader.streamRemaining(&out);

    try std.testing.expectEqualSlices(u8, test_data_long_plain, out.buffer);
    try std.testing.expectEqual(test_data_long_plain.len, decompressed_len);
}

test "Decompress with limit of 1 byte" {
    var in: std.Io.Reader = .fixed(test_data_compressed);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var decompress: Decompress = .init(&in, &.{});
    while (true) {
        decompress.reader.streamExact(&aw.writer, 1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
    try std.testing.expectEqualSlices(u8, test_data_plain, aw.written());
}

test "Decompress discard" {
    const expected_plain_with_discard = "abcDEF";
    const expected_plain = "abcDEFDEF";
    const compressed = "abcDEF" ++ &[_]u8{
        @bitCast(Encoded.backReference(.{ .distance = 3, .length = 3 })),
    };

    var decompress_buf: [Decompress.min_buffer_size]u8 = undefined;

    // Double check that the compressed data results in what we expect when decompressed
    {
        var in: std.Io.Reader = .fixed(compressed);
        var out_buf_exact: [expected_plain.len]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf_exact);

        var decompress: Decompress = .init(&in, &decompress_buf);
        const len = try decompress.reader.streamRemaining(&out);

        try std.testing.expectEqualSlices(u8, expected_plain, out.buffer[0..len]);
    }

    // Check that discarding still allows back references to resolve correctly
    {
        var in: std.Io.Reader = .fixed(compressed);
        var out_buf_exact: [expected_plain_with_discard.len]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf_exact);

        var decompress: Decompress = .init(&in, &decompress_buf);
        try decompress.reader.streamExact(&out, 3);
        try decompress.reader.discardAll(3);
        try decompress.reader.streamExact(&out, 3);

        try std.testing.expectEqualSlices(u8, expected_plain_with_discard, out_buf_exact[0..]);
    }
}

test "Decompress discard from full buffer" {
    var in: std.Io.Reader = .fixed(test_data_long_compressed);

    var decompress_buf: [Decompress.min_buffer_size]u8 = undefined;
    var decompress: Decompress = .init(&in, &decompress_buf);
    try decompress.reader.fillMore();
    _ = try decompress.reader.discardRemaining();
}

test "Decompress readSliceShort" {
    var decompress_buf: [Decompress.min_buffer_size]u8 = undefined;
    var slice_buf: [3]u8 = undefined;

    var in: std.Io.Reader = .fixed(test_data_compressed);
    var out_buf_exact: [test_data_plain.len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf_exact);

    var decompress: Decompress = .init(&in, &decompress_buf);
    while (true) {
        const n = try decompress.reader.readSliceShort(&slice_buf);
        if (n == 0) break;
        try out.writeAll(slice_buf[0..n]);
    }

    try std.testing.expectEqualSlices(u8, test_data_plain, out_buf_exact[0..]);
}

test "Decompress readVecAll" {
    var decompress_buf: [Decompress.min_buffer_size]u8 = undefined;

    var in: std.Io.Reader = .fixed(test_data_compressed);
    var out_buf_exact: [test_data_plain.len]u8 = undefined;

    var decompress: Decompress = .init(&in, &decompress_buf);
    var out_vec = [_][]u8{&out_buf_exact};
    try decompress.reader.readVecAll(&out_vec);

    try std.testing.expectEqualSlices(u8, test_data_plain, out_buf_exact[0..]);
}

pub const Compress = struct {
    out: *std.Io.Writer,
    // TODO: Maybe delete this field. The start can be calculated on-demand with `window_end -| window_len`
    window_start: usize,
    window_end: usize,
    writer: std.Io.Writer,

    pub const min_buffer_size = window_len + max_match_len;
    pub const recommended_buffer_size = window_len * 2;

    pub fn init(out: *std.Io.Writer, buffer: []u8) Compress {
        std.debug.assert(buffer.len >= min_buffer_size);
        return .{
            .out = out,
            .window_start = 0,
            .window_end = 0,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
            },
        };
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const c: *Compress = @fieldParentPtr("writer", w);

        // Process input
        try processWithAtMostNRemaining(c, 0);

        w.end = 0;
        c.window_start = 0;
        c.window_end = 0;
    }

    /// Moves window, but does not modify buffer contents or buffer end
    fn processWithAtMostNRemaining(c: *Compress, max_input_len_remaining: usize) std.Io.Writer.Error!void {
        const w = &c.writer;

        var input = w.buffer[c.window_end..w.end];
        while (input.len > max_input_len_remaining) {
            const window = w.buffer[c.window_start..c.window_end];

            const slide_window = slide_window: {
                if (findMatch(input[0..@min(input.len, max_match_len)], window)) |match| {
                    const encoded: Encoded = .backReference(match);
                    try c.out.writeByte(@bitCast(encoded));
                    break :slide_window match.length;
                } else {
                    const encoded: Encoded = .char(@intCast(input[0]));
                    try c.out.writeByte(@bitCast(encoded));
                    break :slide_window 1;
                }
            };

            c.window_end += slide_window;
            c.window_start = c.window_end -| window_len;
            input = input[slide_window..];
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *Compress = @fieldParentPtr("writer", w);

        // Process input
        try processWithAtMostNRemaining(c, max_match_len - 1);

        // Move window and any input that we don't have enough data to process yet to the start
        {
            const len = w.end - c.window_start;
            const window_size = c.window_end - c.window_start;
            @memmove(w.buffer[0..len], w.buffer[c.window_start..w.end]);
            w.end = len;
            c.window_start = 0;
            c.window_end = window_size;
        }

        // Refill buffer using data
        {
            const end_before_fill = w.end;
            for (data[0 .. data.len - 1]) |bytes| {
                const dest = w.buffer[w.end..];
                const len = @min(bytes.len, dest.len);
                @memcpy(dest[0..len], bytes[0..len]);
                w.end += len;
            }
            const pattern = data[data.len - 1];
            switch (pattern.len) {
                0 => {},
                1 => {
                    @memset(w.buffer[w.end..][0..splat], pattern[0]);
                    w.end += splat;
                },
                else => {
                    const dest = w.buffer[w.end..];
                    for (0..splat) |i| {
                        const remaining = dest[i * pattern.len ..];
                        const len = @min(pattern.len, remaining.len);
                        @memcpy(remaining[0..len], pattern[0..len]);
                        w.end += len;
                    }
                },
            }

            return w.end - end_before_fill;
        }
    }

    fn findMatch(input: []const u8, window: []const u8) ?Match {
        std.debug.assert(input.len <= max_match_len);

        if (window.len == 0) return null;

        var match_len: u3 = @intCast(input.len);
        var longest_match: ?Match = null;
        while (match_len > 0) : (match_len -= 1) {
            const match = findLongestMatchForLen(match_len, input, window) orelse continue;
            if (longest_match == null or match.length > longest_match.?.length) {
                longest_match = match;
                if (match.length == max_match_len) break;
            }
        }
        return longest_match;
    }

    fn findLongestMatchForLen(match_len: u3, input: []const u8, window: []const u8) ?Match {
        std.debug.assert(match_len > 0);
        const potential_match = input[0..match_len];
        const match_index = std.mem.lastIndexOf(u8, window, potential_match) orelse return null;

        var full_len = match_len;
        // If the match is at the very end of the window, then it's possible to take advantage of that
        // and extend the length further.
        if (match_index + full_len == window.len) {
            while (@as(u8, full_len) + match_len <= max_match_len) {
                const remaining_input = input[full_len..];
                if (!std.mem.startsWith(u8, remaining_input, potential_match)) break;
                full_len += match_len;
            }
        }
        if (full_len < min_match_len) return null;

        return .{
            .distance = @intCast(window.len - match_index),
            .length = full_len,
        };
    }
};

test Compress {
    var compressed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compressed.deinit();

    var buf: [Compress.recommended_buffer_size]u8 = undefined;
    var compress: Compress = .init(&compressed.writer, &buf);

    var in: std.Io.Reader = .fixed(test_data_plain);

    _ = try in.streamRemaining(&compress.writer);
    try compress.writer.flush();

    try std.testing.expectEqualSlices(u8, test_data_compressed, compressed.written());
}

test "long repetitive input" {
    var compressed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compressed.deinit();

    var buf: [Compress.recommended_buffer_size]u8 = undefined;
    var compress: Compress = .init(&compressed.writer, &buf);

    const input = test_data_long_plain;
    var in: std.Io.Reader = .fixed(input);

    _ = try in.streamRemaining(&compress.writer);
    try compress.writer.flush();

    try std.testing.expectEqualSlices(
        u8,
        test_data_long_compressed,
        compressed.written(),
    );
}

test "round trip" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();

    var chunk_buf: [64]u8 = undefined;
    for (chunk_buf[0..]) |*c| {
        const printable_range = '~' - ' ';
        c.* = rand.uintAtMost(u8, printable_range) + ' ';
    }

    var buf: [1024]u8 = undefined;
    for (0..100) |_| {
        const len = rand.uintLessThan(usize, buf.len);
        {
            // Fill with random chunks of chunk_buf to make it much more likely to
            // get repeated patterns in the uncompressed data.
            var i: usize = 0;
            while (i < len) {
                const chunk_len = @min(len - i, rand.uintLessThan(usize, 5) + 1);
                const chunk_start = rand.uintLessThan(usize, chunk_buf.len - chunk_len);
                const chunk = chunk_buf[chunk_start..][0..chunk_len];
                @memcpy(buf[i..][0..chunk_len], chunk);
                i += chunk_len;
            }
        }

        const original_uncompressed = buf[0..len];
        var in: std.Io.Reader = .fixed(original_uncompressed);

        var compressed: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer compressed.deinit();

        var compress_buf: [Compress.recommended_buffer_size]u8 = undefined;
        var compress: Compress = .init(&compressed.writer, &compress_buf);

        _ = try in.streamRemaining(&compress.writer);
        try compress.writer.flush();

        var compressed_in: std.Io.Reader = .fixed(compressed.written());

        var uncompressed: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer uncompressed.deinit();

        var decompress: Decompress = .init(&compressed_in, &.{});
        const decompressed_len = try decompress.reader.streamRemaining(&uncompressed.writer);

        try std.testing.expectEqualSlices(u8, original_uncompressed, uncompressed.written());
        try std.testing.expectEqual(len, decompressed_len);
    }
}
