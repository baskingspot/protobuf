//! Reading a message from the wire format.
//!
//! Decode writes into a destination as it walks, so a message with no repeated
//! fields allocates nothing. Strings and bytes borrow from the input, which is
//! why the caller must keep the input alive as long as the value.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const proto = @import("proto.zig");
const Reader = @import("Reader.zig");
const Field = Reader.Field;
const wire = @import("wire.zig");

pub const Error = wire.Error || Allocator.Error || error{
    /// A varint held a value the field's enum has no tag for.
    UnknownEnumValue,
};

pub const Options = struct {
    /// Reject bytes in a `string` field that are not valid UTF-8. Proto3 says
    /// a `string` is UTF-8, and a `bytes` field is never checked.
    validate_utf8: bool = true,
};

/// A decoded message and the arena behind it.
///
/// Strings, bytes, and every nested message borrow from the bytes that were
/// decoded, so the input must outlive this. The arena holds repeated fields
/// and nothing else.
pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: ArenaAllocator,
        value: T,

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Decode one message from `bytes`.
pub fn decode(comptime T: type, gpa: Allocator, bytes: []const u8, options: Options) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();

    var io: Io.Reader = .fixed(bytes);
    var r: Reader = .init(&io);
    var ctx: Ctx = .{ .gpa = parsed.arena.allocator(), .options = options };
    parsed.value = proto.init(T);
    try readMessage(&ctx, &r, T, &parsed.value);
    return parsed;
}

/// Decode into memory the caller already owns. The returned value owns
/// nothing; the arena has to live as long as the value.
pub fn decodeLeaky(comptime T: type, gpa: Allocator, bytes: []const u8, options: Options) Error!T {
    var io: Io.Reader = .fixed(bytes);
    var r: Reader = .init(&io);
    var ctx: Ctx = .{ .gpa = gpa, .options = options };
    var value: T = proto.init(T);
    try readMessage(&ctx, &r, T, &value);
    return value;
}

const Ctx = struct {
    gpa: Allocator,
    options: Options,
};

fn readMessage(ctx: *Ctx, r: *Reader, comptime T: type, dst: *T) Error!void {
    const fields = comptime proto.info(T).fields;
    while (try r.next()) |field| {
        var handled = false;
        inline for (fields) |f| {
            if (field.fieldNumber() == f.number) {
                handled = true;
                try readField(ctx, T, f, dst, field);
            }
        }
        // An unknown number, or a known number with a wire type the field does
        // not take, is skipped. That is what the reference parsers do.
        if (!handled) try skip(field);
    }
}

fn skip(field: Field) Error!void {
    switch (field) {
        .len => |len| try len.skip(),
        // Varint and fixed payloads were consumed when the field was read.
        else => {},
    }
}

fn readField(ctx: *Ctx, comptime T: type, comptime f: proto.Field, dst: *T, field: Field) Error!void {
    const expected = proto.elemWireType(f.elem);
    const packed_arrival = f.repeated and field.wireType() == .len and expected != .len;
    if (field.wireType() != expected and !packed_arrival) return skip(field);

    if (comptime f.repeated) return readRepeated(ctx, T, f, dst, field);

    if (comptime f.elem == .message) {
        const M = f.elem.message;
        var nested = try field.expect(.len).message();
        if (comptime f.optional) {
            if (@field(dst, f.name) == null) @field(dst, f.name) = proto.init(M);
            if (@field(dst, f.name)) |*present| try readMessage(ctx, &nested, M, present);
        } else {
            try readMessage(ctx, &nested, M, &@field(dst, f.name));
        }
        return;
    }

    try assignScalar(ctx, f.elem, field, &@field(dst, f.name));
}

/// Read one value of `elem` and store it, letting an optional field take it
/// through the coercion.
fn assignScalar(ctx: *Ctx, comptime elem: proto.Elem, field: Field, out: anytype) Error!void {
    switch (elem) {
        .scalar => |scalar| out.* = readScalar(field, scalar),
        .@"enum" => |E| {
            const tag = field.expect(.varint).as(.i32);
            out.* = std.enums.fromInt(E, tag) orelse return Error.UnknownEnumValue;
        },
        .string, .bytes => {
            const borrowed = try field.expect(.len).data();
            if (elem == .string and ctx.options.validate_utf8 and !std.unicode.utf8ValidateSlice(borrowed)) {
                return error.InvalidUtf8;
            }
            out.* = borrowed;
        },
        .message => unreachable,
    }
}

fn readScalar(field: Field, comptime scalar: wire.Scalar) wire.Scalar.Type(scalar) {
    return switch (comptime proto.scalarWireType(scalar)) {
        .varint => field.expect(.varint).as(scalar),
        .fixed32 => field.expect(.fixed32).as(scalar),
        .fixed64 => field.expect(.fixed64).as(scalar),
        .len => unreachable,
    };
}

fn readRepeated(ctx: *Ctx, comptime T: type, comptime f: proto.Field, dst: *T, field: Field) Error!void {
    const E = FieldElementType(f);
    var list: std.ArrayList(E) = .empty;
    defer list.deinit(ctx.gpa);
    // Seed from what earlier occurrences of this field already put here.
    try list.appendSlice(ctx.gpa, @field(dst, f.name));

    const numeric = comptime switch (f.elem) {
        .scalar, .@"enum" => true,
        else => false,
    };
    if (comptime f.elem == .message) {
        try appendMessage(ctx, E, &list, field);
    } else if (comptime numeric) {
        if (field.wireType() == .len and proto.elemWireType(f.elem) != .len) {
            try appendPacked(ctx, E, f, &list, field);
        } else {
            try appendOne(ctx, E, f, &list, field);
        }
    } else {
        try appendOne(ctx, E, f, &list, field);
    }

    @field(dst, f.name) = try list.toOwnedSlice(ctx.gpa);
}

fn appendMessage(ctx: *Ctx, comptime E: type, list: *std.ArrayList(E), field: Field) Error!void {
    var nested = try field.expect(.len).message();
    var element: E = proto.init(E);
    try readMessage(ctx, &nested, E, &element);
    try list.append(ctx.gpa, element);
}

fn appendOne(ctx: *Ctx, comptime E: type, comptime f: proto.Field, list: *std.ArrayList(E), field: Field) Error!void {
    var element: E = undefined;
    try assignScalar(ctx, f.elem, field, &element);
    try list.append(ctx.gpa, element);
}

fn appendPacked(
    ctx: *Ctx,
    comptime E: type,
    comptime f: proto.Field,
    list: *std.ArrayList(E),
    field: Field,
) Error!void {
    const payload = try field.expect(.len).data();
    var iterator: Field.Len.PackedIterator(E, packedEncoding(f.elem)) = .{
        .data = payload,
        .pos = 0,
    };
    while (try iterator.next()) |element| try list.append(ctx.gpa, element);
}

fn FieldElementType(comptime f: proto.Field) type {
    return switch (f.elem) {
        .scalar => |s| wire.Scalar.Type(s),
        .@"enum" => |E| E,
        .string, .bytes => []const u8,
        .message => |M| M,
    };
}

fn packedEncoding(comptime elem: proto.Elem) wire.Encoding {
    return switch (elem) {
        .scalar => |s| proto.scalarPacked(s),
        .@"enum" => .varint,
        else => @compileError("only numbers pack"),
    };
}
