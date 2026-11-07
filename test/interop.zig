//! The typed layer against bytes `protoc` wrote.
//!
//! `data/interop/interop.proto` and its `All.txt` text-format message describe
//! every wire shape this library claims to carry. `data/fixtures.txtar` holds
//! `protoc --encode=interop.All` over them, and `just proto` regenerates it.
//! These tests encode the same values and expect those bytes, decode those
//! bytes and expect those values, and re-encode to the same bytes.

const std = @import("std");
const testing = std.testing;

const pb = @import("protobuf");
const testingx = @import("testingx");

const EnumKind = enum(i32) {
    unknown = 0,
    first = 1,
    second = 2,
};

const Inner = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .n = pb.field(1),
        .label = pb.string(2),
    };

    n: i32 = 0,
    label: []const u8 = "",
};

/// Fields are declared in field-number order, because that is the order they
/// are written in, and `protoc` writes in number order too. Re-encoding has to
/// match byte for byte.
/// A `map<string, int64>` is a repeated message with field 1 as the key and
/// field 2 as the value. There is no map on the wire, so there is none here.
const AttrsEntry = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .key = pb.string(1),
        .value = pb.field(2),
    };

    key: []const u8 = "",
    value: i64 = 0,
};

const All = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .i32 = pb.field(1),
        .i64 = pb.field(2),
        .u32 = pb.field(3),
        .u64 = pb.field(4),
        .s32 = pb.sint(5),
        .s64 = pb.sint(6),
        .fx32 = pb.fixed(7),
        .fx64 = pb.fixed(8),
        .sfx32 = pb.fixed(9),
        .sfx64 = pb.fixed(10),
        .flt = pb.field(11),
        .dbl = pb.field(12),
        .flag = pb.field(13),
        .text = pb.string(14),
        .blob = pb.bytes(15),
        .inner = pb.field(16),
        .packed_i32 = pb.field(18),
        .packed_s64 = pb.sint(19),
        .packed_fx32 = pb.fixed(20),
        .unpacked_i32 = pb.unpacked(21),
        .words = pb.string(22),
        .items = pb.field(23),
        .kind = pb.field(24),
        .attrs = pb.field(25),
        .high = pb.field(2047),
        .higher = pb.field(16384),
    };

    i32: i32 = 0,
    i64: i64 = 0,
    u32: u32 = 0,
    u64: u64 = 0,
    s32: i32 = 0,
    s64: i64 = 0,
    fx32: u32 = 0,
    fx64: u64 = 0,
    sfx32: i32 = 0,
    sfx64: i64 = 0,
    flt: f32 = 0,
    dbl: f64 = 0,
    flag: bool = false,
    text: []const u8 = "",
    blob: []const u8 = "",
    inner: Inner = .{},
    packed_i32: []const i32 = &.{},
    packed_s64: []const i64 = &.{},
    packed_fx32: []const u32 = &.{},
    unpacked_i32: []const i32 = &.{},
    words: []const []const u8 = &.{},
    items: []const Inner = &.{},
    kind: EnumKind = .unknown,
    attrs: []const AttrsEntry = &.{},
    high: i32 = 0,
    higher: u32 = 0,
};

const fixtures = testingx.fixtures(@embedFile("data/fixtures.txtar"));
const golden = fixtures.hex("interop/All.pb");

fn sample() All {
    return .{
        .i32 = -1,
        .i64 = -9_000_000_000,
        .u32 = 4_000_000_000,
        .u64 = std.math.maxInt(u64),
        .s32 = -2,
        .s64 = -9_000_000_000,
        .fx32 = 70_000,
        .fx64 = 5_000_000_000,
        .sfx32 = -70_000,
        .sfx64 = -5_000_000_000,
        .flt = 1.5,
        .dbl = -2.25,
        .flag = true,
        .text = "hello, baskingspot",
        .blob = &.{ 0x00, 0x01, 0xff },
        .inner = .{ .n = 7, .label = "in" },
        .packed_i32 = &.{ 1, 2, -1 },
        .packed_s64 = &.{ -1, 300 },
        .packed_fx32 = &.{ 1, std.math.maxInt(u32) },
        .unpacked_i32 = &.{ 5, 6 },
        .words = &.{ "a", "", "ccc" },
        .items = &.{ .{ .n = 1, .label = "one" }, .{ .n = 2, .label = "two" } },
        .kind = .second,
        .attrs = &.{
            .{ .key = "a", .value = 1 },
            .{ .key = "b", .value = 2 },
            .{ .key = "c", .value = 3 },
        },
        .high = 2047,
        .higher = 16384,
    };
}

test "encode matches protoc" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(sample(), .{}, &out.writer);

    try testing.expectEqualSlices(u8, golden, out.written());
    try testing.expectEqual(golden.len, pb.encodedSize(sample(), .{}));
}

