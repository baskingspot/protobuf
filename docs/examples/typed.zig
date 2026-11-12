//! The typed layer: a plain Zig struct with a field-number table.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

const Person = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .id = pb.field(1),
        .name = pb.string(2),
        .blob = pb.bytes(3),
    };

    id: u32 = 0,
    name: []const u8 = "",
    blob: []const u8 = "",
};

test "encode, size, and decode a struct" {
    const person: Person = .{ .id = 150, .name = "Ada", .blob = &.{ 0x00, 0xff } };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.encode(Person, person, .{}, &out.writer);
    try std.testing.expectEqual(out.written().len, pb.encodedSize(Person, person, .{}));

    var storage: [32]u8 = undefined;
    var io: std.Io.Writer = .fixed(&storage);
    var wire: pb.Writer = .init(&io);
    try wire.writeTag(try .init(1, .varint));
    try wire.writeScalar(.u32, person.id);
    try wire.writeTag(try .init(2, .len));
    try wire.writeLen(person.name);
    try wire.writeTag(try .init(3, .len));
    try wire.writeLen(person.blob);
    try std.testing.expectEqualSlices(u8, io.buffered(), out.written());

    var parsed = try pb.decodeFromSlice(Person, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(person.id, parsed.value.id);
    try std.testing.expectEqualStrings(person.name, parsed.value.name);
    try std.testing.expectEqualSlices(u8, person.blob, parsed.value.blob);
}
