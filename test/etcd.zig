//! A real schema, modeled by hand, as a trial of the typed layer.
//!
//! These are the etcd v3 messages an etcd client needs: key-value pairs,
//! watch events, and the KV and watch RPCs. The field numbers and types are
//! copied from etcd's own `api/mvccpb/kv.proto` and
//! `api/etcdserverpb/rpc.proto`, both kept under `data/etcd`, and the bytes
//! they encode to live in `data/fixtures.txtar`, so the tests check interop
//! with a real protobuf implementation rather than with this library's own
//! encoder.
//!
//! This file is a trial, not shipped API. It exists to find out what a real
//! schema feels like through this layer.

const std = @import("std");
const testing = std.testing;
const pb = @import("protobuf");
const testingx = @import("testingx");

// mvccpb

/// A revision of a key. `key` and `value` are arbitrary bytes, not text.
pub const KeyValue = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .key = pb.bytes(1),
        .create_revision = pb.field(2),
        .mod_revision = pb.field(3),
        .version = pb.field(4),
        .value = pb.bytes(5),
        .lease = pb.field(6),
    };

    key: []const u8 = "",
    create_revision: i64 = 0,
    mod_revision: i64 = 0,
    version: i64 = 0,
    value: []const u8 = "",
    lease: i64 = 0,
};

pub const Event = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .type = pb.field(1),
        .kv = pb.field(2),
        .prev_kv = pb.field(3),
    };

    /// A case name is what JSON writes for the value, so it is the `.proto`
    /// name. The wire carries the number.
    pub const EventType = enum(i32) {
        PUT = 0,
        DELETE = 1,
    };

    /// `type` is a Zig keyword, so the field is quoted. The table names the
    /// field by its Zig name, so `@"type"` is the whole cost.
    type: EventType = .PUT,
    kv: ?KeyValue = null,
    prev_kv: ?KeyValue = null,
};

// etcdserverpb

pub const ResponseHeader = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .cluster_id = pb.field(1),
        .member_id = pb.field(2),
        .revision = pb.field(3),
        .raft_term = pb.field(4),
        .leader_id = pb.field(5),
    };

    cluster_id: u64 = 0,
    member_id: u64 = 0,
    revision: i64 = 0,
    raft_term: u64 = 0,
    leader_id: u64 = 0,
};

pub const RangeRequest = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .key = pb.bytes(1),
        .range_end = pb.bytes(2),
        .limit = pb.field(3),
        .revision = pb.field(4),
        .sort_order = pb.field(5),
        .sort_target = pb.field(6),
        .serializable = pb.field(7),
        .keys_only = pb.field(8),
        .count_only = pb.field(9),
        .min_mod_revision = pb.field(10),
        .max_mod_revision = pb.field(11),
        .min_create_revision = pb.field(12),
        .max_create_revision = pb.field(13),
    };

    pub const SortOrder = enum(i32) { NONE = 0, ASCEND = 1, DESCEND = 2 };
    pub const SortTarget = enum(i32) { KEY = 0, VERSION = 1, CREATE = 2, MOD = 3, VALUE = 4 };

    key: []const u8 = "",
    range_end: []const u8 = "",
    limit: i64 = 0,
    revision: i64 = 0,
    sort_order: SortOrder = .NONE,
    sort_target: SortTarget = .KEY,
    serializable: bool = false,
    keys_only: bool = false,
    count_only: bool = false,
    min_mod_revision: i64 = 0,
    max_mod_revision: i64 = 0,
    min_create_revision: i64 = 0,
    max_create_revision: i64 = 0,
};

pub const RangeResponse = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .header = pb.field(1),
        .kvs = pb.field(2),
        .more = pb.field(3),
        .count = pb.field(4),
    };

    header: ?ResponseHeader = null,
    kvs: []const KeyValue = &.{},
    more: bool = false,
    count: i64 = 0,
};

pub const PutRequest = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .key = pb.bytes(1),
        .value = pb.bytes(2),
        .lease = pb.field(3),
        .prev_kv = pb.field(4),
        .ignore_value = pb.field(5),
        .ignore_lease = pb.field(6),
    };

    key: []const u8 = "",
    value: []const u8 = "",
    lease: i64 = 0,
    prev_kv: bool = false,
    ignore_value: bool = false,
    ignore_lease: bool = false,
};

