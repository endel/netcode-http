//! A TypeScript client for an API: a struct whose `pub` declarations are
//! endpoints (`endpoint.get`...). Each becomes a method that calls `fetch`,
//! typed from what crosses it as std.json writes it; a named struct becomes
//! an interface. A type with its own `jsonStringify` declares its TypeScript
//! form as `pub const ts_type = "..."`.
//!
//! ```ts
//! const api = gameApi("https://game.example");
//! const score = await api.score({ game: "tanks" });
//! ```

const std = @import("std");
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;
const api = @import("api.zig");
const Record = api.Record;
const ownName = api.ownName;

/// `<name>Api(base)`, the client of `Api`, returning its methods; the types
/// they take and answer, as `<name>Api.Score`; and `HttpError`.
pub fn write(comptime Api: type, w: *std.Io.Writer, comptime name: []const u8) !void {
    @setEvalBranchQuota(1_000_000);
    const ns = name ++ "Api";
    const eps = comptime api.endpointsOf(Api);
    const records = comptime api.recordsOf(eps);
    try w.print(
        \\
        \\/** What `{s}` takes and answers with. */
        \\export namespace {s} {{
        \\
    , .{ ns, ns });
    inline for (records) |r| try w.writeAll(comptime interface(r, ns));
    try w.print(
        \\}}
        \\
        \\/** An answer other than 2xx: its status and body, and its title and detail when it's a problem (RFC 9457). */
        \\export class HttpError extends Error {{
        \\  status: number;
        \\  body: string;
        \\  title?: string;
        \\  detail?: string;
        \\  constructor(status: number, body: string, type?: string | null) {{
        \\    let problem: {{ title?: string; detail?: string }} = {{}};
        \\    if (type?.startsWith("application/problem+json")) try {{ problem = JSON.parse(body) ?? {{}}; }} catch {{}}
        \\    super(`HTTP ${{status}}: ${{problem.detail ?? problem.title ?? body}}`);
        \\    this.status = status;
        \\    this.body = body;
        \\    this.title = problem.title;
        \\    this.detail = problem.detail;
        \\  }}
        \\}}
        \\
        \\/** The endpoints, under `base`: `https://game.example`, or a prefix they're mounted at. */
        \\export function {s}(base: string | URL, init: RequestInit = {{}}) {{
        \\  const root = String(base).replace(/\/$/, "");
        \\  async function call(method: string, path: string, query: object | undefined, body: unknown, answers = true, as: "json" | "bytes" | "form" = "json"): Promise<any> {{
        \\    const url = new URL(root + path);
        \\    for (const [k, v] of Object.entries(query ?? {{}})) if (v != null) url.searchParams.set(k, String(v));
        \\    const headers = new Headers(init.headers);
        \\    let payload: BodyInit | undefined = undefined;
        \\    if (body === undefined) {{}}
        \\    else if (as === "json") {{
        \\      headers.set("content-type", "application/json");
        \\      payload = JSON.stringify(body);
        \\    }} else if (as === "form" && !(body instanceof FormData)) {{
        \\      const form = new FormData();
        \\      for (const [k, v] of Object.entries(body as object)) if (v != null) form.append(k, v instanceof Blob ? v : String(v));
        \\      payload = form; // its own Content-Type, boundary and all
        \\    }} else {{
        \\      if (!(body instanceof FormData)) headers.set("content-type", "application/octet-stream");
        \\      payload = body as BodyInit;
        \\    }}
        \\    const res = await fetch(url, {{ ...init, method, headers, body: payload }});
        \\    if (!res.ok) throw new HttpError(res.status, await res.text(), res.headers.get("content-type"));
        \\    return answers ? res.json() : undefined;
        \\  }}
        \\  return {{
        \\
    , .{ns});
    inline for (eps) |e| try w.writeAll(comptime doc(e.ep) ++ "    " ++ method(e.name, e.ep, ns) ++ ",\n");
    try w.writeAll("  };\n}\n");
}

fn interface(comptime r: Record, comptime ns: []const u8) []const u8 {
    const s = @typeInfo(r.T).@"struct";
    var out: []const u8 = "  export interface " ++ r.name ++ " {\n";
    for (s.field_names, s.field_types, s.field_attrs) |f, F, a| out = out ++ "    " ++ field(f, F, a.default_value_ptr != null, ns) ++ ";\n";
    return out ++ "  }\n";
}

/// The method's comment: its method and path, and the errors it may answer with.
fn doc(comptime e: Endpoint) []const u8 {
    const what = @tagName(e.method) ++ " " ++ e.path;
    const failures = endpoint.failures(e);
    if (failures.len == 0) return "    /** " ++ what ++ " */\n";
    var out: []const u8 = "    /**\n     * " ++ what ++ "\n";
    for (failures) |f| out = out ++ std.fmt.comptimePrint("     * @throws {{HttpError}} {d}{s}{s}\n", .{ f.status, if (f.why.len > 0) " " else "", commentSafe(f.why) });
    return out ++ "     */\n";
}

/// `text` with no `*/` to end a comment early.
fn commentSafe(comptime text: []const u8) []const u8 {
    var out: []const u8 = "";
    for (text, 0..) |c, i| out = out ++ (if (c == '/' and i > 0 and text[i - 1] == '*') "\\/" else &[_]u8{c});
    return out;
}

/// `name: (args) => call(...)`: params, then the body, then the query.
fn method(comptime name: []const u8, comptime e: Endpoint, comptime ns: []const u8) []const u8 {
    const s = e.spec;
    const has_query = @typeInfo(s.query).@"struct".field_names.len > 0;
    const raw = s.body == []const u8 or s.body == endpoint.Multipart or s.body == endpoint.BodyStream;
    var args: []const u8 = "";
    if (@typeInfo(s.params).@"struct".field_names.len > 0) args = args ++ ", params: " ++ object(s.params, false, ns);
    if (s.body != void) args = args ++ ", body: " ++ (if (s.body == endpoint.Multipart) "FormData" else if (raw) "string | Uint8Array" else tsType(s.body, ns));
    if (has_query) args = args ++ ", query" ++ (if (allOptional(s.query)) "?" else "") ++ ": " ++ object(s.query, true, ns);
    const result = if (e.result == void) "void" else tsType(e.result, ns);
    // `call`'s defaults: an answer to parse, a JSON body.
    const as = if (raw) "\"bytes\"" else if (s.form and endpoint.hasFile(s.body)) "\"form\"" else "";
    const rest = if (as.len > 0) (if (e.result == void) ", false, " else ", true, ") ++ as else if (e.result == void) ", false" else "";
    return name ++ ": (" ++ (if (args.len > 0) args[2..] else "") ++ "): Promise<" ++ result ++ "> => call(\"" ++ @tagName(e.method) ++
        "\", `" ++ pathTemplate(e.path) ++ "`, " ++ (if (has_query) "query" else "undefined") ++ ", " ++ (if (s.body != void) "body" else "undefined") ++ rest ++ ")";
}

/// `/scores/:game` as a template literal's text: `/scores/${...(params.game)}`.
fn pathTemplate(comptime pattern: []const u8) []const u8 {
    return api.fillPath(pattern, "${encodeURIComponent(params.", ")}");
}

fn allOptional(comptime T: type) bool {
    const s = @typeInfo(T).@"struct";
    for (s.field_types, s.field_attrs) |F, a| if (!endpoint.optionalField(F, a)) return false;
    return true;
}

fn field(comptime name: []const u8, comptime T: type, comptime optional: bool, comptime ns: []const u8) []const u8 {
    return name ++ (if (optional) "?" else "") ++ ": " ++ tsType(T, ns);
}

/// A struct as an object type written out; a query's nullable fields may be left out.
fn object(comptime T: type, comptime query: bool, comptime ns: []const u8) []const u8 {
    const s = @typeInfo(T).@"struct";
    var out: []const u8 = "{ ";
    for (s.field_names, s.field_types, s.field_attrs) |f, F, a| {
        out = out ++ field(f, F, if (query) endpoint.optionalField(F, a) else a.default_value_ptr != null, ns) ++ "; ";
    }
    return out ++ "}";
}

/// `T` as std.json writes it.
fn tsType(comptime T: type, comptime ns: []const u8) []const u8 {
    if (T == []const u8 or T == []u8) return "string";
    if (T == endpoint.File) return "Blob";
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "jsonStringify")) {
            if (!@hasDecl(T, "ts_type")) @compileError(@typeName(T) ++ " writes its own JSON: say how TypeScript reads it, with `pub const ts_type`");
            return T.ts_type;
        },
        else => {},
    }
    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .int, .float, .comptime_int, .comptime_float => "number",
        .@"enum" => |e| blk: {
            var out: []const u8 = "";
            for (e.field_names, 0..) |f, i| out = out ++ (if (i > 0) " | " else "") ++ "\"" ++ f ++ "\"";
            break :blk out;
        },
        .optional => |o| tsType(o.child, ns) ++ " | null",
        .pointer => |p| if (p.size == .slice) arrayOf(p.child, ns) else tsType(p.child, ns),
        .array => |a| if (a.child == u8) "string" else arrayOf(a.child, ns),
        .@"struct" => if (ownName(T)) |n| ns ++ "." ++ n else object(T, false, ns),
        else => @compileError("no JSON for " ++ @typeName(T)),
    };
}

