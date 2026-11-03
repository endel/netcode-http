//! A request as a handler sees it, and the answer it builds.

const std = @import("std");
const parser = @import("quic").http1.parser;
const pool = @import("pool.zig");
const Mailbox = @import("quic").Mailbox;

const endpoint = @import("endpoint");
pub const Method = endpoint.Method;

pub const Header = parser.Header;

/// What arrived. Its slices last as long as the request.
pub const Request = struct {
    method: Method,
    /// Path and query, as received.
    target: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// The peer; null when the transport has none (a Unix socket, a test).
    peer: ?*const std.posix.sockaddr.storage = null,

    pub fn path(self: *const Request) []const u8 {
        return self.target[0 .. std.mem.indexOfScalar(u8, self.target, '?') orelse self.target.len];
    }

    /// What follows `?`, still encoded; empty without one.
    pub fn rawQuery(self: *const Request) []const u8 {
        const q = std.mem.indexOfScalar(u8, self.target, '?') orelse return "";
        return self.target[q + 1 ..];
    }

    /// The first header named `name`, matched ignoring case.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return parser.getHeader(self.headers, name);
    }
};

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

/// The answer, built in the request's arena. The first one sent stands.
pub const Response = struct {
    arena: std.mem.Allocator,
    status: u16 = 204,
    content_type: ?[]const u8 = null,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",
    answered: bool = false,
    /// Its answer comes from work offloaded (`Context.offload`).
    deferred: bool = false,
    /// Set by a transport that can answer after the handler returns.
    late: ?Late = null,

    pub const Late = struct {
        ctx: *anyopaque,
        /// The answer is in `Response`: send it, on the loop's thread.
        send: *const fn (ctx: *anyopaque) void,
        /// Where offloaded work comes back to.
        mailbox: *Mailbox,
    };

    pub fn init(arena: std.mem.Allocator) Response {
        return .{ .arena = arena };
    }

    /// Adds a header to the answer. One that isn't a valid field is
    /// refused: a line break in it would let it add headers of its own.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (!parser.isToken(name) or !parser.isFieldValue(value)) return error.InvalidHeader;
        try self.headers.append(self.arena, .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.arena.dupe(u8, value),
        });
    }

    /// `body` is copied: it may live on the handler's stack.
    pub fn send(self: *Response, status: u16, content_type: []const u8, body: []const u8) !void {
        if (self.answered) return;
        self.answer(status, content_type, try self.arena.dupe(u8, body));
    }

    /// `send` of a body that outlives the answer, the request's arena's say:
    /// not copied.
    pub fn sendOwned(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        if (self.answered) return;
        self.answer(status, content_type, body);
    }

    pub fn json(self: *Response, status: u16, value: anytype) !void {
        if (self.answered) return;
        self.answer(status, "application/json", try std.json.Stringify.valueAlloc(self.arena, value, .{}));
    }

    /// `status` with its reason phrase as the body.
    pub fn fail(self: *Response, status: u16) void {
        if (self.answered) return;
        self.answer(status, "text/plain; charset=utf-8", std.fmt.allocPrint(self.arena, "{s}\n", .{parser.reason(status)}) catch "");
    }

    fn answer(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        self.status = status;
        self.content_type = content_type;
        self.body = body;
        self.answered = true;
    }
};

pub const Spec = endpoint.Spec;

