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
    return fetchAfter(port, request, buf, 0);
}

/// `fetch`, waiting `ms` before reading: a client that falls behind.
fn fetchAfter(port: u16, request: []const u8, buf: []u8, ms: u64) ![]const u8 {
    const fd = try dial(port);
    defer sys.close(fd);
    const out: sys.File = .{ .fd = fd };
    try out.writeAll(request);
    sys.sleepNs(ms * std.time.ns_per_ms);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

/// A TCP connection to the server on `port`.
fn dial(port: u16) !std.posix.fd_t {
    const fd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr = try quic.sockaddr.Address.parseIp4("127.0.0.1", port);
    if (std.c.connect(fd, &addr.any, addr.getOsSockLen()) != 0) return error.ConnectionRefused;
    return fd;
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

const Feed = struct {
    fn letters(_: *Feed, ctx: *http.Context(.{})) !void {
        const s = try ctx.stream(200, "text/plain");
        try s.write("a");
        try s.writeAll(&.{ "b", "c" });
    }

    /// Rows printed into a writer's buffer: one trip for all three.
    fn rows(_: *Feed, ctx: *http.Context(.{})) !void {
        var buf: [256]u8 = undefined;
        var out = (try ctx.stream(200, "application/x-ndjson")).writer(&buf);
        for (0..3) |i| try out.interface.print("{{\"n\":{d}}}\n", .{i});
        try out.interface.flush();
    }

    fn scores(_: *Feed, ctx: *http.Context(.{})) !void {
        const events = try ctx.events();
        try events.send(null, "hello\nworld");
        try events.send("score", "{\"ann\":3}");
        try events.comment("still here");
    }

    fn broken(_: *Feed, ctx: *http.Context(.{})) !void {
        const s = try ctx.stream(200, "text/plain");
        try s.write("half");
        return error.Unexpected;
    }

    fn slow(_: *Feed, ctx: *http.Context(.{})) !void {
        const s = try ctx.stream(200, "text/plain");
        try s.write("first");
        try ctx.io.sleep(.fromSeconds(10), .awake);
        try s.write("never");
    }

    /// 4 MiB in 64 KiB pieces: past what a socket takes at once.
    fn big(_: *Feed, ctx: *http.Context(.{})) !void {
        const s = try ctx.stream(200, "application/octet-stream");
        const piece: [64 * 1024]u8 = @splat('x');
        for (0..64) |_| try s.write(&piece);
    }
};

test "a blocking handler streams its answer: pieces, server-sent events, cut off by an error or its deadline" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var feed: Feed = .{};

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const api = try router.scope("").blocking(threaded.io(), .{ .deadline = .fromMilliseconds(100) });
    try api.get("/letters", &feed, Feed.letters);
    try api.get("/scores", &feed, Feed.scores);
    try api.get("/rows", &feed, Feed.rows);
    try api.get("/broken", &feed, Feed.broken);
    try api.get("/slow", &feed, Feed.slow);
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    const letters = try c.get("/letters");
    try expectEqualStrings("abc", letters.body);
    try expectEqualStrings("text/plain", letters.header("content-type").?);
    try expectEqual(false, letters.cut);

    try expectEqualStrings("{\"n\":0}\n{\"n\":1}\n{\"n\":2}\n", (try c.get("/rows")).body);

    const scores = try c.get("/scores");
    try expectEqualStrings("data: hello\ndata: world\n\nevent: score\ndata: {\"ann\":3}\n\n: still here\n\n", scores.body);
    try expectEqualStrings("text/event-stream", scores.header("content-type").?);
    try expectEqualStrings("no-cache", scores.header("cache-control").?);

    const broken = try c.get("/broken");
    try expectEqual(200, broken.status.?);
    try expectEqualStrings("half", broken.body);
    try expectEqual(true, broken.cut);

    const slow = try c.get("/slow");
    try expectEqualStrings("first", slow.body);
    try expectEqual(true, slow.cut);
}

test "on a server: a stream past what the socket takes waits for the client, and arrives whole" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var feed: Feed = .{};

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(threaded.io(), .{})).get("/big", &feed, Feed.big);
    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();

    const buf = try gpa.alloc(u8, 5 << 20);
    defer gpa.free(buf);
    const got = try fetchAfter(server.port(), "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", buf, 300);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n0\r\n\r\n"));
    try expectEqual(64 * 1024 * 64, std.mem.count(u8, bodyOf(got), "x"));
}

/// Reads its body three bytes at a time, as it comes.
fn sumStreamed(ctx: *http.Context(.{ .body = http.endpoint.BodyStream, .max_body = 1 << 20 })) !struct { bytes: usize, sum: u64 } {
    var buf: [3]u8 = undefined;
    var bytes: usize = 0;
    var sum: u64 = 0;
    while (true) {
        const n = try ctx.body.read(&buf);
        if (n == 0) break;
        bytes += n;
        for (buf[0..n]) |b| sum += b;
    }
    return .{ .bytes = bytes, .sum = sum };
}

test "a streamed body is read as it arrives, by a blocking handler; past max_body it's 413" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var router: http.Router = .init(gpa);
    defer router.deinit();
    const blocking = try router.scope("").blocking(threaded.io(), .{});
    try blocking.post("/sum", {}, sumStreamed);
    try blocking.post("/small", {}, sumSmall);
    try std.testing.expectError(error.BodyStreamNotBlocking, router.post("/loop", {}, sumStreamed));
    var c: http.testing.Client = .init(gpa, &router);
    defer c.deinit();

    try expectEqualStrings("{\"bytes\":10,\"sum\":525}", (try c.post("/sum", "0123456789")).body);
    try expectEqualStrings("{\"bytes\":0,\"sum\":0}", (try c.post("/sum", "")).body);

    const server = try http.Server.create(gpa, &router, .{});
    defer server.destroy();
    var buf: [4096]u8 = undefined;
    const body: [300 * 1024]u8 = @splat(1);
    const request = try std.fmt.allocPrint(gpa, "POST /sum HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, &body });
    defer gpa.free(request);
    try expectEqualStrings("{\"bytes\":307200,\"sum\":307200}", bodyOf(try fetch(server.port(), request, &buf)));
    // Chunked, no length to refuse at the head: refused once past it.
    const chunked = "POST /small HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n";
    try std.testing.expect(std.mem.startsWith(u8, try fetch(server.port(), chunked, &buf), "HTTP/1.1 413 "));
}

fn sumSmall(ctx: *http.Context(.{ .body = http.endpoint.BodyStream, .max_body = 8 })) !usize {
    var buf: [16]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try ctx.body.read(&buf);
        if (n == 0) return total;
        total += n;
    }
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
