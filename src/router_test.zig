const std = @import("std");
const http = @import("http.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Shop = struct {
    stock: u32 = 3,
    calls: u32 = 0,

    fn item(shop: *Shop, ctx: *http.Context(.{ .params = struct { id: u32 } })) !struct { id: u32, stock: u32 } {
        shop.calls += 1;
        if (ctx.params.id == 0) return error.NotFound;
        return .{ .id = ctx.params.id, .stock = shop.stock };
    }

    fn newItem(_: *Shop, ctx: *http.Context(.{})) !void {
        try ctx.text(200, "the form");
    }

    fn named(_: *Shop, ctx: *http.Context(.{ .params = struct { name: []const u8 } })) ![]const u8 {
        return ctx.params.name;
    }

    fn review(_: *Shop, ctx: *http.Context(.{ .params = struct { id: u32, n: u8 } })) !u32 {
        return @as(u32, ctx.params.id) * 100 + ctx.params.n;
    }

    const Order = struct { item: u32, count: u32 = 1 };

    fn order(shop: *Shop, ctx: *http.Context(.{ .body = Order, .query = struct { dry: bool = false } })) !struct { left: u32 } {
        if (ctx.body.count > shop.stock) return error.Conflict;
        if (!ctx.query.dry) shop.stock -= ctx.body.count;
        try ctx.setHeader("X-Order", "ok");
        return .{ .left = shop.stock };
    }

    fn forget(_: *Shop, _: *http.Context(.{})) !void {}

    fn closed(_: *Shop, _: *http.Context(.{})) !void {
        return error.ServiceUnavailable;
    }

    fn early(_: *Shop, ctx: *http.Context(.{})) !u32 {
        try ctx.text(202, "accepted");
        return error.Unexpected; // answered already: the 202 stands
    }
};

fn ping(ctx: *http.Context(.{})) !void {
    try ctx.text(200, "pong");
}

fn shopRouter(shop: *Shop) !http.Router {
    var r: http.Router = .init(std.testing.allocator);
    errdefer r.deinit();
    try r.get("/items/:id", shop, Shop.item);
    try r.get("/items/new", shop, Shop.newItem);
    try r.get("/items/:name/x", shop, Shop.named);
    try r.get("/items/:id/reviews/:n", shop, Shop.review);
    try r.post("/orders", shop, Shop.order);
    try r.on(.DELETE, "/orders", shop, Shop.forget);
    try r.get("/closed", shop, Shop.closed);
    try r.get("/early", shop, Shop.early);
    try r.get("/ping", {}, ping);
    return r;
}

test "a path finds its route, static segments before params" {
    var shop: Shop = .{};
    var r = try shopRouter(&shop);
    defer r.deinit();
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    const a = try c.get("/items/7");
    try expectEqual(200, a.status.?);
    try expectEqualStrings("application/json", a.header("content-type").?);
    try expectEqualStrings("{\"id\":7,\"stock\":3}", a.body);
    try expectEqualStrings("the form", (try c.get("/items/new")).body);
    // `new` leads nowhere with `/x`: the param's way takes it.
    try expectEqualStrings("\"new\"", (try c.get("/items/new/x")).body);
    try expectEqualStrings("\"a b\"", (try c.get("/items/a%20b/x")).body);
    try expectEqualStrings("702", (try c.get("/items/7/reviews/2?sort=new")).body);
    try expectEqualStrings("pong", (try c.get("/ping/")).body);
    try expectEqual(null, (try c.get("/items")).status);
    try expectEqual(null, (try c.get("/nowhere")).status);
}

test "a param that doesn't parse, or a handler's error, answers with its status" {
    var shop: Shop = .{};
    var r = try shopRouter(&shop);
    defer r.deinit();
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    try expectEqual(404, (try c.get("/items/seven")).status.?);
    try expectEqual(404, (try c.get("/items/7/reviews/300")).status.?);
    try expectEqual(404, (try c.get("/items/0")).status.?);
    try expectEqual(1, shop.calls); // a param that doesn't parse never reaches the handler
    const closed = try c.get("/closed");
    try expectEqual(503, closed.status.?);
    try expectEqualStrings("Service Unavailable\n", closed.body);
    try expectEqual(500, http.statusOf(error.Unexpected)); // logged, which a test can't take
    const early = try c.get("/early");
    try expectEqual(202, early.status.?);
    try expectEqualStrings("accepted", early.body);
}

