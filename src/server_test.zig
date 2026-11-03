//! A router on a listener of its own, its middleware, and work offloaded
//! to a pool that answers later.

const std = @import("std");
const quic = @import("quic");
const web = @import("web.zig");
const sys = quic.sys;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

const Admin = struct {
    pool: *web.Pool,
    full: *web.Pool,

    fn stats(_: *Admin, _: *web.Context(.{})) !struct { rooms: u32 } {
        return .{ .rooms = 3 };
    }

    /// Sums the body's bytes on a pool thread, as a compile would run.
    fn sum(self: *Admin, ctx: *web.Context(.{ .body = []const u8, .max_body = 1 << 20 })) !void {
        try ctx.offload(self.pool, add, .{ctx.body});
    }

    fn crowded(self: *Admin, ctx: *web.Context(.{})) !void {
        try ctx.offload(self.full, add, .{""});
    }

    fn add(bytes: []const u8) !u64 {
        if (bytes.len == 0) return error.BadRequest;
        var total: u64 = 0;
        for (bytes) |b| total += b;
        return total;
    }
};

/// Sends `request` and reads until the server closes.
fn fetch(port: u16, request: []const u8, buf: []u8) ![]const u8 {
    const fd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer sys.close(fd);
    const addr = try quic.sockaddr.Address.parseIp4("127.0.0.1", port);
    if (std.c.connect(fd, &addr.any, addr.getOsSockLen()) != 0) return error.ConnectionRefused;
    const out: sys.File = .{ .fd = fd };
    try out.writeAll(request);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

fn bodyOf(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

test "a listener of its own: a bearer token guards it, and offloaded work answers from the pool" {
    const pool = try web.Pool.create(gpa, std.testing.io, .{ .threads = 2 });
    defer pool.destroy();
    const full = try web.Pool.create(gpa, std.testing.io, .{ .max_queued = 0 });
    defer full.destroy();
    var admin: Admin = .{ .pool = pool, .full = full };

    var router: web.Router = .init(gpa);
    defer router.deinit();
    const auth: web.Bearer = .{ .token = "s3cret" };
    const guarded = try router.scope("").with(&.{auth.middleware()});
    try guarded.get("/stats", &admin, Admin.stats);
    try guarded.post("/sum", &admin, Admin.sum);
    try guarded.get("/crowded", &admin, Admin.crowded);

    const server = try web.Server.create(gpa, &router, .{});
    defer server.destroy();
    var buf: [4096]u8 = undefined;

    const denied = try fetch(server.port(), "GET /stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, denied, "HTTP/1.1 401 "));
    try std.testing.expect(std.mem.indexOf(u8, denied, "WWW-Authenticate: Bearer\r\n") != null);

    const ok = try fetch(server.port(), "GET /stats HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\n\r\n", &buf);
    try expectEqualStrings("{\"rooms\":3}", bodyOf(ok));

    const summed = try fetch(server.port(), "POST /sum HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\nContent-Length: 3\r\n\r\n\x01\x02\x03", &buf);
    try expectEqualStrings("6", bodyOf(summed));
    const empty = try fetch(server.port(), "POST /sum HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, empty, "HTTP/1.1 400 "));
    const crowded = try fetch(server.port(), "GET /crowded HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, crowded, "HTTP/1.1 503 "));
}

fn hello(ctx: *web.Context(.{})) !void {
    try ctx.text(200, "hello");
}

test "CORS: a listed origin reads the answer, another is refused, a preflight is answered" {
    var router: web.Router = .init(gpa);
    defer router.deinit();
    const cors: web.Cors = .{ .origins = &.{"https://game.example"} };
    try (try router.scope("").with(&.{cors.middleware()})).post("/hello", {}, hello);
    var c: web.testing.Client = .init(gpa, &router);
    defer c.deinit();

    const listed = try c.request(.POST, "/hello", .{ .headers = &.{.{ .name = "Origin", .value = "https://GAME.example" }} });
    try expectEqual(200, listed.status.?);
    try expectEqualStrings("https://GAME.example", listed.header("access-control-allow-origin").?);
    try expectEqualStrings("Origin", listed.header("vary").?);

    const other = try c.request(.POST, "/hello", .{ .headers = &.{.{ .name = "Origin", .value = "https://evil.example" }} });
    try expectEqual(403, other.status.?);
    try expectEqual(null, other.header("access-control-allow-origin"));

    const native = try c.post("/hello", "");
    try expectEqual(200, native.status.?);
    try expectEqual(null, native.header("access-control-allow-origin"));

    const preflight = try c.request(.OPTIONS, "/hello", .{ .headers = &.{
        .{ .name = "Origin", .value = "https://game.example" },
        .{ .name = "Access-Control-Request-Method", .value = "POST" },
        .{ .name = "Access-Control-Request-Headers", .value = "content-type" },
    } });
    try expectEqual(204, preflight.status.?);
    try expectEqualStrings("content-type", preflight.header("access-control-allow-headers").?);
    try expectEqualStrings("https://game.example", preflight.header("access-control-allow-origin").?);

    // Not a preflight: the router says which methods the path takes.
    const options = try c.request(.OPTIONS, "/hello", .{});
    try expectEqual(204, options.status.?);
    try expectEqualStrings("POST", options.header("allow").?);
}

test "a rate limit turns a client away once its bucket is empty" {
    var router: web.Router = .init(gpa);
    defer router.deinit();
    var limit: web.RateLimit = .init(gpa, 0.001, 2);
    defer limit.deinit();
    try (try router.scope("").with(&.{ limit.middleware(), web.access_log })).post("/hello", {}, hello);
    var c: web.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqual(200, (try c.post("/hello", "")).status.?);
    try expectEqual(200, (try c.post("/hello", "")).status.?);
    const third = try c.post("/hello", "");
    try expectEqual(429, third.status.?);
    try expectEqualStrings("1", third.header("retry-after").?);
}
