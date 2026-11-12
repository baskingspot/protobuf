//! Protocol Buffers in Zig: the wire format, and a typed layer over plain
//! structs.
//!
//! `Reader` and `Writer` are the primitives: a field at a time, no schema. The
//! core loop allocates nothing. `encode` and `decode` sit above them and read a
//! Zig struct as a message, with field numbers declared in a `pub const
//! protobuf` table.
//!
//! Based on the protobuf encoding specification:
//! https://protobuf.dev/programming-guides/encoding/

const std = @import("std");

/// Decode one message from a reader, copying strings and bytes into an arena.
pub const decode = @import("decode.zig").decode;
/// Decode one message from a reader into memory the caller owns.
pub const decodeLeaky = @import("decode.zig").decodeLeaky;
/// Decode one message from a slice, borrowing strings and bytes from it.
pub const decodeFromSlice = @import("decode.zig").decodeFromSlice;
/// The borrowing decode, into memory the caller owns.
pub const decodeFromSliceLeaky = @import("decode.zig").decodeFromSliceLeaky;
/// The allocation-free decode: borrow every string, take no allocator, and
/// refuse a repeated field at compile time.
pub const decodeBorrowed = @import("decode.zig").decodeBorrowed;
/// Options for `decode` and its variants.
pub const DecodeOptions = @import("decode.zig").Options;
/// Encode one message into a writer.
pub const encode = @import("encode.zig").encode;
/// The byte count that `encode` writes for this value.
pub const encodedSize = @import("encode.zig").encodedSize;
/// Options for `encode`.
pub const EncodeOptions = @import("encode.zig").Options;
/// A decoded message and the arena that owns its allocations.
pub const Parsed = @import("decode.zig").Parsed;
/// The comptime side of the typed layer: a Zig struct read as a message, and
/// the table that says which field is which number.
pub const proto = @import("proto.zig");
/// The type of a message's `protobuf` table. Declare it as
/// `pub const protobuf: pb.Descriptor(@This()) = .{ ... };` so the compiler
/// checks the literal against the struct.
pub const Descriptor = proto.Descriptor;
/// One entry in that table.
pub const FieldDescriptor = proto.FieldDescriptor;
/// The proto3 JSON mapping of a message: one `Descriptor`, two encodings.
pub const json = @import("json.zig");
/// The well-known types: timestamps, durations, wrappers, field masks, and
/// the empty message.
pub const wkt = @import("wkt.zig");
/// Fields the decoder did not recognize, kept so a re-encode writes them back.
pub const Unknown = proto.Unknown;
/// A field whose Zig type says everything: `pb.field(2)`.
pub const field = proto.field;
/// A `[]const u8` checked as UTF-8.
pub const string = proto.string;
/// A `[]const u8` that is raw bytes.
pub const bytes = proto.bytes;
/// A zigzag varint: `sint32`, `sint64`.
pub const sint = proto.sint;
/// A fixed-width integer: `fixed32`, `sfixed32`, `fixed64`, `sfixed64`.
pub const fixed = proto.fixed;
/// A repeated numeric field written one element per tag.
pub const unpacked = proto.unpacked;
/// A `map<K, V>`: a repeated entry message on the wire, one JSON object.
pub const map = proto.map;
/// A oneof: a `?U` field whose union cases each carry their own number.
pub const oneof = proto.oneof;
/// The case table for a oneof union, the way `Descriptor` is the table for a
/// message struct.
pub const Variants = proto.Variants;
/// Reads one field at a time from an `Io.Reader`.
pub const Reader = @import("Reader.zig");
/// Back-to-back messages on one stream: a varint length, then that many bytes.
pub const delimited = @import("delimited.zig");
/// One field from `Reader.next`.
pub const Field = Reader.Field;
/// The wire primitives: varints, zigzag, tags, and scalar types.
pub const wire = @import("wire.zig");
/// The four wire types this reader accepts.
pub const WireType = wire.WireType;
/// Errors from the wire primitives.
pub const Error = wire.Error;
/// A field number and wire type.
pub const Tag = wire.Tag;
/// Builds a message one tag, scalar, or length-delimited value at a time.
pub const Writer = @import("Writer.zig");

test {
    std.testing.refAllDecls(@This());
}
