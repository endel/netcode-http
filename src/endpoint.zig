//! An HTTP endpoint's contract: its method, its path and what crosses it,
//! declared once in code a server and its clients share. The server binds a
//! handler to it (`Scope.bind`), checked against it at compile time, and
//! clients are generated from it (`typescript`).
//!
//! ```zig
//! pub const Api = struct {
//!     pub const score = http.endpoint.get("/scores/:game", .{
//!         .params = struct { game: []const u8 },
//!         .result = Score,
//!     });
//! };
//! ```
//!
//! It imports nothing but std, so shared code built for the browser or a
//! native client holds it as the server does.

const std = @import("std");

pub const typescript = @import("typescript.zig");

pub const Method = enum { GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS };

pub const max_params = 8;

/// What a handler's `Context` decodes from the request.
pub const Spec = struct {
    /// A field for each `:name` of the route's pattern, percent-decoded.
    /// One that doesn't parse as its type makes the route not found. A
    /// last `*name` takes the rest of the path, a `[]const u8` still
    /// encoded: its slashes and an encoded one differ.
    params: type = struct {},
    /// Fields from the query string; one without a default, or optional,
    /// is required.
    query: type = struct {},
    /// `void` for none, `[]const u8` for the bytes as they came, any other
    /// type parsed from JSON.
    body: type = void,
    /// A longer body is refused with 413 before the handler runs.
    max_body: usize = 64 * 1024,
};

pub const Endpoint = struct {
    method: Method,
    path: []const u8,
    spec: Spec,
    /// The answer, as JSON; `void` for none.
    result: type,
};

/// What `of` takes: a `Spec`'s fields and the `result`.
pub const Shape = struct {
    params: type = struct {},
    query: type = struct {},
    body: type = void,
    max_body: usize = 64 * 1024,
    result: type = void,
};

/// An endpoint, its path checked against its params here, where it's declared.
pub fn of(comptime method: Method, comptime path: []const u8, comptime s: Shape) Endpoint {
    if (catchAll(path)) @compileError(path ++ ": an endpoint's path has no catch-all");
    checkParams(path, paramNames(path), s.params);
    const spec: Spec = .{ .params = s.params, .query = s.query, .body = s.body, .max_body = s.max_body };
    return .{ .method = method, .path = path, .spec = spec, .result = s.result };
}

pub fn get(comptime path: []const u8, comptime s: Shape) Endpoint {
    return of(.GET, path, s);
}
pub fn post(comptime path: []const u8, comptime s: Shape) Endpoint {
    return of(.POST, path, s);
}
pub fn put(comptime path: []const u8, comptime s: Shape) Endpoint {
    return of(.PUT, path, s);
}
pub fn delete(comptime path: []const u8, comptime s: Shape) Endpoint {
    return of(.DELETE, path, s);
}

/// The `:name`s of `pattern`, in order, then its catch-all's.
pub fn paramNames(comptime pattern: []const u8) []const []const u8 {
    if (pattern.len == 0 or pattern[0] != '/') @compileError("a pattern starts with '/': " ++ pattern);
    var names: []const []const u8 = &.{};
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    while (it.next()) |seg| switch (seg[0]) {
        ':' => names = names ++ .{seg[1..]},
        '*' => {
            if (it.peek() != null) @compileError(pattern ++ ": a catch-all is the last segment");
            if (seg.len == 1) @compileError(pattern ++ ": a catch-all has a name, as `*path`");
            names = names ++ .{seg[1..]};
        },
        else => {},
    };
    if (names.len > max_params) @compileError(pattern ++ ": too many params");
    return names;
}

/// Whether `pattern` ends in a catch-all, `*name`.
pub fn catchAll(comptime pattern: []const u8) bool {
    const last = std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, pattern, "/"), '/') orelse return false;
    return last + 1 < pattern.len and pattern[last + 1] == '*';
}

/// Each `:name` of `pattern` a field of `P`, and each field a `:name`.
pub fn checkParams(comptime pattern: []const u8, comptime names: []const []const u8, comptime P: type) void {
    for (names) |n| if (!@hasField(P, n)) @compileError(pattern ++ ": the params have no field '" ++ n ++ "'");
    for (@typeInfo(P).@"struct".field_names) |f| {
        for (names) |n| {
            if (std.mem.eql(u8, n, f)) break;
        } else @compileError(pattern ++ ": no ':" ++ f ++ "' in the pattern for the params' field");
    }
}

/// A query field the request may leave out.
pub fn optionalField(comptime T: type, comptime attrs: anytype) bool {
    return attrs.default_value_ptr != null or @typeInfo(T) == .optional;
}

