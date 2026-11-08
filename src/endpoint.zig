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
const Writer = std.Io.Writer;

pub const typescript = @import("typescript.zig");
pub const openapi = @import("openapi.zig");
/// What a decoded value is held to past its type.
pub const rules = @import("rules.zig");

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

/// A `multipart/form-data` body (RFC 7578), its parts slices of it: the
/// raw form of what a `.form` body decodes, for names given more than once.
pub const Multipart = struct {
    parts: []const Part,

    pub const Part = struct {
        name: []const u8,
        file: File,
    };

    /// The first part named `name`.
    pub fn get(self: Multipart, name: []const u8) ?File {
        for (self.parts) |p| if (std.mem.eql(u8, p.name, name)) return p.file;
        return null;
    }

    /// `body`'s parts, `content_type` naming their boundary; `why`, if
    /// given, says what's wrong with one it refuses.
    pub fn parse(arena: std.mem.Allocator, content_type: []const u8, body: []const u8, why: ?*[]const u8) !Multipart {
        const boundary = param(content_type, "boundary") orelse return fail(why, "body: multipart without a boundary");
        // RFC 2046's limit, and what keeps a client's boundary from slowing the search down.
        if (boundary.len == 0 or boundary.len > 70) return fail(why, "body: a multipart boundary of 1 to 70 characters");
        var buf: [74]u8 = undefined;
        const delimiter = std.fmt.bufPrint(&buf, "\r\n--{s}", .{boundary}) catch unreachable;
        var parts: std.ArrayList(Part) = .empty;
        var at = (std.mem.indexOf(u8, body, delimiter[2..]) orelse return fail(why, "body: no part")) + delimiter.len - 2;
        while (!std.mem.startsWith(u8, body[at..], "--")) {
            if (!std.mem.startsWith(u8, body[at..], "\r\n")) return fail(why, "body: a boundary not on its own line");
            const head_end = std.mem.indexOfPos(u8, body, at + 2, "\r\n\r\n") orelse return fail(why, "body: a part's head doesn't end");
            var disposition: ?[]const u8 = null;
            var content_type_: ?[]const u8 = null;
            var lines = std.mem.splitSequence(u8, body[at + 2 .. head_end], "\r\n");
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const key = line[0..colon];
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(key, "content-disposition")) disposition = value;
                if (std.ascii.eqlIgnoreCase(key, "content-type")) content_type_ = value;
            }
            const d = disposition orelse return fail(why, "body: a part without Content-Disposition");
            const next = std.mem.indexOfPos(u8, body, head_end + 4, delimiter) orelse return fail(why, "body: a part doesn't end");
            try parts.append(arena, .{
                .name = param(d, "name") orelse return fail(why, "body: a part without a name"),
                .file = .{ .filename = param(d, "filename"), .content_type = content_type_, .data = body[head_end + 4 .. next] },
            });
            at = next + delimiter.len;
        }
        return .{ .parts = parts.items };
    }
};

/// The media type of `content_type`, its parameters aside.
pub fn mediaType(content_type: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], " \t");
}

/// `name=value` or `name="value"` among a header's `;`-separated params.
pub fn param(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    _ = it.next(); // the value itself
    while (it.next()) |p| {
        const kv = std.mem.trim(u8, p, " \t");
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, kv[0..eq], " \t"), name)) continue;
        const v = std.mem.trim(u8, kv[eq + 1 ..], " \t");
        return if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v[1 .. v.len - 1] else v;
    }
    return null;
}

fn fail(why: ?*[]const u8, text: []const u8) error{BadRequest} {
    if (why) |w| w.* = text;
    return error.BadRequest;
}

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
    if (try rules.check(P, &p, arena) != null) return error.NotFound;
    return p;
}

/// One pass over `raw`'s pairs; a field takes the first value named for it.
/// A query it refuses, `why` (if given) says what's wrong with.
pub fn decodeQuery(comptime Q: type, raw: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) !Q {
    return decodePairs(Q, raw, arena, why, "query");
}

