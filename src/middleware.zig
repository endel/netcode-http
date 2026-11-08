//! What runs around a scope's routes: `before` at the request's head, ahead
//! of its body; `around` the handler, where it runs; and `after` on every
//! answer the routes send, theirs or one a `before` sent.
//!
//! ```zig
//! const auth: http.Bearer = .{ .token = opts.token };
//! const admin = try router.scope("/admin").with(&.{auth.middleware()});
//! try admin.get("/stats", app, stats);
//! ```

const std = @import("std");
const sys = @import("quic").sys;
const context = @import("context.zig");
const Call = context.Call;

pub const Middleware = struct {
    ctx: ?*const anyopaque = null,
    /// At the request's head, on the loop, before its body arrives. An
    /// answer sent or an error returned (with its status) stops the request.
    before: ?*const fn (ctx: ?*const anyopaque, call: *Call) anyerror!void = null,
    /// Around the handler, where it runs: in a blocking scope that's its
    /// task, so this may block too (`next.call.io`). `next.run()` runs the rest
    /// of the way, handler included; not calling it stops the request here.
    around: ?*const fn (ctx: ?*const anyopaque, next: Next) anyerror!void = null,
    /// On every answer, on the loop.
    after: ?*const fn (ctx: ?*const anyopaque, call: *Call) void = null,
};

/// The rest of the way to a route's handler, for `around` middleware.
pub const Next = struct {
    call: *Call,
    /// The router's: what's left of the way.
    rest: *const anyopaque,
    run_rest: *const fn (rest: *const anyopaque, call: *Call) anyerror!void,

    /// The `around` middleware left, then the handler.
    pub fn run(self: Next) anyerror!void {
        return self.run_rest(self.rest, self.call);
    }
};

/// `Authorization: Bearer <token>`, or 401.
pub const Bearer = struct {
    token: []const u8,

    pub fn middleware(self: *const Bearer) Middleware {
        return .{ .ctx = self, .before = check };
    }

    fn check(ctx: ?*const anyopaque, call: *Call) !void {
        const self: *const Bearer = @ptrCast(@alignCast(ctx.?));
        const given = call.request.header("authorization") orelse "";
        const token = if (std.ascii.startsWithIgnoreCase(given, "Bearer ")) given["Bearer ".len..] else "";
        if (sameSecret(token, self.token)) return;
        try call.response.setHeader("WWW-Authenticate", "Bearer");
        return error.Unauthorized;
    }
};

