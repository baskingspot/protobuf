<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="protobuf" height="48">
  </picture>
</h1>

Protocol Buffers in Zig: the wire format, and a typed layer over plain structs.

`Writer` writes a tag, a scalar, or length-delimited bytes. `Reader.next`
returns one field at a time. The core loop allocates nothing, and neither side
knows a schema.

```zig
var buffer: [16]u8 = undefined;
var io: std.Io.Writer = .fixed(&buffer);
var w: pb.Writer = .init(&io);
try w.writeTag(try .init(1, .varint));
try w.writeScalar(.u32, 150);
// io.buffered() is 08 96 01: field 1, varint 150.
```

`encode` and `decode` build on those primitives. A plain Zig struct declares
its field numbers in a `Descriptor(@This())` table.

The project is incubating. Its pre-1.0 API is unstable.

## What is in it

- [Wire format](docs/content/_index.md#wire-format): `Writer` emits individual fields, and `Reader.next` returns each field from an input reader.
- [Typed messages](docs/content/_index.md#typed-messages): `Descriptor(@This())` maps Zig fields to wire numbers for `encode` and `decode`.
- [Unknown fields](docs/content/_index.md#unknown-fields): a `pb.Unknown` field keeps the fields the table does not declare, so a re-encode writes them back.
- [Message streams](docs/content/_index.md#message-streams): `pb.delimited` writes a varint length before each message and reads the frames back.
- [Ownership](docs/content/_index.md#ownership): `Parsed.deinit` frees decoded allocations, while slice-based decoders borrow string and byte data.
- [Encoding options](docs/content/_index.md#encoding-options): `EncodeOptions` controls default values, and `DecodeOptions` controls UTF-8 checks.

Not implemented:

- Group wire types return `error.InvalidWireType`.
- Map helpers. Maps use repeated entry messages, with the key in field 1 and the value in field 2.

## Install

```sh
zig fetch --save https://baskingspot.dev/protobuf/v0.2.0.tar.gz
```

Add the module in `build.zig`:

```zig
const protobuf = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("protobuf", protobuf.module("protobuf"));
```

Import it as `const pb = @import("protobuf");`. `protobuf` builds with Zig 0.17.

## Documentation

- [The guide](docs/content/_index.md) covers the wire primitives and the typed codec.
- [`src/root.zig`](src/root.zig) is the public namespace. Its doc comments define the API contracts.
- [`docs/examples/`](docs/examples/) contains compiled examples for the guide.
- [`CHANGELOG.md`](CHANGELOG.md) records changes to the public API.

## Work on it

`nix develop` provides the toolchain. `just ci` runs what CI runs: `just test` and `just lint`.

`just test` runs the unit tests, the protoc interop tests, and the examples under `docs/examples/`. `just bench` runs the benchmarks in ReleaseFast.

## License

MIT. See [`LICENSE`](LICENSE).
The logo files in `docs/static/` are baskingspot marks
and are not covered by it. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