/// An `application/x-www-form-urlencoded` body, read as a query is.
pub fn decodeForm(comptime B: type, body: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) !B {
    return decodePairs(B, body, arena, why, "form");
}

/// Whether a `T` can come from a form: a struct of what a query's fields
/// are, and `File`s.
pub fn formable(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    for (@typeInfo(T).@"struct".field_types) |F| if (!scalar(F) and !isFile(F)) return false;
    return true;
}

pub fn isFile(comptime T: type) bool {
    return T == File or T == ?File;
}

/// Whether a `T` has a `File` field: one sent only as a multipart form.
pub fn hasFile(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    for (@typeInfo(T).@"struct".field_types) |F| if (isFile(F)) return true;
    return false;
}

/// A multipart form (`multipart/form-data`) as `B`: a field takes the part
/// named for it, a `File` the part whole.
pub fn decodeMultipart(comptime B: type, content_type: []const u8, body: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) !B {
    const m = try Multipart.parse(arena, content_type, body, why);
    const s = @typeInfo(B).@"struct";
    var b: B = undefined;
    inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
        @field(b, name) = if (m.get(name)) |part|
            if (comptime isFile(F)) part else parseScalar(F, part.data) catch return fail(why, "form." ++ name ++ ": not " ++ comptime kind(F))
        else
            try missing(F, attrs, name, "form", why);
    }
    return keepsRules(B, b, "form", arena, why);
}

/// A field no pair or part gave: its default, null, or refused.
fn missing(comptime T: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime name: []const u8, comptime where: []const u8, why: ?*[]const u8) !T {
    if (comptime attrs.defaultValue(T)) |d| return d;
    if (@typeInfo(T) == .optional) return null;
    return fail(why, where ++ "." ++ name ++ " is required");
}

/// What a param, a query's field or a form's is: the types `parseScalar` reads.
fn scalar(comptime T: type) bool {
    return T == []const u8 or switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |o| scalar(o.child),
        else => false,
    };
}

fn decodePairs(comptime Q: type, raw: []const u8, arena: std.mem.Allocator, why: ?*[]const u8, comptime where: []const u8) !Q {
    const s = @typeInfo(Q).@"struct";
    var q: Q = undefined;
    var seen: [s.field_names.len]bool = @splat(false);
    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try percentDecode(arena, pair[0..eq], true);
        inline for (s.field_names, s.field_types, 0..) |name, T, i| {
            // A file comes only in a multipart form.
            if (comptime isFile(T)) continue;
            if (!seen[i] and std.mem.eql(u8, key, name)) {
                const value = try percentDecode(arena, if (eq < pair.len) pair[eq + 1 ..] else "", true);
                @field(q, name) = parseScalar(T, value) catch return fail(why, where ++ "." ++ name ++ ": not " ++ comptime kind(T));
                seen[i] = true;
            }
        }
    }
    inline for (s.field_names, s.field_types, s.field_attrs, 0..) |name, T, attrs, i| {
        if (!seen[i]) @field(q, name) = try missing(T, attrs, name, where, why);
    }
    return keepsRules(Q, q, where, arena, why);
}

/// `body` as `B`: `void` for none, `[]const u8` as it came, any other
/// type from JSON, unknown fields skipped. A body it refuses, `why` (if
/// given) says what's wrong with.
pub fn decodeBody(comptime B: type, body: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) !B {
    if (B == Multipart) @compileError("a multipart body is read with its Content-Type: Multipart.parse");
    if (B == BodyStream) @compileError("a streamed body is read as it comes: http.BodyReader");
    if (B == void) return {};
    if (B == []const u8) return body;
    var scanner: std.json.Scanner = .initCompleteInput(arena, body);
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    const b = std.json.parseFromTokenSourceLeaky(B, arena, &scanner, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (why) |w| w.* = try std.fmt.allocPrint(arena, "body, line {d} column {d}: {s}", .{ diagnostics.getLine(), diagnostics.getColumn(), jsonWhy(err) });
            return error.BadRequest;
        },
    };
    return keepsRules(B, b, "body", arena, why);
}

