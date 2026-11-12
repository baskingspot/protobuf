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

/// Every error a decode can return: the wire errors, allocator failure, and
/// an enum value with no tag.
pub const Error = wire.Error || Allocator.Error || error{
    /// A varint held a value the field's enum has no tag for.
    UnknownEnumValue,
};

/// Options for `decode` and its variants.
pub const Options = struct {
    /// Reject bytes in a `string` field that are not valid UTF-8. Proto3 says
    /// a `string` is UTF-8, and a `bytes` field is never checked.
    validate_utf8: bool = true,
};

/// A decoded message and the arena behind it.
///
/// `decodeFromSlice` borrows strings and byte slices from the input.
/// The input must outlive the result. The arena owns repeated-field arrays.
/// `decode` copies strings and bytes into the arena. Its reader can use a
/// socket or a file.
pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: ArenaAllocator,
        value: T,

        /// Free the arena.
        ///
        /// This does not free the input passed to `decodeFromSlice`.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// `decode` reads one message and copies strings and bytes into an arena.
/// The arena also owns repeated-field arrays. The reader can use a socket,
/// a file, or a slice.
pub fn decode(
    comptime T: type,
    gpa: Allocator,
    reader: *Io.Reader,
    options: Options,
) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();

    const ctx: Ctx = .{ .gpa = parsed.arena.allocator(), .options = options, .copy = true };
    parsed.value = try read(ctx, reader, T);
    return parsed;
}

/// Decode one message from a reader into memory the caller owns. Strings and
/// bytes are copied, and repeated fields are allocated, from `gpa`. The value
/// has no arena and no `deinit`: free the allocations, or pass an arena that
/// outlives it.
pub fn decodeLeaky(comptime T: type, gpa: Allocator, reader: *Io.Reader, options: Options) Error!T {
    const ctx: Ctx = .{ .gpa = gpa, .options = options, .copy = true };
    return read(ctx, reader, T);
}

/// Decode one message from a slice, borrowing every string and byte slice from
/// it. `bytes` must outlive the value. Repeated fields are allocated from the
/// arena.
pub fn decodeFromSlice(
    comptime T: type,
    gpa: Allocator,
    bytes: []const u8,
    options: Options,
) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();

    var io: Io.Reader = .fixed(bytes);
    const ctx: Ctx = .{ .gpa = parsed.arena.allocator(), .options = options, .copy = false };
    parsed.value = try read(ctx, &io, T);
    return parsed;
}

/// `decodeFromSliceLeaky` borrows strings and bytes from `bytes`.
/// The input must outlive the value. Repeated-field arrays use `gpa`.
/// The value has no arena and no `deinit`.
pub fn decodeFromSliceLeaky(
    comptime T: type,
    gpa: Allocator,
    bytes: []const u8,
    options: Options,
) Error!T {
    var io: Io.Reader = .fixed(bytes);
    const ctx: Ctx = .{ .gpa = gpa, .options = options, .copy = false };
    return read(ctx, &io, T);
}

/// Decode one message from a slice, borrowing every string and byte slice
/// from it, allocating nothing. `T` must have no repeated field, at any
/// depth, because an array needs an allocator: that is a compile-time error
/// here. `bytes` must outlive the value, which for a message read from a
/// stream is until the next read. The value has no arena and no `deinit`.
/// A message that passes the compile-time check cannot fail with
/// `error.OutOfMemory`.
pub fn decodeBorrowed(comptime T: type, bytes: []const u8, options: Options) Error!T {
    comptime assertNoRepeated(T, "decodeBorrowed: " ++ @typeName(T));
    var io: Io.Reader = .fixed(bytes);
    const ctx: Ctx = .{ .gpa = no_allocator, .options = options, .copy = false };
    return read(ctx, &io, T);
}

/// `decodeBorrowed`'s half of the contract: no field anywhere in `T` needs
/// an array.
fn assertNoRepeated(comptime T: type, comptime where: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError(where ++ " is not a message struct"),
    }
    if (comptime proto.unknownFieldName(T)) |name| {
        @compileError(where ++ " has the field '" ++ name ++ "', typed " ++
            @typeName(proto.Unknown) ++ ", which needs an array of every skipped " ++
            "field. Use decodeFromSliceLeaky.");
    }
    for (comptime proto.info(T).fields) |f| {
        if (f.repeated) {
            @compileError(where ++ " has the repeated field '" ++ f.name ++
                "', which needs an array. Use decodeFromSliceLeaky.");
        }
        switch (f.elem) {
            .message => |M| assertNoRepeated(M, where ++ "." ++ f.name),
            else => {},
        }
    }
}

/// An allocator that refuses every request.
///
/// A message that passed `assertNoRepeated` never asks for memory, so
/// `decodeBorrowed` gives its `Ctx` this instead of a real allocator. A path
/// that asks anyway fails with `error.OutOfMemory`, in the error set it
/// already has, rather than taking memory a caller did not provide.
///
/// `Allocator` documents that `ptr` may be `undefined` when an allocator has no
/// state, and that comparing it is illegal.
const no_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = Allocator.noAlloc,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = Allocator.noFree,
    },
};

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
        var claimed = false;
        inline for (fields) |f| {
            if (field.fieldNumber() == f.number) {
                claimed = true;
                if (!try readField(ctx, T, f, dst, field)) {
                    try captureUnknown(ctx, T, dst, field);
                }
            }
        }
        // An unknown number, or a known number with a wire type the field does
        // not take, is skipped. A message with an `Unknown` field keeps it
        // instead, so the next encode writes it back.
        if (!claimed) try captureUnknown(ctx, T, dst, field);
    }
}

