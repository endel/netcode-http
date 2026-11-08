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
    try expectEqualStrings("{\"title\":\"Service Unavailable\",\"status\":503}", closed.body);
    try expectEqualStrings("application/problem+json", closed.header("content-type").?);
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

fn file(ctx: *http.Context(.{ .params = struct { path: []const u8 } })) ![]const u8 {
    return ctx.params.path;
}

fn game(ctx: *http.Context(.{ .params = struct { kind: []const u8, rest: []const u8 } })) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ ctx.params.kind, ctx.params.rest });
}

test "a catch-all takes the rest of the path as it came, after static segments and params" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.get("/files/*path", {}, file);
    try r.get("/files/readme", {}, ping);
    try r.get("/api/:kind/*rest", {}, game);
    try r.on(.DELETE, "/api/:kind/*rest", {}, game);
    try r.get("/api/tank/info", {}, ping);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    try expectEqualStrings("\"a/b%20c/\"", (try c.get("/files/a/b%20c/")).body);
    try expectEqualStrings("\"\"", (try c.get("/files")).body);
    try expectEqualStrings("pong", (try c.get("/files/readme")).body);
    try expectEqualStrings("\"readme/x\"", (try c.get("/files/readme/x")).body);
    try expectEqualStrings("\"tank:scores/7\"", (try c.get("/api/tank/scores/7?x=1")).body);
    try expectEqualStrings("pong", (try c.get("/api/tank/info")).body);
    try expectEqualStrings("\"tank:info/more\"", (try c.get("/api/tank/info/more")).body);
    const put = try c.request(.PUT, "/api/tank/a", .{});
    try expectEqual(405, put.status.?);
    try expectEqualStrings("GET, HEAD, DELETE", put.header("allow").?);
    try expectEqual(null, (try c.get("/nowhere/a")).status);
}

test "addAll's routes outlive the router they came from" {
    var copy: http.Router = .init(std.testing.allocator);
    defer copy.deinit();
    {
        var r: http.Router = .init(std.testing.allocator);
        defer r.deinit();
        try r.get("/ping", {}, ping);
        try r.get("/api/:kind/*rest", {}, game);
        try copy.scope("/v1").addAll(&r);
    }
    var c: http.testing.Client = .init(std.testing.allocator, &copy);
    defer c.deinit();
    try expectEqualStrings("pong", (try c.get("/v1/ping")).body);
    try expectEqualStrings("\"tank:a/b%20c\"", (try c.get("/v1/api/tank/a/b%20c?x=1")).body);
}

test "a request's state is kept for the next one" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.get("/ping", {}, ping);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    for (0..3) |_| try expectEqualStrings("pong", (try c.get("/ping")).body);
    try expectEqual(1, c.pendings.len);
}

const Score = struct { player: []const u8, points: u32 };
const ScoreApi = struct {
    pub const top = http.endpoint.get("/scores/:game", .{ .params = struct { game: []const u8 }, .result = []const Score, .errors = &.{.{ .status = 404, .why = "no such game" }} });
    pub const submit = http.endpoint.post("/scores", .{ .body = Score, .result = struct { best: u32 } });
};

const Board = struct {
    best: u32 = 0,

    fn top(board: *Board, ctx: *http.ContextOf(ScoreApi.top)) ![]const Score {
        if (std.mem.eql(u8, ctx.params.game, "chess")) return error.NotFound;
        return try ctx.arena.dupe(Score, &.{.{ .player = ctx.params.game, .points = board.best }});
    }

    fn submit(board: *Board, ctx: *http.ContextOf(ScoreApi.submit)) !ScoreApi.submit.result {
        board.best = @max(board.best, ctx.body.points);
        return .{ .best = board.best };
    }
};

test "a handler bound to an endpoint serves its contract, its errors' why their detail" {
    var board: Board = .{};
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.bind(ScoreApi.top, &board, Board.top);
    try r.bind(ScoreApi.submit, &board, Board.submit);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    try expectEqualStrings("{\"best\":12}", (try c.post("/scores", "{\"player\":\"ann\",\"points\":12}")).body);
    try expectEqualStrings("[{\"player\":\"tanks\",\"points\":12}]", (try c.get("/scores/tanks")).body);
    try expectEqualStrings("{\"title\":\"Not Found\",\"status\":404,\"detail\":\"no such game\"}", (try c.get("/scores/chess")).body);
}

