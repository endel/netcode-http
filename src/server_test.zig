//! A router on a listener of its own, its middleware, and blocking scopes'
//! handlers, off the loop on an `Io`.

const std = @import("std");
const quic = @import("quic");
const http = @import("http.zig");
const sys = quic.sys;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

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
}

fn hello(ctx: *http.Context(.{})) !void {
    try ctx.text(200, "hello");
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

const Db = struct {
    loop: std.Thread.Id,
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    canceled: std.atomic.Value(bool) = .init(false),

    fn user(db: *Db, ctx: *http.Context(.{ .params = struct { id: u32 } })) !struct { id: u32, off_loop: bool } {
        try ctx.io.sleep(.fromMilliseconds(1), .awake);
        if (ctx.params.id == 0) return error.NotFound;
        return .{ .id = ctx.params.id, .off_loop = std.Thread.getCurrentId() != db.loop };
    }

    fn quiet(_: *Db, _: *http.Context(.{})) !void {}

    /// Holds its task until the test releases it, or it's canceled.
    fn slow(db: *Db, ctx: *http.Context(.{})) !void {
        db.started.set(ctx.io);
        db.release.wait(ctx.io) catch |err| {
            db.canceled.store(true, .release);
            return err;
        };
        try ctx.text(200, "done");
    }
};

/// On the loop, `ctx.io` fails rather than block it.
fn openOnLoop(ctx: *http.Context(.{})) !bool {
    const file = std.Io.Dir.cwd().openFile(ctx.io, "build.zig", .{}) catch return true;
    file.close(ctx.io);
    return false;
}

test "a blocking scope's handlers run off the loop, on its Io, and answer as any other" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const api = try router.scope("/api").blocking(threaded.io(), .{});
    try api.get("/users/:id", &db, Db.user);
    try api.post("/quiet", &db, Db.quiet);
    try router.get("/on-loop", {}, openOnLoop);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqualStrings("{\"id\":7,\"off_loop\":true}", (try c.get("/api/users/7")).body);
    try expectEqual(404, (try c.get("/api/users/0")).status.?);
    try expectEqual(204, (try c.post("/api/quiet", "")).status.?);
    try expectEqualStrings("true", (try c.get("/on-loop")).body);

    // Another router's blocking routes keep running on their Io once added.
    var more: http.Router = .init(gpa);
    try (try more.scope("").blocking(threaded.io(), .{})).get("/more/:id", &db, Db.user);
    try router.scope("/v2").addAll(&more);
    more.deinit();
    try expectEqualStrings("{\"id\":3,\"off_loop\":true}", (try c.get("/v2/more/3")).body);
}

fn fetchInto(port: u16, request: []const u8, buf: []u8, len: *usize) void {
    len.* = if (fetch(port, request, buf)) |got| got.len else |_| 0;
}

test "on a server: the loop answers while a blocking handler waits, and an Io with no room is 503" {
    var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(io, .{})).get("/slow", &db, Db.slow);
    try router.get("/hello", {}, hello);
    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();

    const request = "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var slow_buf: [1024]u8 = undefined;
    var slow_len: usize = 0;
    const first = try std.Thread.spawn(.{}, fetchInto, .{ server.port(), request, &slow_buf, &slow_len });
    try db.started.wait(io);

    var buf: [1024]u8 = undefined;
    try expectEqualStrings("hello", bodyOf(try fetch(server.port(), "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf)));
    try std.testing.expect(std.mem.startsWith(u8, try fetch(server.port(), request, &buf), "HTTP/1.1 503 "));

    db.release.set(io);
    first.join();
    try std.testing.expect(std.mem.startsWith(u8, slow_buf[0..slow_len], "HTTP/1.1 200 "));
    try expectEqualStrings("done", bodyOf(slow_buf[0..slow_len]));
}

test "a blocking handler past its scope's deadline is canceled, and the answer is 504" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const api = try router.scope("").blocking(io, .{ .deadline = .fromMilliseconds(50) });
    try api.get("/slow", &db, Db.slow);
    try router.get("/hello", {}, hello);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    try expectEqual(504, (try c.get("/slow")).status.?);
    try std.testing.expect(t0.untilNow(io).raw.toMilliseconds() < 2000);
    try std.testing.expect(db.canceled.load(.acquire));
    try expectEqualStrings("hello", (try c.get("/hello")).body);
}

test "a blocking handler whose client left is canceled" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(threaded.io(), .{})).get("/slow", &db, Db.slow);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqual(null, (try c.request(.GET, "/slow", .{ .leave = true })).status);
    try std.testing.expect(db.canceled.load(.acquire));
}

const Game = struct {
    score: u32 = 0,
    ran_on: std.Thread.Id = 0,

    /// The loop's own: only ever called there.
    fn bump(game: *Game, by: u32) !u32 {
        if (by == 0) return error.BadRequest;
        game.ran_on = std.Thread.getCurrentId();
        game.score += by;
        return game.score;
    }

    fn add(game: *Game, ctx: *http.Context(.{ .params = struct { by: u32 } })) !u32 {
        return ctx.onLoop(bump, .{ game, ctx.params.by });
    }
};

