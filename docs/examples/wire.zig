//! The primitive layer: a tag, a scalar, and the bytes they produce.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

test "write and read one field at a time" {
    var buffer: [16]u8 = undefined;
    var io: std.Io.Writer = .fixed(&buffer);
    var w: pb.Writer = .init(&io);

    try w.writeTag(try .init(1, .varint));
    try w.writeScalar(.u32, 150);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x96, 0x01 }, io.buffered());

    var input: std.Io.Reader = .fixed(io.buffered());
    var r: pb.Reader = .init(&input);
    const field = (try r.next()).?;
    try std.testing.expectEqual(@as(u32, 1), field.fieldNumber());
    try std.testing.expectEqual(@as(u32, 150), field.expect(.varint).as(.u32));
    try std.testing.expect((try r.next()) == null);
}
