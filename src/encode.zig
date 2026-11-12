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
pub fn encode(comptime T: type, value: T, options: Options, writer: *Io.Writer) !void {
    var w: Writer = .init(writer);
    try message(&w, T, value, options);
}

/// Bytes `encode` would write for this value.
pub fn encodedSize(comptime T: type, value: T, options: Options) usize {
    var counter: Counter = .{};
    message(&counter, T, value, options) catch unreachable;
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
    try unknownFields(sink, T, value);
}

/// Write back the fields a decode did not recognize. They go after the
/// declared fields: the format gives field order no meaning.
fn unknownFields(sink: anytype, comptime T: type, value: T) !void {
    if (comptime !proto.hasUnknown(T)) return;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, Ty| {
        if (Ty == proto.Unknown) {
            for (@field(value, name).records) |record| {
                switch (record) {
                    .varint => |f| {
                        try sink.writeTag(.{ .field_number = f.number, .wire_type = .varint });
                        try sink.writeVarint(u64, f.value);
                    },
                    .fixed64 => |f| {
                        try sink.writeTag(.{ .field_number = f.number, .wire_type = .fixed64 });
                        try sink.writeScalar(.fixed64, f.value);
                    },
                    .fixed32 => |f| {
                        try sink.writeTag(.{ .field_number = f.number, .wire_type = .fixed32 });
                        try sink.writeScalar(.fixed32, f.value);
                    },
                    .len => |f| {
                        try sink.writeTag(.{ .field_number = f.number, .wire_type = .len });
                        try sink.writeLen(f.bytes);
                    },
                }
            }
        }
    }
}

fn emit(sink: anytype, comptime f: proto.Field, value: f.type, options: Options) !void {
    if (comptime f.elem == .oneof) return oneof(sink, f, value, options);
    if (comptime f.optional) {
        if (value) |present| try single(sink, f, present, options);
        return;
    }
    if (comptime f.repeated) return repeated(sink, f, value, options);
    if (!options.write_defaults and isDefault(value)) return;
    return single(sink, f, value, options);
}

/// Write the one case of a oneof that is set. A case is written even when its
/// value is the type's zero: the tag is the presence, and the case was chosen.
fn oneof(sink: anytype, comptime f: proto.Field, value: f.type, options: Options) !void {
    const U = f.elem.oneof;
    const present = value orelse return;
    const tag = std.meta.activeTag(present);
    inline for (comptime proto.variants(U).fields) |v| {
        if (tag == @field(@typeInfo(U).@"union".tag_type.?, v.name)) {
            try single(sink, v, @field(present, v.name), options);
        }
    }
}

/// One tag and one payload: a singular field, or one element of an unpacked
/// repeated field.
fn single(
    sink: anytype,
    comptime f: proto.Field,
    value: proto.ElemType(f.elem),
    options: Options,
) !void {
    try sink.writeTag(.{ .field_number = f.number, .wire_type = proto.elemWireType(f.elem) });
    try payload(sink, f.elem, value, options);
}

fn repeated(
    sink: anytype,
    comptime f: proto.Field,
    values: []const proto.ElemType(f.elem),
    options: Options,
) !void {
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
fn payload(
    sink: anytype,
    comptime elem: proto.Elem,
    value: proto.ElemType(elem),
    options: Options,
) !void {
    switch (elem) {
        .scalar => |scalar| try sink.writeScalar(scalar, value),
        .@"enum" => try sink.writeScalar(.i32, @backingInt(value)),
        .string, .bytes => try sink.writeLen(value),
        .oneof => unreachable,
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
    const T = @TypeOf(value);
    const fields = comptime proto.info(T).fields;
    inline for (fields) |f| {
        if (!isDefault(@field(value, f.name))) return false;
    }
    // A message that carries only skipped fields is not empty: they are bytes
    // the caller asked to keep.
    if (comptime proto.hasUnknown(T)) {
        const s = @typeInfo(T).@"struct";
        inline for (s.field_names, s.field_types) |name, Ty| {
            if (Ty == proto.Unknown and @field(value, name).records.len != 0) {
                return false;
            }
        }
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