test "a body and query decode into the context; a bad one is 400" {
    var shop: Shop = .{};
    var r = try shopRouter(&shop);
    defer r.deinit();
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    const dry = try c.request(.POST, "/orders?dry=true", .{ .body = "{\"item\":1,\"count\":2,\"note\":\"x\"}" });
    try expectEqualStrings("{\"left\":3}", dry.body);
    try expectEqualStrings("ok", dry.header("x-order").?);
    try expectEqualStrings("{\"left\":1}", (try c.post("/orders", "{\"item\":1,\"count\":2}")).body);
    try expectEqual(409, (try c.post("/orders", "{\"item\":1,\"count\":2}")).status.?);
    try expectEqual(400, (try c.post("/orders", "{\"count\":1}")).status.?);
    try expectEqual(400, (try c.post("/orders", "not json")).status.?);
    try expectEqual(400, (try c.request(.POST, "/orders?dry=maybe", .{ .body = "{\"item\":1}" })).status.?);
}

test "a known path with another method is 405 with Allow; HEAD takes GET's route; no answer is 204" {
    var shop: Shop = .{};
    var r = try shopRouter(&shop);
    defer r.deinit();
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    const put = try c.request(.PUT, "/orders", .{});
    try expectEqual(405, put.status.?);
    try expectEqualStrings("POST, DELETE", put.header("allow").?);
    try expectEqualStrings("GET, HEAD", (try c.request(.POST, "/ping", .{})).header("allow").?);
    const head = try c.request(.HEAD, "/ping", .{});
    try expectEqual(200, head.status.?);
    try expectEqualStrings("", head.body);
    try expectEqual(204, (try c.request(.DELETE, "/orders", .{})).status.?);
}

test "a scope puts routes under a prefix known at run time; addAll copies, refusing a taken route" {
    var shop: Shop = .{};
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    var prefix_buf: [16]u8 = undefined;
    const api = r.scope(try std.fmt.bufPrint(&prefix_buf, "/api/v{d}", .{2}));
    try api.get("/items/:id", &shop, Shop.item);
    try api.post("/orders", &shop, Shop.order);
    try r.scope("/shop").get("/", {}, ping);
    try std.testing.expectError(error.DuplicateRoute, r.scope("/shop").get("/", {}, ping));

    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    try expectEqualStrings("{\"id\":9,\"stock\":3}", (try c.get("/api/v2/items/9")).body);
    try expectEqual(null, (try c.get("/items/9")).status);
    try expectEqualStrings("pong", (try c.get("/shop")).body);

    var copy: http.Router = .init(std.testing.allocator);
    defer copy.deinit();
    try copy.addAll(&r);
    var c2: http.testing.Client = .init(std.testing.allocator, &copy);
    defer c2.deinit();
    try expectEqual(200, (try c2.get("/api/v2/items/9")).status.?);
    try std.testing.expectError(error.DuplicateRoute, copy.addAll(&r));
}

const Score = struct { player: []const u8, points: u32 };
const ScoreApi = struct {
    pub const top = http.endpoint.get("/scores/:game", .{ .params = struct { game: []const u8 }, .result = []const Score });
    pub const submit = http.endpoint.post("/scores", .{ .body = Score, .result = struct { best: u32 } });
};

const Board = struct {
    best: u32 = 0,

    fn top(board: *Board, ctx: *http.ContextOf(ScoreApi.top)) ![]const Score {
        return try ctx.arena.dupe(Score, &.{.{ .player = ctx.params.game, .points = board.best }});
    }

    fn submit(board: *Board, ctx: *http.ContextOf(ScoreApi.submit)) !ScoreApi.submit.result {
        board.best = @max(board.best, ctx.body.points);
        return .{ .best = board.best };
    }
};

test "a handler bound to an endpoint serves its contract" {
    var board: Board = .{};
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.bind(ScoreApi.top, &board, Board.top);
    try r.bind(ScoreApi.submit, &board, Board.submit);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    try expectEqualStrings("{\"best\":12}", (try c.post("/scores", "{\"player\":\"ann\",\"points\":12}")).body);
    try expectEqualStrings("[{\"player\":\"tanks\",\"points\":12}]", (try c.get("/scores/tanks")).body);
}