fn brokenAtTheDoor(_: ?*const anyopaque, _: *http.Call) !void {
    return error.SeatBroken;
}

const Seats = struct {
    fn take(_: *Seats, ctx: *http.Context(.{ .params = struct { n: u8 } })) !u8 {
        if (ctx.params.n == 3) return ctx.problem(409, "seat {d} is \"taken\"", .{ctx.params.n});
        if (ctx.params.n == 4) return error.SeatBroken;
        return ctx.params.n;
    }
};

test "an error answers as a problem: with the handler's detail, or as its scope says" {
    var seats: Seats = .{};
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    const seated = try r.scope("").errors(&.{.{ .err = error.SeatBroken, .status = 422, .detail = "that seat is broken" }});
    try seated.get("/seats/:n", &seats, Seats.take);
    try (try seated.with(&.{.{ .before = brokenAtTheDoor }})).get("/door", {}, ping);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    const taken = try c.get("/seats/3");
    try expectEqual(409, taken.status.?);
    try expectEqualStrings("application/problem+json", taken.header("content-type").?);
    try expectEqualStrings("{\"title\":\"Conflict\",\"status\":409,\"detail\":\"seat 3 is \\\"taken\\\"\"}", taken.body);
    try expectEqualStrings("{\"title\":\"Unprocessable Content\",\"status\":422,\"detail\":\"that seat is broken\"}", (try c.get("/seats/4")).body);
    try expectEqual(422, (try c.get("/door")).status.?);
}

const Signup = struct {
    name: []const u8,
    age: u8,
    pub const rules = .{ .name = .{ .min_len = 1, .max_len = 16 }, .age = .{ .min = 13 } };
};

fn signup(_: *http.Context(.{ .body = Signup, .query = struct { page: u8 = 1, sort: enum { name, age } = .name } })) !void {}

fn signupByForm(_: *http.Context(.{ .body = Signup, .form = true })) !void {}

/// The detail of the problem `target` answers with, `status`, given `body`.
fn refusal(c: *http.testing.Client, target: []const u8, body: []const u8) ![]const u8 {
    return refusalAs(c, 400, target, &.{}, body);
}

fn refusalAs(c: *http.testing.Client, status: u16, target: []const u8, headers: []const http.Header, body: []const u8) ![]const u8 {
    const answer = try c.request(.POST, target, .{ .headers = headers, .body = body });
    try expectEqual(status, answer.status.?);
    const Problem = struct { detail: []const u8 };
    return (try std.json.parseFromSliceLeaky(Problem, c.arena.allocator(), answer.body, .{ .ignore_unknown_fields = true })).detail;
}

test "a refused query or body says why: the field, and what it broke" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.post("/signup", {}, signup);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    const ann = "{\"name\":\"ann\",\"age\":20}";

    try expectEqual(204, (try c.request(.POST, "/signup?sort=age", .{ .body = ann })).status.?);
    try expectEqualStrings("query.page: not an integer", try refusal(&c, "/signup?page=x", ann));
    try expectEqualStrings("query.sort: not one of name, age", try refusal(&c, "/signup?sort=size", ann));
    try expectEqualStrings("body, line 1 column 2: not JSON", try refusal(&c, "/signup", "not json"));
    try expectEqualStrings("body, line 1 column 11: a required field is missing", try refusal(&c, "/signup", "{\"age\":20}"));
    try expectEqualStrings("body.name: at least 1 byte long", try refusal(&c, "/signup", "{\"name\":\"\",\"age\":20}"));
    try expectEqualStrings("body.age: at least 13", try refusal(&c, "/signup", "{\"name\":\"ann\",\"age\":9}"));
}

fn missing(_: *http.Context(.{})) !void {
    return error.NotFound;
}

fn item(ctx: *http.Context(.{ .params = struct { id: u32 } })) !u32 {
    return ctx.params.id;
}

