//! A router on a listener of its own: middleware in front of it, WebSocket
//! routes, and with TLS, HTTP/3 and a drain.

const std = @import("std");
const quic = @import("quic");
const http = @import("../http.zig");
const sys = quic.sys;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;
const support = @import("support.zig");
const fetch = support.fetch;
const dial = support.dial;
const bodyOf = support.bodyOf;
const hello = support.hello;
const Visitor = support.Visitor;
const nameVisitor = support.nameVisitor;

const Admin = struct {
    fn stats(_: *Admin, _: *http.Context(.{})) !struct { rooms: u32 } {
        return .{ .rooms = 3 };
    }

    /// Sums the body's bytes, as a compile would run: off the loop, picking
    /// its own answer.
    fn sum(_: *Admin, ctx: *http.Context(.{ .body = []const u8, .max_body = 1 << 20 })) !http.Reply {
        if (ctx.body.len == 0) return error.BadRequest;
        var total: u64 = 0;
        for (ctx.body) |b| total += b;
        return .{ .status = 200, .content_type = "text/plain", .body = try std.fmt.allocPrint(ctx.arena, "{d}", .{total}) };
    }
};

test "a listener of its own: a bearer token guards it, and a blocking handler picks its answer" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var admin: Admin = .{};

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const auth: http.Bearer = .{ .token = "s3cret" };
    const guarded = try router.scope("").with(&.{auth.middleware()});
    try guarded.get("/stats", &admin, Admin.stats);
    try (try guarded.blocking(threaded.io(), .{})).post("/sum", &admin, Admin.sum);

    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();
    var buf: [4096]u8 = undefined;

    const denied = try fetch(server.port(), "GET /stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, denied, "HTTP/1.1 401 "));
    try std.testing.expect(std.mem.indexOf(u8, denied, "WWW-Authenticate: Bearer\r\n") != null);

    const ok = try fetch(server.port(), "GET /stats HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\n\r\n", &buf);
    try expectEqualStrings("{\"rooms\":3}", bodyOf(ok));

    const summed = try fetch(server.port(), "POST /sum HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\nContent-Length: 3\r\n\r\n\x01\x02\x03", &buf);
    try std.testing.expect(std.mem.indexOf(u8, summed, "Content-Type: text/plain\r\n") != null);
    try expectEqualStrings("6", bodyOf(summed));
    const empty = try fetch(server.port(), "POST /sum HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cret\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, empty, "HTTP/1.1 400 "));

    // Quiet, it drains at once, well inside its grace.
    const t0 = sys.nanoTimestamp();
    server.drain(5000);
    try std.testing.expect(sys.nanoTimestamp() - t0 < std.time.ns_per_s);
}

test "CORS: a listed origin reads the answer, another is refused, a preflight is answered" {
    var router: http.Router = .init(gpa);
    defer router.deinit();
    const cors: http.Cors = .{ .origins = &.{"https://game.example"} };
    try (try router.scope("").with(&.{cors.middleware()})).post("/hello", {}, hello);
    var c: http.testing.Client = .init(gpa, &router);
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
    var router: http.Router = .init(gpa);
    defer router.deinit();
    var limit: http.RateLimit = .init(gpa, 0.001, 2);
    defer limit.deinit();
    try (try router.scope("").with(&.{ limit.middleware(), http.access_log })).post("/hello", {}, hello);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqual(200, (try c.post("/hello", "")).status.?);
    try expectEqual(200, (try c.post("/hello", "")).status.?);
    const third = try c.post("/hello", "");
    try expectEqual(429, third.status.?);
    try expectEqualStrings("1", third.header("retry-after").?);
}

fn whoAmI(ctx: *http.Context(.{})) !void {
    const text = try std.fmt.allocPrint(ctx.arena, "{f}", .{ctx.request.client});
    ctx.sendOwned(200, "text/plain", text);
}

test "behind a trusted proxy, each client it names has its own bucket; anyone else's header is ignored" {
    var router: http.Router = .init(gpa);
    defer router.deinit();
    var limit: http.RateLimit = .init(gpa, 0.001, 1);
    defer limit.deinit();
    try (try router.scope("").with(&.{limit.middleware()})).get("/me", {}, whoAmI);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();
    const trusted = [_]http.address.Network{try .parse("10.0.0.0/8")};
    c.host.trusted_proxies = &trusted;

    const proxy = http.Address.parse("10.0.0.2").?;
    const ann: []const http.Header = &.{.{ .name = "X-Forwarded-For", .value = "203.0.113.7" }};
    const bob: []const http.Header = &.{.{ .name = "X-Forwarded-For", .value = "198.51.100.9" }};
    const first = try c.request(.GET, "/me", .{ .peer = proxy, .headers = ann });
    try expectEqualStrings("203.0.113.7", first.body);
    try expectEqual(429, (try c.request(.GET, "/me", .{ .peer = proxy, .headers = ann })).status.?);
    try expectEqual(200, (try c.request(.GET, "/me", .{ .peer = proxy, .headers = bob })).status.?);

    // Not from the proxy: its own address, whatever it claims.
    const stranger = try c.request(.GET, "/me", .{ .peer = http.Address.parse("192.0.2.1").?, .headers = bob });
    try expectEqualStrings("192.0.2.1", stranger.body);
}

const Lobby = struct {
    closed: std.atomic.Value(u32) = .init(0),
};

const Chat = struct {
    pub fn open(_: *Lobby, ctx: *http.Context(.{ .params = struct { id: u32 } })) !void {
        try ctx.call.setLocal(u32, ctx.params.id);
    }

    pub fn ready(_: *Lobby, ws: *http.WebSocket, call: *http.Call) void {
        var buf: [64]u8 = undefined;
        const greeting = std.fmt.bufPrint(&buf, "welcome {s} to {d}", .{ call.local(Visitor).?.name, call.local(u32).?.* }) catch return;
        ws.sendText(greeting) catch {};
    }

    pub fn message(_: *Lobby, ws: *http.WebSocket, data: []const u8, _: http.WebSocket.Kind) void {
        ws.sendText(data) catch {};
    }

    pub fn close(lobby: *Lobby, _: *http.WebSocket, _: u16, _: []const u8) void {
        _ = lobby.closed.fetchAdd(1, .release);
    }
};

const ws_upgrade = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n";

/// A raw WebSocket client, upgraded to `path` as ann.
fn wsOpen(port: u16, path: []const u8) !std.posix.fd_t {
    const fd = try dial(port);
    errdefer sys.close(fd);
    var req: [512]u8 = undefined;
    try (sys.File{ .fd = fd }).writeAll(try std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: x\r\n" ++ ws_upgrade ++ "X-Visitor: ann\r\n\r\n", .{path}));
    // A byte at a time: the first frame may follow the head in the same read.
    var head: [512]u8 = undefined;
    var len: usize = 0;
    while (!std.mem.endsWith(u8, head[0..len], "\r\n\r\n")) : (len += 1) try readExact(fd, head[len..][0..1]);
    if (!std.mem.startsWith(u8, head[0..len], "HTTP/1.1 101 ")) return error.NotUpgraded;
    return fd;
}

/// One frame's payload, unmasked as a server sends it, short.
fn wsRead(fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    var hdr: [2]u8 = undefined;
    try readExact(fd, &hdr);
    const n = hdr[1] & 0x7f;
    try readExact(fd, buf[0..n]);
    return buf[0..n];
}

/// A masked frame, as a client sends one: `opcode` 1 text, 8 close.
fn wsWrite(fd: std.posix.fd_t, opcode: u8, payload: []const u8) !void {
    var frame: [134]u8 = undefined;
    const mask = [4]u8{ 1, 2, 3, 4 };
    frame[0] = 0x80 | opcode;
    frame[1] = 0x80 | @as(u8, @intCast(payload.len));
    @memcpy(frame[2..6], &mask);
    for (payload, 0..) |b, i| frame[6 + i] = b ^ mask[i % 4];
    try (sys.File{ .fd = fd }).writeAll(frame[0 .. 6 + payload.len]);
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) return error.Closed;
        got += @intCast(n);
    }
}

