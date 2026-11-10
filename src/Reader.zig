//! Protobuf message reader.
//!
//! Provides the Reader struct for parsing protobuf-encoded messages.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = mem.Allocator;

const wire = @import("wire.zig");
const Error = wire.Error;
const Tag = wire.Tag;
const Scalar = wire.Scalar;
const Encoding = wire.Encoding;
const decodeVarint = wire.decodeVarint;
const zigzagDecode = wire.zigzagDecode;
const readVarintFromIo = wire.readVarintFromIo;

/// A protobuf field, tagged by wire type.
pub const Field = union(enum) {
    varint: Varint,
    fixed64: Fixed64,
    len: Len,
    fixed32: Fixed32,

    /// The tag of a `Field` arm.
    pub const Kind = meta.Tag(Field);

    /// The payload type of `kind`.
    pub fn Payload(comptime kind: Kind) type {
        return @FieldType(Field, @tagName(kind));
    }

    /// The wire type this field arrived as.
    pub fn wireType(self: Field) wire.WireType {
        return switch (self) {
            .varint => .varint,
            .fixed64 => .fixed64,
            .len => .len,
            .fixed32 => .fixed32,
        };
    }

    /// Get the field number regardless of wire type.
    pub fn fieldNumber(self: Field) u32 {
        return switch (self) {
            inline else => |f| f.field_number,
        };
    }

    /// Get the payload as a specific scalar type.
    pub fn as(self: Field, comptime scalar: Scalar) Scalar.Type(scalar) {
        return switch (self) {
            inline else => |f| f.as(scalar),
        };
    }

    /// Assert the wire type and return the payload.
    pub fn expect(self: Field, comptime kind: Kind) Payload(kind) {
        return @field(self, @tagName(kind));
    }

    /// Varint field payload.
    pub const Varint = struct {
        /// The field number from the tag.
        field_number: u32,
        /// The raw varint bits, before a scalar interpretation.
        value: u64,

        /// Interpret as a specific scalar type.
        pub fn as(self: Varint, comptime scalar: Scalar) Scalar.Type(scalar) {
            return switch (scalar) {
                .i32 => @bitCast(@as(u32, @truncate(self.value))),
                .i64 => @bitCast(self.value),
                .u32 => @truncate(self.value),
                .u64 => self.value,
                .sint32 => zigzagDecode(u32, @truncate(self.value)),
                .sint64 => zigzagDecode(u64, self.value),
                .bool => self.value != 0,
                else => @compileError("Varint cannot be read as " ++ @tagName(scalar)),
            };
        }
    };

    /// Fixed64 field payload.
    pub const Fixed64 = struct {
        /// The field number from the tag.
        field_number: u32,
        /// The little-endian 64-bit payload.
        value: u64,

        /// Interpret as a specific scalar type.
        pub fn as(self: Fixed64, comptime scalar: Scalar) Scalar.Type(scalar) {
            return switch (scalar) {
                .fixed64 => self.value,
                .sfixed64 => @bitCast(self.value),
                .double => @bitCast(self.value),
                else => @compileError("Fixed64 cannot be read as " ++ @tagName(scalar)),
            };
        }
    };

    /// Fixed32 field payload.
    pub const Fixed32 = struct {
        /// The field number from the tag.
        field_number: u32,
        /// The little-endian 32-bit payload.
        value: u32,

        /// Interpret as a specific scalar type.
        pub fn as(self: Fixed32, comptime scalar: Scalar) Scalar.Type(scalar) {
            return switch (scalar) {
                .fixed32 => self.value,
                .sfixed32 => @bitCast(self.value),
                .float => @bitCast(self.value),
                else => @compileError("Fixed32 cannot be read as " ++ @tagName(scalar)),
            };
        }
    };

    /// Length-delimited field payload.
    pub const Len = struct {
        /// The field number from the tag.
        field_number: u32,
        /// Payload length in bytes.
        length: usize,
        /// The stream the payload will be read from.
        io: *Io.Reader,
        /// The enclosing message, when this field is nested.
        parent: ?*Reader = null,

        /// Read as UTF-8 string into the provided buffer. The returned slice
        /// points into `buf`.
        pub fn string(self: Len, buf: []u8) ![]const u8 {
            const payload = try self.bytes(buf);
            if (!unicode.utf8ValidateSlice(payload)) return Error.InvalidUtf8;
            return payload;
        }

        /// Read as UTF-8 string with allocation.
        pub fn stringAlloc(self: Len, gpa: Allocator) ![]u8 {
            const payload = try self.bytesAlloc(gpa);
            if (!unicode.utf8ValidateSlice(payload)) {
                gpa.free(payload);
                return Error.InvalidUtf8;
            }
            return payload;
        }

        /// Borrow the payload from the reader's buffer, with no copy.
        ///
        /// Requires the whole payload to be buffered already, which is true for
        /// a reader over a complete slice and false for a stream whose payload
        /// is larger than the buffer. Returns `error.NotBuffered` in that case.
        /// `bytes` copies the payload for any reader. The returned slice is
        /// valid until the next read from `io`.
        pub fn data(self: Len) ![]const u8 {
            const avail = self.io.buffered();
            if (avail.len < self.length) return Error.NotBuffered;
            const dest = avail[0..self.length];
            self.io.toss(self.length);
            if (self.parent) |p| try p.advance(self.length);
            return dest;
        }

        /// Read raw bytes into the provided buffer. The returned slice points
        /// into `buf`.
        pub fn bytes(self: Len, buf: []u8) ![]u8 {
            if (buf.len < self.length) return Error.BufferTooSmall;
            const dest = buf[0..self.length];
            self.io.readSliceAll(dest) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            if (self.parent) |p| try p.advance(self.length);
            return dest;
        }

        /// Read raw bytes with allocation.
        pub fn bytesAlloc(self: Len, gpa: Allocator) ![]u8 {
            const buf = try gpa.alloc(u8, self.length);
            errdefer gpa.free(buf);
            self.io.readSliceAll(buf) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            if (self.parent) |p| try p.advance(self.length);
            return buf;
        }

        /// Read as embedded message (streaming, no copy).
        /// Returns a Reader that reads directly from the parent stream.
        /// Decrements parent's remaining since the bytes will be consumed by the nested reader.
        pub fn message(self: Len) !Reader {
            if (self.parent) |p| try p.advance(self.length);
            return .{ .io = self.io, .remaining = self.length, .parent = self.parent };
        }

        /// Skip this field without reading the data.
        pub fn skip(self: Len) !void {
            self.io.discardAll(self.length) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            if (self.parent) |p| try p.advance(self.length);
        }

        /// Iterator for packed repeated fields.
        pub fn PackedIterator(comptime T: type, comptime encoding: Encoding) type {
            return struct {
                const Self = @This();

                /// The packed payload, borrowed from the caller's buffer.
                data: []const u8,
                /// The next byte to read.
                pos: usize,

                /// Read the next element, or null at the end of the payload.
                pub fn next(self: *Self) !?T {
                    switch (encoding) {
                        .varint => {
                            if (self.pos >= self.data.len) return null;
                            const value, const bytes_read = try decodeVarint(
                                u64,
                                self.data[self.pos..],
                            );
                            self.pos += bytes_read;
                            return switch (T) {
                                i32 => @bitCast(@as(u32, @truncate(value))),
                                i64 => @bitCast(value),
                                u32 => @truncate(value),
                                u64 => value,
                                bool => value != 0,
                                else => @compileError(
                                    "varint encoding does not support " ++ @typeName(T),
                                ),
                            };
                        },
                        .sint => {
                            if (self.pos >= self.data.len) return null;
                            const value, const bytes_read = try decodeVarint(
                                u64,
                                self.data[self.pos..],
                            );
                            self.pos += bytes_read;
                            return switch (T) {
                                i32 => zigzagDecode(u32, @truncate(value)),
                                i64 => zigzagDecode(u64, value),
                                else => @compileError("sint encoding only supports i32 and i64"),
                            };
                        },
                        .fixed => {
                            const size = @sizeOf(T);
                            if (self.pos + size > self.data.len) {
                                if (self.pos >= self.data.len) return null;
                                return Error.Truncated;
                            }
                            const raw = self.data[self.pos..][0..size];
                            self.pos += size;
                            return @bitCast(raw.*);
                        },
                    }
                }
            };
        }

        /// Result of repeatedAlloc - holds iterator and allocated data.
        pub fn PackedRepeated(comptime T: type, comptime encoding: Encoding) type {
            return struct {
                const Self = @This();

                /// The iterator over the allocated payload.
                iter: PackedIterator(T, encoding),
                /// The payload buffer, freed by `deinit`.
                data: []u8,

                /// Free the payload buffer.
                pub fn deinit(self: *Self, gpa: Allocator) void {
                    gpa.free(self.data);
                    self.* = undefined;
                }
            };
        }

        /// Read packed repeated field into buffer, returns iterator.
        pub fn repeated(
            self: Len,
            comptime T: type,
            comptime encoding: Encoding,
            buf: []u8,
        ) !PackedIterator(T, encoding) {
            const payload = try self.bytes(buf);
            return .{ .data = payload, .pos = 0 };
        }

        /// Read a packed repeated field with allocation.
        ///
        /// The result holds the payload and an iterator. Its `deinit` method
        /// frees the payload.
        pub fn repeatedAlloc(
            self: Len,
            comptime T: type,
            comptime encoding: Encoding,
            gpa: Allocator,
        ) !PackedRepeated(T, encoding) {
            const payload = try self.bytesAlloc(gpa);
            return .{
                .iter = .{ .data = payload, .pos = 0 },
                .data = payload,
            };
        }
    };
};