test "put, patch and delete; a fallback for paths under a prefix no route has; a 405 its scope words" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    const items = try r.scope("/items").errors(&.{.{ .err = error.MethodNotAllowed, .status = 405, .detail = "an item is put, patched or deleted" }});
    try items.put("/:id", {}, item);
    try items.patch("/:id", {}, item);
    try items.delete("/:id", {}, item);
    const api = r.scope("/api");
    try api.fallback({}, missing);
    try std.testing.expectError(error.DuplicateRoute, api.fallback({}, missing));
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    try expectEqualStrings("7", (try c.request(.DELETE, "/items/7", .{})).body);
    try expectEqualStrings("8", (try c.request(.PATCH, "/items/8", .{})).body);
    const nowhere = try c.request(.POST, "/api/nowhere/at/all", .{});
    try expectEqual(404, nowhere.status.?);
    try expectEqualStrings("application/problem+json", nowhere.header("content-type").?);
    try expectEqual(404, (try c.get("/api")).status.?);
    // Outside it, the transport's own: static files, its 404.
    try expectEqual(null, (try c.get("/elsewhere")).status);
    const wrong = try c.get("/items/1");
    try expectEqual(405, wrong.status.?);
    try expectEqualStrings("PUT, PATCH, DELETE", wrong.header("allow").?);
    try expectEqualStrings("{\"title\":\"Method Not Allowed\",\"status\":405,\"detail\":\"an item is put, patched or deleted\"}", wrong.body);
}

fn session(ctx: *http.Context(.{})) ![]const u8 {
    try ctx.setCookie("seen", "yes", .{ .max_age = 60 });
    return ctx.request.cookie("sid") orelse "none";
}

test "cookies: read from the request, set on the answer; one a cookie can't hold is refused" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.get("/me", {}, session);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();

    const me = try c.request(.GET, "/me", .{ .headers = &.{
        .{ .name = "Cookie", .value = "a=1; b=2" },
        .{ .name = "Cookie", .value = "sid=\"abc\"" },
    } });
    try expectEqualStrings("\"abc\"", me.body);
    try expectEqualStrings("seen=yes; Path=/; Max-Age=60; Secure; HttpOnly; SameSite=Lax", me.header("set-cookie").?);
    try expectEqualStrings("\"none\"", (try c.get("/me")).body);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var res: http.Response = .init(arena.allocator());
    try std.testing.expectError(error.InvalidCookie, res.setCookie("a b", "x", .{}));
    try std.testing.expectError(error.InvalidCookie, res.setCookie("a", "x;y", .{}));
    try std.testing.expectError(error.InvalidCookie, res.setCookie("a", "x", .{ .secure = false, .same_site = .none }));
    try res.clearCookie("sid", .{ .path = "/app", .same_site = .strict });
    try expectEqualStrings("sid=; Path=/app; Max-Age=0; Secure; HttpOnly; SameSite=Strict", res.headers.items[0].value);
}

test "a body by its Content-Type: JSON, a form where the spec takes one, 415 otherwise" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.post("/signup", {}, signup);
    try r.post("/signup/form", {}, signupByForm);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    const form: []const http.Header = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded; charset=UTF-8" }};
    const json: []const http.Header = &.{.{ .name = "content-type", .value = "Application/JSON" }};
    const text: []const http.Header = &.{.{ .name = "Content-Type", .value = "text/plain" }};
    const ann = "{\"name\":\"ann\",\"age\":20}";

    try expectEqual(204, (try c.request(.POST, "/signup/form", .{ .headers = form, .body = "name=ann+lee&age=20" })).status.?);
    try expectEqual(204, (try c.request(.POST, "/signup/form", .{ .headers = json, .body = ann })).status.?);
    try expectEqualStrings("form.age: at least 13", try refusalAs(&c, 400, "/signup/form", form, "name=ann&age=9"));
    try expectEqualStrings("body: JSON, by its Content-Type", try refusalAs(&c, 415, "/signup", form, "name=ann&age=20"));
    // A cross-site form posts text/plain without asking first: refused, though it parses.
    try expectEqualStrings("body: JSON, by its Content-Type", try refusalAs(&c, 415, "/signup", text, ann));
}

fn upload(ctx: *http.Context(.{ .body = http.endpoint.Multipart })) !struct { title: []const u8, file: []const u8, size: usize } {
    const map = ctx.body.get("map") orelse return error.BadRequest;
    return .{ .title = (ctx.body.get("title") orelse return error.BadRequest).data, .file = map.filename orelse "", .size = map.data.len };
}

