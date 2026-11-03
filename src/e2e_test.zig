//! Routes served by a real quic-zig server, over HTTP/1.1 and HTTP/3.

const std = @import("std");
const quic = @import("quic");
const web = @import("web.zig");
const sys = quic.sys;
const event_loop = quic.event_loop;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const cert_path = "../quic-zig/interop/browser/certs/server.crt";
const key_path = "../quic-zig/interop/browser/certs/server.key";

const App = struct {
    pub const protocol: event_loop.Protocol = .webtransport;

    router: web.Router,
    host: web.quic.Host,
    total: u64 = 0,

    pub fn onHttpHead(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpHead(ex);
    }
    pub fn onHttpBody(self: *App, ex: *event_loop.Exchange, data: []const u8) void {
        self.host.onHttpBody(ex, data);
    }
    pub fn onHttpEnd(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpEnd(ex);
    }
    pub fn onHttpGone(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpGone(ex);
    }

    fn add(self: *App, ctx: *web.Context(.{ .body = struct { n: u64 } })) !struct { total: u64 } {
        self.total += ctx.body.n;
        return .{ .total = self.total };
    }

    fn hello(_: *App, ctx: *web.Context(.{ .params = struct { name: []const u8 } })) !void {
        try ctx.setHeader("Cache-Control", "no-store");
        try ctx.send(200, "text/plain", try std.fmt.allocPrint(ctx.arena, "hi {s}", .{ctx.params.name}));
    }

    fn size(_: *App, ctx: *web.Context(.{ .body = []const u8, .max_body = 1 << 20 })) !usize {
        return ctx.body.len;
    }
};

const Harness = struct {
    loop: event_loop.Xev.Loop,
    app: App,
    server: event_loop.Server(App),
    port: u16,

    fn init(self: *Harness, port: u16, static_dir: ?[]const u8) !void {
        self.port = port;
        self.app = .{ .router = .init(std.testing.allocator), .host = undefined };
        self.app.host = .init(std.testing.allocator, &self.app.router);
        try self.app.router.post("/add", &self.app, App.add);
        try self.app.router.get("/hello/:name", &self.app, App.hello);
        try self.app.router.on(.PUT, "/size", &self.app, App.size);
        self.loop = try event_loop.Xev.Loop.init(.{});
        self.server = try event_loop.Server(App).init(std.testing.allocator, &self.app, .{
            .address = "127.0.0.1",
            .port = port,
            .cert_path = cert_path,
            .key_path = key_path,
            .loop = &self.loop,
            .http1 = .{ .tls = false, .static_dir = static_dir },
        });
        self.server.start();
    }

    pub fn step(self: *Harness) !void {
        try self.server.tick();
        sys.sleepNs(50 * std.time.ns_per_us);
    }

    fn deinit(self: *Harness) void {
        self.server.stop();
        const deadline = sys.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (!self.server.isStopped() and sys.nanoTimestamp() < deadline) self.server.tick() catch break;
        self.server.deinit();
        self.loop.deinit();
        self.app.router.deinit();
    }

    /// Sends `request` whole and reads until the server closes.
    fn fetch(self: *Harness, request: []const u8, buf: []u8) ![]const u8 {
        const fd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer sys.close(fd);
        const addr = try quic.sockaddr.Address.parseIp4("127.0.0.1", self.port);
        if (std.c.connect(fd, &addr.any, addr.getOsSockLen()) != 0) return error.ConnectionRefused;
        var sent: usize = 0;
        var len: usize = 0;
        const deadline = sys.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (len < buf.len) {
            if (sys.nanoTimestamp() > deadline) return error.Timeout;
            if (sent < request.len) {
                const rc = std.c.send(fd, request[sent..].ptr, request.len - sent, std.c.MSG.DONTWAIT);
                if (rc > 0) sent += @intCast(rc);
            }
            try self.server.tick();
            const rc = std.c.recv(fd, buf[len..].ptr, buf.len - len, std.c.MSG.DONTWAIT);
            if (rc == 0) break;
            if (rc > 0) len += @intCast(rc) else sys.sleepNs(50 * std.time.ns_per_us);
        }
        return buf[0..len];
    }
};

