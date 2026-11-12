//! The proto3 JSON form of a message.
//!
//! The same `Descriptor` table that drives the binary encoder drives this one,
//! so a message has one schema and two encodings. JSON is what a gateway, a
//! browser, or `curl` can read; the binary form is what goes on the wire.
//!
//! ```zig
//! try pb.json.encode(Person, person, .{}, &io);
//! var parsed = try pb.json.decode(Person, json_bytes, .{}, gpa);
//! defer parsed.deinit();
//! ```
//!
//! The rules this follows are the proto3 JSON mapping:
//!
//! - A field name is written in lowerCamelCase, and a camelCase name and the
//!   original name are both accepted on the way in.
//! - A 64-bit integer is a JSON string, because JSON numbers lose precision
//!   above 2^53. A 32-bit integer is a number. Both accept a number or a
//!   string when parsing.
//! - `bytes` is standard base64. The parser also accepts the URL-safe
//!   alphabet and missing padding.
//! - An enum is its name, and a number is accepted. A number with no member is
//!   `error.UnknownEnumTag`, the same way the binary decoder refuses it.
//! - A `float` is a number, and `NaN`, `Infinity`, and `-Infinity` are the
//!   strings of those names.
//! - A field that holds its default and has no presence is not written.
//! - A key that no field claims is `error.UnknownField`, unless
//!   `Options.ignore_unknown_fields` is set.
//! - A well-known type has its own form: a `Timestamp` is RFC 3339, a
//!   `Duration` is `"3.5s"`, a wrapper is the bare value, a `FieldMask` is a
//!   comma-separated string, and `Empty` is `{}`.
//!
//! Two places differ from the reference parsers, and both are honest limits:
//! a duplicate key takes the last value instead of failing, and the binary
//! decoder's rules apply to numbers (a value that does not fit its field is an
//! error, never a truncation).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;

const proto = @import("proto.zig");
const wire = @import("wire.zig");
const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");
const wkt = @import("wkt.zig");

/// Options for `encode`, `decode`, and `decodeLeaky`.
pub const Options = struct {
    /// Write the Zig field names instead of their lowerCamelCase JSON names.
    /// The parser accepts either spelling whatever this is set to.
    use_proto_names: bool = false,
    /// Accept an object key that no field claims instead of failing with
    /// `error.UnknownField`. The value behind it is skipped.
    ignore_unknown_fields: bool = false,
};

/// Every error a JSON codec returns: the scanner's, the allocator's, and the
/// mapping's own.
pub const Error = Scanner.AllocError || Allocator.Error || error{
    /// An object key that no field claims, with `ignore_unknown_fields` off.
    UnknownField,
    /// A number that the field's enum has no member for.
    UnknownEnumTag,
    /// A string in a `bytes` field that is not base64.
    InvalidBase64,
    /// A value the field cannot hold: a number out of range, a timestamp that
    /// is not a date, a duration with two signs.
    InvalidValue,
    /// A token in a place the schema does not allow it.
    UnexpectedToken,
    /// A streaming scanner that ran out of buffer. The complete-input scanner
    /// this package uses does not return it.
    BufferUnderrun,
};

/// A decoded message and the arena behind it.
pub const Parsed = decode_mod.Parsed;

/// Write `value` as proto3 JSON.
pub fn encode(comptime T: type, value: T, options: Options, writer: *Io.Writer) !void {
    var e: Encoder = .{ .io = writer, .options = options };
    try e.message(T, value);
}

/// Read one JSON message, copying every string and array into an arena. Free
/// the result with `Parsed.deinit`.
pub fn decode(
    comptime T: type,
    bytes: []const u8,
    options: Options,
    gpa: Allocator,
) Error!Parsed(T) {
    var parsed: Parsed(T) = .{ .arena = .init(gpa), .value = undefined };
    errdefer parsed.arena.deinit();
    var d: Decoder = .{
        .scanner = .initCompleteInput(parsed.arena.allocator(), bytes),
        .gpa = parsed.arena.allocator(),
        .options = options,
    };
    defer d.scanner.deinit();
    parsed.value = try d.read(T);
    try d.end();
    return parsed;
}