test "decode what protoc wrote" {
    var parsed = try pb.decodeFromSlice(All, testing.allocator, golden, .{});
    defer parsed.deinit();
    const got = parsed.value;
    const want = sample();

    try testing.expectEqual(want.i32, got.i32);
    try testing.expectEqual(want.i64, got.i64);
    try testing.expectEqual(want.u32, got.u32);
    try testing.expectEqual(want.u64, got.u64);
    try testing.expectEqual(want.s32, got.s32);
    try testing.expectEqual(want.s64, got.s64);
    try testing.expectEqual(want.fx32, got.fx32);
    try testing.expectEqual(want.fx64, got.fx64);
    try testing.expectEqual(want.sfx32, got.sfx32);
    try testing.expectEqual(want.sfx64, got.sfx64);
    try testing.expectEqual(want.flt, got.flt);
    try testing.expectEqual(want.dbl, got.dbl);
    try testing.expectEqual(want.flag, got.flag);
    try testing.expectEqualStrings(want.text, got.text);
    try testing.expectEqualSlices(u8, want.blob, got.blob);
    try testing.expectEqual(want.inner.n, got.inner.n);
    try testing.expectEqualStrings(want.inner.label, got.inner.label);
    try testing.expectEqual(want.kind, got.kind);
    try testing.expectEqualSlices(i32, want.packed_i32, got.packed_i32);
    try testing.expectEqualSlices(i64, want.packed_s64, got.packed_s64);
    try testing.expectEqualSlices(u32, want.packed_fx32, got.packed_fx32);
    try testing.expectEqualSlices(i32, want.unpacked_i32, got.unpacked_i32);
    try testing.expectEqual(want.words.len, got.words.len);
    try testing.expectEqualStrings("", got.words[1]);
    try testing.expectEqual(want.items.len, got.items.len);
    try testing.expectEqualStrings("two", got.items[1].label);
    try testing.expectEqual(want.attrs.len, got.attrs.len);
    try testing.expectEqualStrings("a", got.attrs[0].key);
    try testing.expectEqual(2, got.attrs[1].value);
    try testing.expectEqualStrings("c", got.attrs[2].key);
    try testing.expectEqual(3, got.attrs[2].value);
    try testing.expectEqual(want.high, got.high);
    try testing.expectEqual(want.higher, got.higher);
}

test "re-encode what protoc wrote" {
    var parsed = try pb.decodeFromSlice(All, testing.allocator, golden, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(parsed.value, .{}, &out.writer);
    try testing.expectEqualSlices(u8, golden, out.written());
}

test "a map entry decodes, and its zero value is not written back" {
    // protoc writes the value of a map entry even when it is the default:
    // `10 00` below is `value: 0`. This library treats an entry as the message
    // it is, so the zero is dropped. Both forms decode to the same entry, and
    // both are valid protobuf; only the bytes differ.
    const from_protoc = [_]u8{ 0xca, 0x01, 0x05, 0x0a, 0x01, 'c', 0x10, 0x00 };

    var parsed = try pb.decodeFromSlice(All, testing.allocator, &from_protoc, .{});
    defer parsed.deinit();
    try testing.expectEqual(1, parsed.value.attrs.len);
    try testing.expectEqualStrings("c", parsed.value.attrs[0].key);
    try testing.expectEqual(0, parsed.value.attrs[0].value);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(parsed.value, .{}, &out.writer);
    try testing.expectEqualSlices(u8, &.{ 0xca, 0x01, 0x03, 0x0a, 0x01, 'c' }, out.written());

    // Which decodes back to the same entry.
    var again = try pb.decodeFromSlice(All, testing.allocator, out.written(), .{});
    defer again.deinit();
    try testing.expectEqualStrings("c", again.value.attrs[0].key);
    try testing.expectEqual(0, again.value.attrs[0].value);
}

/// An editions 2023 schema's choices, in this table. `explicit` is
/// `features.field_presence = EXPLICIT`, so a zero is a value and not absence.
/// `expanded` is `features.repeated_field_encoding = EXPANDED`, which is what
/// `pb.unpacked` says. `text` is `features.utf8_validation = NONE`, which is
/// what `pb.bytes` says.
const Editions = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .explicit = pb.field(1),
        .packed_values = pb.field(3),
        .expanded_values = pb.unpacked(4),
        .text = pb.bytes(5),
    };

    explicit: ?i32 = null,
    packed_values: []const i32 = &.{},
    expanded_values: []const i32 = &.{},
    text: []const u8 = "",
};

