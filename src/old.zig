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

// In theory this could just be `window_len`, but being able to guarantee
// that it's always possible to write a full match at-once into the
// internal buffer (while keeping window_len bytes of history) simplifies
// the implementation.
pub const decompress_min_buffer_size = window_len + max_match_len;
pub const decompress_recommended_buffer_size = window_len * 2;

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        in: ReaderType,
        buffer: []u8,
        seek: usize,
        end: usize,

        const Self = @This();

        pub fn init(in: ReaderType, buffer: []u8) Self {
            std.debug.assert(buffer.len >= decompress_min_buffer_size);
            return .{
                .in = in,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            };
        }

        pub const Reader = std.io.Reader(*Self, Error, read);
        pub const Error = error{InvalidMatch} || ReaderType.Error;

        /// Returns the number of bytes read. It may be less than buffer.len.
        /// If the number of bytes read is 0, it means end of stream.
        /// End of stream is not an error condition.
        pub fn read(self: *Self, buffer: []u8) Error!usize {
            // The general idea here is:
            // - Fill the internal buffer while there is still space in the `read` buffer
            // - When there is not enough room in the internal buffer to write a full match,
            //   copy whatever's been internally buffered into the `read` buffer and rebase
            //   the internal buffer by moving up to `window_len` bytes to the beginning.
            // - If there's ever enough buffered bytes to satisfy the remaining bit of the
            //   `read` buffer (or in.readByte() returned EndOfStream), break out of the loop
            //
            // This means that at most one extra Encoded's worth of data will be read
            // into the internal buffer before returning.

            var num_read: usize = 0;
            while (num_read < buffer.len) {
                const dest = blk: {
                    const cur_slice = self.writableSlice();

                    const buffered = self.bufferedSlice();
                    const buffered_satifies_remaining = buffered.len >= buffer.len - num_read;
                    if (buffered_satifies_remaining) break;

                    if (cur_slice.len >= max_match_len) break :blk cur_slice;

                    // Make enough room to be able to write a full match.

                    // First, write out anything we have buffered
                    @memcpy(buffer[num_read..][0..buffered.len], buffered);
                    self.seek = self.end;
                    num_read += buffered.len;

                    // Then, rebase to free up as much room as possible
                    self.rebase();

                    break :blk self.writableSlice();
                };
                std.debug.assert(dest.len >= max_match_len);

                const byte = self.in.readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                const encoded: Encoded = @bitCast(byte);

                switch (encoded.is_back_reference) {
                    false => {
                        dest[0] = encoded.payload.char;
                        self.end += 1;
                    },
                    true => {
                        const match: Match = .fromEncoded(encoded.payload.back_reference);
                        if (self.end < match.distance) return error.InvalidMatch;

                        const end = dest.ptr - self.buffer.ptr;
                        const src = self.buffer[end - match.distance ..][0..match.length];
                        // This is not a @memmove; it intentionally repeats patterns caused by
                        // iterating one byte at a time.
                        for (dest[0..match.length], src) |*d, s| d.* = s;
                        self.end += match.length;
                    },
                }
            }

            // Write out anything that's still buffered if there's room in the `read` buffer.
            // This can occur when breaking from the loop.
            const buffered = self.bufferedSlice();
            if (num_read < buffer.len and buffered.len > 0) {
                const dest = buffer[num_read..];
                const available = @min(dest.len, buffered.len);
                @memcpy(dest[0..available], buffered[0..available]);
                self.seek += available;
                num_read += available;
            }

            return num_read;
        }

        fn rebase(self: *Self) void {
            const discard_n = @min(self.seek, self.end -| window_len);
            const keep = self.buffer[discard_n..self.end];
            std.mem.copyForwards(u8, self.buffer[0..keep.len], keep);
            self.end = keep.len;
            self.seek -= discard_n;
        }

        fn bufferedSlice(self: *Self) []u8 {
            return self.buffer[self.seek..self.end];
        }

        fn writableSlice(self: *Self) []u8 {
            return self.buffer[self.end..];
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn decompressor(reader: anytype, buffer: []u8) Decompressor(@TypeOf(reader)) {
    return Decompressor(@TypeOf(reader)).init(reader, buffer);
}

test decompressor {
    {
        var in = std.io.fixedBufferStream(test_data_compressed);

        var decompress_buf: [decompress_min_buffer_size]u8 = undefined;
        var d = decompressor(in.reader(), &decompress_buf);
        const out = try d.reader().readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
        defer std.testing.allocator.free(out);

        try std.testing.expectEqualSlices(u8, test_data_plain, out);
    }
    {
        var in = std.io.fixedBufferStream(test_data_compressed);

        var decompress_buf: [decompress_min_buffer_size]u8 = undefined;
        var d = decompressor(in.reader(), &decompress_buf);

        var out_buf: [test_data_plain.len]u8 = undefined;
        try d.reader().readNoEof(&out_buf);

        try std.testing.expectEqualSlices(u8, test_data_plain, &out_buf);
    }
    {
        var in = std.io.fixedBufferStream(test_data_long_compressed);

        var decompress_buf: [decompress_min_buffer_size]u8 = undefined;
        var d = decompressor(in.reader(), &decompress_buf);
        const out = try d.reader().readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
        defer std.testing.allocator.free(out);

        try std.testing.expectEqualSlices(u8, test_data_long_plain, out);
    }
    {
        var in = std.io.fixedBufferStream(test_data_long_compressed);

        var decompress_buf: [decompress_min_buffer_size]u8 = undefined;
        var d = decompressor(in.reader(), &decompress_buf);

        var out_buf: [test_data_long_plain.len]u8 = undefined;
        try d.reader().readNoEof(&out_buf);

        try std.testing.expectEqualSlices(u8, test_data_long_plain, &out_buf);
    }
}

test "decompress but read one byte at a time" {
    var in = std.io.fixedBufferStream(test_data_long_compressed);

    var decompress_buf: [decompress_min_buffer_size]u8 = undefined;
    var d = decompressor(in.reader(), &decompress_buf);
    const reader = d.reader();

    var i: usize = 0;
    while (true) : (i += 1) {
        const out = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try std.testing.expectEqual(test_data_long_plain[i], out);
    }

    try std.testing.expectEqual(test_data_long_plain.len, i);
}

pub const compress_min_buffer_size = window_len + max_match_len;
pub const compress_recommended_buffer_size = window_len * 2;

pub fn Compressor(comptime WriterType: type) type {
    return struct {
        out: WriterType,
        buffer: []u8,
        end: usize,
        window_end: usize,

        const Self = @This();

        pub fn init(out: WriterType, buffer: []u8) Self {
            std.debug.assert(buffer.len >= compress_min_buffer_size);
            return .{
                .out = out,
                .buffer = buffer,
                .end = 0,
                .window_end = 0,
            };
        }

        pub const Writer = std.io.Writer(*Self, Error, write);
        pub const Error = WriterType.Error;

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            var num_written: usize = 0;
            while (num_written != bytes.len) {
                if (self.end == self.buffer.len) {
                    self.rebase();
                }

                const remaining = bytes[num_written..];
                const available = self.buffer[self.end..];
                const fill_len = @min(remaining.len, available.len);

                @memcpy(available[0..fill_len], remaining[0..fill_len]);
                num_written += fill_len;
                self.end += fill_len;

                try self.processWithAtMostNRemaining(max_match_len - 1);
            }
            return num_written;
        }

        pub fn flush(self: *Self) Error!void {
            try self.processWithAtMostNRemaining(0);

            self.end = 0;
            self.window_end = 0;
        }

        fn processWithAtMostNRemaining(self: *Self, max_input_len_remaining: usize) Error!void {
            var input = self.buffer[self.window_end..self.end];
            while (input.len > max_input_len_remaining) {
                const window = self.buffer[self.window_end -| window_len..self.window_end];

                const slide_window = slide_window: {
                    if (common.findMatch(input[0..@min(input.len, max_match_len)], window)) |match| {
                        const encoded: Encoded = .backReference(match);
                        try self.out.writeByte(@bitCast(encoded));
                        break :slide_window match.length;
                    } else {
                        const encoded: Encoded = .char(@intCast(input[0]));
                        try self.out.writeByte(@bitCast(encoded));
                        break :slide_window 1;
                    }
                };

                self.window_end += slide_window;
                input = input[slide_window..];
            }
        }

        fn rebase(self: *Self) void {
            const discard_n = self.window_end -| window_len;
            const keep = self.buffer[discard_n..self.end];
            std.mem.copyForwards(u8, self.buffer[0..keep.len], keep);
            self.end = keep.len;
            self.window_end -= discard_n;
        }
    };
}