fn bodyOf(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

fn has(response: []const u8, line: []const u8) bool {
    return std.mem.indexOf(u8, response, line) != null;
}

test "HTTP/1.1: the router answers; what no route has goes on to the static files" {
    var h: Harness = undefined;
    try h.init(24911, "src");
    defer h.deinit();
    var buf: [16 * 1024]u8 = undefined;

    const hello = try h.fetch("GET /hello/ann%20lee HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, hello, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(has(hello, "Content-Type: text/plain\r\nCache-Control: no-store\r\n"));
    try expectEqualStrings("hi ann lee", bodyOf(hello));

    const add = try h.fetch("POST /add HTTP/1.1\r\nHost: a\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{\"n\r\n5\r\n\":41}\r\n0\r\n\r\n", &buf);
    try expectEqualStrings("{\"total\":41}", bodyOf(add));

    const head = try h.fetch("HEAD /hello/x HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(has(head, "Content-Length: 4\r\n"));
    try expectEqualStrings("", bodyOf(head));

    const wrong = try h.fetch("DELETE /add HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, wrong, "HTTP/1.1 405 "));
    try std.testing.expect(has(wrong, "Allow: POST\r\n"));

    const file = try h.fetch("GET /web.zig HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, file, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(has(bodyOf(file), "pub const Router"));
}

test "HTTP/1.1: a body past the route's limit is 413; under it, it arrives whole" {
    var h: Harness = undefined;
    try h.init(24912, null);
    defer h.deinit();
    var buf: [4096]u8 = undefined;

    const big = try h.fetch("POST /add HTTP/1.1\r\nHost: a\r\nContent-Length: 70000\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, big, "HTTP/1.1 413 "));
    try std.testing.expect(has(big, "Connection: close\r\n"));

    const body = try std.testing.allocator.alloc(u8, 300_000);
    defer std.testing.allocator.free(body);
    @memset(body, 'z');
    const request = try std.fmt.allocPrint(std.testing.allocator, "PUT /size HTTP/1.1\r\nHost: a\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer std.testing.allocator.free(request);
    try expectEqualStrings("300000", bodyOf(try h.fetch(request, &buf)));
}

test "HTTP/1.1 keep-alive: requests on one connection each get their answer, in order" {
    var h: Harness = undefined;
    try h.init(24913, null);
    defer h.deinit();
    var buf: [16 * 1024]u8 = undefined;
    const both = try h.fetch(
        "POST /add HTTP/1.1\r\nHost: a\r\nContent-Length: 7\r\n\r\n{\"n\":1}" ++
            "POST /add HTTP/1.1\r\nHost: a\r\nConnection: close\r\nContent-Length: 7\r\n\r\n{\"n\":2}",
        &buf,
    );
    const first = std.mem.indexOf(u8, both, "{\"total\":1}") orelse return error.NoFirstAnswer;
    const second = std.mem.indexOf(u8, both, "{\"total\":3}") orelse return error.NoSecondAnswer;
    try std.testing.expect(first < second);
    try expectEqual(3, h.app.total);
}

test "HTTP/3: the same routes answer, a body comes in, and no route's path is 404" {
    var h: Harness = undefined;
    try h.init(24914, null);
    defer h.deinit();

    var a: web.testing.Http3 = .{ .path = "/hello/bob" };
    try a.fetch(std.testing.allocator, &h.loop, h.port, &h);
    try expectEqualStrings("200", &a.status);
    try expectEqualStrings("hi bob", a.text());

    var b: web.testing.Http3 = .{ .method = "POST", .path = "/add", .body = "{\"n\":5}" };
    try b.fetch(std.testing.allocator, &h.loop, h.port, &h);
    try expectEqualStrings("{\"total\":5}", b.text());

    var c: web.testing.Http3 = .{ .path = "/none" };
    try c.fetch(std.testing.allocator, &h.loop, h.port, &h);
    try expectEqualStrings("404", &c.status);
}