fn arrayOf(comptime T: type, comptime ns: []const u8) []const u8 {
    const inner = tsType(T, ns);
    return if (std.mem.indexOfScalar(u8, inner, ' ') != null) "(" ++ inner ++ ")[]" else inner ++ "[]";
}

const Score = struct { player: []const u8, points: u32, mode: enum { solo, team } = .solo, tag: [4]u8 = "none".* };
const Thread = struct { text: []const u8, replies: []const Thread };
const TestApi = struct {
    pub const score = endpoint.get("/scores/:game", .{ .params = struct { game: []const u8 }, .query = struct { top: u8 = 10, since: ?u32 }, .result = []const Score });
    pub const submit = endpoint.post("/scores", .{ .body = Score, .result = struct { rank: ?u32 } });
    pub const upload = endpoint.put("/maps/:name", .{ .params = struct { name: []const u8 }, .body = []const u8 });
    pub const thread = endpoint.get("/thread", .{ .result = Thread });
    pub const map = endpoint.post("/maps", .{ .body = endpoint.Multipart });
    pub const avatar = endpoint.put("/avatar", .{ .body = struct { name: []const u8, picture: endpoint.File }, .form = true });
    pub const claim = endpoint.post("/claim", .{ .errors = &.{ .{ .status = 409, .why = "taken */ already" }, .{ .status = 404 } } });
    pub const not_one = 3;
};

