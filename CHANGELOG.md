# Changelog

All notable changes to protobuf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `pb.delimited`: `encode`, `writeBytes`, and `Reader`, the varint length prefix
  that separates back-to-back messages on one stream. `Frame.fields` bounds a
  field reader to one message, and `Frame.rest` returns the whole frame.

## [0.2.0] - 2026-11-12

### Changed

- `encode` and `encodedSize` name the message type instead of inferring it:
  `pb.encode(T, value, options, writer)` and
  `pb.encodedSize(T, value, options)`. Existing call sites add the type as
  the first argument.

### Added

- `pb.decodeBorrowed(T, bytes, options)`: decode a message whose strings and
  bytes borrow the input slice, with no allocation and no arena to free.
  `T` must have no repeated field at any depth; that is a compile-time error,
  because an array needs an allocator. `bytes` must outlive the result, which
  for a message read from a stream is until the next read.

## [0.1.0] - 2026-11-10

### Added

- `Reader`, `Writer`, `Tag`, and the wire primitives: varints, zigzag, and the
  four wire types. Fields are read one at a time, with no `.proto` file and no
  generated code.
- The typed layer: `Descriptor`, `field`, `string`, `bytes`, `sint`, `fixed`,
  and `unpacked` describe a plain Zig struct as a message. `encode`,
  `encodedSize`, `decode`, and `decodeFromSlice` read and write it without
  generated code.
- `decodeLeaky` and `decodeFromSliceLeaky` decode into memory the caller owns.
  `Parsed.deinit` frees the arena behind `decode` and `decodeFromSlice`.
- `DecodeOptions.validate_utf8` rejects invalid UTF-8 in `string` fields, and
  `EncodeOptions.write_defaults` writes zero-valued scalar fields.
