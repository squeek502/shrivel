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
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const ascii_data = try allocator.alloc(u8, data.len);
    defer allocator.free(ascii_data);

    for (ascii_data, data) |*c, byte| {
        c.* = @as(u7, @truncate(byte));
    }

    // Compress the data
    var compressed: std.ArrayList(u8) = .init(allocator);
    defer compressed.deinit();

    var compress_buf: [shrivel.compress_recommended_buffer_size]u8 = undefined;
    var compress = shrivel.compressor(compressed.writer(), &compress_buf);

    try compress.writer().writeAll(ascii_data);
    try compress.flush();

    var compressed_in = std.io.fixedBufferStream(compressed.items);

    var decompress_buf: [shrivel.decompress_recommended_buffer_size]u8 = undefined;
    var decompress = shrivel.decompressor(compressed_in.reader(), &decompress_buf);

    const uncompressed = try decompress.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(uncompressed);

    try std.testing.expectEqualSlices(u8, ascii_data, uncompressed);
}
