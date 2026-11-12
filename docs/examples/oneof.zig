//! One case at a time.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

/// The cases of a oneof. Each case carries its own field number, the way a
/// message field does.
const Pick = union(enum) {
    pub const protobuf: pb.Variants(@This()) = .{
        .number = pb.field(2),
        .name = pb.string(3),
    };

    number: i32,
    name: []const u8,
};

const Reply = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .pick = pb.oneof() };

    pick: ?Pick = null,
};

test "a decode keeps the last case on the wire" {
    // Both cases are present, which a well-behaved writer does not do.
    const bytes = [_]u8{
        0x10, 0x07, // number = 7
        0x1a, 0x02, 'h', 'i', // name = "hi"
    };
    const reply = try pb.decodeFromSliceLeaky(Reply, std.testing.allocator, &bytes, .{});
    try std.testing.expect(std.meta.activeTag(reply.pick.?) == .name);
    try std.testing.expectEqualStrings("hi", reply.pick.?.name);
}

test "a case set to zero is not the same message as no case" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.encode(Reply, .{ .pick = .{ .number = 0 } }, .{}, &out.writer);

    // Tag 2, varint, and a zero. The tag is the presence.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x00 }, out.written());
    try std.testing.expectEqual(@as(usize, 0), pb.encodedSize(Reply, .{}, .{}));
}