test "editions change the encoding policy, not the wire" {
    // protoc 36.2 --encode=ed.Fields over an `edition = "2023"` file with
    // field_presence EXPLICIT on field 1, repeated_field_encoding PACKED on 3
    // and EXPANDED on 4, and utf8_validation NONE on 5. The explicit zero is
    // written, field 3 is one packed block, and field 4 is one tag per element.
    const from_protoc = [_]u8{
        0x08, 0x00, // explicit: 0, written because presence is explicit
        0x1a, 0x02, 0x01, 0x02, // packed: { 1, 2 }
        0x20, 0x03, 0x20, 0x04, // expanded: 3, then 4
        0x2a, 0x02, 'h', 'i', // text: "hi", not checked as UTF-8
    };

    var parsed = try pb.decodeFromSlice(Editions, testing.allocator, &from_protoc, .{});
    defer parsed.deinit();

    // Present, and zero: the one thing proto3 implicit presence cannot say.
    try testing.expect(parsed.value.explicit != null);
    try testing.expectEqual(0, parsed.value.explicit.?);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, parsed.value.packed_values);
    try testing.expectEqualSlices(i32, &.{ 3, 4 }, parsed.value.expanded_values);
    try testing.expectEqualStrings("hi", parsed.value.text);

    // Every editions choice here has a table entry that says the same thing,
    // so re-encoding reproduces protoc's bytes exactly.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(parsed.value, .{}, &out.writer);
    try testing.expectEqualSlices(u8, &from_protoc, out.written());
}

test "a group is not a field this reader can parse" {
    // The same editions file with `message_encoding = DELIMITED` on field 6:
    // protoc writes START_GROUP, the contents, and END_GROUP. Wire types 3 and
    // 4 were removed from proto3 and are back through editions, so a message
    // that uses them fails before any field is looked at.
    const delimited = [_]u8{ 0x33, 0x08, 0x07, 0x34 };

    try testing.expectError(
        error.InvalidWireType,
        pb.decodeFromSlice(Editions, testing.allocator, &delimited, .{}),
    );
}

test "decode from a reader copies instead of borrowing" {
    var io: std.Io.Reader = .fixed(golden);

    var parsed = try pb.decode(All, testing.allocator, &io, .{});
    defer parsed.deinit();
    const got = parsed.value;
    const want = sample();

    try testing.expectEqualStrings(want.text, got.text);
    try testing.expectEqualSlices(u8, want.blob, got.blob);
    try testing.expectEqualStrings(want.inner.label, got.inner.label);
    try testing.expectEqualSlices(i32, want.packed_i32, got.packed_i32);
    try testing.expectEqualStrings("a", got.attrs[0].key);
    try testing.expectEqualSlices(i32, want.unpacked_i32, got.unpacked_i32);

    // Copied, not borrowed: the text does not point into the input.
    const start = @intFromPtr(golden.ptr);
    const text_at = @intFromPtr(got.text.ptr);
    try testing.expect(text_at < start or text_at >= start + golden.len);
}

test "packed on the wire decodes into an unpacked field" {
    // Field 21 as a packed length-delimited field: tag 0xaa 0x01, two values.
    const bytes = [_]u8{ 0xaa, 0x01, 0x02, 0x05, 0x06 };

    var parsed = try pb.decodeFromSlice(All, testing.allocator, &bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(i32, &.{ 5, 6 }, parsed.value.unpacked_i32);
}

test "string fields are checked as UTF-8, bytes fields are not" {
    const invalid = [_]u8{ 0xc3, 0x28 };

    // field 14, string, two bytes that are not UTF-8
    const as_text = [_]u8{ 0x72, 0x02, 0xc3, 0x28 };
    try testing.expectError(error.InvalidUtf8, pb.decodeFromSlice(All, testing.allocator, &as_text, .{}));

    var lenient = try pb.decodeFromSlice(All, testing.allocator, &as_text, .{ .validate_utf8 = false });
    defer lenient.deinit();
    try testing.expectEqualSlices(u8, &invalid, lenient.value.text);

    // field 15, bytes, the same two bytes
    const as_blob = [_]u8{ 0x7a, 0x02, 0xc3, 0x28 };
    var parsed = try pb.decodeFromSlice(All, testing.allocator, &as_blob, .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(u8, &invalid, parsed.value.blob);
}

test "duplicate fields: last one wins for a scalar, messages merge" {
    // i32 = 1, then i32 = 2; inner.n = 7, then inner.label = "x".
    const bytes = [_]u8{
        0x08, 0x01, // i32 = 1
        0x08, 0x02, // i32 = 2
        0x82, 0x01, 0x02, 0x08, 0x07, // inner { n: 7 }
        0x82, 0x01, 0x03, 0x12, 0x01, 'x', // inner { label: "x" }
    };

    var parsed = try pb.decodeFromSlice(All, testing.allocator, &bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(2, parsed.value.i32);
    try testing.expectEqual(7, parsed.value.inner.n);
    try testing.expectEqualStrings("x", parsed.value.inner.label);
}

test "write_defaults writes the zero values too" {
    const zeros: Inner = .{};
    try testing.expectEqual(0, pb.encodedSize(zeros, .{}));
    // n = 0 and label = "" are two tags and nothing else.
    try testing.expectEqual(4, pb.encodedSize(zeros, .{ .write_defaults = true }));
}
