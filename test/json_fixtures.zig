//! Structural equality for the JSON fixture tests.
//!
//! Two JSON documents say the same thing when they hold the same values, in
//! the same array order, under the same member names. Whitespace and the order
//! of an object's members carry no meaning, so they are not compared.

const std = @import("std");

/// Compare two JSON documents, or fail with an error naming what differs.
pub fn expectSame(expected: []const u8, actual: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const want = try std.json.parseFromSliceLeaky(std.json.Value, gpa, expected, .{});
    const got = try std.json.parseFromSliceLeaky(std.json.Value, gpa, actual, .{});
    try same(want, got);
}

fn same(want: std.json.Value, got: std.json.Value) !void {
    if (std.meta.activeTag(want) != std.meta.activeTag(got)) return error.JsonTypeMismatch;

    switch (want) {
        .null => {},
        .bool => |x| try std.testing.expectEqual(x, got.bool),
        .integer => |x| try std.testing.expectEqual(x, got.integer),
        .float => |x| try std.testing.expectEqual(x, got.float),
        .number_string => |x| try std.testing.expectEqualStrings(x, got.number_string),
        .string => |x| try std.testing.expectEqualStrings(x, got.string),
        .array => |x| {
            try std.testing.expectEqual(x.items.len, got.array.items.len);
            for (x.items, got.array.items) |a, b| try same(a, b);
        },
        .object => |x| {
            try std.testing.expectEqual(x.count(), got.object.count());
            var members = x.iterator();
            while (members.next()) |member| {
                // A JSON object is a set of members, not a list: a peer that
                // writes the map in another order says the same thing.
                const other = got.object.get(member.key_ptr.*) orelse
                    return error.JsonMissingMember;
                try same(member.value_ptr.*, other);
            }
        },
    }
}
