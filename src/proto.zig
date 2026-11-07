//! The comptime half of the typed layer: reads a Zig struct as a protobuf
//! message.
//!
//! A struct is a message when it declares `pub const protobuf`, a
//! `Descriptor(@This())`: one `FieldDescriptor` per field, keyed by the field
//! names, so the literal has a type and the compiler checks it:
//!
//! ```zig
//! pub const Person = struct {
//!     pub const protobuf: Descriptor(@This()) = .{
//!         .name = string(2),
//!         .id = field(1),
//!         .delta = sint(3),
//!     };
//!
//!     name: []const u8 = "",
//!     id: u32 = 0,
//!     delta: i32 = 0,
//! };
//! ```
//!
//! The compiler catches a missing entry, a misspelled one, and an entry of the
//! wrong type. `info` adds what a type cannot say: unique field numbers, a
//! default for every field, and field types the wire format can carry.
//!
//! There is no map type, and that is deliberate. On the wire `map<K, V>` is a
//! repeated message with the key in field 1 and the value in field 2, so a map
//! field is a slice of that message:
//!
//! ```zig
//! const Entry = struct {
//!     pub const protobuf: Descriptor(@This()) = .{ .key = string(1), .value = field(2) };
//!     key: []const u8 = "",
//!     value: i64 = 0,
//! };
//! // map<string, int64> attrs = 25;
//! attrs: []const Entry = &.{},
//! ```
//!
//! A hash map would also give up the one thing that makes map output stable:
//! protobuf leaves the entry order unspecified, and a slice keeps it in the
//! caller's hands. Build a lookup structure from the slice if you need one.

const std = @import("std");
const wire = @import("wire.zig");

/// How a field's bytes are encoded. `auto` picks the obvious one for the Zig
/// type: `int32` for `i32`, `uint32` for `u32`, `float` for `f32`. The others
/// exist because the Zig type cannot say them, and a `[]const u8` has no
/// obvious one at all.
pub const Encoding = enum {
    /// `int32`, `int64`, `uint32`, `uint64`, `float`, `double`.
    auto,
    /// `[]const u8`, checked as UTF-8 on decode.
    string,
    /// `[]const u8`, raw.
    bytes,
    /// `sint32`, `sint64`: zigzag varint.
    sint,
    /// `sfixed32`, `sfixed64`, `fixed32`, `fixed64`: little endian, fixed width.
    fixed,
};

/// One field's wire metadata: its number, and the encoding when the Zig type
/// cannot say it. Written as `field(2)`, through a helper for the ambiguous
/// cases, or as a literal when a rarer knob matters.
pub const FieldDescriptor = struct {
    number: u32,
    encoding: Encoding = .auto,
    /// Packed repeated encoding, the `.proto` option. `null` means packed for a
    /// numeric field and per element otherwise, which is what proto3 does.
    /// The name is quoted because `packed` is a Zig keyword.
    @"packed": ?bool = null,
};

/// A field whose Zig type says everything: `int32` for an `i32`, `uint32` for
/// a `u32`, `float` for an `f32`, and a message or a repeated field straight
/// from the shape. A `[]const u8` is not enough: say `pb.string` or
/// `pb.bytes`.
pub fn field(number: u32) FieldDescriptor {
    return .{ .number = number };
}

/// A `[]const u8` checked as UTF-8 on decode.
pub fn string(number: u32) FieldDescriptor {
    return .{ .number = number, .encoding = .string };
}

/// A `[]const u8` that is raw bytes.
pub fn bytes(number: u32) FieldDescriptor {
    return .{ .number = number, .encoding = .bytes };
}

/// An `i32` or `i64` written as a zigzag varint: `sint32`, `sint64`.
pub fn sint(number: u32) FieldDescriptor {
    return .{ .number = number, .encoding = .sint };
}

/// An `i32`, `i64`, `u32`, or `u64` written at fixed width: `fixed32`,
/// `sfixed32`, `fixed64`, `sfixed64`.
pub fn fixed(number: u32) FieldDescriptor {
    return .{ .number = number, .encoding = .fixed };
}

/// A repeated numeric field written one element per tag, as proto2 does.
pub fn unpacked(number: u32) FieldDescriptor {
    return .{ .number = number, .@"packed" = false };
}

/// The field-number table for message `T`: one `FieldDescriptor` per field of
/// `T`, named exactly like the fields and with no defaults, so a literal must
/// cover every field and may name no other. The compiler catches a missing
/// entry, a misspelled one, and one of the wrong type.
pub fn Descriptor(comptime T: type) type {
    const s = @typeInfo(T).@"struct";
    const n = s.field_names.len;
    var types: [n]type = @splat(FieldDescriptor);
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, s.field_names, &types, &attrs);
}

