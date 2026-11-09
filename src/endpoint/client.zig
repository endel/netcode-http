//! What a client sends for an endpoint, and makes of the answer: what a
//! Zig client is built on, as the TypeScript one is generated.

const std = @import("std");
const Writer = std.Io.Writer;
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;
const Problem = endpoint.Problem;
const BodyStream = endpoint.BodyStream;
const decode = @import("decode.zig");
const Multipart = decode.Multipart;
const scalar = decode.scalar;

/// What a call of `e` takes: `params` when its path has any, `query` when
/// it has fields (optional when they all may be left out), and `body`
/// unless it's `void`. `.{}` for an endpoint that takes nothing.
pub fn Args(comptime e: Endpoint) type {
    const FieldAttributes = std.builtin.Type.Struct.FieldAttributes;
    const s = e.spec;
    var names: []const [:0]const u8 = &.{};
    var types: []const type = &.{};
    var attrs: []const FieldAttributes = &.{};
    if (@typeInfo(s.params).@"struct".field_names.len > 0) {
        names = names ++ .{"params"};
        types = types ++ .{s.params};
        attrs = attrs ++ [_]FieldAttributes{.{}};
    }
    if (@typeInfo(s.query).@"struct".field_names.len > 0) {
        names = names ++ .{"query"};
        types = types ++ .{s.query};
        attrs = attrs ++ [_]FieldAttributes{.{ .default_value_ptr = queryDefault(s.query) }};
    }
    if (s.body != void) {
        names = names ++ .{"body"};
        types = types ++ .{s.body};
        attrs = attrs ++ [_]FieldAttributes{.{}};
    }
    return @Struct(.auto, null, names, types[0..types.len], attrs[0..attrs.len]);
}

/// A query of nothing but defaults and nulls, when every field has one.
fn queryDefault(comptime Q: type) ?*const anyopaque {
    const s = @typeInfo(Q).@"struct";
    var q: Q = undefined;
    for (s.field_names, s.field_types, s.field_attrs) |name, T, a| {
        @field(q, name) = a.defaultValue(T) orelse if (@typeInfo(T) == .optional) null else return null;
    }
    const final = q;
    return &final;
}

/// A status other than 2xx, and the body that came with it.
pub const Status = struct {
    code: u16,
    body: []const u8,

    /// The body as a `Problem`, if it is one.
    pub fn problem(self: Status, arena: std.mem.Allocator) ?Problem {
        return std.json.parseFromSliceLeaky(Problem, arena, self.body, .{ .ignore_unknown_fields = true }) catch null;
    }
};

/// How a call of `e` ended.
pub fn Answer(comptime e: Endpoint) type {
    return union(enum) {
        /// A 2xx, its body read as the result.
        ok: e.result,
        /// Any other status: an error the handler returned (`statusOf`),
        /// or the server's own, a 404 or a 413, say.
        status: Status,
        /// Nothing to read: the server couldn't be reached, the connection
        /// dropped, or a 2xx came with a body that isn't the result.
        failed: anyerror,
    };
}

/// Where a call of `e` goes: its path, params filled in, then its query.
/// A prefix the routes are mounted at goes before it.
pub fn writeTarget(comptime e: Endpoint, args: Args(e), w: *Writer) Writer.Error!void {
    const segments = comptime blk: {
        var list: []const []const u8 = &.{};
        var it = std.mem.tokenizeScalar(u8, e.path, '/');
        while (it.next()) |seg| list = list ++ .{seg};
        break :blk list;
    };
    if (segments.len == 0) try w.writeByte('/');
    inline for (segments) |seg| {
        try w.writeByte('/');
        if (seg[0] == ':') try writeScalar(w, @field(args.params, seg[1..])) else try w.writeAll(seg);
    }
    if (@hasField(Args(e), "query")) {
        var sep: u8 = '?';
        const s = @typeInfo(e.spec.query).@"struct";
        inline for (s.field_names) |name| {
            const v = @field(args.query, name);
            const present = if (@typeInfo(@TypeOf(v)) == .optional) v != null else true;
            if (present) {
                try w.print("{c}{s}=", .{ sep, name });
                try writeScalar(w, v);
                sep = '&';
            }
        }
    }
}

/// The body of a call of `e`: JSON, or the bytes as they are for a
/// `[]const u8` body; nothing for `void`.
pub fn writeBody(comptime e: Endpoint, args: Args(e), w: *Writer) Writer.Error!void {
    const B = e.spec.body;
    if (B == Multipart) @compileError(e.path ++ ": a Zig client doesn't write multipart bodies yet");
    if (B == BodyStream) @compileError(e.path ++ ": a Zig client doesn't stream a body yet");
    if (B == void) return;
    if (B == []const u8) return w.writeAll(args.body);
    try std.json.Stringify.value(args.body, .{}, w);
}