pub const PutResponse = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .header = pb.field(1),
        .prev_kv = pb.field(2),
    };

    header: ?ResponseHeader = null,
    prev_kv: ?KeyValue = null,
};

pub const WatchResponse = struct {
    pub const protobuf: pb.Descriptor(@This()) = .{
        .header = pb.field(1),
        .watch_id = pb.field(2),
        .created = pb.field(3),
        .canceled = pb.field(4),
        .compact_revision = pb.field(5),
        .cancel_reason = pb.string(6),
        .fragment = pb.field(7),
        .events = pb.field(11),
    };

    header: ?ResponseHeader = null,
    watch_id: i64 = 0,
    created: bool = false,
    canceled: bool = false,
    compact_revision: i64 = 0,
    cancel_reason: []const u8 = "",
    fragment: bool = false,
    events: []const Event = &.{},
};

const fixtures = testingx.fixtures(@embedFile("data/fixtures.txtar"));
const range_golden = fixtures.hex("etcd/RangeResponse.pb");

/// JSON written by google.protobuf's `json_format` over the same text-format
/// messages, so the two encodings come from two reference implementations.
/// `just protojson` regenerates it.
const json_fixtures = testingx.fixtures(@embedFile("data/json.txtar"));
const json_eql = @import("json_fixtures.zig");

test "decode a RangeResponse protoc wrote" {
    var parsed = try pb.decodeFromSlice(RangeResponse, testing.allocator, range_golden, .{});
    defer parsed.deinit();
    const response = parsed.value;

    const header = response.header.?;
    try testing.expectEqual(1234, header.cluster_id);
    try testing.expectEqual(5678, header.member_id);
    try testing.expectEqual(42, header.revision);
    try testing.expectEqual(3, header.raft_term);
    try testing.expectEqual(9, header.leader_id);

    try testing.expectEqual(2, response.kvs.len);
    try testing.expectEqualStrings("foo", response.kvs[0].key);
    try testing.expectEqual(10, response.kvs[0].create_revision);
    try testing.expectEqualStrings("bar", response.kvs[0].value);

    // A binary key, and a value that is not UTF-8. Under a `string` default
    // this decode would fail, which is why these fields say `.bytes`.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff, 0x01 }, response.kvs[1].key);
    try testing.expectEqualSlices(u8, &.{ 0xc3, 0x28 }, response.kvs[1].value);

    try testing.expect(response.more);
    try testing.expectEqual(2, response.count);
}