/// Tells nothing of how much of `given` was right, nor its length: the
/// digests are compared, in constant time. An empty `expected` takes none.
fn sameSecret(given: []const u8, expected: []const u8) bool {
    if (expected.len == 0) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(given, &a, .{});
    Sha256.hash(expected, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}

/// Pages from other origins: those listed may read the answers, and a
/// request from any other page (by its `Origin`) is refused with 403. A
/// preflight (OPTIONS) is answered here.
pub const Cors = struct {
    /// As browsers send them, scheme and port included; matched ignoring
    /// case. Null takes any origin.
    origins: ?[]const []const u8 = null,

    pub fn middleware(self: *const Cors) Middleware {
        return .{ .ctx = self, .before = check, .after = allow };
    }

    pub fn allows(self: *const Cors, origin: ?[]const u8) bool {
        const list = self.origins orelse return true;
        const o = origin orelse return true; // a native client sends none
        for (list) |entry| if (std.ascii.eqlIgnoreCase(entry, o)) return true;
        return false;
    }

    fn check(ctx: ?*const anyopaque, call: *Call) !void {
        const self: *const Cors = @ptrCast(@alignCast(ctx.?));
        const req = &call.request;
        const res = &call.response;
        if (!self.allows(req.header("origin"))) return res.send(403, "text/plain", "origin not allowed\n");
        if (req.method != .OPTIONS or req.header("access-control-request-method") == null) return;
        try res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, PATCH, DELETE");
        if (req.header("access-control-request-headers")) |h| try res.setHeader("Access-Control-Allow-Headers", h);
        try res.setHeader("Access-Control-Max-Age", "600");
        try res.send(204, "text/plain", "");
    }

    fn allow(ctx: ?*const anyopaque, call: *Call) void {
        const self: *const Cors = @ptrCast(@alignCast(ctx.?));
        const req = &call.request;
        const res = &call.response;
        if (self.origins == null) return res.setHeader("Access-Control-Allow-Origin", "*") catch {};
        const origin = req.header("origin") orelse return;
        if (!self.allows(origin)) return;
        res.setHeader("Access-Control-Allow-Origin", origin) catch {};
        res.setHeader("Vary", "Origin") catch {};
    }
};

/// Requests per client address (`Request.client`, so behind a trusted proxy
/// each client has its own): `per_second` on average, `burst` at once;
/// past it, 429. GCRA, as routez's `limit_req`: each address keeps only
/// when its bucket is next full. Any thread.
pub const RateLimit = struct {
    gpa: std.mem.Allocator,
    /// Between two requests at the average rate.
    interval_ns: i64,
    /// How far ahead of the average a client may run: the burst.
    tolerance_ns: i64,
    locked: std.atomic.Value(bool) = .init(false),
    full_at: std.AutoHashMapUnmanaged([16]u8, i64) = .empty,

    /// Addresses remembered at once; past it every bucket starts over.
    const max_clients = 16 * 1024;

    pub fn init(gpa: std.mem.Allocator, per_second: f64, burst: u32) RateLimit {
        const interval: i64 = @intFromFloat(std.time.ns_per_s / per_second);
        return .{ .gpa = gpa, .interval_ns = interval, .tolerance_ns = interval * @max(burst, 1) };
    }

    pub fn deinit(self: *RateLimit) void {
        self.full_at.deinit(self.gpa);
    }

    pub fn middleware(self: *RateLimit) Middleware {
        return .{ .ctx = self, .before = check };
    }

    fn check(ctx: ?*const anyopaque, call: *Call) !void {
        const self: *RateLimit = @ptrCast(@alignCast(@constCast(ctx.?)));
        if (self.take(call.request.client.bytes, sys.nanoTimestamp())) return;
        try call.response.setHeader("Retry-After", "1");
        return error.TooManyRequests;
    }

    fn take(self: *RateLimit, key: [16]u8, now_ns: i64) bool {
        var spins: u32 = 0;
        while (self.locked.swap(true, .acquire)) : (spins += 1) {
            // The holder may be growing the map: let it run.
            if (spins % 64 == 63) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        defer self.locked.store(false, .release);
        if (self.full_at.count() >= max_clients) self.full_at.clearRetainingCapacity();
        const at = self.full_at.getOrPut(self.gpa, key) catch return true;
        const full = if (at.found_existing) @max(at.value_ptr.*, now_ns) else now_ns;
        if (full + self.interval_ns - now_ns > self.tolerance_ns) return false;
        at.value_ptr.* = full + self.interval_ns;
        return true;
    }
};

/// A line per answer: client, method, target, status and body length.
pub const access_log: Middleware = .{ .after = logAnswer };

fn logAnswer(_: ?*const anyopaque, call: *Call) void {
    const req = &call.request;
    std.log.scoped(.http).info("{f} {t} {s} {d} {d}", .{ req.client, req.method, req.target, call.response.status, call.response.body.len });
}

test "a bucket empties, refills with time, and each address has its own" {
    var limit: RateLimit = .init(std.testing.allocator, 2, 2);
    defer limit.deinit();
    const a: [16]u8 = @splat(1);
    const b: [16]u8 = @splat(2);
    try std.testing.expect(limit.take(a, 0));
    try std.testing.expect(limit.take(a, 0));
    try std.testing.expect(!limit.take(a, 0));
    try std.testing.expect(limit.take(b, 0));
    try std.testing.expect(limit.take(a, std.time.ns_per_s / 2));
    try std.testing.expect(!limit.take(a, std.time.ns_per_s / 2));
}

test "a secret compares whole, and an empty one takes nothing" {
    try std.testing.expect(sameSecret("secret", "secret"));
    try std.testing.expect(!sameSecret("secreT", "secret"));
    try std.testing.expect(!sameSecret("", ""));
}
