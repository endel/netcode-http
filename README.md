# netcode-http

HTTP routes for servers built on [quic-zig](https://github.com/endel/quic-zig):
a router you embed in a server that already runs an event loop, a game
server say, so its HTTP shares the port, the certificates and the loop.
[netcode](https://github.com/endel/netcode) serves its HTTP with it.

```zig
const http = @import("http");

const Game = struct {
    scores: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn score(game: *Game, ctx: *http.Context(.{ .params = struct { id: u64 } })) !u32 {
        return game.scores.get(ctx.params.id) orelse error.NotFound;
    }

    fn submit(game: *Game, ctx: *http.Context(.{ .body = struct { id: u64, score: u32 } })) !void {
        try game.scores.put(gpa, ctx.body.id, ctx.body.score);
        try ctx.text(201, "saved\n");
    }
};

var router: http.Router = .init(gpa);
defer router.deinit();
try router.get("/scores/:id", &game, Game.score);
try router.post("/scores", &game, Game.submit);
```

## Using it

Zig 0.17:

```sh
zig fetch --save=http git+https://github.com/endel/netcode-http
```

```zig
// build.zig
const http = b.dependency("http", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("http", http.module("http"));
// Code shared with clients takes the contracts alone: std only.
shared.addImport("endpoint", http.module("endpoint"));
```

A project that also depends on quic-zig must pin the same commit this
package does, or the build fails with "file exists in modules". To build
against local checkouts instead of the pins:
`zig build --fork=../quic-zig --fork=../http`.

## Handlers

`fn (app: *App, ctx: *http.Context(spec)) !Result`, or without `app`.

- `spec` says what the context decodes: `.params` (a field for each
  `:name` of the pattern, checked at compile time), `.query` (fields with
  defaults are optional) and `.body` (`[]const u8` as it came, any other
  type from JSON). A param that doesn't parse makes the route not found;
  a query or body that doesn't is 400, its detail saying which field and
  why: `query.limit: not an integer`, `body.name: at least 1 byte long`.
- Past its type, a struct holds its fields to its `rules`: `min` and
  `max` for numbers, `min_len` and `max_len` for slices, checked into
  nested structs and slices of them. Its `check` says what's wrong across
  fields:

```zig
const Signup = struct {
    name: []const u8,
    age: u8,
    pub const rules = .{ .name = .{ .min_len = 1, .max_len = 16 }, .age = .{ .min = 13 } };
    pub fn check(s: Signup) ?[]const u8 {
        return if (std.mem.eql(u8, s.name, "admin")) "that name is taken" else null;
    }
};
```

- A `Result` other than `void` is sent as JSON with 200, but an
  `http.Reply`, which is sent as it is: status, type, headers and body.
  With `void` the handler answers through `ctx` (`text`, `json`, `send`,
  `setHeader`); one that doesn't gets 204.
- An error answers with its status: `error.NotFound` 404, `error.Forbidden`
  403, `error.BadRequest` 400… (`http.statusOf`); any other is 500, logged.
  The answer is an RFC 9457 problem, `application/problem+json`:
  `{"title":"Not Found","status":404}`. `return ctx.problem(409, "seat {d}
  taken", .{n})` adds a `detail` the handler words, and a scope's `errors`
  answers the app's own: `scope.errors(&.{.{ .err = error.SeatTaken,
  .status = 409, .detail = "seat taken" }})`, whether the handler or any
  middleware returns it. The first answer stands: one sent before the
  error isn't replaced.
- Handlers run on the event loop's thread: they must not block, unless
  their scope is `blocking` (below).

## Routes

- `router.on(.PUT, pattern, app, handler)`, or `get`, `post`, `put`,
  `patch` and `delete` for short. A method and path added twice is
  `error.DuplicateRoute`.
- `router.scope(prefix)` puts routes under a prefix known at run time,
  from a config file say: `router.scope(opts.api).get("/:id", ...)`.
- `router.addAll(&other)` adds another router's routes.
- A last `*name` takes the rest of the path, slashes and all, as it came:
  `/files/*path` has `/files/a/b%20c` with `path` `a/b%20c`, and `/files`
  with it empty. Static segments win over params (`/items/new` before
  `/items/:id`), params over a catch-all, and a path that leads nowhere
  one way tries the next. A known path with another
  method is 405 with `Allow`, `error.MethodNotAllowed` on its way, so a
  scope's `errors` may word it; HEAD takes GET's route.
- What no route has goes back to the server: static files, a 404. A
  scope's `fallback(app, handler)` takes what its prefix's routes don't,
  any method: `router.scope("/api").fallback({}, notFound)` gives an API
  its own 404 (`return error.NotFound`) and leaves `/` to static files.
- A JSON body comes as `application/json` (or none): a cross-site form
  can't post one unasked. Another `Content-Type` is 415, unless the spec
  takes `.form = true` and it's a form: `application/x-www-form-urlencoded`
  read as a query is, or `multipart/form-data`, whose `http.endpoint.File`
  fields take a file part whole (`filename`, `content_type`, `data`).
  `.body = http.endpoint.Multipart` gives the raw parts instead.
- `.body = http.endpoint.BodyStream` reads the body as it arrives:
  `ctx.body.read(&buf)` in a blocking handler, started at the request's
  head, each piece freed once read. It's bounded by `max_body`, and the
  upload counts against the scope's deadline and `max_running`.
- `ctx.request.cookie(name)` reads a cookie; `ctx.setCookie(name, value,
  .{ .max_age = 3600 })` sets one, `Secure`, `HttpOnly` and `SameSite=Lax`
  unless it says otherwise, and `ctx.response.clearCookie` drops it.

## Endpoints, declared once

An endpoint's contract (method, path, what crosses it) can live in code a
server and its clients share. `http.endpoint` imports nothing but std, so
shared code built for the browser or a native client holds it too.

```zig
// shared.zig
pub const Api = struct {
    pub const top = http.endpoint.get("/scores/:game", .{
        .params = struct { game: []const u8 },
        .query = struct { limit: u8 = 10 },
        .result = []const Score,
        // What it answers with beside the result, as problems.
        .errors = &.{.{ .status = 404, .why = "no such game" }},
    });
};

// server.zig: checked against the contract at compile time.
fn top(game: *Game, ctx: *http.ContextOf(Api.top)) !Api.top.result { ... }
try router.bind(Api.top, &game, top);
```

`http.endpoint.typescript.write(Api, writer, "game")` writes a client for
them: `gameApi(base)` with a typed method per endpoint, its types as
`gameApi.Score`, and `HttpError` for an answer other than 2xx, with the
problem's `title` and `detail` when there is one. netcode's
bindings write it beside a module's glue when its bindings file has
`pub const http = Api;`.

```ts
const api = gameApi("https://game.example");
const best = await api.top({ game: "tanks" }, { limit: 3 });
```

A contract's `errors`, and the 400 and 404 its spec implies
(`endpoint.failures`), become the method's `@throws`. A Zig client reads
an error's problem with `answer.status.problem(arena)`.

`http.endpoint.openapi.write(Api, writer, .{ .title = "game", .version =
"1.0.0" })` writes an OpenAPI 3.1 document of the same contracts: an
operation per endpoint, a schema per named struct with its `rules` as
`minLength`, `maximum` and the like, and each declared error as an
`application/problem+json` answer. A type with its own `jsonStringify`
says what it looks like with `pub const json_schema`, as it does for
TypeScript with `ts_type`.

## Middleware

A scope's `with` runs middleware around its routes:

- `before(ctx, call)` at the request's head, on the loop, ahead of its body.
- `around(ctx, next)` the handler, where it runs: in a blocking scope
  that's its task, so it may block too (`call.io`). `next.run()` runs the
  rest of the way.
- `after(ctx, call)` on every answer they send.

An answer sent, or an error returned (answered with its status), stops the
request where it is. Middleware leaves what it found for the handler, one
value per type:

```zig
fn session(ctx: ?*const anyopaque, next: http.Next) !void {
    const db: *const Db = @ptrCast(@alignCast(ctx.?));
    const call = next.call;
    const token = call.request.header("cookie") orelse return error.Unauthorized;
    try call.setLocal(User, try db.userFor(call.io, token)); // may block, off the loop
    return next.run();
}

fn profile(ctx: *http.Context(.{})) !User {
    return ctx.local(User).?.*;
}

const api = try (try router.scope("/api").blocking(io, .{})).with(&.{.{ .ctx = &db, .around = session }});
try api.get("/me", {}, profile);
```

The built-ins:

```zig
const auth: http.Bearer = .{ .token = opts.token };
const cors: http.Cors = .{ .origins = &.{"https://game.example"} };
const admin = try router.scope("/admin").with(&.{ auth.middleware(), cors.middleware(), http.access_log });
try admin.get("/stats", app, stats);
```

- `http.Bearer`: `Authorization: Bearer <token>`, or 401.
- `http.Cors`: listed origins read the answers, others get 403, and
  preflights are answered. A known path answers OPTIONS with `Allow`.
- `http.RateLimit`: a token bucket per client address, or 429.
- `http.access_log`: a line per answer, the client's address first.

Behind a proxy such as routez, list it in `trusted_proxies` (the `Host`'s,
or `http.Server`'s option): a request from it is the client its
`X-Forwarded-For` names, `Request.client`, which the rate limit and the
log use. Anyone else's `X-Forwarded-For` is ignored.

A scope's `limit(n)` takes bodies up to `n` whatever its routes' `Spec`
says, for a limit known at run time.

## Work that blocks

A handler runs on its event loop's thread. A scope's `blocking(io, ...)` runs
its handlers as tasks on a `std.Io` instead, off the loop, where they may
block: a database query, a file read. They do their I/O with `ctx.io`.

```zig
var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(64) });
defer threaded.deinit(); // after the router's

const api = try router.scope("/api").blocking(threaded.io(), .{ .deadline = .fromSeconds(10) });
try api.get("/users/:id", &app, user);

fn user(app: *App, ctx: *http.Context(.{ .params = struct { id: u64 } })) !User {
    return app.db.fetchUser(ctx.io, ctx.params.id);
}
```

- Each request in flight is a task until its handler returns. One the `Io`
  refuses is 503: with `std.Io.Threaded`, past its `concurrent_limit`.
- A handler is canceled when its client leaves, or when the scope's
  `deadline` passes, which answers 504. Its next `ctx.io` call fails with
  `error.Canceled`, which it returns. Code that never calls into `ctx.io`
  isn't interrupted: a 504 waits for it to return.
- Over HTTP/1.1, quic-zig reads a client closing its connection the way it
  reads one half-closing it, which still gets its answer. The handler there
  runs to its end; only the deadline cuts it short.
- A handler off the loop shares nothing with it: what the loop owns, a
  game's state say, it reaches through `ctx.onLoop(func, args)`, which runs
  `func` on the loop and waits for what it returns. `around` middleware runs
  with the handler; `before` and `after` stay on the loop.

```zig
fn submit(game: *Game, ctx: *http.Context(.{ .body = Score })) !void {
    try game.db.save(ctx.io, ctx.body); // blocks: off the loop
    _ = try ctx.onLoop(Game.rank, .{ game, ctx.body }); // the game's, on the loop
}
```

- On the loop, `ctx.io` is `std.Io.failing`: I/O fails there rather than
  stall the loop.
- The first blocking scope on an `Io` starts a thread that collects and
  cancels its tasks. `router.deinit()` stops it, so the `Io` outlives the
  router.

A scope's `max_running` runs fewer at once than the `Io` takes, one compile
at a time say: `max_waiting` more wait their turn (64 unless it says), the
rest are 503. A wait is canceled as running would be.

## Streams

A blocking handler can answer as it goes: `ctx.stream(status, type)` sends
the head and the headers set so far, then each `write` a piece, waiting
while the client is behind. It ends when the handler returns. An error
from it, or its deadline, cuts the stream off, so the client can tell.

```zig
fn export_(db: *Db, ctx: *http.Context(.{})) !void {
    const out = try ctx.stream(200, "application/x-ndjson");
    var rows = try db.rows(ctx.io);
    while (try rows.next()) |row| try out.writeAll(&.{ row.json, "\n" });
}
```

`stream.writer(&buf)` is a `std.Io.Writer` over it: `print`s and JSON
gather in `buf` and go in one trip when it fills or on `flush`, cheaper
than a trip per small write.

`ctx.events()` is a stream of server-sent events: `send(name, data)`, a
`data:` line per line of `data`, and `comment(text)` to keep a quiet one
alive through proxies. Each holds a blocking task for as long as it's
open, so it suits a few clients each; a game pushing to many wants a
stream written from the loop, which isn't here yet (TODO/streaming.md).

## A listener of its own

`http.Server` serves a router on an HTTP/1.1 listener of its own, with a
thread and loop of its own: a control or admin port beside a game's.

```zig
const admin = try http.Server.create(gpa, &router, .{ .address = "127.0.0.1", .port = 4480 });
defer admin.destroy();
```

## On quic-zig

The handler of a quic-zig server passes its request callbacks on to a
`http.quic.Host`, and the routes answer over HTTP/1.1 and HTTP/3 alike:

```zig
host: http.quic.Host, // .init(gpa, &router)

pub fn onHttpHead(self: *App, ex: *quic.event_loop.Exchange) void {
    self.host.onHttpHead(ex);
}
pub fn onHttpBody(self: *App, ex: *quic.event_loop.Exchange, data: []const u8) void {
    self.host.onHttpBody(ex, data);
}
pub fn onHttpEnd(self: *App, ex: *quic.event_loop.Exchange) void {
    self.host.onHttpEnd(ex);
}
pub fn onHttpGone(self: *App, ex: *quic.event_loop.Exchange) void {
    self.host.onHttpGone(ex);
}
pub fn onHttpWritable(self: *App, ex: *quic.event_loop.Exchange) void {
    self.host.onHttpWritable(ex); // a stream's client caught up
}
```

A request gets an arena of its own, freed once it's answered. Its body,
sized or chunked, is gathered before the handler runs, up to the route's
`.max_body` (64 KiB unless its `Spec` says more); past that it's 413.

## Tests

`http.testing.Client` calls a router's routes through the same `Host` a
server runs, limits included, without a socket. An answer made off the
loop, a blocking scope's, is waited for:

```zig
var client: http.testing.Client = .init(std.testing.allocator, &router);
defer client.deinit();
try std.testing.expectEqual(404, (try client.get("/scores/7")).status);
```

With `.leave = true` the client leaves once its request is sent, which
cancels a blocking handler still running.

`http.testing.Http3` sends one request over HTTP/3 to a server in the
test. `zig build test` runs the package's own, real quic-zig servers'
among them.

## Benchmarks

`bench/run.ts` serves the same routes from http and from `Bun.serve` and
loads both with [oha](https://github.com/hatoo/oha): HTTP/1.1, TLS, and
HTTP/3 given an oha built with it (`OHA_H3`). It reports the server's CPU
per request beside requests/s, which a busy machine skews.

```sh
zig build bench -Doptimize=ReleaseFast && bun bench/run.ts
```

## License

MIT
