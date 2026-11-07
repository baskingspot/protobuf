//! Benchmarks for the protobuf wire codec.
//!
//! The message the read benchmarks consume is built once, by this library's
//! own writer. Unit tests pin correctness against hand-encoded bytes; these
//! measure speed.

const std = @import("std");
const Io = std.Io;
const testingx = @import("testingx");
const protobuf = @import("protobuf");

var message_buf: [256]u8 = undefined;
var message: []const u8 = &.{};

/// One of each wire type, a nested message, and a packed repeated field.
fn emit(w: *protobuf.Writer) !void {
    try w.writeTag(try .init(1, .varint));
    try w.writeScalar(.u32, 150);

    try w.writeTag(try .init(2, .len));
    try w.writeLen("hello, baskingspot");

    try w.writeTag(try .init(3, .len));
    {
        var nested_buf: [32]u8 = undefined;
        var nested_io: Io.Writer = .fixed(&nested_buf);
        var nested: protobuf.Writer = .init(&nested_io);
        try nested.writeTag(try .init(1, .varint));
        try nested.writeScalar(.i64, 42);
        try nested.writeTag(try .init(2, .fixed64));
        try nested.writeScalar(.double, 3.14);
        try w.writeLen(nested_io.buffered());
    }

    try w.writeTag(try .init(4, .len));
    {
        var repeated_buf: [16]u8 = undefined;
        var repeated_io: Io.Writer = .fixed(&repeated_buf);
        var repeated: protobuf.Writer = .init(&repeated_io);
        for ([_]u32{ 1, 2, 3, 4, 5 }) |v| try repeated.writeScalar(.u32, v);
        try w.writeLen(repeated_io.buffered());
    }
}

pub fn benchmarkMain(b: *testingx.B) !void {
    var io: Io.Writer = .fixed(&message_buf);
    var w: protobuf.Writer = .init(&io);
    try emit(&w);
    message = io.buffered();

    try b.add("Varint/Decode", benchmarkVarintDecode);
    try b.add("Varint/Encode", benchmarkVarintEncode);
    try b.add("Varint/Zigzag", benchmarkZigzag);
    try b.add("Tag/Parse", benchmarkTagParse);
    try b.add("Read/Walk", benchmarkReadWalk);
    try b.add("Read/String", benchmarkReadString);
    try b.add("Write/Message", benchmarkWriteMessage);
}

fn benchmarkVarintDecode(b: *testingx.B) !void {
    const data = [_]u8{ 0x96, 0x80, 0x80, 0x01 };
    b.setBytes(@intCast(data.len));
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const value, const n = try protobuf.wire.decodeVarint(u64, &data);
        sink +%= value +% n;
    }
}

fn benchmarkVarintEncode(b: *testingx.B) !void {
    var buf: [protobuf.wire.max_varint_len]u8 = undefined;
    var value: u64 = 0x3fffffff;
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const data = try protobuf.wire.encodeVarint(u64, value, &buf);
        sink +%= data.len;
        value +%= 1;
    }
}

fn benchmarkZigzag(b: *testingx.B) !void {
    var value: i64 = -1234567;
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        sink +%= protobuf.wire.zigzagEncode(i64, value);
        value = -%value;
    }
}

fn benchmarkTagParse(b: *testingx.B) !void {
    var raw: u64 = (0x1F << 3) | @as(u64, @backingInt(protobuf.WireType.len));
    var sink: u32 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const tag = try protobuf.Tag.parse(raw);
        sink +%= tag.field_number;
        raw +%= 8;
    }
}

/// Walk every field of the message, skipping length-delimited payloads. This
/// is the cost of reading a message whose schema the caller does not know.
fn benchmarkReadWalk(b: *testingx.B) !void {
    b.setBytes(@intCast(message.len));
    var fields: usize = 0;
    var sink: u64 = 0;
    defer b.keepAlive(sink + fields);
    while (try b.loop()) {
        var io: Io.Reader = .fixed(message);
        var r: protobuf.Reader = .init(&io);
        while (try r.next()) |field| {
            fields +%= 1;
            switch (field) {
                .varint => |f| sink +%= f.value,
                .fixed32 => |f| sink +%= f.value,
                .fixed64 => |f| sink +%= f.value,
                .len => |f| {
                    sink +%= f.length;
                    try f.skip();
                },
            }
        }
    }
}

/// Copy the message's string field out, which is the LEN path a caller with a
/// schema takes.
fn benchmarkReadString(b: *testingx.B) !void {
    var buf: [64]u8 = undefined;
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var io: Io.Reader = .fixed(message);
        var r: protobuf.Reader = .init(&io);
        while (try r.next()) |field| {
            switch (field) {
                .len => |f| {
                    if (f.field_number == 2) {
                        sink +%= (try f.string(&buf)).len;
                    } else try f.skip();
                },
                else => {},
            }
        }
    }
}

fn benchmarkWriteMessage(b: *testingx.B) !void {
    b.setBytes(@intCast(message.len));
    var buf: [256]u8 = undefined;
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var io: Io.Writer = .fixed(&buf);
        var w: protobuf.Writer = .init(&io);
        try emit(&w);
        sink +%= io.buffered().len;
    }
}
