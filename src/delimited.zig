//! Back-to-back messages, each one preceded by its length.
//!
//! A stream has no way to say where one message ends and the next begins, so
//! the convention is a varint length and then exactly that many bytes. `Writer`
//! and `encode` write one such frame; `Reader` hands out a bounded `Reader` for
//! each frame in turn, so every field is read through the same primitives.
//!
//! ```zig
//! var w: std.Io.Writer = .fixed(&buffer);
//! try pb.delimited.encode(Person, person, .{}, &w);
//! ```
//!
//! Reading is a loop over `Reader.next`, which returns null at a clean end of
//! stream:
//!
//! ```zig
//! var d: pb.delimited.Reader = .init(&io);
//! while (try d.next()) |frame| {
//!     const person = try pb.decodeFromSliceLeaky(Person, gpa, frame.rest(), .{});
//!     _ = person;
//! }
//! ```

const std = @import("std");
const Io = std.Io;

const wire = @import("wire.zig");
const FieldReader = @import("Reader.zig");
const MessageWriter = @import("Writer.zig");
const encode_mod = @import("encode.zig");
const proto = @import("proto.zig");

/// The options `encode` passes to the encoder.
pub const Options = encode_mod.Options;

/// Every error a frame can return.
pub const Error = wire.Error;

/// Write one message as a length and then its bytes.
pub fn encode(comptime T: type, value: T, options: Options, writer: *Io.Writer) !void {
    // The length comes before the bytes it measures, so the size walk runs
    // first. It is the same walk `encodedSize` does, which is why a frame
    // costs two traversals.
    var w: MessageWriter = .init(writer);
    try w.writeVarint(usize, encode_mod.encodedSize(T, value, options));
    try encode_mod.encode(T, value, options, writer);
}

/// Bytes `encode` writes for this value, length prefix included.
pub fn encodedSize(comptime T: type, value: T, options: Options) usize {
    const payload = encode_mod.encodedSize(T, value, options);
    return wire.varintLen(payload) + payload;
}

/// Write already-encoded message bytes as one frame.
pub fn writeBytes(writer: *Io.Writer, message: []const u8) !void {
    var w: MessageWriter = .init(writer);
    try w.writeLen(message);
}

/// Reads one frame at a time from a stream.
///
/// Each `next` returns a reader bounded to one message. Reading a frame to its
/// end, or calling `next` again, leaves the stream at the start of the next
/// frame: a caller that stops early does not have to finish reading.
pub const Reader = struct {
    io: *Io.Reader,
    /// The frame being read, or an empty one before the first `next`.
    frame: Frame,
    started: bool = false,

    /// Read frames from `io`.
    pub fn init(io: *Io.Reader) Reader {
        return .{ .io = io, .frame = .{ .reader = .{ .io = io, .remaining = 0 } } };
    }

    /// The next frame, or null when the stream ends exactly at a frame
    /// boundary. A length with no payload behind it is `error.Truncated`.
    pub fn next(self: *Reader) Error!?*Frame {
        // Whatever the caller left unread belongs to the frame that just
        // ended, and it is not theirs to read again.
        if (self.started) try self.frame.drain();
        const length = try readLength(self.io) orelse return null;
        self.started = true;
        self.frame = .{ .reader = .{ .io = self.io, .remaining = length } };
        return &self.frame;
    }

    /// One frame: a `Reader` bounded to its length, so `Reader.next` returns
    /// null at the end of the message rather than reading into the next frame.
    pub const Frame = struct {
        reader: FieldReader,

        /// The fields of this frame. A `Reader` knows only its own bound, so
        /// reading through it keeps the frame's remaining length current.
        pub fn fields(self: *Frame) *FieldReader {
            return &self.reader;
        }

        /// Bytes left in this frame.
        pub fn remaining(self: *Frame) usize {
            return self.reader.remaining orelse 0;
        }

        /// Read the rest of the frame into `buf`, which must hold all of it.
        pub fn readAll(self: *Frame, buf: []u8) Error![]const u8 {
            const left = self.remaining();
            if (buf.len < left) return Error.BufferTooSmall;
            const dest = buf[0..left];
            if (dest.len != 0) {
                self.reader.io.readSliceAll(dest) catch |err| switch (err) {
                    error.EndOfStream => return Error.Truncated,
                    error.ReadFailed => return Error.ReadFailed,
                };
            }
            self.reader.remaining = 0;
            return dest;
        }

        /// The rest of the frame, borrowed from the reader's buffer. Requires
        /// the whole frame to be buffered already: true for a reader over a
        /// complete slice, false for a stream and a frame larger than its
        /// buffer. Returns `error.NotBuffered` in that case.
        pub fn rest(self: *Frame) Error![]const u8 {
            const left = self.remaining();
            const avail = self.reader.io.buffered();
            if (avail.len < left) return Error.NotBuffered;
            const dest = avail[0..left];
            self.reader.io.toss(left);
            self.reader.remaining = 0;
            return dest;
        }

        /// Skip what is left of the frame.
        pub fn drain(self: *Frame) Error!void {
            const left = self.remaining();
            if (left == 0) return;
            self.reader.io.discardAll(left) catch |err| switch (err) {
                error.EndOfStream => return Error.Truncated,
                error.ReadFailed => return Error.ReadFailed,
            };
            self.reader.remaining = 0;
        }
    };
};