/// A handler's view of its request: `params`, `query` and `body` decoded
/// as `spec` says, and the answer it sends.
pub fn Context(comptime spec: Spec) type {
    return struct {
        const Self = @This();
        pub const web_spec = spec;

        params: spec.params,
        query: spec.query,
        body: spec.body,
        request: *const Request,
        response: *Response,
        /// Freed once the request is answered.
        arena: std.mem.Allocator,

        pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
            return self.response.setHeader(name, value);
        }

        pub fn send(self: *Self, status: u16, content_type: []const u8, body: []const u8) !void {
            return self.response.send(status, content_type, body);
        }

        pub fn text(self: *Self, status: u16, body: []const u8) !void {
            return self.response.send(status, "text/plain; charset=utf-8", body);
        }

        pub fn json(self: *Self, status: u16, value: anytype) !void {
            return self.response.json(status, value);
        }

        /// `send`, of a body that outlives the answer: not copied.
        pub fn sendOwned(self: *Self, status: u16, content_type: []const u8, body: []const u8) void {
            self.response.sendOwned(status, content_type, body);
        }

        /// `func(args)` on one of `on`'s threads, whose result answers back
        /// on the loop: a `Reply` as it is, anything else as JSON (204 for
        /// `void`), an error with its status. The request (its arena, body
        /// and params) stays until then, so `args` may point into it. A full
        /// pool is `error.ServiceUnavailable`.
        pub fn offload(self: *Self, on: *pool.Pool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
            const res = self.response;
            const late = res.late orelse return error.ServiceUnavailable;
            const J = Offload(func);
            const job = try res.arena.create(J);
            job.* = .{ .job = .{ .work = J.work, .post = .{ .run = J.done }, .mailbox = late.mailbox }, .res = res, .args = args };
            late.mailbox.expect();
            if (!on.submit(&job.job)) {
                late.mailbox.forget();
                return error.ServiceUnavailable;
            }
            res.deferred = true;
        }
    };
}

/// An answer whole, for offloaded work that picks its own status and body.
pub const Reply = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

fn Offload(comptime func: anytype) type {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return struct {
        job: pool.Job,
        res: *Response,
        args: std.meta.ArgsTuple(@TypeOf(func)),
        result: R = undefined,

        fn work(j: *pool.Job) void {
            const self: *@This() = @fieldParentPtr("job", j);
            self.result = @call(.auto, func, self.args);
        }

        /// On the loop's thread. The job lives in the request's arena,
        /// which sending the answer frees.
        fn done(p: *Mailbox.Post) void {
            const j: *pool.Job = @fieldParentPtr("post", p);
            const self: *@This() = @fieldParentPtr("job", j);
            const res = self.res;
            defer res.late.?.send(res.late.?.ctx);
            const value = switch (@typeInfo(R)) {
                .error_union => self.result catch |err| return res.fail(statusOf(err)),
                else => self.result,
            };
            if (@TypeOf(value) == Reply) return res.send(value.status, value.content_type, value.body) catch res.fail(500);
            if (@TypeOf(value) != void) res.json(200, value) catch res.fail(500);
        }
    };
}

pub fn isContext(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "web_spec");
}

/// `params`' fields from the pattern's captures, in the pattern's order.
pub fn decodeParams(comptime P: type, comptime names: []const []const u8, captures: []const []const u8, arena: std.mem.Allocator) !P {
    var p: P = undefined;
    inline for (names, 0..) |name, i| {
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

pub fn decodeBody(comptime B: type, req: *const Request, arena: std.mem.Allocator) !B {
    if (B == void) return {};
    if (B == []const u8) return req.body;
    return std.json.parseFromSliceLeaky(B, arena, req.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadRequest,
    };
}

/// `%XX` decoded (a malformed one kept as it is), and `+` as a space in a query.
fn percentDecode(arena: std.mem.Allocator, text: []const u8, plus_is_space: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, text, if (plus_is_space) "%+" else "%") == null) return text;
    const out = try arena.dupe(u8, text);
    if (plus_is_space) std.mem.replaceScalar(u8, out, '+', ' ');
    return std.Uri.percentDecodeInPlace(out);
}

fn parseScalar(comptime T: type, text: []const u8) !T {
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

test "a header that would split the head is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var res: Response = .init(arena.allocator());
    try res.setHeader("X-Ok", "fine");
    try std.testing.expectError(error.InvalidHeader, res.setHeader("X-Bad", "a\r\nSet-Cookie: x"));
    try std.testing.expectError(error.InvalidHeader, res.setHeader("Bad Name", "a"));
    try std.testing.expectEqual(1, res.headers.items.len);
}