test "re-encode a RangeResponse byte for byte" {
    var parsed = try pb.decodeFromSlice(RangeResponse, testing.allocator, range_golden, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(RangeResponse, parsed.value, .{}, &out.writer);

    try testing.expectEqualSlices(u8, range_golden, out.written());
}

test "encode a RangeRequest the way protoc does" {
    const request: RangeRequest = .{
        .key = "foo",
        .range_end = "fop",
        .limit = 10,
        .revision = 42,
        .sort_order = .DESCEND,
        .sort_target = .MOD,
        .serializable = true,
        .keys_only = true,
        .min_mod_revision = 5,
    };

    const golden = fixtures.hex("etcd/RangeRequest.pb");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(RangeRequest, request, .{}, &out.writer);
    try testing.expectEqualSlices(u8, golden, out.written());
    try testing.expectEqual(golden.len, pb.encodedSize(RangeRequest, request, .{}));
}

const watch_golden = fixtures.hex("etcd/WatchResponse.pb");

test "decode a WatchResponse with events" {
    var parsed = try pb.decodeFromSlice(WatchResponse, testing.allocator, watch_golden, .{});
    defer parsed.deinit();
    const response = parsed.value;

    try testing.expectEqual(101, response.header.?.revision);
    try testing.expectEqual(7, response.watch_id);
    try testing.expect(response.created);
    try testing.expect(!response.canceled);

    try testing.expectEqual(2, response.events.len);

    const put = response.events[0];
    try testing.expectEqual(Event.EventType.PUT, put.type);
    try testing.expectEqualStrings("/registry/nodes/a", put.kv.?.key);
    try testing.expectEqual(5, put.kv.?.lease);
    try testing.expect(put.prev_kv == null);

    const delete = response.events[1];
    try testing.expectEqual(Event.EventType.DELETE, delete.type);
    try testing.expectEqual(88, delete.kv.?.mod_revision);
    try testing.expectEqualStrings("bye", delete.prev_kv.?.value);
    try testing.expectEqual(3, delete.prev_kv.?.version);
}

test "re-encode a WatchResponse byte for byte" {
    var parsed = try pb.decodeFromSlice(WatchResponse, testing.allocator, watch_golden, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(WatchResponse, parsed.value, .{}, &out.writer);

    try testing.expectEqualSlices(u8, watch_golden, out.written());
}

test "an empty message is zero bytes and decodes to defaults" {
    const request: PutRequest = .{};
    try testing.expectEqual(0, pb.encodedSize(PutRequest, request, .{}));

    var parsed = try pb.decodeFromSlice(PutRequest, testing.allocator, &.{}, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.key);
    try testing.expectEqual(0, parsed.value.lease);
    try testing.expect(!parsed.value.prev_kv);
}

test "unknown and mismatched fields are skipped" {
    // Field 9 as a varint into PutRequest, which has no field 9, and field 1
    // declared as varint where `key` wants bytes.
    const bytes = [_]u8{
        0x48, 0x2a, // unknown field 9, varint 42
        0x08, 0x07, // field 1 with the wrong wire type
        0x12, 0x02, 'h', 'i', // value = "hi"
    };

    var parsed = try pb.decodeFromSlice(PutRequest, testing.allocator, &bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.key);
    try testing.expectEqualStrings("hi", parsed.value.value);
}

test "an Unknown field keeps what the schema does not have" {
    const Keeping = struct {
        pub const protobuf: pb.Descriptor(@This()) = .{
            .key = pb.bytes(1),
            .value = pb.bytes(2),
        };

        key: []const u8 = "",
        value: []const u8 = "",
        unknown: pb.Unknown = .{},
    };

    // The same bytes as above: field 9 varint 42, field 1 with the wrong wire
    // type, then the value.
    const bytes = [_]u8{
        0x48, 0x2a, // unknown field 9, varint 42
        0x08, 0x07, // field 1 with the wrong wire type
        0x12, 0x02, 'h', 'i', // value = "hi"
    };

    var parsed = try pb.decodeFromSlice(Keeping, testing.allocator, &bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.key);
    try testing.expectEqualStrings("hi", parsed.value.value);
    try testing.expectEqual(@as(usize, 2), parsed.value.unknown.records.len);

    const first = parsed.value.unknown.records[0].varint;
    try testing.expectEqual(@as(u32, 9), first.number);
    try testing.expectEqual(@as(u64, 42), first.value);

    const second = parsed.value.unknown.records[1].varint;
    try testing.expectEqual(@as(u32, 1), second.number);
    try testing.expectEqual(@as(u64, 7), second.value);

    // Encoding writes them back after the fields the schema knows, which is a
    // different order and the same message.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(Keeping, parsed.value, .{}, &out.writer);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x12, 0x02, 'h', 'i', // value
            0x48, 0x2a, // unknown field 9
            0x08, 0x07, // field 1, wrong wire type
        },
        out.written(),
    );

    var again = try pb.decodeFromSlice(Keeping, testing.allocator, out.written(), .{});
    defer again.deinit();
    try testing.expectEqual(@as(usize, 2), again.value.unknown.records.len);
    try testing.expectEqual(@as(u64, 42), again.value.unknown.records[0].varint.value);
}

test "the JSON fixture decodes to the bytes protoc wrote" {
    // Two reference implementations, one message: the JSON printer's output
    // goes through this decoder and this encoder, and has to come out as the
    // bytes protoc made from the same text-format source.
    var parsed = try pb.json.decode(
        RangeRequest,
        json_fixtures.get("etcd/RangeRequest.json"),
        .{},
        testing.allocator,
    );
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try pb.encode(RangeRequest, parsed.value, .{}, &out.writer);
    try testing.expectEqualSlices(u8, fixtures.hex("etcd/RangeRequest.pb"), out.written());

    // And the JSON this layer writes says the same thing as the reference's.
    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try pb.json.encode(RangeRequest, parsed.value, .{}, &json.writer);
    try json_eql.expectSame(json_fixtures.get("etcd/RangeRequest.json"), json.written());
}
