//! The well-known types that are plain messages: `google.protobuf`'s time,
//! duration, wrapper, field-mask, and empty types.
//!
//! Each one is a struct with a descriptor like any other message, so it encodes
//! and decodes with `encode` and `decode`. JSON has a form of its own for each:
//! a `Timestamp` is an RFC 3339 string, a `Duration` is `"3.5s"`, a wrapper is
//! the bare value it wraps, and `FieldMask` is a comma-separated string.
//!
//! `google.protobuf.Any`, `Struct`, `Value`, `ListValue`, and `NullValue` are
//! not here. `Any` needs a registry that maps a type URL to a message, and the
//! other four hold themselves, which this layer cannot express: a message field
//! is a value, not a pointer.

const std = @import("std");
const Io = std.Io;

const proto = @import("proto.zig");

/// Errors in the string form of a `Timestamp` or a `Duration`.
pub const Error = error{
    /// A timestamp that no RFC 3339 string can express: before year 0001,
    /// after year 9999, or nanos outside 0 to 999 999 999.
    InvalidTimestamp,
    /// A duration beyond 315 576 000 000 seconds, or with a sign that the
    /// seconds and the nanos disagree on.
    InvalidDuration,
};

/// The JSON form of a well-known type.
pub const Form = enum {
    /// An RFC 3339 string: `"2024-04-05T12:00:00Z"`.
    timestamp,
    /// Seconds and an optional fraction: `"3.5s"`.
    duration,
    /// The value the type wraps, with no object around it.
    wrapper,
    /// Comma-separated camelCase paths.
    field_mask,
    /// `{}`, with nothing in it.
    empty,
};

/// An instant, `google.protobuf.Timestamp`.
pub const Timestamp = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{
        .seconds = proto.field(1),
        .nanos = proto.field(2),
    };

    /// Seconds from 1970-01-01T00:00:00Z, negative before it.
    seconds: i64 = 0,
    /// Non-negative, below 1e9.
    nanos: i32 = 0,
};

/// A signed span of time, `google.protobuf.Duration`.
pub const Duration = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{
        .seconds = proto.field(1),
        .nanos = proto.field(2),
    };

    seconds: i64 = 0,
    /// The same sign as `seconds`, and below 1e9 in magnitude.
    nanos: i32 = 0,
};

/// A set of field paths, `google.protobuf.FieldMask`.
pub const FieldMask = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{
        .paths = proto.string(1),
    };

    paths: []const []const u8 = &.{},
};

/// `google.protobuf.Empty`: a message with no fields.
pub const Empty = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{};
};

/// A `double` with presence, `google.protobuf.DoubleValue`.
pub const DoubleValue = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: f64 = 0,
};

/// A `float` with presence, `google.protobuf.FloatValue`.
pub const FloatValue = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: f32 = 0,
};

/// An `int64` with presence, `google.protobuf.Int64Value`.
pub const Int64Value = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: i64 = 0,
};

/// A `uint64` with presence, `google.protobuf.UInt64Value`.
pub const UInt64Value = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: u64 = 0,
};

/// An `int32` with presence, `google.protobuf.Int32Value`.
pub const Int32Value = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: i32 = 0,
};

/// A `uint32` with presence, `google.protobuf.UInt32Value`.
pub const UInt32Value = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: u32 = 0,
};

/// A `bool` with presence, `google.protobuf.BoolValue`.
pub const BoolValue = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.field(1) };
    value: bool = false,
};

/// A `string` with presence, `google.protobuf.StringValue`.
pub const StringValue = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.string(1) };
    value: []const u8 = "",
};

/// `bytes` with presence, `google.protobuf.BytesValue`.
pub const BytesValue = struct {
    pub const protobuf: proto.Descriptor(@This()) = .{ .value = proto.bytes(1) };
    value: []const u8 = "",
};

/// The nine wrapper types, in the order the protobuf documentation lists them.
pub const wrappers = .{
    DoubleValue, FloatValue, Int64Value,  UInt64Value, Int32Value,
    UInt32Value, BoolValue,  StringValue, BytesValue,
};

