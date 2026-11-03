//! What runs around a scope's routes: `before` at the request's head, ahead
//! of its body and its handler, and `after` on every answer the routes
//! send, theirs or one a `before` sent.
//!
//! ```zig
//! const auth: web.Bearer = .{ .token = opts.token };
//! const admin = try router.scope("/admin").with(&.{auth.middleware()});
//! try admin.get("/stats", app, stats);
//! ```

const std = @import("std");
const sys = @import("quic").sys;
const context = @import("context.zig");
const Request = context.Request;
const Response = context.Response;

pub const Middleware = struct {
    ctx: ?*const anyopaque = null,
    /// An answer sent here (`res.fail`, `res.send`...) stops the request.
    before: ?*const fn (ctx: ?*const anyopaque, req: *const Request, res: *Response) void = null,
    after: ?*const fn (ctx: ?*const anyopaque, req: *const Request, res: *Response) void = null,
};

/// `Authorization: Bearer <token>`, or 401.
pub const Bearer = struct {
    token: []const u8,

    pub fn middleware(self: *const Bearer) Middleware {
        return .{ .ctx = self, .before = check };
    }

    fn check(ctx: ?*const anyopaque, req: *const Request, res: *Response) void {
        const self: *const Bearer = @ptrCast(@alignCast(ctx.?));
        const given = req.header("authorization") orelse "";
        const token = if (std.ascii.startsWithIgnoreCase(given, "Bearer ")) given["Bearer ".len..] else "";
        if (sameSecret(token, self.token)) return;
        res.setHeader("WWW-Authenticate", "Bearer") catch {};
        res.fail(401);
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

    fn check(ctx: ?*const anyopaque, req: *const Request, res: *Response) void {
        const self: *const Cors = @ptrCast(@alignCast(ctx.?));
        const origin = req.header("origin");
        if (!self.allows(origin)) return res.send(403, "text/plain", "origin not allowed\n") catch {};
        if (req.method != .OPTIONS or req.header("access-control-request-method") == null) return;
        res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, PATCH, DELETE") catch {};
        if (req.header("access-control-request-headers")) |h| res.setHeader("Access-Control-Allow-Headers", h) catch {};
        res.setHeader("Access-Control-Max-Age", "600") catch {};
        res.send(204, "text/plain", "") catch {};
    }

    fn allow(ctx: ?*const anyopaque, req: *const Request, res: *Response) void {
        const self: *const Cors = @ptrCast(@alignCast(ctx.?));
        if (self.origins == null) return res.setHeader("Access-Control-Allow-Origin", "*") catch {};
        const origin = req.header("origin") orelse return;
        if (!self.allows(origin)) return;
        res.setHeader("Access-Control-Allow-Origin", origin) catch {};
        res.setHeader("Vary", "Origin") catch {};
    }
};

/// Requests per client address: `per_second` on average, `burst` at once;
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

    fn check(ctx: ?*const anyopaque, req: *const Request, res: *Response) void {
        const self: *RateLimit = @ptrCast(@alignCast(@constCast(ctx.?)));
        const peer = req.peer orelse return;
        if (self.take(addressKey(peer), sys.nanoTimestamp())) return;
        res.setHeader("Retry-After", "1") catch {};
        res.fail(429);
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

/// The client's IP, IPv4 as IPv4-mapped IPv6.
fn addressKey(peer: *const std.posix.sockaddr.storage) [16]u8 {
    var key: [16]u8 = @splat(0);
    switch (peer.family) {
        std.posix.AF.INET => {
            const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(peer));
            key[10] = 0xff;
            key[11] = 0xff;
            @memcpy(key[12..], std.mem.asBytes(&in.addr));
        },
        std.posix.AF.INET6 => {
            const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(peer));
            key = in6.addr;
        },
        else => {},
    }
    return key;
}

/// A line per answer: method, target, status and body length.
pub const access_log: Middleware = .{ .after = logAnswer };

fn logAnswer(_: ?*const anyopaque, req: *const Request, res: *Response) void {
    std.log.scoped(.http).info("{t} {s} {d} {d}", .{ req.method, req.target, res.status, res.body.len });
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