/// A field's type, or the element type of a repeated field.
pub const Elem = union(enum) {
    scalar: wire.Scalar,
    @"enum": type,
    string,
    bytes,
    message: type,
};

/// One field of a message, with everything the wire format needs.
pub const Field = struct {
    /// The name in the Zig struct, which is this field's name in the table.
    name: [:0]const u8,
    number: u32,
    /// `?T`: the field can be absent, which is not the same as its default.
    optional: bool,
    repeated: bool,
    is_packed: bool,
    /// The Zig type of the struct field.
    type: type,
    elem: Elem,

    /// The wire type the encoder writes for this field.
    pub fn wireType(self: Field) wire.WireType {
        if (self.repeated and self.is_packed) return .len;
        return elemWireType(self.elem);
    }
};

pub fn scalarWireType(comptime scalar: wire.Scalar) wire.WireType {
    return switch (scalar) {
        .i32, .i64, .u32, .u64, .sint32, .sint64, .bool => .varint,
        .fixed64, .sfixed64, .double => .fixed64,
        .fixed32, .sfixed32, .float => .fixed32,
    };
}

/// The packed encoding of a numeric scalar, for the repeated reader.
pub fn scalarPacked(comptime scalar: wire.Scalar) wire.Encoding {
    return switch (scalar) {
        .sint32, .sint64 => .sint,
        .fixed32, .sfixed32, .float, .fixed64, .sfixed64, .double => .fixed,
        else => .varint,
    };
}

pub fn elemWireType(elem: Elem) wire.WireType {
    return switch (elem) {
        .scalar => |s| scalarWireType(s),
        .@"enum" => .varint,
        .string, .bytes, .message => .len,
    };
}

/// Every field of a message, in the order the struct declares them.
pub const Info = struct {
    fields: []const Field,
};

/// Read `T` as a message. Everything here is comptime work, so a bad table is
/// a compile error in the code that tried to encode or decode `T`.
pub fn info(comptime T: type) Info {
    comptime {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError(@typeName(T) ++ " is not a struct, so it is not a message");
        }
        if (!@hasDecl(T, "protobuf")) {
            @compileError(@typeName(T) ++ " needs a field number table:\n" ++
                "    pub const protobuf: pb.Descriptor(@This()) = .{ ... };");
        }
        const specs = @field(T, "protobuf");
        if (@TypeOf(specs) != Descriptor(T)) {
            @compileError(@typeName(T) ++ ".protobuf must be declared as:\n" ++
                "    pub const protobuf: pb.Descriptor(@This()) = .{ ... };");
        }

        const s = type_info.@"struct";
        var fields: [s.field_names.len]Field = undefined;

        for (s.field_names, s.field_types, s.field_attrs, 0..) |name, Ty, attrs, i| {
            if (attrs.@"comptime") {
                @compileError(@typeName(T) ++ "." ++ name ++ " is a comptime field, which is not a message field");
            }
            if (attrs.defaultValue(Ty) == null) {
                @compileError(@typeName(T) ++ "." ++ name ++ " needs a default value. " ++
                    "An absent protobuf field decodes as its default, so the default is part of the schema.");
            }
            fields[i] = normalizeField(T, Ty, name, @field(specs, name));
        }

        for (fields, 0..) |f, i| {
            for (fields[i + 1 ..]) |other| {
                if (f.number == other.number) {
                    @compileError(@typeName(T) ++ "." ++ f.name ++ " and " ++ other.name ++
                        " both claim field number " ++ std.fmt.comptimePrint("{d}", .{f.number}));
                }
            }
        }

        // A message-typed field must itself be a message, and the error should
        // point at this struct, not at the decode call that reached it.
        for (fields) |f| switch (f.elem) {
            .message => |M| {
                if (!@hasDecl(M, "protobuf")) {
                    @compileError(f.name ++ " of " ++ @typeName(T) ++ " is not a message: " ++
                        @typeName(M) ++ " has no `pub const protobuf` table");
                }
                _ = info(M);
            },
            else => {},
        };

        const final = fields;
        return .{ .fields = &final };
    }
}