/// The JSON form of `T`, or null when `T` is not a well-known type.
pub fn form(comptime T: type) ?Form {
    if (T == Timestamp) return .timestamp;
    if (T == Duration) return .duration;
    if (T == FieldMask) return .field_mask;
    if (T == Empty) return .empty;
    inline for (wrappers) |W| {
        if (T == W) return .wrapper;
    }
    return null;
}

/// Whether `T` is the wrapper that holds `bytes`, whose JSON form is base64
/// and not a string.
pub fn isBytesWrapper(comptime T: type) bool {
    return T == BytesValue;
}

/// The value type of a wrapper, or null for any other type.
pub fn wrapped(comptime T: type) ?type {
    if (form(T) != .wrapper) return null;
    return @FieldType(T, "value");
}

/// Write `ts` as the RFC 3339 string that JSON and the text format use. The
/// caller writes the quotes.
pub fn writeTimestamp(writer: *Io.Writer, ts: Timestamp) (Error || Io.Writer.Error)!void {
    if (ts.nanos < 0 or ts.nanos > 999_999_999) return Error.InvalidTimestamp;
    // 0001-01-01T00:00:00Z, and 9999-12-31T23:59:59Z.
    if (ts.seconds < -62_135_596_800 or ts.seconds > 253_402_300_799) {
        return Error.InvalidTimestamp;
    }

    const days = @divFloor(ts.seconds, 86_400);
    const of_day: u32 = @intCast(ts.seconds - days * 86_400);
    const date = civilFromDays(days);
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        date.year,
        date.month,
        date.day,
        of_day / 3600,
        (of_day % 3600) / 60,
        of_day % 60,
    });
    try writeFraction(writer, @intCast(ts.nanos));
    try writer.writeByte('Z');
}

/// Read the RFC 3339 string that `writeTimestamp` writes, with a `Z` or a
/// numeric offset. A string without an offset is not a timestamp.
pub fn parseTimestamp(text: []const u8) Error!Timestamp {
    const Bad = Error.InvalidTimestamp;
    if (text.len < 20) return Bad;

    const year = try digits(text, 0, 4);
    if (text[4] != '-') return Bad;
    const month = try digits(text, 5, 2);
    if (text[7] != '-') return Bad;
    const day = try digits(text, 8, 2);
    if (text[10] != 'T') return Bad;
    const hour = try digits(text, 11, 2);
    if (text[13] != ':') return Bad;
    const minute = try digits(text, 14, 2);
    if (text[16] != ':') return Bad;
    const second = try digits(text, 17, 2);

    var at: usize = 19;
    var nanos: i32 = 0;
    if (at < text.len and text[at] == '.') {
        at += 1;
        const start = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        const fraction = text[start..at];
        if (fraction.len == 0 or fraction.len > 9) return Bad;
        var value: i32 = 0;
        for (fraction) |c| value = value * 10 + @as(i32, c - '0');
        var pad: usize = 9 - fraction.len;
        while (pad > 0) : (pad -= 1) value *= 10;
        nanos = value;
    }

    if (at >= text.len) return Bad;
    var offset: i64 = 0;
    switch (text[at]) {
        'Z' => at += 1,
        '+', '-' => {
            if (text.len < at + 6) return Bad;
            const negative = text[at] == '-';
            const oh = try digits(text, at + 1, 2);
            if (text[at + 3] != ':') return Bad;
            const om = try digits(text, at + 4, 2);
            if (oh > 23 or om > 59) return Bad;
            offset = @as(i64, oh) * 3600 + @as(i64, om) * 60;
            if (negative) offset = -offset;
            at += 6;
        },
        else => return Bad,
    }
    if (at != text.len) return Bad;

    if (year < 1 or year > 9999) return Bad;
    if (month < 1 or month > 12) return Bad;
    if (day < 1 or day > daysInMonth(year, month)) return Bad;
    if (hour > 23 or minute > 59 or second > 59) return Bad;

    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const seconds = days * 86_400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second) -
        offset;
    return .{ .seconds = seconds, .nanos = nanos };
}