/// Reads fields from a protobuf-encoded message. A reader returned by
/// `Field.Len.message` is bounded by that field's length.
const Reader = @This();

/// The stream this reader consumes.
io: *Io.Reader,
/// Bytes left in this message, or null for an unbounded reader.
remaining: ?usize = null,
/// The enclosing message, for a reader returned by `Field.Len.message`.
parent: ?*Reader = null,

/// Read from `reader`, with no message bound.
pub fn init(reader: *Io.Reader) Reader {
    return .{ .io = reader };
}

/// Decrement remaining bytes (for bounded readers).
/// A step past the end is an error, not a wrapping subtraction: a length
/// that does not fit the enclosing message is malformed input, and letting
/// it through would make `remaining` meaningless for every field after it.
fn advance(self: *Reader, n: usize) !void {
    if (self.remaining) |*rem| {
        if (rem.* < n) return Error.Truncated;
        rem.* -= n;
    }
}

/// Read the next field, or return null if at end of message.
pub fn next(self: *Reader) !?Field {
    // If bounded and exhausted, return null
    if (self.remaining) |rem| {
        if (rem == 0) return null;
    }

    // Try to read tag - EOF means end of message (unbounded) or error (bounded)
    const tag, const tag_len = readVarintFromIo(self.io, u64) catch |err| switch (err) {
        Error.Truncated => return if (self.remaining == null) null else err,
        else => |e| return e,
    };

    self.advance(tag_len) catch return Error.Truncated;

    const parsed: Tag = try .parse(tag);

    return switch (parsed.wire_type) {
        .varint => {
            const value, const value_len = try readVarintFromIo(self.io, u64);
            try self.advance(value_len);
            return .{ .varint = .{
                .field_number = parsed.field_number,
                .value = value,
            } };
        },
        .fixed64 => {
            const value = self.io.takeInt(u64, .little) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            try self.advance(8);
            return .{ .fixed64 = .{
                .field_number = parsed.field_number,
                .value = value,
            } };
        },
        .len => {
            const len, const len_len = try readVarintFromIo(self.io, u64);
            try self.advance(len_len);
            const length: usize = std.math.cast(usize, len) orelse return Error.Truncated;
            // A payload longer than the field's own message is malformed,
            // and the payload code below trusts this length.
            if (self.remaining) |rem| {
                if (length > rem) return Error.Truncated;
            }
            return .{ .len = .{
                .field_number = parsed.field_number,
                .length = length,
                .io = self.io,
                .parent = self,
            } };
        },
        .fixed32 => {
            const value = self.io.takeInt(u32, .little) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            try self.advance(4);
            return .{ .fixed32 = .{
                .field_number = parsed.field_number,
                .value = value,
            } };
        },
    };
}

