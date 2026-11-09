//! Blocking scopes' handlers, off the loop on an `Io`: canceled, past a
//! deadline, on the loop's state, held to a limit, wrapped in middleware,
//! streaming an answer or reading a body as it comes.

const std = @import("std");
const quic = @import("quic");
const http = @import("../http.zig");
const sys = quic.sys;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;
const support = @import("support.zig");
const fetch = support.fetch;
const fetchAfter = support.fetchAfter;
const fetchInto = support.fetchInto;
const bodyOf = support.bodyOf;
const hello = support.hello;
const Visitor = support.Visitor;
const nameVisitor = support.nameVisitor;

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

test "destroy cancels a blocking handler still running, its client still waiting, then stops" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: Db = .{ .loop = std.Thread.getCurrentId() };
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try (try router.scope("").blocking(io, .{})).get("/slow", &db, Db.slow);
    const server = try http.Server.create(gpa, &router, .{});

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    const client = try std.Thread.spawn(.{}, fetchInto, .{ server.port(), "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n", &buf, &len });
    defer client.join();
    try db.started.wait(io);
    server.destroy();
    try std.testing.expect(db.canceled.load(.acquire));
}
