//! Writing a message to the wire format.
//!
//! `encodedSize` and `encode` walk the same code. The sink is comptime-chosen,
//! so one is a write and the other only adds up lengths: a length prefix comes
//! before the bytes it measures, and the destination may be a socket, so the
//! size walk happens first.

const std = @import("std");
const Io = std.Io;

const proto = @import("proto.zig");
const wire = @import("wire.zig");
const Writer = @import("Writer.zig");

/// Options for `encode`.
pub const Options = struct {
    /// Write scalar fields that hold their type's zero value. Proto3 parsers
    /// read an absent field as its zero, so the default writes fewer bytes and
    /// means the same thing. A `?T` field that is present is always written.
    write_defaults: bool = false,
};

/// Encode a message into `writer`. `T` must be a message: a struct with a
/// `pub const protobuf` table.
pub fn encode(value: anytype, options: Options, writer: *Io.Writer) !void {
    var w: Writer = .init(writer);
    try message(&w, @TypeOf(value), value, options);
}

/// Bytes `encode` would write for this value.
pub fn encodedSize(value: anytype, options: Options) usize {
    var counter: Counter = .{};
    message(&counter, @TypeOf(value), value, options) catch unreachable;
    return counter.total;
}

/// A sink that counts instead of writing. It answers to the same four methods
/// as `Writer`, so the walk below does not know which one it has.
const Counter = struct {
    total: usize = 0,

    fn writeVarint(self: *Counter, comptime T: type, value: T) !void {
        self.total += wire.varintLen(value);
    }

    fn writeTag(self: *Counter, tag: wire.Tag) !void {
        self.total += wire.varintLen(tag.encode());
    }

    fn writeScalar(
        self: *Counter,
        comptime scalar: wire.Scalar,
        value: wire.Scalar.Type(scalar),
    ) !void {
        self.total += wire.scalarLen(scalar, value);
    }

    fn writeLen(self: *Counter, bytes: []const u8) !void {
        self.total += wire.varintLen(bytes.len) + bytes.len;
    }
};

fn isCounter(comptime Sink: type) bool {
    return @typeInfo(Sink) == .pointer and @typeInfo(Sink).pointer.child == Counter;
}

fn message(sink: anytype, comptime T: type, value: T, options: Options) !void {
    const fields = comptime proto.info(T).fields;
    inline for (fields) |f| {
        try emit(sink, f, @field(value, f.name), options);
    }
}

fn emit(sink: anytype, comptime f: proto.Field, value: anytype, options: Options) !void {
    if (comptime @typeInfo(@TypeOf(value)) == .optional) {
        if (value) |present| try single(sink, f, present, options);
        return;
    }
    if (comptime f.repeated) return repeated(sink, f, value, options);
    if (!options.write_defaults and isDefault(value)) return;
    return single(sink, f, value, options);
}

/// One tag and one payload: a singular field, or one element of an unpacked
/// repeated field.
fn single(sink: anytype, comptime f: proto.Field, value: anytype, options: Options) !void {
    try sink.writeTag(.{ .field_number = f.number, .wire_type = proto.elemWireType(f.elem) });
    try payload(sink, f.elem, value, options);
}

fn repeated(sink: anytype, comptime f: proto.Field, values: anytype, options: Options) !void {
    if (comptime !f.is_packed) {
        for (values) |element| try single(sink, f, element, options);
        return;
    }

    var counted: Counter = .{};
    for (values) |element| try payload(&counted, f.elem, element, options);
    if (counted.total == 0) return;

    try sink.writeTag(.{ .field_number = f.number, .wire_type = .len });
    try sink.writeVarint(usize, counted.total);
    if (comptime isCounter(@TypeOf(sink))) {
        sink.total += counted.total;
    } else {
        for (values) |element| try payload(sink, f.elem, element, options);
    }
}

/// The bytes of one value, with no tag.
fn payload(sink: anytype, comptime elem: proto.Elem, value: anytype, options: Options) !void {
    switch (elem) {
        .scalar => |scalar| try sink.writeScalar(scalar, value),
        .@"enum" => try sink.writeScalar(.i32, @backingInt(value)),
        .string, .bytes => try sink.writeLen(value),
        .message => |M| {
            var counted: Counter = .{};
            try message(&counted, M, value, options);
            try sink.writeVarint(usize, counted.total);
            if (comptime isCounter(@TypeOf(sink))) {
                sink.total += counted.total;
            } else {
                try message(sink, M, value, options);
            }
        },
    }
}

fn messageIsDefault(value: anytype) bool {
    const fields = comptime proto.info(@TypeOf(value)).fields;
    inline for (fields) |f| {
        if (!isDefault(@field(value, f.name))) return false;
    }
    return true;
}

/// Whether a field holds the value protobuf treats as absent.
fn isDefault(value: anytype) bool {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => !value,
        .int => value == 0,
        // Bitwise, so negative zero is written out rather than dropped. It is
        // a different value on the wire.
        .float => |f| @as(@Int(.unsigned, f.bits), @bitCast(value)) == 0,
        .@"enum" => @backingInt(value) == 0,
        .pointer => value.len == 0,
        // A message field written without `?` has no way to be absent, so it
        // behaves like any other implicit-presence field: all defaults means
        // nothing on the wire. A `?T` that is present is written even when it
        // is empty, which is how presence gets said.
        .@"struct" => messageIsDefault(value),
        .optional => value == null,
        else => @compileError("no default test for " ++ @typeName(T)),
    };
}