/// `value`, unless it breaks a rule its type has (`rules`).
fn keepsRules(comptime T: type, value: T, comptime where: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) !T {
    const broken = try rules.check(T, &value, arena) orelse return value;
    if (why) |w| w.* = try std.fmt.allocPrint(arena, where ++ "{s}: {s}", .{ broken.at, broken.what });
    return error.BadRequest;
}

/// What a value of `T` is, for a query field that didn't parse as one.
fn kind(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "an integer",
        .float => "a number",
        .bool => "true or false",
        .@"enum" => |e| blk: {
            var names: []const u8 = "one of ";
            for (e.field_names, 0..) |f, i| names = names ++ (if (i == 0) "" else ", ") ++ f;
            break :blk names;
        },
        .optional => |o| kind(o.child),
        else => "valid",
    };
}

fn jsonWhy(err: anyerror) []const u8 {
    return switch (err) {
        error.SyntaxError, error.UnexpectedEndOfInput => "not JSON",
        error.MissingField => "a required field is missing",
        error.DuplicateField => "a field is given twice",
        error.Overflow, error.InvalidNumber, error.InvalidCharacter => "a number that doesn't fit its field",
        error.InvalidEnumTag => "not one of the field's values",
        else => "a value of the wrong type",
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
    if (comptime !scalar(T)) @compileError("a param or query field can't be " ++ @typeName(T));
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
        else => unreachable, // not `scalar`
    };
}

// --- What a client sends for an endpoint, and makes of the answer ---

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
    const e = get("/scores/:game/:round", .{ .params = struct { game: []const u8, round: u8 }, .query = Q });
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeTarget(e, .{ .params = .{ .game = "a b/c+é", .round = 3 }, .query = .{ .who = "ann&lee=+", .mode = .team } }, &w);
    const target = w.buffered();
    try std.testing.expectEqualStrings("/scores/a%20b%2Fc%2B%C3%A9/3?top=10&who=ann%26lee%3D%2B&mode=team", target);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const q = try decodeQuery(Q, target[std.mem.indexOfScalar(u8, target, '?').? + 1 ..], arena.allocator(), null);
    try std.testing.expectEqualStrings("ann&lee=+", q.who.?);
    try std.testing.expectEqual(null, q.since);
    try std.testing.expectEqual(.team, q.mode);
    const p = try decodeParams(e.spec.params, &.{ "game", "round" }, false, &.{ "a%20b%2Fc%2B%C3%A9", "3" }, arena.allocator());
    try std.testing.expectEqualStrings("a b/c+é", p.game);
}

test "a call takes only what its endpoint does" {
    const none = get("/", .{});
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeTarget(none, .{}, &w);
    try std.testing.expectEqualStrings("/", w.buffered());
    try std.testing.expectEqual(null, contentType(none));

    const Score = struct { player: []const u8, points: u32 };
    const submit = post("/scores", .{ .body = Score, .query = struct { since: ?u32 } });
    try std.testing.expect(!@hasField(Args(submit), "params"));
    w = .fixed(&buf);
    try writeBody(submit, .{ .body = .{ .player = "ann", .points = 3 } }, &w);
    try std.testing.expectEqualStrings("{\"player\":\"ann\",\"points\":3}", w.buffered());
    try std.testing.expectEqualStrings("application/json", contentType(submit).?);
    // A query field with neither default nor optional must be given.
    try std.testing.expect(@typeInfo(Args(get("/q", .{ .query = struct { n: u8 } }))).@"struct".field_attrs[0].default_value_ptr == null);
}

