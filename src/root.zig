//! Protobuf wire format encoder/decoder.
//!
//! This module provides low-level primitives for reading and writing protobuf
//! wire format messages without requiring .proto files or code generation.
//!
//! Based on the protobuf encoding specification:
//! https://protobuf.dev/programming-guides/encoding/

pub const Reader = @import("Reader.zig");
pub const Field = Reader.Field;
pub const wire = @import("wire.zig");
pub const WireType = wire.WireType;
pub const Error = wire.Error;
pub const Tag = wire.Tag;
pub const Writer = @import("Writer.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