test "onLoop takes a blocking handler to the loop's state, and is a call on the loop" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var game: Game = .{};

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("/off").blocking(threaded.io(), .{})).get("/add/:by", &game, Game.add);
    try router.get("/on/add/:by", &game, Game.add);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqualStrings("5", (try c.get("/off/add/5")).body);
    try expectEqual(std.Thread.getCurrentId(), game.ran_on); // the client's loop
    try expectEqualStrings("7", (try c.get("/on/add/2")).body);
    try expectEqual(400, (try c.get("/off/add/0")).status.?);
    try expectEqual(7, game.score);
}

fn addOne(port: u16) void {
    var buf: [512]u8 = undefined;
    for (0..4) |_| _ = fetch(port, "GET /add/1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf) catch {};
}

test "on a server: blocking handlers in parallel update the loop's state one at a time" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var game: Game = .{};

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(threaded.io(), .{})).get("/add/:by", &game, Game.add);
    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();

    var clients: [16]std.Thread = undefined;
    for (&clients) |*t| t.* = try std.Thread.spawn(.{}, addOne, .{server.port()});
    for (clients) |t| t.join();
    try expectEqual(64, game.score);
}

const Visitor = struct { name: []const u8 };

/// At the head: who's visiting, left for the handler.
fn nameVisitor(_: ?*const anyopaque, call: *http.Call) !void {
    const name = call.request.header("x-visitor") orelse return error.Unauthorized;
    try call.setLocal(Visitor, .{ .name = name });
}

/// Around the handler: refuses one visitor, settles another's conflict.
fn guard(_: ?*const anyopaque, next: http.Next) !void {
    if (std.mem.eql(u8, next.call.local(Visitor).?.name, "mallory")) return error.Forbidden;
    next.run() catch |err| switch (err) {
        error.Conflict => return next.call.response.send(200, "text/plain", "settled"),
        else => return err,
    };
}

fn greet(ctx: *http.Context(.{})) ![]const u8 {
    const visitor = ctx.local(Visitor).?;
    if (std.mem.eql(u8, visitor.name, "clash")) return error.Conflict;
    return visitor.name;
}

test "middleware leaves locals for the handler, and around it refuses, answers or maps its errors" {
    var router: http.Router = .init(gpa);
    defer router.deinit();
    const scope = try router.scope("").with(&.{ .{ .before = nameVisitor }, .{ .around = guard } });
    try scope.get("/greet", {}, greet);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqualStrings("\"ann\"", (try greetAs(&c, "ann")).body);
    try expectEqual(401, (try c.get("/greet")).status.?);
    try expectEqual(403, (try greetAs(&c, "mallory")).status.?);
    try expectEqualStrings("settled", (try greetAs(&c, "clash")).body);
}

fn greetAs(c: *http.testing.Client, name: []const u8) !http.testing.Answer {
    return c.request(.GET, "/greet", .{ .headers = &.{.{ .name = "X-Visitor", .value = name }} });
}

/// Around a blocking handler: where does it run?
fn whereAround(ctx: ?*const anyopaque, next: http.Next) !void {
    const ran_on: *std.Thread.Id = @ptrCast(@alignCast(@constCast(ctx.?)));
    ran_on.* = std.Thread.getCurrentId();
    return next.run();
}

test "in a blocking scope, around middleware runs off the loop with the handler" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var ran_on: std.Thread.Id = std.Thread.getCurrentId();

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const scope = try (try router.scope("").blocking(threaded.io(), .{})).with(&.{.{ .ctx = &ran_on, .around = whereAround }});
    try scope.get("/hello", {}, hello);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqualStrings("hello", (try c.get("/hello")).body);
    try std.testing.expect(ran_on != std.Thread.getCurrentId());
}

test "on a server: a scope's max_running holds the rest back, max_waiting of them, then 503" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(io, .{ .max_running = 1, .max_waiting = 1 })).get("/slow", &db, Db.slow);
    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();

    const request = "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var bufs: [2][512]u8 = undefined;
    var lens: [2]usize = .{ 0, 0 };
    const running = try std.Thread.spawn(.{}, fetchInto, .{ server.port(), request, &bufs[0], &lens[0] });
    try db.started.wait(io);
    const waiting = try std.Thread.spawn(.{}, fetchInto, .{ server.port(), request, &bufs[1], &lens[1] });
    try io.sleep(.fromMilliseconds(200), .awake); // for it to reach the gate

    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try fetch(server.port(), request, &buf), "HTTP/1.1 503 "));
    db.release.set(io);
    running.join();
    waiting.join();
    for (bufs, lens) |b, n| try expectEqualStrings("done", bodyOf(b[0..n]));
}
