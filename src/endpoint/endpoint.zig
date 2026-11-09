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
const decode = @import("decode.zig");
const client = @import("client.zig");

pub const typescript = @import("typescript.zig");
pub const openapi = @import("openapi.zig");
/// What a decoded value is held to past its type.
pub const rules = @import("rules.zig");

// What a request decodes into, as a `Spec` says: the server's, and a sandboxed guest's.
pub const Multipart = decode.Multipart;
pub const mediaType = decode.mediaType;
pub const param = decode.param;
pub const decodeParams = decode.decodeParams;
pub const decodeQuery = decode.decodeQuery;
pub const decodeForm = decode.decodeForm;
pub const decodeMultipart = decode.decodeMultipart;
pub const decodeBody = decode.decodeBody;
pub const formable = decode.formable;
pub const isFile = decode.isFile;
pub const hasFile = decode.hasFile;
pub const percentDecode = decode.percentDecode;
pub const parseScalar = decode.parseScalar;

// What a client sends for an endpoint, and makes of the answer.
pub const Args = client.Args;
pub const Answer = client.Answer;
pub const Status = client.Status;
pub const writeTarget = client.writeTarget;
pub const writeBody = client.writeBody;
pub const contentType = client.contentType;
pub const decodeAnswer = client.decodeAnswer;

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
    /// `void` for none, `[]const u8` for the bytes as they came, `Multipart`
    /// for a `multipart/form-data` one's parts, any other type parsed from
    /// JSON. A body sent as another `Content-Type` than its kind is refused
    /// with 415: a cross-site form can't post JSON unasked.
    body: type = void,
    /// The body may also come as an `application/x-www-form-urlencoded`
    /// form, read as a query is: its fields are a query's kind.
    form: bool = false,
    /// A longer body is refused with 413 before the handler runs.
    max_body: usize = 64 * 1024,
};

pub const Endpoint = struct {
    method: Method,
    path: []const u8,
    spec: Spec,
    /// The answer, as JSON; `void` for none.
    result: type,
    /// The errors it answers with, beside those any endpoint may (400, 404, 413...).
    errors: []const Failure = &.{},
};

/// An error an endpoint answers with: a `Problem` with this status.
pub const Failure = struct {
    status: u16,
    /// When it's answered: "the seat is taken".
    why: []const u8 = "",
};

/// What `e` may answer with beside its result: its `errors`, and those its
/// spec implies, a 400 for a query or JSON body it refuses and a 404 for
/// params that may not parse.
pub fn failures(comptime e: Endpoint) []const Failure {
    var out = e.errors;
    const s = e.spec;
    const refuses = @typeInfo(s.query).@"struct".field_names.len > 0 or (s.body != void and s.body != []const u8);
    if (refuses and !declares(e, 400)) out = out ++ .{Failure{ .status = 400, .why = "the query or body is refused: its detail says why" }};
    if (paramsMayFail(s.params) and !declares(e, 404)) out = out ++ .{Failure{ .status = 404, .why = "a path param doesn't parse" }};
    return out;
}

fn declares(comptime e: Endpoint, comptime status: u16) bool {
    for (e.errors) |f| if (f.status == status) return true;
    return false;
}

fn paramsMayFail(comptime P: type) bool {
    if (@hasDecl(P, "rules")) return true;
    for (@typeInfo(P).@"struct".field_types) |F| if (F != []const u8) return true;
    return false;
}

/// A form's file (`multipart/form-data`): a field of this type in a
/// `.form` body takes the part named for it.
pub const File = struct {
    /// What it was called where it came from.
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

/// The body as it arrives, a piece at a time (`http.BodyReader`): for a
/// blocking handler, started at the request's head. Bounded by `max_body`.
pub const BodyStream = struct {};

/// An error's answer (RFC 9457), as the server writes it and a client reads it.
pub const Problem = struct {
    title: []const u8,
    status: u16,
    detail: ?[]const u8 = null,
};

/// What `of` takes: a `Spec`'s fields, the `result` and the `errors`.
pub const Shape = struct {
    params: type = struct {},
    query: type = struct {},
    body: type = void,
    form: bool = false,
    max_body: usize = 64 * 1024,
    result: type = void,
    errors: []const Failure = &.{},
};

/// An endpoint, its path checked against its params here, where it's declared.
pub fn of(comptime method: Method, comptime path: []const u8, comptime s: Shape) Endpoint {
    if (catchAll(path)) @compileError(path ++ ": an endpoint's path has no catch-all");
    checkParams(path, paramNames(path), s.params);
    const spec: Spec = .{ .params = s.params, .query = s.query, .body = s.body, .form = s.form, .max_body = s.max_body };
    return .{ .method = method, .path = path, .spec = spec, .result = s.result, .errors = s.errors };
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
pub fn patch(comptime path: []const u8, comptime s: Shape) Endpoint {
    return of(.PATCH, path, s);
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

test {
    _ = decode;
    _ = client;
    _ = typescript;
    _ = openapi;
    _ = rules;
}