test "on a server: a WebSocket route's upgrade goes through its middleware and open, then its hooks hear the socket" {
    var lobby: Lobby = .{};
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").with(&.{.{ .before = nameVisitor }})).ws("/rooms/:id", &lobby, Chat);
    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();

    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try fetch(server.port(), "GET /rooms/7 HTTP/1.1\r\nHost: x\r\n" ++ ws_upgrade ++ "\r\n", &buf), "HTTP/1.1 401 "));
    try std.testing.expect(std.mem.startsWith(u8, try fetch(server.port(), "GET /rooms/seven HTTP/1.1\r\nHost: x\r\n" ++ ws_upgrade ++ "X-Visitor: ann\r\n\r\n", &buf), "HTTP/1.1 404 "));

    const fd = try wsOpen(server.port(), "/rooms/7");
    try expectEqualStrings("welcome ann to 7", try wsRead(fd, &buf));
    try wsWrite(fd, 1, "hi");
    try expectEqualStrings("hi", try wsRead(fd, &buf));
    try wsWrite(fd, 8, &.{ 0x03, 0xe8 }); // close, 1000
    _ = try wsRead(fd, &buf); // its answer
    sys.close(fd);
    var waited: u32 = 0;
    while (lobby.closed.load(.acquire) == 0) : (waited += 1) {
        if (waited > 2000) return error.NotClosed;
        sys.sleepNs(std.time.ns_per_ms);
    }
}

/// A client's own loop, stepped while the server runs on its thread.
const ClientLoop = struct {
    loop: quic.event_loop.Xev.Loop,

    pub fn step(self: *ClientLoop) !void {
        try self.loop.run(.no_wait);
        sys.sleepNs(50 * std.time.ns_per_us);
    }
};

test "with tls: HTTP/3 on its own thread and loop, and a drain that stops it once it's quiet" {
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.get("/hello", {}, hello);
    const server = try http.Server.create(gpa, &router, .{ .tls = .{
        .cert_path = "../quic-zig/interop/browser/certs/server.crt",
        .key_path = "../quic-zig/interop/browser/certs/server.key",
    } });
    defer server.destroy();

    var client: ClientLoop = .{ .loop = try .init(.{}) };
    defer client.loop.deinit();
    var a: http.testing.Http3 = .{ .path = "/hello" };
    try a.fetch(gpa, &client.loop, server.port(), &client);
    try expectEqualStrings("200", &a.status);
    try expectEqualStrings("hello", a.text());

    const t0: i64 = sys.nanoTimestamp();
    server.drain(5000);
    try std.testing.expect(sys.nanoTimestamp() - t0 < 5 * std.time.ns_per_s);
}