fn skip(field: Field) Error!void {
    switch (field) {
        .len => |len| try len.skip(),
        // Varint and fixed payloads were consumed when the field was read.
        else => {},
    }
}

/// Keep a field the message did not recognize, when the message declares an
/// `Unknown` field. Without one the field is skipped, the way the reference
/// parsers drop what they have no schema for.
fn captureUnknown(ctx: *Ctx, comptime T: type, dst: *T, field: Field) Error!void {
    if (comptime !proto.hasUnknown(T)) return skip(field);

    const record = try unknownRecord(ctx, field);
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, Ty| {
        if (Ty == proto.Unknown) {
            var list: std.ArrayList(proto.Unknown.Record) = .empty;
            defer list.deinit(ctx.gpa);
            try list.appendSlice(ctx.gpa, @field(dst, name).records);
            try list.append(ctx.gpa, record);
            @field(dst, name) = .{ .records = try list.toOwnedSlice(ctx.gpa) };
        }
    }
}

/// One skipped field, as the wire value it arrived as.
fn unknownRecord(ctx: *Ctx, field: Field) Error!proto.Unknown.Record {
    return switch (field) {
        .varint => |f| .{ .varint = .{ .number = f.field_number, .value = f.value } },
        .fixed64 => |f| .{ .fixed64 = .{ .number = f.field_number, .value = f.value } },
        .fixed32 => |f| .{ .fixed32 = .{ .number = f.field_number, .value = f.value } },
        .len => |f| .{ .len = .{
            .number = f.field_number,
            .bytes = try payloadBytes(ctx, f),
        } },
    };
}

/// Read `field` into `dst`. Returns false, without consuming the field, when
/// the wire type is one the field does not accept: the caller keeps it as an
/// unknown field or skips it.
fn readField(
    ctx: *Ctx,
    comptime T: type,
    comptime f: proto.Field,
    dst: *T,
    field: Field,
) Error!bool {
    const expected = proto.elemWireType(f.elem);
    const packed_arrival = f.repeated and field.wireType() == .len and expected != .len;
    if (field.wireType() != expected and !packed_arrival) return false;

    if (comptime f.repeated) {
        try readRepeated(ctx, T, f, dst, field);
        return true;
    }

    if (comptime f.elem == .message) {
        const M = f.elem.message;
        var nested = try field.expect(.len).message();
        if (comptime f.optional) {
            if (@field(dst, f.name) == null) @field(dst, f.name) = proto.init(M);
            if (@field(dst, f.name)) |*present| try readMessage(ctx, &nested, M, present);
        } else {
            try readMessage(ctx, &nested, M, &@field(dst, f.name));
        }
        return true;
    }

    @field(dst, f.name) = try scalarValue(ctx, f.elem, field);
    return true;
}

/// Read one value of `elem`. An optional field takes it through the coercion
/// at the assignment above.
fn scalarValue(ctx: *Ctx, comptime elem: proto.Elem, field: Field) Error!proto.ElemType(elem) {
    return switch (elem) {
        .scalar => |scalar| readScalar(field, scalar),
        .@"enum" => |E| blk: {
            const tag = field.expect(.varint).as(.i32);
            break :blk std.enums.fromInt(E, tag) orelse return Error.UnknownEnumValue;
        },
        .string, .bytes => blk: {
            const payload = try payloadBytes(ctx, field.expect(.len));
            if (elem == .string and ctx.options.validate_utf8 and
                !std.unicode.utf8ValidateSlice(payload))
            {
                return error.InvalidUtf8;
            }
            break :blk payload;
        },
        .message => unreachable,
    };
}

fn readScalar(field: Field, comptime scalar: wire.Scalar) wire.Scalar.Type(scalar) {
    return switch (comptime proto.scalarWireType(scalar)) {
        .varint => field.expect(.varint).as(scalar),
        .fixed32 => field.expect(.fixed32).as(scalar),
        .fixed64 => field.expect(.fixed64).as(scalar),
        .len => unreachable,
    };
}

fn readRepeated(
    ctx: *Ctx,
    comptime T: type,
    comptime f: proto.Field,
    dst: *T,
    field: Field,
) Error!void {
    const E = proto.ElemType(f.elem);
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

fn appendOne(
    ctx: *Ctx,
    comptime E: type,
    comptime f: proto.Field,
    list: *std.ArrayList(E),
    field: Field,
) Error!void {
    const element = try scalarValue(ctx, f.elem, field);
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

fn packedEncoding(comptime elem: proto.Elem) wire.Encoding {
    return switch (elem) {
        .scalar => |s| proto.scalarPacked(s),
        .@"enum" => .varint,
        else => @compileError("only numbers pack"),
    };
}
