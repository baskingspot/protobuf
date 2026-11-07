//! Reading a message from the wire format.
//!
//! Decode writes into a destination as it walks, so a message whose repeated
//! fields and strings are absent allocates nothing from the arena.
//!
//! Where strings and bytes end up depends on what is being read. A reader can
//! refill its buffer between fields, so a slice into it would not survive the
//! next read: decoding from a reader copies each one into the arena.
//! Decoding from a complete slice borrows instead, because the bytes are not
//! going anywhere, and then the caller must keep the slice alive.

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
/// `decodeFromSlice` borrows every string and byte slice from the input, so
/// that slice must outlive this. `decode` copies them, so the reader may be a
/// socket or a file and the value owns everything it points at.
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

/// Decode one message from a reader, copying every string and byte slice into
/// the arena. The reader may be a socket, a file, or a slice.
pub fn decode(comptime T: type, gpa: Allocator, reader: *Io.Reader, options: Options) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();

    const ctx: Ctx = .{ .gpa = parsed.arena.allocator(), .options = options, .copy = true };
    parsed.value = try read(ctx, reader, T);
    return parsed;
}

/// Decode one message from a reader into memory the caller already owns. The
/// returned value owns nothing; the allocator has to live as long as the
/// value, and an arena is the only sane choice.
pub fn decodeLeaky(comptime T: type, gpa: Allocator, reader: *Io.Reader, options: Options) Error!T {
    const ctx: Ctx = .{ .gpa = gpa, .options = options, .copy = true };
    return read(ctx, reader, T);
}

/// Decode one message from a slice, borrowing every string and byte slice from
/// it. `bytes` must outlive the value.
pub fn decodeFromSlice(comptime T: type, gpa: Allocator, bytes: []const u8, options: Options) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();

    var io: Io.Reader = .fixed(bytes);
    const ctx: Ctx = .{ .gpa = parsed.arena.allocator(), .options = options, .copy = false };
    parsed.value = try read(ctx, &io, T);
    return parsed;
}

/// The borrowing decode, into memory the caller already owns.
pub fn decodeFromSliceLeaky(comptime T: type, gpa: Allocator, bytes: []const u8, options: Options) Error!T {
    var io: Io.Reader = .fixed(bytes);
    const ctx: Ctx = .{ .gpa = gpa, .options = options, .copy = false };
    return read(ctx, &io, T);
}

fn read(ctx: Ctx, io: *Io.Reader, comptime T: type) Error!T {
    var local = ctx;
    var r: Reader = .init(io);
    var value: T = proto.init(T);
    try readMessage(&local, &r, T, &value);
    return value;
}

const Ctx = struct {
    gpa: Allocator,
    options: Options,
    /// Copy strings and bytes into the arena instead of borrowing them from
    /// the input. A reader has to, a complete slice does not.
    copy: bool,
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
            const payload = try payloadBytes(ctx, field.expect(.len));
            if (elem == .string and ctx.options.validate_utf8 and !std.unicode.utf8ValidateSlice(payload)) {
                return error.InvalidUtf8;
            }
            out.* = payload;
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
    const payload = try payloadBytes(ctx, field.expect(.len));
    var iterator: Field.Len.PackedIterator(E, packedEncoding(f.elem)) = .{
        .data = payload,
        .pos = 0,
    };
    while (try iterator.next()) |element| try list.append(ctx.gpa, element);
}

/// The bytes of a length-delimited field, borrowed or copied depending on the
/// source.
fn payloadBytes(ctx: *Ctx, len: Field.Len) Error![]const u8 {
    return if (ctx.copy) len.bytesAlloc(ctx.gpa) else len.data();
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
