//! Back-to-back messages on one stream.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

const Person = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .id = pb.field(1), .name = pb.string(2) };

    id: u32 = 0,
    name: []const u8 = "",
};

test "each frame decodes on its own" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.delimited.encode(Person, .{ .id = 1, .name = "Ada" }, .{}, &out.writer);
    try pb.delimited.encode(Person, .{ .id = 2, .name = "Grace" }, .{}, &out.writer);

    // The first byte is the length of the first message: field 1 and the
    // string "Ada" come to seven bytes.
    try std.testing.expectEqual(@as(u8, 7), out.written()[0]);

    var input: std.Io.Reader = .fixed(out.written());
    var frames: pb.delimited.Reader = .init(&input);

    const ids = [_]u32{ 1, 2 };
    var count: usize = 0;
    while (try frames.next()) |frame| : (count += 1) {
        const person = try pb.decodeFromSliceLeaky(
            Person,
            std.testing.allocator,
            try frame.rest(),
            .{},
        );
        try std.testing.expectEqual(ids[count], person.id);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "a frame left unread does not desynchronize the stream" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.delimited.encode(Person, .{ .id = 1, .name = "Ada" }, .{}, &out.writer);
    try pb.delimited.encode(Person, .{ .id = 2, .name = "Grace" }, .{}, &out.writer);

    var input: std.Io.Reader = .fixed(out.written());
    var frames: pb.delimited.Reader = .init(&input);

    // The first frame is read as fields, and the second is read as bytes:
    // both use the same framing.
    const first = (try frames.next()).?;
    const field = (try first.fields().next()).?;
    try std.testing.expectEqual(@as(u32, 1), field.fieldNumber());

    const second = try pb.decodeFromSliceLeaky(
        Person,
        std.testing.allocator,
        try (try frames.next()).?.rest(),
        .{},
    );
    try std.testing.expectEqualStrings("Grace", second.name);
}
