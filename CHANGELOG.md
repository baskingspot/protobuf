# Changelog

All notable changes to protobuf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