/// Read one JSON message into allocations the caller owns. Free them, or pass
/// an allocator that outlives the value.
pub fn decodeLeaky(comptime T: type, bytes: []const u8, options: Options, gpa: Allocator) Error!T {
    var d: Decoder = .{
        .scanner = .initCompleteInput(gpa, bytes),
        .gpa = gpa,
        .options = options,
    };
    defer d.scanner.deinit();
    const value = try d.read(T);
    try d.end();
    return value;
}

/// The lowerCamelCase name the JSON form writes for a field, and the parser
/// accepts beside the original: `user_id` is `userId`.
fn jsonName(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        var len: usize = 0;
        var upper = false;
        for (name) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            buf[len] = if (upper) std.ascii.toUpper(c) else c;
            len += 1;
            upper = false;
        }
        const final = buf[0..len].*;
        return &final;
    }
}

/// Whether `name` is how a field named `proto_name` is spelled in JSON. Both
/// spellings are always accepted: `use_proto_names` only affects output.
fn matches(comptime proto_name: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, proto_name, name) or
        std.mem.eql(u8, comptime jsonName(proto_name), name);
}

/// Two fields whose JSON names collide would make one of them unreachable:
/// `user_id` and `userId` both answer to `userId`.
fn assertDistinctNames(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(10_000);
        const fields = proto.info(T).fields;
        for (fields, 0..) |a, i| {
            for (fields[i + 1 ..]) |b| {
                if (std.mem.eql(u8, jsonName(a.name), jsonName(b.name))) {
                    @compileError(@typeName(T) ++ "." ++ a.name ++ " and " ++ b.name ++
                        " both answer to the JSON name " ++ jsonName(a.name));
                }
            }
            switch (a.elem) {
                .oneof => |U| {
                    const cases = proto.variants(U).fields;
                    for (cases, 0..) |c, ci| {
                        // A case shares the object with every field, and with
                        // its own siblings.
                        for (fields) |other| {
                            if (other.number != 0 and
                                std.mem.eql(u8, jsonName(c.name), jsonName(other.name)))
                            {
                                @compileError(@typeName(U) ++ "." ++ c.name ++
                                    " and " ++ @typeName(T) ++ "." ++ other.name ++
                                    " both answer to the JSON name " ++ jsonName(c.name));
                            }
                        }
                        for (cases[ci + 1 ..]) |d| {
                            if (std.mem.eql(u8, jsonName(c.name), jsonName(d.name))) {
                                @compileError(@typeName(U) ++ "." ++ c.name ++ " and " ++ d.name ++
                                    " both answer to the JSON name " ++ jsonName(c.name));
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

const Encoder = struct {
    io: *Io.Writer,
    options: Options,

    fn message(e: *Encoder, T: type, v: T) !void {
        if (comptime wkt.form(T)) |form| return e.special(T, form, v);
        comptime assertDistinctNames(T);

        const fields = comptime proto.info(T).fields;
        try e.io.writeByte('{');
        var first = true;
        inline for (fields) |f| {
            if (comptime f.elem == .oneof) {
                try e.oneof(f, @field(v, f.name), &first);
            } else {
                try e.field(f, @field(v, f.name), &first);
            }
        }
        try e.io.writeByte('}');
    }

    /// One field, unless it has nothing to say: an absent optional, an empty
    /// repeated field, or a default value in a field with no presence.
    fn field(e: *Encoder, comptime f: proto.Field, v: f.type, first: *bool) !void {
        if (comptime f.optional) {
            const present = v orelse return;
            try e.key(f.name, first);
            return e.value(f.elem, present);
        }
        if (comptime f.repeated) {
            if (v.len == 0) return;
            try e.key(f.name, first);
            return e.array(f, v);
        }
        if (!encode_mod.isDefault(v)) {
            try e.key(f.name, first);
            return e.value(f.elem, v);
        }
    }

    /// The case of a oneof that is set. A case is written even when its value
    /// is its type's zero, because the tag is the presence.
    fn oneof(e: *Encoder, comptime f: proto.Field, v: f.type, first: *bool) !void {
        const U = f.elem.oneof;
        const present = v orelse return;
        const tag = std.meta.activeTag(present);
        inline for (comptime proto.variants(U).fields) |case| {
            if (tag == @field(@typeInfo(U).@"union".tag_type.?, case.name)) {
                try e.key(case.name, first);
                try e.value(case.elem, @field(present, case.name));
            }
        }
    }

    fn key(e: *Encoder, comptime name: []const u8, first: *bool) !void {
        if (!first.*) try e.io.writeByte(',');
        first.* = false;
        try e.io.writeByte('"');
        try e.io.writeAll(if (e.options.use_proto_names) name else comptime jsonName(name));
        try e.io.writeAll("\":");
    }

    fn value(e: *Encoder, comptime elem: proto.Elem, v: proto.ElemType(elem)) !void {
        return switch (elem) {
            .scalar => |s| e.scalar(s, v),
            .@"enum" => e.string(@tagName(v)),
            .string => e.string(v),
            .bytes => e.base64(v),
            .message => |M| e.message(M, v),
            .oneof => unreachable,
        };
    }

    fn array(
        e: *Encoder,
        comptime f: proto.Field,
        values: []const proto.ElemType(f.elem),
    ) !void {
        try e.io.writeByte('[');
        for (values, 0..) |element, i| {
            if (i != 0) try e.io.writeByte(',');
            try e.value(f.elem, element);
        }
        try e.io.writeByte(']');
    }

    fn scalar(e: *Encoder, comptime s: wire.Scalar, v: wire.Scalar.Type(s)) !void {
        const V = @TypeOf(v);
        switch (@typeInfo(V)) {
            .int => |int| {
                // A 64-bit integer is a string: JSON numbers stop counting
                // exactly at 2^53.
                if (comptime int.bits == 64) {
                    try e.io.print("\"{d}\"", .{v});
                } else {
                    try e.io.print("{d}", .{v});
                }
            },
            .float => try e.float(V, v),
            .bool => try e.io.writeAll(if (v) "true" else "false"),
            else => unreachable,
        }
    }

    fn float(e: *Encoder, comptime F: type, v: F) !void {
        if (std.math.isNan(v)) return e.string("NaN");
        if (std.math.isInf(v)) return e.string(if (v > 0) "Infinity" else "-Infinity");
        // `{d}` writes a plain decimal, which turns 1e300 into 301 digits.
        // Past the range where a reader expects digits, ask for the exponent.
        const magnitude = @abs(v);
        if (v != 0 and (magnitude >= 1e21 or magnitude < 1e-6)) {
            try e.io.print("{e}", .{v});
        } else {
            try e.io.print("{d}", .{v});
        }
    }

    fn string(e: *Encoder, s: []const u8) !void {
        try std.json.Stringify.value(s, .{}, e.io);
    }

    /// Standard base64, in chunks, so no allocation is needed for the output.
    fn base64(e: *Encoder, bytes: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        try e.io.writeByte('"');
        var buffer: [1024]u8 = undefined;
        var rest = bytes;
        while (rest.len >= 3) {
            const take = @min(rest.len / 3, buffer.len / 4) * 3;
            try e.io.writeAll(encoder.encode(&buffer, rest[0..take]));
            rest = rest[take..];
        }
        if (rest.len > 0) {
            var tail: [4]u8 = undefined;
            try e.io.writeAll(encoder.encode(&tail, rest));
        }
        try e.io.writeByte('"');
    }

    fn special(e: *Encoder, T: type, comptime form: wkt.Form, v: T) !void {
        switch (form) {
            .empty => try e.io.writeAll("{}"),
            .timestamp => {
                try e.io.writeByte('"');
                try wkt.writeTimestamp(e.io, v);
                try e.io.writeByte('"');
            },
            .duration => {
                try e.io.writeByte('"');
                try wkt.writeDuration(e.io, v);
                try e.io.writeByte('"');
            },
            .wrapper => try e.wrapper(T, wkt.wrapped(T).?, v.value),
            .field_mask => try e.fieldMask(v),
        }
    }

    /// A wrapper holds its value bare, with no object around it.
    fn wrapper(e: *Encoder, T: type, V: type, v: V) !void {
        if (comptime V == []const u8) {
            if (comptime wkt.isBytesWrapper(T)) return e.base64(v);
            return e.string(v);
        }
        switch (@typeInfo(V)) {
            .int => |int| if (comptime int.bits == 64)
                try e.io.print("\"{d}\"", .{v})
            else
                try e.io.print("{d}", .{v}),
            .float => try e.float(V, v),
            .bool => try e.io.writeAll(if (v) "true" else "false"),
            else => unreachable,
        }
    }

    /// Field paths are snake_case on the wire and camelCase in JSON.
    fn fieldMask(e: *Encoder, v: wkt.FieldMask) !void {
        try e.io.writeByte('"');
        for (v.paths, 0..) |path, i| {
            if (i != 0) try e.io.writeByte(',');
            var upper = false;
            for (path) |c| {
                if (c == '_') {
                    upper = true;
                    continue;
                }
                try e.io.writeByte(if (upper) std.ascii.toUpper(c) else c);
                upper = false;
            }
        }
        try e.io.writeByte('"');
    }
};

const Decoder = struct {
    scanner: Scanner,
    gpa: Allocator,
    options: Options,

    fn read(d: *Decoder, comptime T: type) Error!T {
        var value: T = proto.init(T);
        try d.readInto(T, &value);
        return value;
    }

    fn readInto(d: *Decoder, comptime T: type, dst: *T) Error!void {
        if (comptime wkt.form(T)) |form| return d.readSpecial(T, form, dst);

        try d.take(.object_begin);
        while (true) {
            const key = try d.next();
            const name: []const u8 = switch (key) {
                .object_end => return,
                .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            defer d.freeToken(key);
            try d.readField(T, name, dst);
        }
    }

    fn readField(d: *Decoder, comptime T: type, name: []const u8, dst: *T) Error!void {
        const fields = comptime proto.info(T).fields;
        inline for (fields) |f| {
            if (comptime f.elem == .oneof) {
                const U = f.elem.oneof;
                inline for (comptime proto.variants(U).fields) |v| {
                    if (matches(v.name, name)) return d.readCase(U, f.name, v, dst);
                }
            } else if (matches(f.name, name)) {
                return d.readValue(f, &@field(dst, f.name));
            }
        }
        if (d.options.ignore_unknown_fields) return d.skip();
        return error.UnknownField;
    }

    fn readCase(
        d: *Decoder,
        comptime U: type,
        comptime field_name: []const u8,
        comptime v: proto.Field,
        dst: anytype,
    ) Error!void {
        const value = try d.element(proto.ElemType(v.elem), v.elem);
        @field(dst, field_name) = @unionInit(U, v.name, value);
    }

    /// `null` is accepted for any field and leaves it as it was, which is the
    /// proto3 JSON rule for a field that is not set.
    fn readValue(d: *Decoder, comptime f: proto.Field, dst: *f.type) Error!void {
        const kind = try d.scanner.peekNextTokenType();
        if (kind == .null) {
            _ = try d.next();
            return;
        }
        if (comptime f.repeated) return d.readArray(f, dst);
        if (comptime f.optional) {
            const E = @typeInfo(f.type).optional.child;
            dst.* = try d.element(E, f.elem);
            return;
        }
        dst.* = try d.element(proto.ElemType(f.elem), f.elem);
    }

    fn readArray(d: *Decoder, comptime f: proto.Field, dst: *f.type) Error!void {
        if (try d.scanner.peekNextTokenType() != .array_begin) return error.UnexpectedToken;
        _ = try d.next();

        const E = proto.ElemType(f.elem);
        var list: std.ArrayList(E) = .empty;
        defer list.deinit(d.gpa);
        while (true) {
            const kind = try d.scanner.peekNextTokenType();
            if (kind == .array_end) {
                _ = try d.next();
                break;
            }
            // A null element has no meaning in a repeated field: there is no
            // presence to clear.
            if (kind == .null) return error.UnexpectedToken;
            try list.append(d.gpa, try d.element(E, f.elem));
        }
        dst.* = try list.toOwnedSlice(d.gpa);
    }

    fn element(d: *Decoder, E: type, comptime elem: proto.Elem) Error!E {
        return switch (elem) {
            .scalar => d.scalar(E),
            .@"enum" => |E1| d.enumValue(E1),
            .string => d.stringValue(),
            .bytes => d.bytesValue(),
            .message => |M| d.message(M),
            .oneof => unreachable,
        };
    }

    fn message(d: *Decoder, comptime M: type) Error!M {
        var value: M = proto.init(M);
        try d.readInto(M, &value);
        return value;
    }

    fn scalar(d: *Decoder, comptime E: type) Error!E {
        const tok = try d.next();
        defer d.freeToken(tok);

        const text: []const u8 = switch (tok) {
            .true => if (comptime E == bool) return true else return error.UnexpectedToken,
            .false => if (comptime E == bool) return false else return error.UnexpectedToken,
            .number, .allocated_number, .string, .allocated_string => |t| t,
            else => return error.UnexpectedToken,
        };

        return switch (@typeInfo(E)) {
            .int => std.fmt.parseInt(E, text, 10) catch error.InvalidValue,
            .float => parseFloatText(E, text),
            .bool => error.UnexpectedToken,
            else => @compileError(@typeName(E) ++ " is not a JSON scalar"),
        };
    }

    fn enumValue(d: *Decoder, comptime E: type) Error!E {
        const tok = try d.next();
        defer d.freeToken(tok);

        switch (tok) {
            .number, .allocated_number => |text| {
                const value = std.fmt.parseInt(@typeInfo(E).@"enum".tag_type, text, 10) catch
                    return error.InvalidValue;
                return std.enums.fromInt(E, value) orelse error.UnknownEnumTag;
            },
            .string, .allocated_string => |text| {
                inline for (@typeInfo(E).@"enum".field_names) |member| {
                    if (std.mem.eql(u8, member, text)) return @field(E, member);
                }
                return error.UnknownEnumTag;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn stringValue(d: *Decoder) Error![]const u8 {
        const tok = try d.next();
        defer d.freeToken(tok);
        const text: []const u8 = switch (tok) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return d.gpa.dupe(u8, text);
    }

    fn bytesValue(d: *Decoder) Error![]const u8 {
        const tok = try d.next();
        defer d.freeToken(tok);
        const text: []const u8 = switch (tok) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return decodeBase64(d.gpa, text);
    }

    fn readSpecial(d: *Decoder, T: type, comptime form: wkt.Form, dst: *T) Error!void {
        switch (form) {
            .empty => {
                try d.take(.object_begin);
                try d.take(.object_end);
            },
            .timestamp => {
                const text = try d.quoted();
                defer d.gpa.free(text);
                dst.* = wkt.parseTimestamp(text) catch return error.InvalidValue;
            },
            .duration => {
                const text = try d.quoted();
                defer d.gpa.free(text);
                dst.* = wkt.parseDuration(text) catch return error.InvalidValue;
            },
            .field_mask => dst.paths = try d.fieldMask(),
            .wrapper => {
                const kind = try d.scanner.peekNextTokenType();
                if (kind == .null) {
                    _ = try d.next();
                    return;
                }
                const V = wkt.wrapped(T).?;
                if (comptime V == []const u8) {
                    dst.value = if (comptime wkt.isBytesWrapper(T))
                        try d.bytesValue()
                    else
                        try d.stringValue();
                } else {
                    dst.value = try d.scalar(V);
                }
            },
        }
    }

    /// A JSON string, copied: the scanner's slice is only good until the next
    /// token, and the caller reads nothing else before it is done.
    fn quoted(d: *Decoder) Error![]const u8 {
        const tok = try d.next();
        defer d.freeToken(tok);
        const text: []const u8 = switch (tok) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return d.gpa.dupe(u8, text);
    }

    fn fieldMask(d: *Decoder) Error![]const []const u8 {
        const text = try d.stringValue();
        defer d.gpa.free(text);
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(d.gpa);
        var rest = text;
        while (rest.len != 0) {
            const comma = std.mem.findScalar(u8, rest, ',') orelse rest.len;
            try list.append(d.gpa, try snakeCase(d.gpa, rest[0..comma]));
            rest = if (comma == rest.len) "" else rest[comma + 1 ..];
        }
        return list.toOwnedSlice(d.gpa);
    }

    fn end(d: *Decoder) Error!void {
        const tok = try d.next();
        defer d.freeToken(tok);
        if (std.meta.activeTag(tok) != .end_of_document) return error.UnexpectedToken;
    }

    fn skip(d: *Decoder) Error!void {
        const kind = try d.scanner.peekNextTokenType();
        switch (kind) {
            .object_begin, .array_begin => {
                _ = try d.next();
                var depth: usize = 1;
                while (depth > 0) {
                    const inner = try d.scanner.peekNextTokenType();
                    const tok = try d.next();
                    d.freeToken(tok);
                    switch (inner) {
                        .object_begin, .array_begin => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
            },
            else => {
                const tok = try d.next();
                d.freeToken(tok);
            },
        }
    }

    fn take(d: *Decoder, comptime tag: std.meta.Tag(Scanner.Token)) Error!void {
        const tok = try d.next();
        defer d.freeToken(tok);
        if (std.meta.activeTag(tok) != tag) return error.UnexpectedToken;
    }

    fn next(d: *Decoder) Error!Scanner.Token {
        return d.scanner.nextAlloc(d.gpa, .alloc_if_needed);
    }

    fn freeToken(d: *Decoder, tok: Scanner.Token) void {
        switch (tok) {
            .allocated_string => |s| d.gpa.free(s),
            .allocated_number => |s| d.gpa.free(s),
            else => {},
        }
    }
};

fn parseFloatText(comptime E: type, text: []const u8) Error!E {
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(E);
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(E);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(E);
    return std.fmt.parseFloat(E, text) catch error.InvalidValue;
}

/// Base64 into memory the caller owns. Accepts the standard and URL-safe
/// alphabets, with or without padding.
fn decodeBase64(gpa: Allocator, text: []const u8) Error![]const u8 {
    if (text.len == 0) return &.{};
    var padded = try gpa.alloc(u8, text.len + 3);
    defer gpa.free(padded);
    for (text, 0..) |c, i| {
        padded[i] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
    }
    var length = text.len;
    while (length % 4 != 0) : (length += 1) padded[length] = '=';

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(padded[0..length]) catch return error.InvalidBase64;
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    decoder.decode(out, padded[0..length]) catch return error.InvalidBase64;
    return out;
}

/// `userName` becomes `user_name`: the field-mask form is camelCase, and the
/// paths it names are snake_case.
fn snakeCase(gpa: Allocator, path: []const u8) Error![]const u8 {
    var extra: usize = 0;
    for (path) |c| {
        if (std.ascii.isUpper(c)) extra += 1;
    }
    const out = try gpa.alloc(u8, path.len + extra);
    var len: usize = 0;
    for (path) |c| {
        if (std.ascii.isUpper(c)) {
            out[len] = '_';
            len += 1;
            out[len] = std.ascii.toLower(c);
        } else {
            out[len] = c;
        }
        len += 1;
    }
    return out;
}

test jsonName {
    try std.testing.expectEqualStrings("userId", comptime jsonName("user_id"));
    try std.testing.expectEqualStrings("type", comptime jsonName("type"));
    try std.testing.expectEqualStrings("i32", comptime jsonName("i32"));
    try std.testing.expectEqualStrings(
        "sourceContextFilePath",
        comptime jsonName("source_context_file_path"),
    );
}

test "snake case is the inverse for the paths it writes" {
    const gpa = std.testing.allocator;
    const snake = try snakeCase(gpa, "user.displayName");
    defer gpa.free(snake);
    try std.testing.expectEqualStrings("user.display_name", snake);
}

test "base64 accepts both alphabets and no padding" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { text: []const u8, bytes: []const u8 }{
        .{ .text = "aGVsbG8=", .bytes = "hello" },
        .{ .text = "aGVsbG8", .bytes = "hello" },
        .{ .text = "aGVsbG8h", .bytes = "hello!" },
        .{ .text = "-_8", .bytes = &.{ 0xfb, 0xff } },
        .{ .text = "+/8=", .bytes = &.{ 0xfb, 0xff } },
        .{ .text = "", .bytes = "" },
    };
    for (cases) |case| {
        const bytes = try decodeBase64(gpa, case.text);
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, case.bytes, bytes);
    }
}

const test_Kind = enum(i32) {
    UNKNOWN = 0,
    FIRST = 1,
};

const test_Inner = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{
        .n = proto.field(1),
        .label = proto.string(2),
    };

    n: i32 = 0,
    label: []const u8 = "",
};

const test_Pick = union(enum) {
    pub const protobuf: proto.Variants(@This()) = .{
        .number = proto.field(20),
        .note = proto.string(21),
    };

    number: i32,
    note: []const u8,
};

const test_Msg = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{
        .id = proto.field(1),
        .big = proto.field(2),
        .flag = proto.field(3),
        .flt = proto.field(4),
        .text = proto.string(5),
        .blob = proto.bytes(6),
        .kind = proto.field(7),
        .inner = proto.field(8),
        .words = proto.string(9),
        .nums = proto.field(10),
        .nick = proto.string(11),
        .pick = proto.oneof(),
        .user_id = proto.field(13),
    };

    id: i32 = 0,
    big: i64 = 0,
    flag: bool = false,
    flt: f64 = 0,
    text: []const u8 = "",
    blob: []const u8 = "",
    kind: test_Kind = .UNKNOWN,
    inner: test_Inner = .{},
    words: []const []const u8 = &.{},
    nums: []const i32 = &.{},
    nick: ?[]const u8 = null,
    pick: ?test_Pick = null,
    user_id: i32 = 0,
};

fn testSample() test_Msg {
    return .{
        .id = 7,
        .big = -9_000_000_000_000,
        .flag = true,
        .flt = 1.5,
        .text = "hello",
        .blob = &.{ 0xfb, 0xff },
        .kind = .FIRST,
        .inner = .{ .n = 1, .label = "x" },
        .words = &.{ "a", "" },
        .nums = &.{ 1, -2 },
        .pick = .{ .number = 3 },
        .user_id = 42,
    };
}

const test_sample_json =
    "{\"id\":7,\"big\":\"-9000000000000\",\"flag\":true,\"flt\":1.5,\"text\":\"hello\"," ++
    "\"blob\":\"+/8=\",\"kind\":\"FIRST\",\"inner\":{\"n\":1,\"label\":\"x\"}," ++
    "\"words\":[\"a\",\"\"],\"nums\":[1,-2],\"number\":3,\"userId\":42}";

test "a message writes the mapping, and reads it back" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(test_Msg, testSample(), .{}, &out.writer);
    try std.testing.expectEqualStrings(test_sample_json, out.written());

    var parsed = try decode(test_Msg, test_sample_json, .{}, std.testing.allocator);
    defer parsed.deinit();
    const back = parsed.value;

    try std.testing.expectEqual(@as(i32, 7), back.id);
    try std.testing.expectEqual(@as(i64, -9_000_000_000_000), back.big);
    try std.testing.expect(back.flag);
    try std.testing.expectEqual(@as(f64, 1.5), back.flt);
    try std.testing.expectEqualStrings("hello", back.text);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, back.blob);
    try std.testing.expectEqual(test_Kind.FIRST, back.kind);
    try std.testing.expectEqual(@as(i32, 1), back.inner.n);
    try std.testing.expectEqualStrings("x", back.inner.label);
    try std.testing.expectEqual(@as(usize, 2), back.words.len);
    try std.testing.expectEqualStrings("", back.words[1]);
    try std.testing.expectEqualSlices(i32, &.{ 1, -2 }, back.nums);
    try std.testing.expectEqual(@as(i32, 3), back.pick.?.number);
    try std.testing.expectEqual(@as(i32, 42), back.user_id);
}

test "the proto names are written when asked for" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(test_Msg, .{ .user_id = 42 }, .{ .use_proto_names = true }, &out.writer);
    try std.testing.expectEqualStrings("{\"user_id\":42}", out.written());

    // The parser reads either spelling whatever the option says.
    var parsed = try decode(test_Msg, "{\"user_id\":42}", .{}, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 42), parsed.value.user_id);
}

test "a number and a string both parse, and out-of-range is an error" {
    var from_string = try decode(test_Msg, "{\"big\":\"-5\"}", .{}, std.testing.allocator);
    defer from_string.deinit();
    try std.testing.expectEqual(@as(i64, -5), from_string.value.big);

    var from_number = try decode(test_Msg, "{\"big\":-5}", .{}, std.testing.allocator);
    defer from_number.deinit();
    try std.testing.expectEqual(@as(i64, -5), from_number.value.big);

    try std.testing.expectError(
        error.InvalidValue,
        decode(test_Msg, "{\"id\":9999999999}", .{}, std.testing.allocator),
    );
}

test "null leaves a field alone and unknown keys are refused" {
    var parsed = try decode(test_Msg, "{\"id\":null,\"nick\":null}", .{}, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 0), parsed.value.id);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.nick);

    try std.testing.expectError(
        error.UnknownField,
        decode(test_Msg, "{\"nope\":1}", .{}, std.testing.allocator),
    );

    var ignored = try decode(
        test_Msg,
        "{\"nope\":{\"a\":[1,2]},\"id\":5}",
        .{ .ignore_unknown_fields = true },
        std.testing.allocator,
    );
    defer ignored.deinit();
    try std.testing.expectEqual(@as(i32, 5), ignored.value.id);
}

test "floats that JSON cannot say are strings" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(test_Msg, .{ .flt = std.math.nan(f64) }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"flt\":\"NaN\"}", out.written());

    var parsed = try decode(test_Msg, "{\"flt\":\"-Infinity\"}", .{}, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expect(std.math.isInf(parsed.value.flt));
    try std.testing.expect(parsed.value.flt < 0);
}

test "trailing characters are refused" {
    // The scanner sees a second document before `end` does.
    try std.testing.expectError(
        error.SyntaxError,
        decode(test_Msg, "{} {}", .{}, std.testing.allocator),
    );
}

test "an enum tag with no member is refused" {
    try std.testing.expectError(
        error.UnknownEnumTag,
        decode(test_Msg, "{\"kind\":\"NOPE\"}", .{}, std.testing.allocator),
    );
    try std.testing.expectError(
        error.UnknownEnumTag,
        decode(test_Msg, "{\"kind\":9}", .{}, std.testing.allocator),
    );
}

test "a string is escaped and a slash is not" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(test_Msg, .{ .text = "a\"b\\c\td\u{1F600}" }, .{}, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"text\":\"a\\\"b\\\\c\\td\u{1F600}\"}",
        out.written(),
    );

    var parsed = try decode(test_Msg, out.written(), .{}, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\td\u{1F600}", parsed.value.text);
}

test "the well-known types have their own forms" {
    const When = struct {
        pub const protobuf: proto.Descriptor(@This()) = .{
            .when = proto.field(1),
            .how_long = proto.field(2),
            .count = proto.field(3),
            .raw = proto.field(4),
            .mask = proto.field(5),
            .nothing = proto.field(6),
        };

        when: ?wkt.Timestamp = null,
        how_long: ?wkt.Duration = null,
        count: ?wkt.Int32Value = null,
        raw: ?wkt.BytesValue = null,
        mask: ?wkt.FieldMask = null,
        nothing: ?wkt.Empty = null,
    };

    const value: When = .{
        .when = .{ .seconds = 1_712_320_496, .nanos = 500_000_000 },
        .how_long = .{ .seconds = -3, .nanos = -500_000_000 },
        .count = .{ .value = 5 },
        .raw = .{ .value = &.{ 0xfb, 0xff } },
        .mask = .{ .paths = &.{ "user_id", "display_name" } },
        .nothing = .{},
    };

    const expected =
        "{\"when\":\"2024-04-05T12:34:56.500Z\",\"howLong\":\"-3.500s\"," ++
        "\"count\":5,\"raw\":\"+/8=\",\"mask\":\"userId,displayName\"," ++
        "\"nothing\":{}}";

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(When, value, .{}, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());

    var parsed = try decode(When, expected, .{}, std.testing.allocator);
    defer parsed.deinit();
    const back = parsed.value;
    try std.testing.expectEqual(@as(i64, 1_712_320_496), back.when.?.seconds);
    try std.testing.expectEqual(@as(i32, 500_000_000), back.when.?.nanos);
    try std.testing.expectEqual(@as(i64, -3), back.how_long.?.seconds);
    try std.testing.expectEqual(@as(i32, -500_000_000), back.how_long.?.nanos);
    try std.testing.expectEqual(@as(i32, 5), back.count.?.value);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, back.raw.?.value);
    try std.testing.expectEqual(@as(usize, 2), back.mask.?.paths.len);
    try std.testing.expectEqualStrings("user_id", back.mask.?.paths[0]);
    try std.testing.expectEqualStrings("display_name", back.mask.?.paths[1]);
}