/// A message with every field at its declared default, or at its type's zero
/// where it declares none. Decode starts here, so an absent field lands on the
/// value the schema says it should.
pub fn init(comptime T: type) T {
    const s = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (s.field_names, s.field_types, s.field_attrs) |name, Ty, attrs| {
        @field(out, name) = attrs.defaultValue(Ty) orelse zero(Ty);
    }
    return out;
}

/// The protobuf zero value for a field type: what an absent field means when
/// the struct does not declare a default.
fn zero(comptime Ty: type) Ty {
    return switch (@typeInfo(Ty)) {
        .bool => false,
        .int => 0,
        .float => 0,
        .@"enum" => std.enums.fromInt(Ty, 0) orelse
            @compileError(@typeName(Ty) ++ " is an enum with no zero tag, " ++
                "so an absent field of that type has no value"),
        .optional => null,
        .pointer => &.{},
        .@"struct" => init(Ty),
        else => @compileError(@typeName(Ty) ++ " has no protobuf zero value"),
    };
}

fn normalizeField(comptime T: type, comptime Ty: type, comptime name: [:0]const u8, spec: FieldDescriptor) Field {
    comptime {
        const where = @typeName(T) ++ "." ++ name;
        var E = Ty;
        var optional = false;
        if (@typeInfo(E) == .optional) {
            optional = true;
            E = @typeInfo(E).optional.child;
            if (@typeInfo(E) == .optional) {
                @compileError(where ++ " is a double optional; a field is either present or not");
            }
        }

        var repeated = false;
        var is_bytes = false;
        if (@typeInfo(E) == .pointer) {
            const p = @typeInfo(E).pointer;
            if (p.size == .slice) {
                if (p.child == u8 and p.attrs.@"const" and p.sentinel_ptr == null) {
                    is_bytes = true;
                } else {
                    repeated = true;
                    E = p.child;
                }
            }
        }

        const elem: Elem = if (is_bytes) switch (spec.encoding) {
            .auto => @compileError(where ++ " is a []const u8, and the wire cannot tell a string " ++
                "from bytes. Say pb.string(n) or pb.bytes(n)."),
            .string => .string,
            .bytes => .bytes,
            else => @compileError(where ++ " is a []const u8 and cannot use ." ++ @tagName(spec.encoding)),
        } else resolve(E, where, spec.encoding);

        if (optional and repeated) {
            @compileError(where ++ " is an optional repeated field; protobuf has no presence for repeated fields, " ++
                "and an absent field and an empty one are the same bytes");
        }

        const numeric = switch (elem) {
            .scalar, .@"enum" => true,
            .string, .bytes, .message => false,
        };
        const is_packed = if (repeated)
            spec.@"packed" orelse numeric
        else blk: {
            if (spec.@"packed" != null) @compileError(where ++ " is not repeated, so it cannot be packed");
            break :blk false;
        };
        if (is_packed and !numeric) {
            @compileError(where ++ " is a repeated " ++ @tagName(elem) ++ " field, which cannot be packed");
        }
        if (spec.number < 1 or spec.number > 0x1FFFFFFF) {
            @compileError(where ++ " has field number out of range 1..2^29-1");
        }

        return .{
            .name = name,
            .number = spec.number,
            .optional = optional,
            .repeated = repeated,
            .is_packed = is_packed,
            .type = Ty,
            .elem = elem,
        };
    }
}

