//! What a request decodes into, as a `Spec` says: the server's, and a
//! sandboxed guest's. A value it refuses, `why` (if given) says what's wrong with.

const std = @import("std");
const rules = @import("rules.zig");
const File = @import("endpoint.zig").File;
const BodyStream = @import("endpoint.zig").BodyStream;

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
pub fn scalar(comptime T: type) bool {
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
