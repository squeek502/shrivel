const std = @import("std");
const shrivel = @import("shrivel");

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.fs.File.stdin();
    const data = blk: {
        var stdin_reader = stdin.readerStreaming(&.{});
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        _ = try stdin_reader.interface.streamRemaining(&out.writer);
        break :blk try out.toOwnedSlice();
    };
    defer allocator.free(data);

    const ascii_data = try allocator.alloc(u8, data.len);
    defer allocator.free(ascii_data);

    for (ascii_data, data) |*c, byte| {
        c.* = @as(u7, @truncate(byte));
    }

    // Compress the data
    var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, ascii_data.len);
    defer compressed.deinit();

    {
        var compress_buf: [shrivel.Compress.recommended_buffer_size]u8 = undefined;
        var compress: shrivel.Compress = .init(&compressed.writer, &compress_buf);

        var in: std.Io.Reader = .fixed(ascii_data);
        _ = try in.streamRemaining(&compress.writer);
        try compress.writer.flush();
    }

    // Decompress the compressed data
    const uncompressed = try allocator.alloc(u8, ascii_data.len);
    defer allocator.free(uncompressed);

    {
        var in: std.Io.Reader = .fixed(compressed.written());
        var decompress_buf: [shrivel.Decompress.recommended_buffer_size]u8 = undefined;
        var decompress: shrivel.Decompress = .init(&in, &decompress_buf);

        var out: std.Io.Writer = .fixed(uncompressed);

        var misc_buf: [256]u8 = undefined;
        const max_peek_take_len = decompress_buf.len - shrivel.window_len;

        var remaining = ascii_data.len;
        std.debug.print("ascii len: {}\n", .{remaining});
        for (data[0..]) |byte| {
            const op = Operation.fromByte(byte);
            std.debug.print("{t} {}\n", .{ op, byte });
            process: switch (op) {
                .stream_unlimited => {
                    remaining -= decompress.reader.stream(&out, .unlimited) catch |err| switch (err) {
                        error.ReadFailed, error.WriteFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .stream_limited => {
                    remaining -= decompress.reader.stream(&out, .limited(byte)) catch |err| switch (err) {
                        error.ReadFailed, error.WriteFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .discard_unlimited => {
                    remaining -= decompress.reader.discard(.unlimited) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .discard_limited => {
                    remaining -= decompress.reader.discard(.limited(byte)) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .stream_exact => {
                    const count = byte;
                    decompress.reader.streamExact(&out, count) catch |err| switch (err) {
                        error.ReadFailed, error.WriteFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= count;
                },
                .stream_exact_preserve => {
                    const preserve = byte % decompress_buf.len;
                    const count = byte;
                    decompress.reader.streamExactPreserve(&out, preserve, count) catch |err| switch (err) {
                        error.ReadFailed, error.WriteFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= count;
                },
                .stream_remaining => {
                    remaining -= decompress.reader.streamRemaining(&out) catch |err| switch (err) {
                        error.ReadFailed, error.WriteFailed => |e| return e,
                    };
                },
                .discard_remaining => {
                    remaining -= decompress.reader.discardRemaining() catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                    };
                },
                .alloc_remaining_unlimited => {
                    const slice = decompress.reader.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
                        error.OutOfMemory, error.ReadFailed => |e| return e,
                        error.StreamTooLong => unreachable,
                    };
                    defer allocator.free(slice);
                    remaining -= slice.len;
                },
                .alloc_remaining_limited => {
                    const count = byte;
                    const slice = decompress.reader.allocRemaining(allocator, .limited(count)) catch |err| switch (err) {
                        error.OutOfMemory, error.ReadFailed => |e| return e,
                        error.StreamTooLong => {
                            remaining -= count;
                            break :process;
                        },
                    };
                    defer allocator.free(slice);
                    remaining -= slice.len;
                },
                .append_remaining_unlimited => {
                    var buffer: std.ArrayList(u8) = .empty;
                    defer buffer.deinit(allocator);
                    decompress.reader.appendRemainingUnlimited(allocator, &buffer) catch |err| switch (err) {
                        error.OutOfMemory, error.ReadFailed => |e| return e,
                    };
                    remaining -= buffer.items.len;
                },
                .read_vec => {
                    const count = byte;
                    var vec = [_][]u8{misc_buf[0..count]};
                    remaining -= decompress.reader.readVec(&vec) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .read_vec_all => {
                    const count = byte;
                    var vec = [_][]u8{misc_buf[0..count]};
                    decompress.reader.readVecAll(&vec) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= count;
                },
                .peek => {
                    const count = byte % max_peek_take_len;
                    const slice = decompress.reader.peek(count) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    std.debug.assert(slice.len == count);
                },
                .peek_greedy => {
                    const count = byte % max_peek_take_len;
                    const slice = decompress.reader.peekGreedy(count) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    std.debug.assert(slice.len >= count);
                },
                .take => {
                    const count = byte % max_peek_take_len;
                    const slice = decompress.reader.take(count) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    std.debug.assert(slice.len == count);
                    remaining -= slice.len;
                },
                .take_array => {
                    const ptr_to_array = decompress.reader.takeArray(max_peek_take_len) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= ptr_to_array.len;
                },
                .peek_array => {
                    _ = decompress.reader.peekArray(max_peek_take_len) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                },
                .discard_all => {
                    const count = byte;
                    decompress.reader.discardAll(count) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= count;
                },
                .discard_short => {
                    const count = byte;
                    const n = decompress.reader.discardShort(count) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                    };
                    remaining -= n;
                },
                .read_slice_all => {
                    const count = byte;
                    const buf = misc_buf[0..count];
                    decompress.reader.readSliceAll(buf) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                        error.EndOfStream => break,
                    };
                    remaining -= count;
                },
                .read_slice_short => {
                    const count = byte;
                    const buf = misc_buf[0..count];
                    const n = decompress.reader.readSliceShort(buf) catch |err| switch (err) {
                        error.ReadFailed => |e| return e,
                    };
                    remaining -= n;
                },
            }
            std.debug.print("remaining: {}\n", .{remaining});
            if (remaining == 0) break;
        }
    }
}

const Operation = enum {
    stream_unlimited,
    stream_limited,
    discard_unlimited,
    discard_limited,
    stream_exact,
    stream_exact_preserve,
    stream_remaining,
    discard_remaining,
    alloc_remaining_unlimited,
    alloc_remaining_limited,
    append_remaining_unlimited,
    read_vec,
    read_vec_all,
    peek,
    peek_greedy,
    take,
    take_array,
    peek_array,
    discard_all,
    discard_short,
    read_slice_all,
    read_slice_short,
    // read_slice_endian,
    // read_slice_endian_alloc,
    // read_alloc,
    // take_sentinel,
    // peek_sentinel,
    // take_delimiter_inclusive,
    // peek_delimiter_inclusive,
    // take_delimiter_exclusive,
    // peek_delimiter_exclusive,
    // stream_delimiter,
    // stream_delimiter_ending,
    // stream_delimiter_limit,
    // discard_delimiter_inclusive,
    // discard_delimiter_exclusive,
    // discard_delimiter_limit,
    // fill,
    // fill_more,
    // peek_byte,
    // take_byte,
    // take_byte_signed,
    // take_int,
    // peek_int,
    // take_var_int,
    // take_struct_pointer,
    // peek_struct_pointer,
    // take_struct,
    // peek_struct,
    // rebase,

    pub fn fromByte(byte: u8) Operation {
        return @enumFromInt(byte % @typeInfo(Operation).@"enum".fields.len);
    }
};
