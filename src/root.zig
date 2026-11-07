//! Protobuf in Zig: the wire format, and a typed layer over plain structs.
//!
//! `Reader` and `Writer` are the primitives: a field at a time, no schema, no
//! allocation. `encode` and `decode` sit above them and read a Zig struct as a
//! message, with field numbers declared in a `pub const protobuf` table.
//!
//! Based on the protobuf encoding specification:
//! https://protobuf.dev/programming-guides/encoding/

const std = @import("std");

pub const decode = @import("decode.zig").decode;
pub const decodeLeaky = @import("decode.zig").decodeLeaky;
pub const decodeFromSlice = @import("decode.zig").decodeFromSlice;
pub const decodeFromSliceLeaky = @import("decode.zig").decodeFromSliceLeaky;
pub const DecodeOptions = @import("decode.zig").Options;
pub const encode = @import("encode.zig").encode;
pub const encodedSize = @import("encode.zig").encodedSize;
pub const EncodeOptions = @import("encode.zig").Options;
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
pub const Reader = @import("Reader.zig");
pub const Field = Reader.Field;
pub const wire = @import("wire.zig");
pub const WireType = wire.WireType;
pub const Error = wire.Error;
pub const Tag = wire.Tag;
pub const Writer = @import("Writer.zig");

test {
    std.testing.refAllDecls(@This());
}