test Reader {
    // Basic varint
    {
        const data = [_]u8{
            0x08, // tag(1, VARINT)
            0x96, 0x01, // 150
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        try testing.expectEqual(@as(u32, 1), field.fieldNumber());
        try testing.expectEqual(@as(u32, 150), field.expect(.varint).as(.u32));

        try testing.expect((try r.next()) == null);
    }

    // String field
    {
        const data = [_]u8{
            0x12, // tag(2, LEN)
            0x07, // length 7
            't',
            'e',
            's',
            't',
            'i',
            'n',
            'g',
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        try testing.expectEqual(@as(u32, 2), field.fieldNumber());

        var buf: [32]u8 = undefined;
        const s = try field.expect(.len).string(&buf);
        try testing.expectEqualStrings("testing", s);
    }

    // Nested message
    {
        const data = [_]u8{
            0x08, 0x2a, // field 1: uint32 42
            0x12, 0x0a, // field 2: len 10
            0x0a, 0x06, 'n', 'e', 's', 't', 'e', 'd', // nested field 1: string "nested"
            0x10, 0x64, // nested field 2: uint32 100
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        // Field 1: uint32
        {
            const field = (try r.next()).?;
            try testing.expectEqual(@as(u32, 1), field.fieldNumber());
            try testing.expectEqual(@as(u32, 42), field.expect(.varint).as(.u32));
        }

        // Field 2: nested message
        {
            const field = (try r.next()).?;
            try testing.expectEqual(@as(u32, 2), field.fieldNumber());

            var nested = field.expect(.len).message() catch unreachable;

            // Nested field 1: string
            {
                const nf = (try nested.next()).?;
                var str_buf: [32]u8 = undefined;
                try testing.expectEqualStrings("nested", try nf.expect(.len).string(&str_buf));
            }

            // Nested field 2: uint32
            {
                const nf = (try nested.next()).?;
                try testing.expectEqual(@as(u32, 100), nf.expect(.varint).as(.u32));
            }

            try testing.expect((try nested.next()) == null);
        }

        try testing.expect((try r.next()) == null);
    }

    // Python-encoded bytes compatibility
    {
        const data = [_]u8{
            0x0a, 0x05, 'h',  'e',  'l', 'l', 'o',
            0x10, 0x2a, 0x18, 0x01,
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        {
            const field = (try r.next()).?;
            var buf: [32]u8 = undefined;
            try testing.expectEqualStrings("hello", try field.expect(.len).string(&buf));
        }

        {
            const field = (try r.next()).?;
            try testing.expectEqual(@as(i64, 42), field.expect(.varint).as(.i64));
        }

        {
            const field = (try r.next()).?;
            try testing.expectEqual(true, field.expect(.varint).as(.bool));
        }

        try testing.expect((try r.next()) == null);
    }
}

test "bounded reader" {
    // Empty nested message
    {
        const data = [_]u8{
            0x0a, 0x00, // field 1: len 0 (empty message)
            0x10, 0x2a, // field 2: varint 42
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        // Field 1: empty nested message
        {
            const field = (try r.next()).?;
            try testing.expectEqual(@as(u32, 1), field.fieldNumber());
            var nested = field.expect(.len).message() catch unreachable;
            try testing.expectEqual(@as(usize, 0), nested.remaining.?);
            try testing.expect((try nested.next()) == null);
        }

        // Field 2: varint after empty message
        {
            const field = (try r.next()).?;
            try testing.expectEqual(@as(u32, 42), field.expect(.varint).as(.u32));
        }

        try testing.expect((try r.next()) == null);
    }

    // All wire types within nested message
    {
        const data = [_]u8{
            0x0a, 0x18, // field 1: len 24 (nested message)
            // nested contents:
            0x08, 0x96, 0x01, // field 1: varint 150
            0x15, 0x00, 0x00, 0x80, 0x3f, // field 2: fixed32 (float 1.0)
            0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f, // field 3: fixed64 (double 1.0)
            0x22, 0x05, 'h', 'e', 'l', 'l', 'o', // field 4: string "hello"
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        try testing.expectEqual(@as(u32, 1), field.fieldNumber());
        var nested = field.expect(.len).message() catch unreachable;
        try testing.expectEqual(@as(usize, 24), nested.remaining.?);

        // Nested field 1: varint
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 1), nf.fieldNumber());
            try testing.expectEqual(@as(u32, 150), nf.expect(.varint).as(.u32));
        }

        // Nested field 2: fixed32
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 2), nf.fieldNumber());
            try testing.expectEqual(@as(f32, 1.0), nf.expect(.fixed32).as(.float));
        }

        // Nested field 3: fixed64
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 3), nf.fieldNumber());
            try testing.expectEqual(@as(f64, 1.0), nf.expect(.fixed64).as(.double));
        }

        // Nested field 4: string
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 4), nf.fieldNumber());
            var buf: [32]u8 = undefined;
            try testing.expectEqualStrings("hello", try nf.expect(.len).string(&buf));
        }

        try testing.expectEqual(@as(usize, 0), nested.remaining.?);
        try testing.expect((try nested.next()) == null);
        try testing.expect((try r.next()) == null);
    }

    // Skip within nested message decrements remaining
    {
        const data = [_]u8{
            0x0a, 0x0b, // field 1: len 11 (nested message)
            // nested contents:
            0x0a, 0x05, 'h', 'e', 'l', 'l', 'o', // field 1: string "hello" (7 bytes)
            0x10, 0x2a, // field 2: varint 42 (2 bytes)
            0x18, 0x01, // field 3: varint 1 (2 bytes)
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        var nested = field.expect(.len).message() catch unreachable;
        try testing.expectEqual(@as(usize, 11), nested.remaining.?);

        // Skip field 1
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 1), nf.fieldNumber());
            try nf.expect(.len).skip();
        }

        // Remaining should be decremented by skipped content
        // Started with 11, consumed tag (1) + len (1), then skipped 5 = 4 remaining
        try testing.expectEqual(@as(usize, 4), nested.remaining.?);

        // Read remaining fields
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(@as(u32, 42), nf.expect(.varint).as(.u32));
        }
        {
            const nf = (try nested.next()).?;
            try testing.expectEqual(true, nf.expect(.varint).as(.bool));
        }

        try testing.expectEqual(@as(usize, 0), nested.remaining.?);
        try testing.expect((try nested.next()) == null);
    }

    // Multiple levels of nesting
    {
        const data = [_]u8{
            0x0a, 0x0a, // field 1: len 10 (outer nested)
            // outer nested (10 bytes):
            0x08, 0x01, // field 1: varint 1 (2 bytes)
            0x12, 0x06, // field 2: len 6 (inner nested)
            // inner nested (6 bytes):
            0x08, 0x02, // field 1: varint 2 (2 bytes)
            0x12, 0x02, 'h', 'i', // field 2: string "hi" (4 bytes)
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        var outer = field.expect(.len).message() catch unreachable;

        // Outer field 1
        {
            const of = (try outer.next()).?;
            try testing.expectEqual(@as(u32, 1), of.expect(.varint).as(.u32));
        }

        // Outer field 2: inner nested
        {
            const of = (try outer.next()).?;
            var inner = of.expect(.len).message() catch unreachable;

            // Inner field 1
            {
                const inf = (try inner.next()).?;
                try testing.expectEqual(@as(u32, 2), inf.expect(.varint).as(.u32));
            }

            // Inner field 2
            {
                const inf = (try inner.next()).?;
                var buf: [8]u8 = undefined;
                try testing.expectEqualStrings("hi", try inf.expect(.len).string(&buf));
            }

            try testing.expect((try inner.next()) == null);
        }

        try testing.expect((try outer.next()) == null);
        try testing.expect((try r.next()) == null);
    }

    // Packed repeated within nested message
    {
        const data = [_]u8{
            0x0a, 0x07, // field 1: len 7 (nested message)
            // nested contents:
            0x0a, 0x05, // field 1: packed repeated, len 5
            0x01, 0x02, 0x03, 0x04, 0x05, // values 1,2,3,4,5
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        var nested = field.expect(.len).message() catch unreachable;

        const nf = (try nested.next()).?;
        try testing.expectEqual(@as(u32, 1), nf.fieldNumber());

        var buf: [16]u8 = undefined;
        var iter = try nf.expect(.len).repeated(u32, .varint, &buf);

        try testing.expectEqual(@as(u32, 1), (try iter.next()).?);
        try testing.expectEqual(@as(u32, 2), (try iter.next()).?);
        try testing.expectEqual(@as(u32, 3), (try iter.next()).?);
        try testing.expectEqual(@as(u32, 4), (try iter.next()).?);
        try testing.expectEqual(@as(u32, 5), (try iter.next()).?);
        try testing.expect((try iter.next()) == null);

        try testing.expect((try nested.next()) == null);
        try testing.expect((try r.next()) == null);
    }

    // Remaining tracking with multi-byte varints
    {
        const data = [_]u8{
            0x0a, 0x04, // field 1: len 4 (nested message)
            0x08, 0x80, 0x80, 0x01, // field 1: varint 16384 (3-byte encoding)
        };

        var io_reader: Io.Reader = .fixed(&data);
        var r: Reader = .init(&io_reader);

        const field = (try r.next()).?;
        var nested = field.expect(.len).message() catch unreachable;
        try testing.expectEqual(@as(usize, 4), nested.remaining.?);

        const nf = (try nested.next()).?;
        try testing.expectEqual(@as(u32, 16384), nf.expect(.varint).as(.u32));

        try testing.expectEqual(@as(usize, 0), nested.remaining.?);
        try testing.expect((try nested.next()) == null);
    }
}

test "a payload longer than its message is truncated, not wrapped" {
    // The nested message claims 4 bytes but holds a field claiming 127. Before
    // the bound check, the skip below underflowed `remaining` and the reader
    // kept reading past the nested message's end.
    const data = [_]u8{
        0x0a, 0x04, // field 1: LEN, 4 bytes
        0x0a, 0x7f, // nested field 1: LEN, claims 127
        0x41, 0x42, // bytes that belong to the outer message
    };

    var io_reader: Io.Reader = .fixed(&data);
    var r: Reader = .init(&io_reader);
    const field = (try r.next()).?;
    var nested = try field.expect(.len).message();
    try testing.expectError(Error.Truncated, nested.next());
}

test "a varint longer than its message is truncated, not wrapped" {
    // Nested message of 2 bytes holding a 1-byte tag and a 2-byte varint.
    const data = [_]u8{
        0x0a, 0x02, // field 1: LEN, 2 bytes
        0x08, 0x80, // nested field 1: varint, tag plus one unterminated byte
        0x01, // a byte that belongs to the outer message
    };

    var io_reader: Io.Reader = .fixed(&data);
    var r: Reader = .init(&io_reader);
    const field = (try r.next()).?;
    var nested = try field.expect(.len).message();
    try testing.expectError(Error.Truncated, nested.next());
}

test "data borrows from the input buffer" {
    const data = [_]u8{
        0x0a, 0x05, 'h', 'e', 'l', 'l', 'o',
    };

    var io_reader: Io.Reader = .fixed(&data);
    var r: Reader = .init(&io_reader);
    const field = (try r.next()).?;
    const borrowed = try field.expect(.len).data();
    try testing.expectEqualStrings("hello", borrowed);
    // No copy: the bytes are the input's own.
    try testing.expectEqual(@intFromPtr(&data[2]), @intFromPtr(borrowed.ptr));
}
