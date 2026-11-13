//! The adapter the guide shows for `stdx.base64`, run against stdx itself.
//!
//! This file exists so the snippet in the guide is compiled: if stdx renames
//! `encodedLen` or changes a signature, this test stops building, and so does
//! the documentation.

const std = @import("std");
const stdx = @import("stdx");
const pb = @import("protobuf");

/// The six lines from the guide, verbatim.
const fast: pb.json.Base64 = .{
    .encoded_len = stdx.base64.standard.encodedLen,
    .encode = stdx.base64.standard.encode,
    .decoded_len = stdx.base64.standard.decodedLen,
    .decode = stdx.base64.standard.decode,
};

const Blob = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .data = pb.bytes(1) };

    data: []const u8 = "",
};

test "the codec the guide brings in writes the same bytes as the default" {
    const gpa = std.testing.allocator;

    var blob: [4096]u8 = undefined;
    var seed: u64 = 99;
    for (&blob) |*b| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(seed >> 33);
    }

    var slow: std.Io.Writer.Allocating = .init(gpa);
    defer slow.deinit();
    try pb.json.encode(Blob, .{ .data = &blob }, .{}, &slow.writer);

    var quick: std.Io.Writer.Allocating = .init(gpa);
    defer quick.deinit();
    try pb.json.encode(Blob, .{ .data = &blob }, .{ .base64 = fast }, &quick.writer);

    try std.testing.expectEqualStrings(slow.written(), quick.written());

    var parsed = try pb.json.decode(
        Blob,
        quick.written(),
        .{ .base64 = fast },
        gpa,
    );
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &blob, parsed.value.data);
}
