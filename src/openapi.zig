//! An OpenAPI 3.1 document for an API: a struct whose `pub` declarations are
//! endpoints (`endpoint.get`...). Each becomes an operation, its parameters,
//! body and answers typed as std.json writes them, and each named struct a
//! schema, its `rules` as `minLength`, `maximum` and the like. A type with
//! its own `jsonStringify` declares its schema as `pub const json_schema`.
//!
//! ```zig
//! try http.endpoint.openapi.write(Api, writer, .{ .title = "game", .version = "1.0.0" });
//! ```

const std = @import("std");
const endpoint = @import("endpoint.zig");
const api = @import("api.zig");
const rules = @import("rules.zig");

pub const Info = struct {
    title: []const u8,
    version: []const u8 = "0.0.0",
    /// Where it's served: `https://game.example/api`.
    servers: []const []const u8 = &.{},
};

pub fn write(comptime Api: type, w: *std.Io.Writer, info: Info) !void {
    @setEvalBranchQuota(1_000_000);
    const eps = comptime api.endpointsOf(Api);
    const records = comptime api.recordsOf(eps);
    comptime for (records) |r| if (std.mem.eql(u8, r.name, "Problem")) @compileError("a type crosses as Problem, the name of an error's answer: " ++ @typeName(r.T));
    const paths = comptime blk: {
        var o: [eps.len][]const u8 = undefined;
        for (eps, 0..) |e, i| o[i] = api.fillPath(e.ep.path, "{", "}");
        break :blk o;
    };
    try w.writeAll("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    try std.json.Stringify.value(info.title, .{}, w);
    try w.writeAll(",\"version\":");
    try std.json.Stringify.value(info.version, .{}, w);
    try w.writeAll("},\"servers\":[");
    for (info.servers, 0..) |url, i| {
        try w.writeAll(if (i > 0) ",{\"url\":" else "{\"url\":");
        try std.json.Stringify.value(url, .{}, w);
        try w.writeAll("}");
    }
    // In pieces: one string for the whole document grows quadratically at comptime.
    try w.writeAll("],\"paths\":{");
    comptime var written = 0;
    inline for (paths, 0..) |p, i| {
        const first = comptime for (paths[0..i]) |q| {
            if (std.mem.eql(u8, q, p)) break false;
        } else true;
        if (first) {
            try w.writeAll(comptime comma(written) ++ str(p) ++ ":{");
            written += 1;
            comptime var n = 0;
            inline for (eps[i..], paths[i..]) |e, q| if (comptime std.mem.eql(u8, q, p)) {
                try w.writeAll(comptime comma(n) ++ "\"" ++ lower(@tagName(e.ep.method)) ++ "\":" ++ operation(e));
                n += 1;
            };
            try w.writeAll("}");
        }
    }
    try w.writeAll("},\"components\":{\"schemas\":{");
    inline for (records) |r| try w.writeAll(comptime str(r.name) ++ ":" ++ object(r.T) ++ ",");
    try w.writeAll(comptime "\"Problem\":" ++ object(endpoint.Problem) ++ "}}}");
}

fn operation(comptime n: api.Named) []const u8 {
    const e = n.ep;
    const s = e.spec;
    var out: []const u8 = "{\"operationId\":" ++ str(n.name);
    var params: []const u8 = "";
    const p = @typeInfo(s.params).@"struct";
    for (p.field_names, p.field_types, p.field_attrs) |f, F, a| {
        params = params ++ comma(params.len) ++ "{\"name\":" ++ str(f) ++ ",\"in\":\"path\",\"required\":true,\"schema\":" ++ field(s.params, f, F, a) ++ "}";
    }
    const q = @typeInfo(s.query).@"struct";
    for (q.field_names, q.field_types, q.field_attrs) |f, F, a| {
        const required = if (endpoint.optionalField(F, a)) "false" else "true";
        params = params ++ comma(params.len) ++ "{\"name\":" ++ str(f) ++ ",\"in\":\"query\",\"required\":" ++ required ++ ",\"schema\":" ++ field(s.query, f, F, a) ++ "}";
    }
    if (params.len > 0) out = out ++ ",\"parameters\":[" ++ params ++ "]";
    if (s.body != void) out = out ++ ",\"requestBody\":{\"required\":true,\"content\":{" ++ if (s.body == []const u8)
        "\"application/octet-stream\":{\"schema\":{\"type\":\"string\",\"format\":\"binary\"}}}}"
    else
        "\"application/json\":{\"schema\":" ++ schema(s.body, .{}) ++ "}}}";
    out = out ++ ",\"responses\":{" ++ if (e.result == void)
        "\"204\":{\"description\":\"No Content\"}"
    else
        "\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":" ++ schema(e.result, .{}) ++ "}}}";
    for (endpoint.failures(e)) |f| {
        out = out ++ std.fmt.comptimePrint(",\"{d}\":", .{f.status}) ++ "{\"description\":" ++ str(if (f.why.len > 0) f.why else reason(f.status)) ++
            ",\"content\":{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/Problem\"}}}}";
    }
    return out ++ "}}";
}

