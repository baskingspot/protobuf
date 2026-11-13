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
- [Oneofs](#oneofs): a `?U` field sets one union case at a time, and each case carries its own number.
- [Unknown fields](#unknown-fields): a field typed `pb.Unknown` keeps the fields the table does not declare, and `encode` writes them back.
- [JSON](#json): `pb.json` writes and reads the proto3 JSON mapping, with the well-known types in their own forms.
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

## Maps

A map is a repeated entry message: the key in field 1 and the value in field 2.
The field is a slice of that entry, and `pb.map` marks it.

```zig
const Entry = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .key = pb.string(1), .value = pb.field(2) };

    key: []const u8 = "",
    value: i64 = 0,
};

const Item = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .attrs = pb.map(25) };

    attrs: []const Entry = &.{},
};
```

The binary encoding is the entry list, which is what the wire format carries.
JSON writes the same field as one object, which is what the mapping requires.
The slice stays a slice because protobuf leaves the entry order unspecified, so
a caller that needs a lookup structure builds it from the slice.

# Oneofs

A oneof sets one case at a time. The Zig field is `?U`, where `U` is a
`union(enum)` that declares a field number for each case.

```zig
const Pick = union(enum) {
    pub const protobuf: pb.Variants(@This()) = .{
        .number = pb.field(2),
        .name = pb.string(3),
    };

    number: i32,
    name: []const u8,
};

const Reply = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{ .pick = pb.oneof() };

    pick: ?Pick = null,
};
```

`pb.Variants(@This())` is the case table. It does the job `Descriptor` does for
a message: the compiler checks that every case has an entry and that no other
name is present. `pb.oneof()` marks the field, and the field has no number of
its own.

A decode reads the case that the wire carried and replaces the case before it.
The last case on the wire wins. `null` means that the message carried no case.

An encode writes the case that is set, and writes nothing for `null`. A case is
written even when its value is the type's zero: the tag is the presence, so
`.number = 0` and `null` are different messages.

A case is singular and has no optional wrapper, because the union tag is its
presence. Both are compile errors, as is a oneof inside a oneof. The
[oneof example](https://github.com/baskingspot/protobuf/blob/main/docs/examples/oneof.zig)
checks the last case on the wire and a case that holds zero.

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

# JSON

`pb.json` reads and writes the proto3 JSON mapping. The same `Descriptor` table
drives both encodings, so a message has one schema and two forms.

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try pb.json.encode(Person, person, .{}, &out.writer);

var parsed = try pb.json.decode(Person, out.written(), .{}, gpa);
defer parsed.deinit();
```

The rules that this follows:

- A field name is lowerCamelCase in the output. The parser accepts that name
  and the original Zig name.
- A 64-bit integer is a JSON string, because a JSON number stops counting
  exactly at 2^53. A 32-bit integer is a number. The parser accepts a number or
  a string for both.
- `bytes` is standard base64. The parser also accepts the URL-safe alphabet
  and missing padding.
- An enum is the name of its case, so declare the cases with the `.proto`
  names: `FIRST`, not `first`. The parser accepts a number as well. A number
  with no member is `error.UnknownEnumTag`, the same as the binary decoder.
- A `pb.map` field is one JSON object, with each key as a member name. An
  integer key is its digits in quotes, and a message value is an object.
- A `float` that is not a number is one of the strings `"NaN"`, `"Infinity"`,
  and `"-Infinity"`.
- A field with no presence that holds its default value is not written. A oneof
  case is written even when its value is zero, because the tag is the presence.
- An object key that no field claims is `error.UnknownField`. Set
  `pb.json.Options.ignore_unknown_fields` to skip it instead.
- A `null` value leaves its field unset.

`Options.use_proto_names` writes the Zig field names instead of the camelCase
names. The parser accepts both spellings whatever this option says.

## Base64

A `bytes` field is base64, and a large payload spends most of its JSON time in
the codec. std's codec is scalar: `pb.json` reaches about 60 MB/s of payload
with it. `Options.base64` selects another codec, which is four functions and no
state:

```zig
const stdx = @import("stdx");

const fast: pb.json.Base64 = .{
    .encoded_len = stdx.base64.standard.encodedLen,
    .encode = stdx.base64.standard.encode,
    .decoded_len = stdx.base64.standard.decodedLen,
    .decode = stdx.base64.standard.decode,
};

try pb.json.encode(Blob, blob, .{ .base64 = fast }, &out.writer);
```

`stdx.base64` moves whole vectors per instruction, and the same payload goes at
about 900 MB/s. Decoding is different: the JSON scanner walks every character
of the string before the codec sees it, so a large `bytes` field parses at
about 40 MB/s whatever codec is selected.

The codec needs a canonical alphabet, so the parser still accepts the URL-safe
alphabet and missing padding by normalizing the text first. It copies the text
only when it needs padding; canonical input is decoded in place.

The decoder copies every string and array into an arena, so `pb.json` has no
borrowing form: the scanner's string is only valid until the next token.
`decodeLeaky` allocates from the allocator that you pass.

[`docs/examples/json.zig`](https://github.com/baskingspot/protobuf/blob/main/docs/examples/json.zig)
writes a message and reads it back.

## Well-known types

A well-known type has a form of its own, and `pb.wkt` holds the ones that are
plain messages:

| Type                                              | JSON                         |
| ------------------------------------------------- | ---------------------------- |
| `pb.wkt.Timestamp`                                | `"2024-04-05T12:34:56.500Z"` |
| `pb.wkt.Duration`                                 | `"3.500s"`                   |
| `pb.wkt.Int32Value`, and the eight other wrappers | the bare value: `5`, `"abc"` |
| `pb.wkt.FieldMask`                                | `"userId,displayName"`       |
| `pb.wkt.Empty`                                    | `{}`                         |

A timestamp is always written in UTC, and a fraction has three, six, or nine
digits: the fewest that name the value. A duration keeps the sign of both
halves. A field mask converts between the camelCase paths of JSON and the
snake_case paths of the message.

`google.protobuf.Any`, `Struct`, `Value`, and `ListValue` are not in `pb.wkt`.
`Any` needs a registry from a type URL to a message, and the other three hold
themselves, which this layer cannot express.

## The fixtures

The tests compare against JSON that `google.protobuf`'s `json_format` wrote, so
the oracle is the reference implementation and not this package's idea of it.
`just protojson` regenerates `test/data/json.txtar` from the same text-format
messages that `just proto` gives to protoc. A fixture pair therefore describes
one message in two encodings from two implementations, and the tests check that
both describe the same message: the JSON decodes to a value that encodes to
protoc's bytes, or the value this layer writes is the JSON the reference
printer wrote.

The comparison is structural: member order and whitespace carry no meaning in
JSON, so neither is compared. A map written in another order is the same map.

This is not the conformance suite. The upstream suite covers cases that this
layer does not claim: `Any`, `Struct`, and `Value`, editions, and the exact
treatment of a duplicate key.

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

No `.proto` parser, no code generation, no groups, no extensions, and no
`Any`, `Struct`, or `Value`. A text-format reader and writer are also absent.
