# Changelog

All notable changes to protobuf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Reader`, `Writer`, `Tag`, and the wire primitives: varints, zigzag, and the
  four wire types. Fields are read one at a time, with no `.proto` file and no
  generated code.