/// Write `d` as the seconds-and-fraction string that JSON and the text format
/// use: `"3.5s"`. The caller writes the quotes.
pub fn writeDuration(writer: *Io.Writer, d: Duration) (Error || Io.Writer.Error)!void {
    const limit = 315_576_000_000;
    if (d.seconds < -limit or d.seconds > limit) return Error.InvalidDuration;
    if (d.nanos <= -1_000_000_000 or d.nanos >= 1_000_000_000) {
        return Error.InvalidDuration;
    }
    // The two halves are one number, so they cannot disagree on its sign.
    if ((d.seconds > 0 and d.nanos < 0) or (d.seconds < 0 and d.nanos > 0)) {
        return Error.InvalidDuration;
    }

    if (d.seconds < 0 or d.nanos < 0) try writer.writeByte('-');
    try writer.print("{d}", .{@abs(d.seconds)});
    try writeFraction(writer, @intCast(@abs(d.nanos)));
    try writer.writeByte('s');
}

/// Read the string that `writeDuration` writes.
pub fn parseDuration(text: []const u8) Error!Duration {
    const Bad = Error.InvalidDuration;
    if (text.len < 2) return Bad;

    var at: usize = 0;
    const negative = text[0] == '-';
    if (negative) at = 1;

    const start = at;
    while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
    if (at == start or at - start > 12) return Bad;
    const seconds = std.fmt.parseInt(i64, text[start..at], 10) catch return Bad;
    if (seconds > 315_576_000_000) return Bad;

    var nanos: i32 = 0;
    if (at < text.len and text[at] == '.') {
        at += 1;
        const fraction_start = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        const fraction = text[fraction_start..at];
        if (fraction.len == 0 or fraction.len > 9) return Bad;
        var value: i32 = 0;
        for (fraction) |c| value = value * 10 + @as(i32, c - '0');
        var pad: usize = 9 - fraction.len;
        while (pad > 0) : (pad -= 1) value *= 10;
        nanos = value;
    }

    if (at >= text.len or text[at] != 's') return Bad;
    if (at + 1 != text.len) return Bad;

    return .{
        .seconds = if (negative) -seconds else seconds,
        .nanos = if (negative) -nanos else nanos,
    };
}

/// Write 0, 3, 6, or 9 fraction digits: the fewest that name the value.
fn writeFraction(writer: *Io.Writer, nanos: u32) Io.Writer.Error!void {
    if (nanos == 0) return;
    if (nanos % 1_000_000 == 0) {
        try writer.print(".{d:0>3}", .{nanos / 1_000_000});
    } else if (nanos % 1_000 == 0) {
        try writer.print(".{d:0>6}", .{nanos / 1_000});
    } else {
        try writer.print(".{d:0>9}", .{nanos});
    }
}

/// `count` decimal digits at `at`, as a number.
fn digits(text: []const u8, at: usize, count: usize) Error!u32 {
    if (at + count > text.len) return Error.InvalidTimestamp;
    var value: u32 = 0;
    for (text[at .. at + count]) |c| {
        if (!std.ascii.isDigit(c)) return Error.InvalidTimestamp;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0))
            29
        else
            28,
        else => 0,
    };
}

/// Days from 1970-01-01 to a Gregorian date, by eras of 400 years.
/// Howard Hinnant's `days_from_civil`, which is exact for every year.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (month + @as(i64, if (month > 2) -3 else 9)) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The Gregorian date for days from 1970-01-01, the inverse of
/// `daysFromCivil`.
fn civilFromDays(days: i64) struct { year: u32, month: u32, day: u32 } {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) -
        @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{
        .year = @intCast(y + @intFromBool(m <= 2)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

test "civil dates round-trip" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, 19_818), daysFromCivil(2024, 4, 5));

    for ([_]i64{ -719_162, -1, 0, 19_818, 2_932_896 }) |days| {
        const date = civilFromDays(days);
        try std.testing.expectEqual(days, daysFromCivil(date.year, date.month, date.day));
    }

    const date = civilFromDays(19_818);
    try std.testing.expectEqual(@as(u32, 2024), date.year);
    try std.testing.expectEqual(@as(u32, 4), date.month);
    try std.testing.expectEqual(@as(u32, 5), date.day);
}