/// The Content-Type of a call's body, none without one.
pub fn contentType(comptime e: Endpoint) ?[]const u8 {
    return switch (e.spec.body) {
        void => null,
        []const u8, BodyStream => "application/octet-stream",
        Multipart => "multipart/form-data",
        else => "application/json",
    };
}

/// The answer to a call of `e`: `status` and `body` as they came, the
/// result parsed into `arena`. `body` must outlive it on a status.
pub fn decodeAnswer(comptime e: Endpoint, status: u16, body: []const u8, arena: std.mem.Allocator) Answer(e) {
    if (status < 200 or status > 299) return .{ .status = .{ .code = status, .body = body } };
    if (e.result == void) return .{ .ok = {} };
    const result = std.json.parseFromSliceLeaky(e.result, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return .{ .failed = err };
    return .{ .ok = result };
}

/// A param or query value, as `parseScalar` reads it back.
fn writeScalar(w: *Writer, v: anytype) Writer.Error!void {
    const T = @TypeOf(v);
    if (comptime !scalar(T)) @compileError("a param or query field can't be " ++ @typeName(T));
    if (T == []const u8) return std.Uri.Component.percentEncode(w, v, isUnreserved);
    switch (@typeInfo(T)) {
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try std.Uri.Component.percentEncode(w, @tagName(v), isUnreserved),
        .optional => if (v) |x| try writeScalar(w, x),
        else => unreachable, // not `scalar`
    }
}

/// What `encodeURIComponent` leaves as it is.
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*'()", c) != null;
}

test "a call's target, as the server's decoders read it back" {
    const Q = struct { top: u8 = 10, since: ?u32 = null, who: ?[]const u8 = null, mode: enum { solo, team } = .solo };
    const e = endpoint.get("/scores/:game/:round", .{ .params = struct { game: []const u8, round: u8 }, .query = Q });
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeTarget(e, .{ .params = .{ .game = "a b/c+é", .round = 3 }, .query = .{ .who = "ann&lee=+", .mode = .team } }, &w);
    const target = w.buffered();
    try std.testing.expectEqualStrings("/scores/a%20b%2Fc%2B%C3%A9/3?top=10&who=ann%26lee%3D%2B&mode=team", target);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const q = try decode.decodeQuery(Q, target[std.mem.indexOfScalar(u8, target, '?').? + 1 ..], arena.allocator(), null);
    try std.testing.expectEqualStrings("ann&lee=+", q.who.?);
    try std.testing.expectEqual(null, q.since);
    try std.testing.expectEqual(.team, q.mode);
    const p = try decode.decodeParams(e.spec.params, &.{ "game", "round" }, false, &.{ "a%20b%2Fc%2B%C3%A9", "3" }, arena.allocator());
    try std.testing.expectEqualStrings("a b/c+é", p.game);
}

test "a call takes only what its endpoint does" {
    const none = endpoint.get("/", .{});
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeTarget(none, .{}, &w);
    try std.testing.expectEqualStrings("/", w.buffered());
    try std.testing.expectEqual(null, contentType(none));

    const Score = struct { player: []const u8, points: u32 };
    const submit = endpoint.post("/scores", .{ .body = Score, .query = struct { since: ?u32 } });
    try std.testing.expect(!@hasField(Args(submit), "params"));
    w = .fixed(&buf);
    try writeBody(submit, .{ .body = .{ .player = "ann", .points = 3 } }, &w);
    try std.testing.expectEqualStrings("{\"player\":\"ann\",\"points\":3}", w.buffered());
    try std.testing.expectEqualStrings("application/json", contentType(submit).?);
    // A query field with neither default nor optional must be given.
    try std.testing.expect(@typeInfo(Args(endpoint.get("/q", .{ .query = struct { n: u8 } }))).@"struct".field_attrs[0].default_value_ptr == null);
}

test "an answer: the result from a 2xx, the status and its body otherwise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const e = endpoint.get("/top", .{ .result = []const struct { player: []const u8, points: u32 } });
    const ok = decodeAnswer(e, 200, "[{\"player\":\"ann\",\"points\":3,\"extra\":1}]", arena.allocator());
    try std.testing.expectEqualStrings("ann", ok.ok[0].player);
    const not_found = decodeAnswer(e, 404, "no", arena.allocator()).status;
    try std.testing.expectEqual(404, not_found.code);
    try std.testing.expectEqual(null, not_found.problem(arena.allocator()));
    const taken = decodeAnswer(e, 409, "{\"title\":\"Conflict\",\"status\":409,\"detail\":\"seat taken\"}", arena.allocator()).status;
    try std.testing.expectEqualStrings("seat taken", taken.problem(arena.allocator()).?.detail.?);
    try std.testing.expect(decodeAnswer(e, 200, "{", arena.allocator()) == .failed);
    try std.testing.expect(decodeAnswer(endpoint.post("/x", .{}), 204, "", arena.allocator()) == .ok);
}