test "an API's client: an interface per named struct, a method per endpoint" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(TestApi, &out.writer, "game");
    const ts = out.written();
    for ([_][]const u8{
        "export namespace gameApi {\n  export interface Score {\n    player: string;\n    points: number;\n    mode?: \"solo\" | \"team\";\n    tag?: string;\n  }\n",
        "    score: (params: { game: string; }, query?: { top?: number; since?: number | null; }): Promise<gameApi.Score[]> => call(\"GET\", `/scores/${encodeURIComponent(params.game)}`, query, undefined),",
        "    submit: (body: gameApi.Score): Promise<{ rank: number | null; }> => call(\"POST\", `/scores`, undefined, body),",
        "    upload: (params: { name: string; }, body: string | Uint8Array): Promise<void> => call(\"PUT\", `/maps/${encodeURIComponent(params.name)}`, undefined, body, false, \"bytes\"),",
        "export function gameApi(base: string | URL, init: RequestInit = {}) {",
        "  export interface Thread {\n    text: string;\n    replies: gameApi.Thread[];\n  }\n",
        "    map: (body: FormData): Promise<void> => call(\"POST\", `/maps`, undefined, body, false, \"bytes\"),",
        "    avatar: (body: { name: string; picture: Blob; }): Promise<void> => call(\"PUT\", `/avatar`, undefined, body, false, \"form\"),",
        "    /**\n     * POST /claim\n     * @throws {HttpError} 409 taken *\\/ already\n     * @throws {HttpError} 404\n     */\n    claim: (): Promise<void>",
    }) |line| {
        if (std.mem.indexOf(u8, ts, line) == null) {
            std.debug.print("missing:\n{s}\n--- in:\n{s}\n", .{ line, ts });
            return error.Missing;
        }
    }
}