test "timestamps write what they parsed" {
    const cases = [_][]const u8{
        "1970-01-01T00:00:00Z",
        "2024-04-05T12:34:56Z",
        "1969-12-31T23:59:59Z",
        "0001-01-01T00:00:00Z",
        "9999-12-31T23:59:59Z",
        "2024-04-05T12:34:56.500Z",
        "2024-04-05T12:34:56.000000001Z",
    };
    for (cases) |text| {
        const parsed = try parseTimestamp(text);
        var buffer: [64]u8 = undefined;
        var io: Io.Writer = .fixed(&buffer);
        try writeTimestamp(&io, parsed);
        try std.testing.expectEqualStrings(text, io.buffered());
    }
}

test "a timestamp keeps the instant and drops the offset" {
    try std.testing.expectEqual(@as(i64, 0), (try parseTimestamp("1970-01-01T00:00:00Z")).seconds);
    try std.testing.expectEqual(
        @as(i64, -1),
        (try parseTimestamp("1969-12-31T23:59:59Z")).seconds,
    );

    const plus = try parseTimestamp("2024-04-05T14:34:56+02:00");
    const minus = try parseTimestamp("2024-04-05T10:34:56-02:00");
    try std.testing.expectEqual(@as(i64, 1_712_320_496), plus.seconds);
    try std.testing.expectEqual(@as(i64, 1_712_320_496), minus.seconds);

    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try writeTimestamp(&io, plus);
    try std.testing.expectEqualStrings("2024-04-05T12:34:56Z", io.buffered());
}

test "a timestamp refuses what RFC 3339 cannot say" {
    for ([_][]const u8{
        "2024-04-05T12:34:56", // no offset
        "2024-13-05T12:34:56Z", // month 13
        "2024-02-30T12:34:56Z", // no such day
        "2023-02-29T12:34:56Z", // not a leap year
        "2024-04-05T24:00:00Z", // hour 24
        "0000-01-01T00:00:00Z", // year 0
        "2024-04-05T12:34:56.Z", // an empty fraction
        "2024-04-05T12:34:56.1234567890Z", // ten digits
        "2024-04-05 12:34:56Z", // a space
    }) |text| {
        try std.testing.expectError(Error.InvalidTimestamp, parseTimestamp(text));
    }
}

test "durations round-trip" {
    const cases = [_]struct { text: []const u8, seconds: i64, nanos: i32 }{
        .{ .text = "0s", .seconds = 0, .nanos = 0 },
        .{ .text = "3s", .seconds = 3, .nanos = 0 },
        .{ .text = "3.500s", .seconds = 3, .nanos = 500_000_000 },
        .{ .text = "-3.500s", .seconds = -3, .nanos = -500_000_000 },
        .{ .text = "315576000000s", .seconds = 315_576_000_000, .nanos = 0 },
        .{ .text = "0.000000001s", .seconds = 0, .nanos = 1 },
    };

    for (cases) |case| {
        const parsed = try parseDuration(case.text);
        try std.testing.expectEqual(case.seconds, parsed.seconds);
        try std.testing.expectEqual(case.nanos, parsed.nanos);

        var buffer: [64]u8 = undefined;
        var io: Io.Writer = .fixed(&buffer);
        try writeDuration(&io, parsed);
        try std.testing.expectEqualStrings(case.text, io.buffered());
    }
}

test "a duration refuses mixed signs and bad strings" {
    var buffer: [64]u8 = undefined;
    var io: Io.Writer = .fixed(&buffer);
    try std.testing.expectError(
        Error.InvalidDuration,
        writeDuration(&io, .{ .seconds = 1, .nanos = -1 }),
    );
    for ([_][]const u8{ "3", "3.s", "3.5", "-", "315576000001s", "s" }) |text| {
        try std.testing.expectError(Error.InvalidDuration, parseDuration(text));
    }
}
