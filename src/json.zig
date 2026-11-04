//! An answer's JSON: what `std.json.Stringify.value` writes with its default
//! options, byte for byte, faster for the shapes answers take. A struct's
//! field names are escaped at compile time and written with its punctuation
//! in one piece, and a string that needs no escaping is copied whole. What
//! std.json does more with (a type's own `jsonStringify`, unions, floats,
//! strings to escape or that aren't UTF-8) is left to it.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn write(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime std.meta.hasFn(T, "jsonStringify")) return std.json.Stringify.value(value, .{}, w);
    switch (@typeInfo(T)) {
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int => return w.printInt(value, 10, .lower, .{}),
        .optional => return if (value) |v| write(w, v) else w.writeAll("null"),
        .@"enum" => |e| if (comptime e.mode == .exhaustive) {
            switch (value) {
                inline else => |tag| return w.writeAll(comptime quoted(@tagName(tag))),
            }
        },
        .@"struct" => |s| if (comptime !s.is_tuple) {
            comptime var sep: []const u8 = "{";
            inline for (s.field_names, s.field_types) |name, F| {
                if (F == void) continue;
                try w.writeAll(comptime sep ++ quoted(name) ++ ":");
                try write(w, @field(value, name));
                sep = ",";
            }
            return w.writeAll(comptime if (std.mem.eql(u8, sep, "{")) "{}" else "}");
        },
        .pointer => |p| switch (p.size) {
            .one => if (@typeInfo(p.child) == .array) {
                return write(w, @as([]const std.meta.Elem(p.child), value));
            } else return write(w, value.*),
            .slice => if (p.child == u8) {
                if (plain(value)) {
                    try w.writeByte('"');
                    try w.writeAll(value);
                    return w.writeByte('"');
                }
            } else {
                try w.writeByte('[');
                for (value, 0..) |x, i| {
                    if (i > 0) try w.writeByte(',');
                    try write(w, x);
                }
                return w.writeByte(']');
            },
            else => {},
        },
        .array => return write(w, @as([]const std.meta.Elem(T), &value)),
        else => {},
    }
    return std.json.Stringify.value(value, .{}, w);
}

/// No control byte, `"` or `\`, and UTF-8: a JSON string's text as it is.
fn plain(s: []const u8) bool {
    const n = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(n, u8);
    var high = false;
    var i: usize = 0;
    while (i + n <= s.len) : (i += n) {
        const v: V = s[i..][0..n].*;
        const bad = (v < @as(V, @splat(0x20))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\')));
        if (@reduce(.Or, bad)) return false;
        high = high or @reduce(.Or, v >= @as(V, @splat(0x80)));
    }
    for (s[i..]) |c| {
        if (c < 0x20 or c == '"' or c == '\\') return false;
        high = high or c >= 0x80;
    }
    // std.json writes a string that isn't UTF-8 as an array of its bytes.
    return !high or std.unicode.utf8ValidateSlice(s);
}

fn quoted(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len * 6 + 2]u8 = undefined;
        var fw: Writer = .fixed(&buf);
        std.json.Stringify.encodeJsonString(s, .{}, &fw) catch unreachable;
        const done = buf[0..fw.end].*;
        return &done;
    }
}

test "the same bytes std.json writes" {
    const Mode = enum { solo, team };
    const Inner = struct { mode: Mode, tags: []const []const u8, nothing: void = {} };
    const Custom = struct {
        n: u8,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n * 2);
        }
    };
    const Value = struct {
        id: u64,
        neg: i32,
        name: []const u8,
        quote: []const u8,
        long: []const u8,
        utf8: []const u8,
        bytes: []const u8,
        fixed: [4]u8,
        on: bool,
        maybe: ?u32,
        none: ?u32,
        inner: Inner,
        list: []const Inner,
        empty: struct {},
        custom: Custom,
        float: f64,
        tuple: struct { u8, bool },
        u: union(enum) { a: u8, b: void },
        @"we\"ird": u8,
        ptr: *const u8,
    };
    const one: u8 = 1;
    const v: Value = .{
        .id = 1 << 60,
        .neg = -42,
        .name = "battle",
        .quote = "say \"hi\"\\ \n\t\x01",
        .long = "a string longer than sixteen bytes, all of it plain",
        .utf8 = "café ☕ and more than sixteen bytes",
        .bytes = "\xff\xfe",
        .fixed = "none".*,
        .on = true,
        .maybe = 7,
        .none = null,
        .inner = .{ .mode = .team, .tags = &.{ "x", "y" } },
        .list = &.{ .{ .mode = .solo, .tags = &.{} }, .{ .mode = .team, .tags = &.{"z"} } },
        .empty = .{},
        .custom = .{ .n = 21 },
        .float = 1.5,
        .tuple = .{ 3, false },
        .u = .{ .a = 9 },
        .@"we\"ird" = 2,
        .ptr = &one,
    };
    var ours: Writer.Allocating = .init(std.testing.allocator);
    defer ours.deinit();
    try write(&ours.writer, v);
    const theirs = try std.json.Stringify.valueAlloc(std.testing.allocator, v, .{});
    defer std.testing.allocator.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours.written());
}