fn resolve(comptime E: type, comptime where: []const u8, comptime encoding: Encoding) Elem {
    const type_info = @typeInfo(E);
    return switch (type_info) {
        .bool => blk: {
            if (encoding != .auto) @compileError(where ++ " is a bool, which has no encoding");
            break :blk .{ .scalar = .bool };
        },
        .float => |f| blk: {
            if (encoding != .auto) @compileError(where ++ " is a float, which has no encoding");
            break :blk switch (f.bits) {
                32 => .{ .scalar = .float },
                64 => .{ .scalar = .double },
                else => @compileError(where ++ " is f" ++ std.fmt.comptimePrint("{d}", .{f.bits}) ++
                    ", and protobuf has only float and double"),
            };
        },
        .int => |i| blk: {
            const signed = i.signedness == .signed;
            const scalar: wire.Scalar = switch (i.bits) {
                32 => if (signed) switch (encoding) {
                    .auto => .i32,
                    .sint => .sint32,
                    .fixed => .sfixed32,
                    else => @compileError(badEncoding(where, encoding)),
                } else switch (encoding) {
                    .auto => .u32,
                    .fixed => .fixed32,
                    else => @compileError(badEncoding(where, encoding)),
                },
                64 => if (signed) switch (encoding) {
                    .auto => .i64,
                    .sint => .sint64,
                    .fixed => .sfixed64,
                    else => @compileError(badEncoding(where, encoding)),
                } else switch (encoding) {
                    .auto => .u64,
                    .fixed => .fixed64,
                    else => @compileError(badEncoding(where, encoding)),
                },
                else => @compileError(where ++ " is " ++ std.fmt.comptimePrint("{d}", .{i.bits}) ++
                    "-bit, and protobuf has only 32-bit and 64-bit integers"),
            };
            break :blk .{ .scalar = scalar };
        },
        .@"enum" => |e| blk: {
            if (encoding != .auto) @compileError(where ++ " is an enum, which has no encoding");
            if (@typeInfo(e.tag_type) != .int or @typeInfo(e.tag_type).int.bits != 32 or
                @typeInfo(e.tag_type).int.signedness != .signed)
            {
                @compileError(where ++ " must be an enum(i32); protobuf enums are int32 values");
            }
            break :blk .{ .@"enum" = E };
        },
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8 and p.attrs.@"const" and p.sentinel_ptr == null) {
                break :blk switch (encoding) {
                    .auto => @compileError(where ++ " is a []const u8, and the wire cannot tell a string " ++
                        "from bytes. Say pb.string(n) or pb.bytes(n)."),
                    .string => .string,
                    .bytes => .bytes,
                    else => @compileError(badEncoding(where, encoding)),
                };
            }
            @compileError(where ++ " is " ++ @typeName(E) ++ ". The only pointer a field can be is []const u8.");
        },
        .@"struct" => blk: {
            if (encoding != .auto) @compileError(where ++ " is a message, which has no encoding");
            break :blk .{ .message = E };
        },
        else => @compileError(where ++ " is " ++ @typeName(E) ++ ", which the protobuf wire format cannot carry"),
    };
}

fn badEncoding(comptime where: []const u8, comptime encoding: Encoding) []const u8 {
    return where ++ " cannot use ." ++ @tagName(encoding) ++ " with its Zig type";
}

test "field table" {
    const Inner = struct {
        pub const protobuf: Descriptor(@This()) = .{ .n = field(1) };

        n: u32 = 0,
    };

    const Person = struct {
        pub const protobuf: Descriptor(@This()) = .{
            .name = string(2),
            .id = field(1),
            .delta = sint(3),
            .tags = string(4),
            .inner = field(5),
            .blob = bytes(6),
            .nick = string(7),
            .scores = unpacked(8),
        };

        name: []const u8 = "",
        id: u64 = 0,
        delta: i32 = 0,
        tags: []const []const u8 = &.{},
        inner: Inner = .{},
        blob: []const u8 = "",
        nick: ?[]const u8 = null,
        scores: []const i32 = &.{},
    };

    const fields = comptime info(Person).fields;
    try std.testing.expectEqual(8, fields.len);

    // A helper and a literal say the same thing.
    const Helper = struct {
        pub const protobuf: Descriptor(@This()) = .{ .a = sint(3), .b = sint(4) };
        a: i32 = 0,
        b: i32 = 0,
    };
    const helper_fields = comptime info(Helper).fields;
    try std.testing.expectEqual(@as(u32, 3), helper_fields[0].number);
    try std.testing.expectEqual(wire.Scalar.sint32, helper_fields[0].elem.scalar);
    try std.testing.expectEqual(helper_fields[0].number, helper_fields[1].number - 1);
    try std.testing.expectEqual(helper_fields[0].elem.scalar, helper_fields[1].elem.scalar);

    // Declaration order is encode order, and the numbers are the table's, not
    // the position's.
    try std.testing.expectEqualStrings("name", fields[0].name);
    try std.testing.expectEqual(2, fields[0].number);
    try std.testing.expectEqualStrings("id", fields[1].name);
    try std.testing.expectEqual(1, fields[1].number);

    try std.testing.expectEqual(wire.Scalar.sint32, fields[2].elem.scalar);
    try std.testing.expect(fields[3].repeated);
    try std.testing.expect(std.meta.activeTag(fields[3].elem) == .string);
    try std.testing.expect(std.meta.activeTag(fields[4].elem) == .message);
    try std.testing.expect(std.meta.activeTag(fields[5].elem) == .bytes);
    try std.testing.expect(fields[6].optional);
    try std.testing.expect(!fields[6].repeated);
    try std.testing.expect(fields[7].repeated);
    try std.testing.expect(!fields[7].is_packed);
    try std.testing.expectEqual(wire.WireType.varint, fields[7].wireType());
}