/// Field `f` of `Owner`: its type's schema, held to `Owner`'s rule for it, with its default.
fn field(comptime Owner: type, comptime f: []const u8, comptime F: type, comptime a: std.lang.Type.Struct.FieldAttributes) []const u8 {
    const rule = if (@hasDecl(Owner, "rules") and @hasField(@TypeOf(Owner.rules), f)) @field(Owner.rules, f) else .{};
    const optional = @typeInfo(F) == .optional;
    const base = if (optional) "{\"anyOf\":[" ++ schema(@typeInfo(F).optional.child, rule) ++ ",{\"type\":\"null\"}]}" else schema(F, rule);
    const d = (comptime a.defaultValue(F)) orelse return base;
    return extend(base, ",\"default\":" ++ json(d));
}

/// `T` as std.json writes it, held to `rule`'s limits (`rules`).
fn schema(comptime T: type, comptime rule: anytype) []const u8 {
    var lo: ?[]const u8 = null;
    var hi: ?[]const u8 = null;
    var len: []const u8 = "";
    const words: [2][]const u8 = if (T == []const u8 or T == []u8) .{ "minLength", "maxLength" } else .{ "minItems", "maxItems" };
    for (@typeInfo(@TypeOf(rule)).@"struct".field_names) |k| switch (std.meta.stringToEnum(rules.Keyword, k).?) {
        .min => lo = std.fmt.comptimePrint("{d}", .{rule.min}),
        .max => hi = std.fmt.comptimePrint("{d}", .{rule.max}),
        .min_len => len = len ++ std.fmt.comptimePrint(",\"{s}\":{d}", .{ words[0], rule.min_len }),
        .max_len => len = len ++ std.fmt.comptimePrint(",\"{s}\":{d}", .{ words[1], rule.max_len }),
    };
    if (@typeInfo(T) == .int) return "{\"type\":\"integer\",\"minimum\":" ++ (lo orelse std.fmt.comptimePrint("{d}", .{std.math.minInt(T)})) ++
        ",\"maximum\":" ++ (hi orelse std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)})) ++ "}";
    const limits = (if (lo) |v| ",\"minimum\":" ++ v else "") ++ (if (hi) |v| ",\"maximum\":" ++ v else "") ++ len;
    if (T == []const u8 or T == []u8) return extend("{\"type\":\"string\"}", limits);
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "jsonStringify")) {
            if (!@hasDecl(T, "json_schema")) @compileError(@typeName(T) ++ " writes its own JSON: say what it looks like, with `pub const json_schema`");
            return T.json_schema;
        },
        else => {},
    }
    return extend(switch (@typeInfo(T)) {
        .bool => "{\"type\":\"boolean\"}",
        .float, .comptime_float, .comptime_int => "{\"type\":\"number\"}",
        .@"enum" => |e| blk: {
            var names: []const u8 = "";
            for (e.field_names, 0..) |f, i| names = names ++ comma(i) ++ str(f);
            break :blk "{\"type\":\"string\",\"enum\":[" ++ names ++ "]}";
        },
        .optional => |o| "{\"anyOf\":[" ++ schema(o.child, .{}) ++ ",{\"type\":\"null\"}]}",
        .pointer => |p| if (p.size == .slice) "{\"type\":\"array\",\"items\":" ++ schema(p.child, .{}) ++ "}" else schema(p.child, .{}),
        .array => |a| if (a.child == u8)
            "{\"type\":\"string\"}"
        else
            std.fmt.comptimePrint("{{\"type\":\"array\",\"items\":{s},\"minItems\":{d},\"maxItems\":{d}}}", .{ schema(a.child, .{}), a.len, a.len }),
        .@"struct" => if (api.ownName(T)) |n| "{\"$ref\":\"#/components/schemas/" ++ n ++ "\"}" else object(T),
        else => @compileError("no JSON for " ++ @typeName(T)),
    }, limits);
}

/// A struct's properties, held to its `rules`; those without a default required.
fn object(comptime T: type) []const u8 {
    if (@hasDecl(T, "rules")) rules.validRules(T, @TypeOf(T.rules));
    const s = @typeInfo(T).@"struct";
    var props: []const u8 = "";
    var required: []const u8 = "";
    for (s.field_names, s.field_types, s.field_attrs, 0..) |f, F, a, i| {
        props = props ++ comma(i) ++ str(f) ++ ":" ++ field(T, f, F, a);
        if (a.default_value_ptr == null) required = required ++ comma(required.len) ++ str(f);
    }
    return "{\"type\":\"object\",\"properties\":{" ++ props ++ "}" ++ (if (required.len > 0) ",\"required\":[" ++ required ++ "]" else "") ++ "}";
}

