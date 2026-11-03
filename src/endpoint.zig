//! An HTTP endpoint's contract: its method, its path and what crosses it,
//! declared once in code a server and its clients share. The server binds a
//! handler to it (`Scope.bind`), checked against it at compile time, and
//! clients are generated from it (`typescript`).
//!
//! ```zig
//! pub const Api = struct {
//!     pub const score = web.endpoint.get("/scores/:game", .{
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
    /// One that doesn't parse as its type makes the route not found.
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

/// The `:name`s of `pattern`, in order.
pub fn paramNames(comptime pattern: []const u8) []const []const u8 {
    if (pattern.len == 0 or pattern[0] != '/') @compileError("a pattern starts with '/': " ++ pattern);
    var names: []const []const u8 = &.{};
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    while (it.next()) |seg| if (seg[0] == ':') {
        names = names ++ .{seg[1..]};
    };
    if (names.len > max_params) @compileError(pattern ++ ": too many params");
    return names;
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

test {
    _ = typescript;
}
