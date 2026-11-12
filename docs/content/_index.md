+++
title = "protobuf"
+++

Protocol Buffers in Zig: the wire format, and a typed layer over plain structs.

`Writer` writes a tag, a scalar, or length-delimited bytes. `Reader.next`
returns one field at a time. The core loop allocates nothing, and neither side
knows a schema.

`encode` and `decode` build on those primitives. A plain Zig struct declares
its field numbers in a `Descriptor(@This())` table.

- [Wire format](#wire-format): `Writer` emits individual fields, and `Reader.next` returns each field from an input reader.
- [Typed messages](#typed-messages): `Descriptor(@This())` maps Zig fields to wire numbers for `encode` and `decode`.
- [Unknown fields](#unknown-fields): a field typed `pb.Unknown` keeps the fields the table does not declare, and `encode` writes them back.
- [Message streams](#message-streams): `pb.delimited` writes and reads the length prefix that separates back-to-back messages.
- [Ownership](#ownership): `Parsed.deinit` frees decoded allocations, while slice-based decoders borrow string and byte data.
- [Encoding options](#encoding-options): `EncodeOptions` controls default values, and `DecodeOptions` controls UTF-8 checks.
- [Limits](#limits): group wire types are `error.InvalidWireType`, there is no `.proto` parser or code generation, and maps stay repeated entry messages.

The [public namespace](https://github.com/baskingspot/protobuf/blob/main/src/root.zig)
links the API declarations and their contracts.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/protobuf/v0.2.0.tar.gz
```

The package builds with Zig 0.17. Its pre-1.0 API is unstable.

## Import it

Add the module in `build.zig`:

```zig
const protobuf = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("protobuf", protobuf.module("protobuf"));
```

Import the namespace:

```zig
const pb = @import("protobuf");
```

## Read the examples

[`docs/examples/`](https://github.com/baskingspot/protobuf/tree/main/docs/examples)
contains executable examples. `just test` compiles and runs them alongside the
library tests.

# Wire format

`Writer` wraps a `std.Io.Writer`. A tag identifies the field number and wire
type. The value follows that tag.

```zig
var buffer: [16]u8 = undefined;
var io: std.Io.Writer = .fixed(&buffer);
var w: pb.Writer = .init(&io);
try w.writeTag(try .init(1, .varint));
try w.writeScalar(.u32, 150);
// io.buffered() is 08 96 01: field 1, varint 150.
```

`Reader.next` reads one field from a `std.Io.Reader`. `Field.fieldNumber`
identifies the field, and `Field.expect` selects its wire representation.

```zig
var input: std.Io.Reader = .fixed(io.buffered());
var r: pb.Reader = .init(&input);
const field = (try r.next()).?;
const number = field.fieldNumber();
const value = field.expect(.varint).as(.u32);
```

`Reader.Field.Len` represents a length-delimited value. `data` borrows bytes
from the reader buffer and returns `error.NotBuffered` if that buffer lacks the
complete value. The borrowed slice stays valid until the next read from that
reader. `bytes(buf)` copies the value into the caller's buffer.

The [wire example](https://github.com/baskingspot/protobuf/blob/main/docs/examples/wire.zig)
checks the encoded bytes and the field values above.

# Typed messages

A message is a Zig struct with a `pub const protobuf` descriptor. Each entry
names a field and its wire number. The helpers select the wire representation.

```zig
const Person = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .id = pb.field(1),
        .name = pb.string(2),
        .blob = pb.bytes(3),
    };

    id: u32 = 0,
    name: []const u8 = "",
    blob: []const u8 = "",
};
```

`encode(T, value, options, writer)` writes the message through `Writer`.
`encodedSize(T, value, options)` returns the exact byte count without output.
The [typed example](https://github.com/baskingspot/protobuf/blob/main/docs/examples/typed.zig)
compares those bytes with explicit field writes and checks the size.

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try pb.encode(Person, .{ .id = 150, .name = "Ada" }, .{}, &out.writer);
var parsed = try pb.decodeFromSlice(Person, gpa, out.written(), .{});
defer parsed.deinit();
```

The wire format has no message delimiter. `decode` reads until the reader ends.
A persistent stream adds a length before each message. Refer to
[Message streams](#message-streams).

# Unknown fields

A decoder skips a field number that no table entry claims. A struct with a
field of type `pb.Unknown` keeps those fields instead, and `encode` writes them
back. An older schema then passes a newer message through without deleting it.

```zig
const Person = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .id = pb.field(1) };

    id: u32 = 0,
    unknown: pb.Unknown = .{},
};
```

`pb.Unknown.records` holds one record for each skipped field, in arrival order.
A record holds the field number and the value as it arrived: `varint`,
`fixed32`, `fixed64`, or `len`. A `len` record borrows its bytes from the input
when the decoder borrows, in the same way as a `string` field.

The `unknown` field is not part of `Descriptor(@This())`, and its name is
yours. Declare one field of this type. Two such fields are a compile error.

`encode` writes the records after the declared fields. Field order has no
meaning in the format, so a round trip can move a field.

A record array needs an allocator, so a message with an `Unknown` field cannot
use `decodeBorrowed`. Use `decodeFromSliceLeaky` instead.

# Message streams

A message carries no length of its own, so a stream of messages writes a
varint length before each one. `pb.delimited` writes and reads that framing.

`pb.delimited.encode(T, value, options, writer)` writes the length and then the
message. `pb.delimited.writeBytes(writer, bytes)` writes bytes that are already
encoded.

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try pb.delimited.encode(Person, .{ .id = 150 }, .{}, &out.writer);
```

`pb.delimited.Reader.next` returns the next frame as a `Frame`, or `null` at a
clean end of stream. `Frame.fields` returns a `Reader` bounded to that message,
so field reads stop at the end of the frame and never enter the next one.

```zig
var input: std.Io.Reader = .fixed(out.written());
var frames: pb.delimited.Reader = .init(&input);
while (try frames.next()) |frame| {
    while (try frame.fields().next()) |field| {
        // One field of this message.
        _ = field;
    }
}
```

`Frame.rest` returns the whole frame, borrowed from the reader buffer.
`Frame.readAll(buf)` copies it. `Frame.drain` skips the rest of it. The next
call to `next` skips the unread part of the current frame, so a caller does not
have to read a frame to its end.

A stream that ends in the middle of a length, or a length with no payload
behind it, returns `error.Truncated`. The
[stream example](https://github.com/baskingspot/protobuf/blob/main/docs/examples/delimited.zig)
writes two messages and reads them back.

# Ownership

`decodeFromSlice` borrows strings and bytes from its input. That input must
outlive the returned `Parsed` value. The result's arena owns repeated-field
arrays. `Parsed.deinit` frees the arena without freeing the input.

`decode` copies strings and bytes into its arena. The reader can reuse its
buffer after the decode returns. `Parsed.deinit` frees those copies and the
repeated-field arrays.

`decodeLeaky` and `decodeFromSliceLeaky` return a bare value with no `deinit`
method. Their allocations use the caller's allocator. A caller-owned arena can
release all allocations, including allocations before a decode error.
`decodeFromSliceLeaky` still borrows string and byte data from the input.

The [ownership example](https://github.com/baskingspot/protobuf/blob/main/docs/examples/ownership.zig)
checks borrowed pointers and copied values. It also demonstrates both leaky
variants with a caller-owned arena.

# Encoding options

`EncodeOptions.write_defaults` defaults to `false`. Zero-valued scalar fields
then produce no bytes. A present optional field produces output even when its
value is zero.

`DecodeOptions.validate_utf8` defaults to `true`. It rejects invalid UTF-8 in
string fields. Byte fields do not receive UTF-8 checks.

# Limits

Group wire types return `error.InvalidWireType`, so an unknown group field is
an error and not an `Unknown` record. The package does not parse `.proto` files
or generate Zig types.

Maps use repeated entry messages. Each entry places its key in field 1 and its
value in field 2. There is no separate map helper.