/// The status an error from a handler answers with.
pub fn statusOf(err: anyerror) u16 {
    return switch (err) {
        error.BadRequest => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        error.MethodNotAllowed => 405,
        error.Conflict => 409,
        error.Gone => 410,
        error.PayloadTooLarge => 413,
        error.UnsupportedMediaType => 415,
        error.TooManyRequests => 429,
        error.ServiceUnavailable => 503,
        else => 500,
    };
}

// --- What a request decodes into, as a `Spec` says: the server's, and a sandboxed guest's ---

/// `params`' fields from the pattern's captures, in the pattern's order.
/// `rest`: the last name is a catch-all's, kept as it came.
pub fn decodeParams(comptime P: type, comptime names: []const []const u8, comptime rest: bool, captures: []const []const u8, arena: std.mem.Allocator) !P {
    var p: P = undefined;
    inline for (names, 0..) |name, i| {
        if (rest and i == names.len - 1) {
            if (@FieldType(P, name) != []const u8) @compileError("a catch-all's param is a []const u8: " ++ name);
            @field(p, name) = captures[i];
            continue;
        }
        const text = try percentDecode(arena, captures[i], false);
        @field(p, name) = parseScalar(@FieldType(P, name), text) catch return error.NotFound;
    }
    return p;
}

/// One pass over `raw`'s pairs; a field takes the first value named for it.
pub fn decodeQuery(comptime Q: type, raw: []const u8, arena: std.mem.Allocator) !Q {
    const s = @typeInfo(Q).@"struct";
    var q: Q = undefined;
    var seen: [s.field_names.len]bool = @splat(false);
    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try percentDecode(arena, pair[0..eq], true);
        inline for (s.field_names, s.field_types, 0..) |name, T, i| {
            if (!seen[i] and std.mem.eql(u8, key, name)) {
                const value = try percentDecode(arena, if (eq < pair.len) pair[eq + 1 ..] else "", true);
                @field(q, name) = parseScalar(T, value) catch return error.BadRequest;
                seen[i] = true;
            }
        }
    }
    inline for (s.field_names, s.field_types, s.field_attrs, 0..) |name, T, attrs, i| {
        if (!seen[i]) @field(q, name) = if (comptime attrs.defaultValue(T)) |d|
            d
        else if (@typeInfo(T) == .optional)
            null
        else
            return error.BadRequest;
    }
    return q;
}

/// `body` as `B`: `void` for none, `[]const u8` as it came, any other
/// type from JSON, unknown fields skipped.
pub fn decodeBody(comptime B: type, body: []const u8, arena: std.mem.Allocator) !B {
    if (B == void) return {};
    if (B == []const u8) return body;
    return std.json.parseFromSliceLeaky(B, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadRequest,
    };
}

/// `%XX` decoded (a malformed one kept as it is), and `+` as a space in a query.
pub fn percentDecode(arena: std.mem.Allocator, text: []const u8, plus_is_space: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, text, if (plus_is_space) "%+" else "%") == null) return text;
    const out = try arena.dupe(u8, text);
    if (plus_is_space) std.mem.replaceScalar(u8, out, '+', ' ');
    return std.Uri.percentDecodeInPlace(out);
}

pub fn parseScalar(comptime T: type, text: []const u8) !T {
    if (T == []const u8) return text;
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10),
        .float => std.fmt.parseFloat(T, text),
        .bool => if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1"))
            true
        else if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0"))
            false
        else
            error.InvalidCharacter,
        .@"enum" => std.meta.stringToEnum(T, text) orelse error.InvalidCharacter,
        .optional => |o| try parseScalar(o.child, text),
        else => @compileError("a param or query field can't be " ++ @typeName(T)),
    };
}

test "a query decodes into its fields, defaults and optionals filling the gaps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Q = struct { name: []const u8, limit: u32 = 10, mode: ?enum { fast, slow } = null, on: bool = false };
    const q = try decodeQuery(Q, "name=ann+lee%21&on=1&extra=x&name=bob", arena.allocator());
    try std.testing.expectEqualStrings("ann lee!", q.name);
    try std.testing.expectEqual(10, q.limit);
    try std.testing.expectEqual(null, q.mode);
    try std.testing.expect(q.on);
    try std.testing.expectError(error.BadRequest, decodeQuery(Q, "limit=3", arena.allocator()));
    try std.testing.expectError(error.BadRequest, decodeQuery(Q, "name=a&limit=lots", arena.allocator()));
    try std.testing.expectEqual(.slow, (try decodeQuery(Q, "name=a&mode=slow", arena.allocator())).mode.?);
}

test {
    _ = typescript;
}