pub fn compressor(writer: anytype, buffer: []u8) Compressor(@TypeOf(writer)) {
    return Compressor(@TypeOf(writer)).init(writer, buffer);
}

test compressor {
    var compressed: std.ArrayList(u8) = .init(std.testing.allocator);
    defer compressed.deinit();

    var buf: [compress_min_buffer_size]u8 = undefined;
    var c = compressor(compressed.writer(), &buf);

    try c.writer().writeAll(test_data_plain);
    try c.flush();

    try std.testing.expectEqualSlices(u8, test_data_compressed, compressed.items);
}

test "long repetitive input" {
    var compressed: std.ArrayList(u8) = .init(std.testing.allocator);
    defer compressed.deinit();

    var buf: [compress_min_buffer_size]u8 = undefined;
    var c = compressor(compressed.writer(), &buf);

    try c.writer().writeAll(test_data_long_plain);
    try c.flush();

    try std.testing.expectEqualSlices(
        u8,
        test_data_long_compressed,
        compressed.items,
    );
}

test "compress but write one byte at a time" {
    var out_exact: [test_data_long_compressed.len]u8 = undefined;
    var out = std.io.fixedBufferStream(&out_exact);

    var buf: [compress_min_buffer_size]u8 = undefined;
    var c = compressor(out.writer(), &buf);

    for (test_data_long_plain) |byte| {
        try c.writer().writeByte(byte);
    }
    try c.flush();

    try std.testing.expectEqualSlices(
        u8,
        test_data_long_compressed,
        &out_exact,
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

        var compressed: std.ArrayList(u8) = .init(std.testing.allocator);
        defer compressed.deinit();

        var compress_buf: [compress_recommended_buffer_size]u8 = undefined;
        var compress = compressor(compressed.writer(), &compress_buf);

        try compress.writer().writeAll(original_uncompressed);
        try compress.flush();

        var compressed_in = std.io.fixedBufferStream(compressed.items);

        var decompress_buf: [decompress_recommended_buffer_size]u8 = undefined;
        var decompress = decompressor(compressed_in.reader(), &decompress_buf);

        const uncompressed = try decompress.reader().readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
        defer std.testing.allocator.free(uncompressed);

        try std.testing.expectEqualSlices(u8, original_uncompressed, uncompressed);
    }
}