test "an answer: the result from a 2xx, the status and its body otherwise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const e = get("/top", .{ .result = []const struct { player: []const u8, points: u32 } });
    const ok = decodeAnswer(e, 200, "[{\"player\":\"ann\",\"points\":3,\"extra\":1}]", arena.allocator());
    try std.testing.expectEqualStrings("ann", ok.ok[0].player);
    const not_found = decodeAnswer(e, 404, "no", arena.allocator()).status;
    try std.testing.expectEqual(404, not_found.code);
    try std.testing.expectEqual(null, not_found.problem(arena.allocator()));
    const taken = decodeAnswer(e, 409, "{\"title\":\"Conflict\",\"status\":409,\"detail\":\"seat taken\"}", arena.allocator()).status;
    try std.testing.expectEqualStrings("seat taken", taken.problem(arena.allocator()).?.detail.?);
    try std.testing.expect(decodeAnswer(e, 200, "{", arena.allocator()) == .failed);
    try std.testing.expect(decodeAnswer(post("/x", .{}), 204, "", arena.allocator()) == .ok);
}

test "a query decodes into its fields, defaults and optionals filling the gaps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Q = struct { name: []const u8, limit: u32 = 10, mode: ?enum { fast, slow } = null, on: bool = false };
    const q = try decodeQuery(Q, "name=ann+lee%21&on=1&extra=x&name=bob", arena.allocator(), null);
    try std.testing.expectEqualStrings("ann lee!", q.name);
    try std.testing.expectEqual(10, q.limit);
    try std.testing.expectEqual(null, q.mode);
    try std.testing.expect(q.on);
    var why: []const u8 = "";
    try std.testing.expectError(error.BadRequest, decodeQuery(Q, "limit=3", arena.allocator(), &why));
    try std.testing.expectEqualStrings("query.name is required", why);
    try std.testing.expectError(error.BadRequest, decodeQuery(Q, "name=a&limit=lots", arena.allocator(), &why));
    try std.testing.expectEqualStrings("query.limit: not an integer", why);
    try std.testing.expectEqual(.slow, (try decodeQuery(Q, "name=a&mode=slow", arena.allocator(), null)).mode.?);
}

test {
    _ = typescript;
    _ = openapi;
    _ = rules;
}

test "a multipart body's parts: fields and files, a quoted boundary, refusals that say why" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "preamble\r\n--xyz\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nmy map\r\n" ++
        "--xyz\r\nContent-Disposition: form-data; name=\"map\"; filename=\"de_dust.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\r\n\x01\r\n" ++
        "--xyz--\r\n";
    const m = try Multipart.parse(a, "multipart/form-data; boundary=\"xyz\"", body, null);
    try std.testing.expectEqual(2, m.parts.len);
    try std.testing.expectEqualStrings("my map", m.get("title").?.data);
    const map = m.get("map").?;
    try std.testing.expectEqualStrings("de_dust.bin", map.filename.?);
    try std.testing.expectEqualStrings("application/octet-stream", map.content_type.?);
    try std.testing.expectEqualStrings("\x00\r\n\x01", map.data);
    try std.testing.expectEqual(null, m.get("none"));

    var why: []const u8 = "";
    try std.testing.expectError(error.BadRequest, Multipart.parse(a, "multipart/form-data", body, &why));
    try std.testing.expectEqualStrings("body: multipart without a boundary", why);
    try std.testing.expectError(error.BadRequest, Multipart.parse(a, "multipart/form-data; boundary=xyz", "--xyz\r\nContent-Disposition: form-data; name=a\r\n\r\nno end", &why));
    try std.testing.expectEqualStrings("body: a part doesn't end", why);
    const long = comptime blk: {
        var t: []const u8 = "multipart/form-data; boundary=";
        for (0..71) |_| t = t ++ "b";
        break :blk t;
    };
    try std.testing.expectError(error.BadRequest, Multipart.parse(a, long, body, &why));
    try std.testing.expectEqualStrings("body: a multipart boundary of 1 to 70 characters", why);
}