/// Read a frame length, or null at a clean ends of stream.
///
/// The first byte decides: nothing there is the end of the stream, and a
/// half-written varint is truncated input.
fn readLength(io: *Io.Reader) Error!?usize {
    const first = io.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return Error.ReadFailed,
    };

    var result: u64 = first & 0x7f;
    var shift: u6 = 7;
    var byte = first;
    var read: usize = 1;
    while (byte & 0x80 != 0) {
        if (read >= wire.max_varint_len) return Error.VarintTooLong;
        byte = io.takeByte() catch |err| switch (err) {
            error.EndOfStream => return Error.Truncated,
            error.ReadFailed => return Error.ReadFailed,
        };
        result |= @as(u64, byte & 0x7f) << shift;
        shift +|= 7;
        read += 1;
    }
    return std.math.cast(usize, result) orelse Error.Truncated;
}

test "a frame is a length and the message" {
    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try writeBytes(&io, "hello");
    try writeBytes(&io, "");
    try writeBytes(&io, "x");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 5, 'h', 'e', 'l', 'l', 'o', 0, 1, 'x' },
        io.buffered(),
    );
}

test "read frames back" {
    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try writeBytes(&io, "hello");
    try writeBytes(&io, "");
    try writeBytes(&io, "x");

    var in_io: Io.Reader = .fixed(io.buffered());
    var d: Reader = .init(&in_io);
    var seen: usize = 0;
    while (try d.next()) |frame| : (seen += 1) {
        var buf: [16]u8 = undefined;
        const bytes = try frame.readAll(&buf);
        switch (seen) {
            0 => try std.testing.expectEqualStrings("hello", bytes),
            1 => try std.testing.expectEqualStrings("", bytes),
            2 => try std.testing.expectEqualStrings("x", bytes),
            else => return error.TooManyFrames,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "frames carry fields the field reader understands" {
    const Person = struct {
        pub const protobuf: proto.Descriptor(@This()) = .{ .id = proto.field(1) };

        id: u32 = 0,
    };

    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try encode(Person, .{ .id = 150 }, .{}, &io);

    var in_io: Io.Reader = .fixed(io.buffered());
    var d: Reader = .init(&in_io);
    const frame = (try d.next()).?;
    const fields = frame.fields();
    const field = (try fields.next()).?;
    try std.testing.expectEqual(@as(u32, 1), field.fieldNumber());
    try std.testing.expectEqual(@as(u32, 150), field.expect(.varint).as(.u32));
    try std.testing.expect((try fields.next()) == null);
    try std.testing.expect((try d.next()) == null);
}

test "an unread frame is skipped by the next call" {
    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try writeBytes(&io, "hello");
    try writeBytes(&io, "second");

    var in_io: Io.Reader = .fixed(io.buffered());
    var d: Reader = .init(&in_io);
    _ = (try d.next()).?;
    // Deliberately read nothing from the first frame.
    const frame = (try d.next()).?;
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("second", try frame.readAll(&buf));
}

test "a stream that ends mid-length is truncated" {
    const data = [_]u8{ 0x80, 0x80 };
    var in_io: Io.Reader = .fixed(&data);
    var d: Reader = .init(&in_io);
    try std.testing.expectError(Error.Truncated, d.next());
}

test "a frame with no payload behind it is truncated" {
    const data = [_]u8{5};
    var in_io: Io.Reader = .fixed(&data);
    var d: Reader = .init(&in_io);
    const frame = (try d.next()).?;
    var buf: [16]u8 = undefined;
    try std.testing.expectError(Error.Truncated, frame.readAll(&buf));
}

test "a length longer than the buffer needs a reader that can copy" {
    var buffer: [8]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try writeBytes(&io, "hello");

    var in_io: Io.Reader = .fixed(io.buffered());
    var d: Reader = .init(&in_io);
    const frame = (try d.next()).?;
    try std.testing.expectEqualStrings("hello", try frame.rest());
    try std.testing.expect((try d.next()) == null);
}

test "encodedSize matches what encode writes" {
    const Item = struct {
        pub const protobuf: proto.Descriptor(@This()) = .{
            .name = proto.string(1),
            .n = proto.field(2),
        };

        name: []const u8 = "",
        n: u64 = 0,
    };
    const value: Item = .{ .name = "abc", .n = 300 };
    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try encode(Item, value, .{}, &io);
    try std.testing.expectEqual(encodedSize(Item, value, .{}), io.buffered().len);
}
