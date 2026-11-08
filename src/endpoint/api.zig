//! An API's endpoints, and the named types that cross them: what the
//! generators (`typescript`, `openapi`) walk.

const std = @import("std");
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;

pub const Named = struct { name: []const u8, ep: Endpoint };
/// A named struct, and its name worked out once.
pub const Record = struct { T: type, name: []const u8 };

/// `Api`'s `pub` declarations that are endpoints.
pub fn endpointsOf(comptime Api: type) []const Named {
    var list: []const Named = &.{};
    for (@typeInfo(Api).@"struct".decl_names) |d| {
        const v = @field(Api, d);
        if (@TypeOf(v) == Endpoint) list = list ++ .{Named{ .name = d, .ep = v }};
    }
    return list;
}

/// The named structs `eps` take and answer with, each once; two that would
/// cross under one name don't compile.
pub fn recordsOf(comptime eps: []const Named) []const Record {
    var list: []const Record = &.{};
    for (eps) |e| for (.{ e.ep.spec.params, e.ep.spec.query, e.ep.spec.body, e.ep.result }) |T| {
        if (T != endpoint.Multipart and T != endpoint.BodyStream) list = recordsIn(list, T);
    };
    for (list, 0..) |a, i| for (list[i + 1 ..]) |b| if (std.mem.eql(u8, a.name, b.name)) {
        @compileError("two types cross as " ++ a.name ++ ": " ++ @typeName(a.T) ++ " and " ++ @typeName(b.T));
    };
    return list;
}

/// A struct's own name, an identifier: none for one made in place
/// (`score__struct_12`), or of a generic (`Page(Score)`), which crosses
/// written out. One pass over the type's name.
pub fn ownName(comptime T: type) ?[]const u8 {
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) return null;
    const full = @typeName(T);
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(', ')', '[', ']', '{', '}', '*', '?', ',', ' ' => return null,
        '.' => start = i + 1,
        '_' => if (std.mem.startsWith(u8, full[i..], "__struct_")) return null,
        else => {},
    };
    return full[start..];
}

/// `list` and the named structs `T` reaches, each once. One is listed
/// before its fields are walked, so a type holding itself ends.
pub fn recordsIn(comptime list: []const Record, comptime T: type) []const Record {
    switch (@typeInfo(T)) {
        .optional => |o| return recordsIn(list, o.child),
        .pointer => |p| return recordsIn(list, p.child),
        .array => |a| return recordsIn(list, a.child),
        .@"struct" => |s| {
            if (@hasDecl(T, "jsonStringify") or T == endpoint.File) return list;
            for (list) |seen| if (seen.T == T) return list;
            var out: []const Record = if (ownName(T)) |n| list ++ .{Record{ .T = T, .name = n }} else list;
            for (s.field_types) |F| out = recordsIn(out, F);
            return out;
        },
        else => return list,
    }
}

/// `pattern` with each `:name` as `pre ++ name ++ post`: `/scores/{game}`.
pub fn fillPath(comptime pattern: []const u8, comptime pre: []const u8, comptime post: []const u8) []const u8 {
    var out: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    while (it.next()) |seg| out = out ++ "/" ++ if (seg[0] == ':') pre ++ seg[1..] ++ post else seg;
    return if (out.len == 0) "/" else out;
}

const Inner = struct { a: u8 };
const Outer = struct { inner: Inner, more: []const Inner };

test "the named structs a type reaches, each once, one inside another too" {
    const list = comptime recordsIn(&.{}, Outer);
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqualStrings("Outer", list[0].name);
    try std.testing.expectEqualStrings("Inner", list[1].name);
    try std.testing.expectEqualStrings("/a/{b}/c", comptime fillPath("/a/:b/c", "{", "}"));
}
