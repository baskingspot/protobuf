//! Where decoded strings and bytes live.
//!
//! `just test` compiles and runs this file with the module's own tests.

const std = @import("std");
const pb = @import("protobuf");

const Name = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .name = pb.string(1) };

    name: []const u8 = "",
};

// field 1, LEN 5, "Ada!!"
const encoded = [_]u8{ 0x0a, 0x05, 'A', 'd', 'a', '!', '!' };

test "decodeFromSlice borrows the string bytes from the input" {
    var parsed = try pb.decodeFromSlice(Name, std.testing.allocator, &encoded, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Ada!!", parsed.value.name);
    try std.testing.expectEqual(@intFromPtr(&encoded[2]), @intFromPtr(parsed.value.name.ptr));
}

test "decode copies the string bytes out of the reader" {
    var io: std.Io.Reader = .fixed(&encoded);
    var parsed = try pb.decode(Name, std.testing.allocator, &io, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Ada!!", parsed.value.name);
    try std.testing.expect(@intFromPtr(parsed.value.name.ptr) != @intFromPtr(&encoded[2]));
}

test "the leaky decoders allocate from the allocator you pass" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var io: std.Io.Reader = .fixed(&encoded);
    const copied = try pb.decodeLeaky(Name, arena.allocator(), &io, .{});
    try std.testing.expectEqualStrings("Ada!!", copied.name);

    const borrowed = try pb.decodeFromSliceLeaky(Name, arena.allocator(), &encoded, .{});
    try std.testing.expectEqualStrings("Ada!!", borrowed.name);
}
