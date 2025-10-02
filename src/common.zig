const std = @import("std");

pub const Match = struct {
    distance: u6,
    length: u3,

    pub fn fromEncoded(encoded: Encoded.BackReference) Match {
        return .{
            .distance = encoded.distance(),
            .length = encoded.length(),
        };
    }
};

pub fn findMatch(input: []const u8, window: []const u8) ?Match {
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

pub fn findLongestMatchForLen(match_len: u3, input: []const u8, window: []const u8) ?Match {
    std.debug.assert(match_len > 0);
    const potential_match = input[0..match_len];
    const match_index = std.mem.lastIndexOf(u8, window, potential_match) orelse return null;
    //std.debug.print("found match of {s} in window {s}\n", .{ potential_match, window });

    var full_len = match_len;
    // If the match is at the very end of the window, then it's possible to take advantage of that
    // and extend the length further.
    if (match_index + full_len == window.len) {
        while (@as(u8, full_len) + match_len <= max_match_len) {
            const remaining_input = input[full_len..];
            //std.debug.print("checking if {s} starts with {s}\n", .{ remaining_input, potential_match });
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

pub const Encoded = packed struct(u8) {
    payload: packed union {
        char: u7,
        back_reference: BackReference,
    },
    is_back_reference: bool,

    pub fn backReference(match: Match) Encoded {
        return .{ .is_back_reference = true, .payload = .{ .back_reference = .{
            .encoded_distance = .fromValue(match.distance),
            .encoded_length = .fromValue(match.length),
        } } };
    }

    pub fn char(c: u7) Encoded {
        return .{ .is_back_reference = false, .payload = .{ .char = c } };
    }

    pub const BackReference = packed struct(u7) {
        encoded_distance: Distance,
        encoded_length: Length,

        pub fn distance(self: BackReference) u6 {
            return self.encoded_distance.value();
        }

        pub fn length(self: BackReference) u3 {
            return self.encoded_length.value();
        }

        pub const Distance = enum(u5) {
            _,

            pub fn value(d: Distance) u6 {
                return @as(u6, @intFromEnum(d)) + 1;
            }

            pub fn fromValue(d: u6) Distance {
                return @enumFromInt(d - 1);
            }
        };

        pub const Length = enum(u2) {
            three,
            four,
            five,
            six,

            pub fn value(l: Length) u3 {
                return @as(u3, @intFromEnum(l)) + 3;
            }

            pub fn fromValue(l: u3) Length {
                return @enumFromInt(l - 3);
            }
        };
    };
};

pub const window_len = 32;
pub const min_match_len = 3;
pub const max_match_len = 6;

pub const test_data_plain = "foobarfoofoobaraaaaa";
pub const test_data_compressed = "foobar" ++ &[_]u8{
    @bitCast(Encoded.backReference(.{ .distance = 6, .length = 3 })),
    @bitCast(Encoded.backReference(.{ .distance = 9, .length = 6 })),
    'a',
    @bitCast(Encoded.backReference(.{ .distance = 1, .length = 4 })),
};

const quad_window_len = window_len * 4;
pub const test_data_long_plain = "a" ** (quad_window_len - 1);
pub const test_data_long_compressed = "a" ++ &[_]u8{
    @bitCast(Encoded.backReference(.{ .distance = 1, .length = 6 })),
} ++ &([_]u8{
    @bitCast(Encoded.backReference(.{ .distance = 6, .length = 6 })),
} ** (quad_window_len / max_match_len - 1));