/// `obj` with `more` (",\"key\":value...") added before its closing brace.
fn extend(comptime obj: []const u8, comptime more: []const u8) []const u8 {
    return if (more.len == 0) obj else obj[0 .. obj.len - 1] ++ more ++ "}";
}

/// `v` as JSON, at compile time.
fn json(comptime v: anytype) []const u8 {
    return std.fmt.comptimePrint("{f}", .{std.json.fmt(v, .{})});
}

fn str(comptime text: []const u8) []const u8 {
    return json(text);
}

fn lower(comptime text: []const u8) []const u8 {
    var out: []const u8 = "";
    for (text) |c| out = out ++ &[_]u8{std.ascii.toLower(c)};
    return out;
}

fn comma(i: usize) []const u8 {
    return if (i > 0) "," else "";
}

/// As the server titles a problem: quic-zig's phrases, which std's differ from.
fn reason(comptime status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        410 => "Gone",
        413 => "Content Too Large",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        else => "An error",
    };
}

const Seat = struct {
    row: []const u8,
    number: u16,
    holder: ?[]const u8 = null,
    pub const rules = .{ .row = .{ .min_len = 1, .max_len = 2 }, .number = .{ .min = 1, .max = 500 } };
};
const Thread = struct { text: []const u8, replies: []const Thread };
const TestApi = struct {
    pub const seats = endpoint.get("/halls/:hall/seats", .{ .params = struct { hall: u8 }, .query = struct { row: ?[]const u8, limit: u8 = 50, sort: enum { row, number } = .row }, .result = []const Seat });
    pub const take = endpoint.post("/halls/:hall/seats", .{
        .params = struct { hall: u8 },
        .body = Seat,
        .result = Seat,
        .errors = &.{ .{ .status = 409, .why = "the seat is taken" }, .{ .status = 404 } },
    });
    pub const upload = endpoint.put("/maps/:name", .{ .params = struct { name: []const u8 }, .body = []const u8 });
    pub const thread = endpoint.get("/thread", .{ .result = Thread });
};

test "an API's OpenAPI: its paths and their operations, a schema per named struct, rules and errors in them" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(TestApi, &out.writer, .{ .title = "cinema \"x\"", .version = "1.2.0", .servers = &.{"https://cinema.example"} });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const doc = parsed.value.object;
    try std.testing.expectEqualStrings("3.1.0", doc.get("openapi").?.string);
    try std.testing.expectEqualStrings("cinema \"x\"", doc.get("info").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("https://cinema.example", doc.get("servers").?.array.items[0].object.get("url").?.string);

    const hall = doc.get("paths").?.object.get("/halls/{hall}/seats").?.object;
    const get = hall.get("get").?.object;
    try std.testing.expectEqualStrings("seats", get.get("operationId").?.string);
    const params = get.get("parameters").?.array.items;
    try std.testing.expectEqualStrings("hall", params[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("path", params[0].object.get("in").?.string);
    try std.testing.expectEqual(false, params[1].object.get("required").?.bool);
    try std.testing.expectEqual(50, params[2].object.get("schema").?.object.get("default").?.integer);
    try std.testing.expectEqualStrings("row", params[3].object.get("schema").?.object.get("default").?.string);

    const post = hall.get("post").?.object;
    const responses = post.get("responses").?.object;
    try std.testing.expectEqualStrings("the seat is taken", responses.get("409").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("Not Found", responses.get("404").?.object.get("description").?.string);
    try std.testing.expect(responses.get("400") != null);

    const schemas = doc.get("components").?.object.get("schemas").?.object;
    const seat = schemas.get("Seat").?.object;
    const props = seat.get("properties").?.object;
    try std.testing.expectEqual(2, props.get("row").?.object.get("maxLength").?.integer);
    try std.testing.expectEqual(500, props.get("number").?.object.get("maximum").?.integer);
    try std.testing.expectEqual(2, seat.get("required").?.array.items.len);
    const replies = schemas.get("Thread").?.object.get("properties").?.object.get("replies").?.object;
    try std.testing.expectEqualStrings("#/components/schemas/Thread", replies.get("items").?.object.get("$ref").?.string);
    try std.testing.expect(schemas.get("Problem") != null);
    const upload = doc.get("paths").?.object.get("/maps/{name}").?.object.get("put").?.object;
    try std.testing.expect(upload.get("requestBody").?.object.get("content").?.object.get("application/octet-stream") != null);
}