test "a multipart body's parts, by its Content-Type; another is 415, a broken one 400 with why" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.post("/maps", {}, upload);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    const multipart: []const http.Header = &.{.{ .name = "Content-Type", .value = "multipart/form-data; boundary=b0und" }};
    const body = "--b0und\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nde_dust\r\n" ++
        "--b0und\r\nContent-Disposition: form-data; name=\"map\"; filename=\"dust.bin\"\r\n\r\n1234\r\n--b0und--\r\n";

    try expectEqualStrings("{\"title\":\"de_dust\",\"file\":\"dust.bin\",\"size\":4}", (try c.request(.POST, "/maps", .{ .headers = multipart, .body = body })).body);
    try expectEqualStrings("body: multipart/form-data, by its Content-Type", try refusalAs(&c, 415, "/maps", &.{}, body));
    try expectEqualStrings("body: a part doesn't end", try refusalAs(&c, 400, "/maps", multipart, "--b0und\r\nContent-Disposition: form-data; name=a\r\n\r\nx"));
}

const Avatar = struct {
    name: []const u8,
    picture: http.endpoint.File,
    pub const rules = .{ .name = .{ .min_len = 1 } };
};

fn avatar(ctx: *http.Context(.{ .body = Avatar, .form = true })) !struct { name: []const u8, file: []const u8, bytes: usize } {
    return .{ .name = ctx.body.name, .file = ctx.body.picture.filename orelse "", .bytes = ctx.body.picture.data.len };
}

test "a .form body from a multipart form: its fields, a File whole, rules and all; urlencoded can't carry the file" {
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.put("/avatar", {}, avatar);
    var c: http.testing.Client = .init(std.testing.allocator, &r);
    defer c.deinit();
    const multipart: []const http.Header = &.{.{ .name = "Content-Type", .value = "multipart/form-data; boundary=x" }};
    const form: []const http.Header = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }};
    const body = "--x\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nann\r\n" ++
        "--x\r\nContent-Disposition: form-data; name=\"picture\"; filename=\"ann.png\"\r\nContent-Type: image/png\r\n\r\nPNG!\r\n--x--\r\n";

    const ok = try c.request(.PUT, "/avatar", .{ .headers = multipart, .body = body });
    try expectEqualStrings("{\"name\":\"ann\",\"file\":\"ann.png\",\"bytes\":4}", ok.body);
    try expectEqualStrings("form.name: at least 1 byte long", try refusalAsPut(&c, "/avatar", multipart, "--x\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\r\n" ++
        "--x\r\nContent-Disposition: form-data; name=\"picture\"\r\n\r\nPNG!\r\n--x--\r\n"));
    try expectEqualStrings("form.picture is required", try refusalAsPut(&c, "/avatar", form, "name=ann&picture=x"));
}

fn refusalAsPut(c: *http.testing.Client, target: []const u8, headers: []const http.Header, body: []const u8) ![]const u8 {
    const answer = try c.request(.PUT, target, .{ .headers = headers, .body = body });
    try expectEqual(400, answer.status.?);
    const Problem = struct { detail: []const u8 };
    return (try std.json.parseFromSliceLeaky(Problem, c.arena.allocator(), answer.body, .{ .ignore_unknown_fields = true })).detail;
}

const Echo = struct {
    pub fn open(_: *http.Context(.{})) !void {}
    pub fn message(ws: *http.WebSocket, data: []const u8, _: http.WebSocket.Kind) void {
        ws.send(data) catch {};
    }
};

test "a WebSocket route is found for an upgrade only, and comes along with addAll" {
    var inner: http.Router = .init(std.testing.allocator);
    defer inner.deinit();
    try inner.ws("/echo", {}, Echo);
    try std.testing.expectError(error.DuplicateRoute, inner.ws("/echo", {}, Echo));
    var r: http.Router = .init(std.testing.allocator);
    defer r.deinit();
    try r.scope("/v1").addAll(&inner);

    const upgrade: http.Request = .{ .method = .GET, .target = "/v1/echo" };
    var found: http.Found = undefined;
    try std.testing.expect(r.findUpgrade(&upgrade, &found));
    try std.testing.expect(!r.find(&upgrade, &found)); // no method's route
}
