//! The same message as JSON.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

const Person = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .id = pb.field(1),
        .name = pb.string(2),
        .needs_review = pb.field(3),
    };

    id: u64 = 0,
    name: []const u8 = "",
    needs_review: bool = false,
};

test "JSON writes camelCase, and a 64-bit integer as a string" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.json.encode(Person, .{ .id = 42, .name = "Ada" }, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        "{\"id\":\"42\",\"name\":\"Ada\"}",
        out.written(),
    );
}

test "the parser takes either spelling and gives back the message" {
    var parsed = try pb.json.decode(
        Person,
        "{\"id\":\"42\",\"name\":\"Ada\",\"needs_review\":true}",
        .{},
        std.testing.allocator,
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 42), parsed.value.id);
    try std.testing.expectEqualStrings("Ada", parsed.value.name);
    try std.testing.expect(parsed.value.needs_review);
}

test "a timestamp is an RFC 3339 string, not an object" {
    const Event = struct {
        pub const protobuf: pb.Descriptor(@This()) = .{
            .at = pb.field(1),
            .took = pb.field(2),
        };

        at: ?pb.wkt.Timestamp = null,
        took: ?pb.wkt.Duration = null,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try pb.json.encode(Event, .{
        .at = .{ .seconds = 1_712_320_496 },
        .took = .{ .seconds = 3, .nanos = 500_000_000 },
    }, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        "{\"at\":\"2024-04-05T12:34:56Z\",\"took\":\"3.500s\"}",
        out.written(),
    );
}
