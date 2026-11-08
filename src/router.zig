//! Routes: a method and a path pattern (`/rooms/:name`) bound to a handler.
//!
//! The pattern and the handler are known at compile time, which checks one
//! against the other; where the route lives (`Router.scope`) and the state it
//! serves can be chosen at run time. Built before serving, then only read:
//! threads may share one router.

const std = @import("std");
const context = @import("context.zig");
const endpoint = @import("endpoint");
const Middleware = @import("middleware.zig").Middleware;
const Reaper = @import("reaper.zig").Reaper;
const websocket = @import("websocket.zig");
const Method = context.Method;
const Request = context.Request;
const Response = context.Response;
const Call = context.Call;

const log = std.log.scoped(.http);

pub const max_params = endpoint.max_params;

/// `captures`: the `:params`' segments, in the pattern's order, still encoded.
const Thunk = *const fn (app: ?*anyopaque, call: *Call, captures: []const []const u8) anyerror!void;

const Route = struct {
    /// The type of the state the handler takes first; `void` when it takes
    /// only its context.
    App: type,
    Ctx: type,
    /// What a call returns, sent as JSON, or as it is for a `Reply`; `void`
    /// when it answers by itself.
    Result: type,
    thunk: Thunk,
    max_body: usize,
};

/// The body by its `Content-Type`: JSON, the spec's `form` if it takes one
/// (urlencoded or multipart), 415 for anything else. None is read as JSON.
fn decodeBody(comptime spec: endpoint.Spec, req: *const Request, arena: std.mem.Allocator, why: *[]const u8) !spec.body {
    const B = spec.body;
    if (comptime spec.form and !endpoint.formable(B)) @compileError("a .form body is a struct of a query's kind of fields and Files");
    if (comptime B == void or B == []const u8) return endpoint.decodeBody(B, req.body, arena, why);
    const t = req.header("content-type") orelse "";
    const media = endpoint.mediaType(t);
    if (comptime B == endpoint.Multipart) {
        if (std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return endpoint.Multipart.parse(arena, t, req.body, why);
        why.* = "body: multipart/form-data, by its Content-Type";
        return error.UnsupportedMediaType;
    }
    if (t.len == 0 or std.ascii.eqlIgnoreCase(media, "application/json") or std.ascii.endsWithIgnoreCase(media, "+json")) {
        return endpoint.decodeBody(B, req.body, arena, why);
    }
    if (spec.form) {
        if (std.ascii.eqlIgnoreCase(media, "application/x-www-form-urlencoded")) return endpoint.decodeForm(B, req.body, arena, why);
        if (std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return endpoint.decodeMultipart(B, t, req.body, arena, why);
    }
    why.* = if (spec.form) "body: JSON or a form, by its Content-Type" else "body: JSON, by its Content-Type";
    return error.UnsupportedMediaType;
}

/// A request its spec refuses: `why` as the problem's detail.
fn refuse(c: *Call, err: anyerror, why: []const u8) anyerror {
    if (why.len > 0) c.response.problem(context.statusOf(err), why);
    return err;
}

/// `handler` is `fn (app: *App, ctx: *http.Context(spec)) !Result`, or
/// without `app`. A `Result` other than `void` is sent as JSON with 200, a
/// `Reply` as it is; with `void` the handler answers through `ctx`, and one that doesn't
/// gets 204. An error answers with its status (`statusOf`) unless the
/// handler answered already.
fn route(comptime pattern: []const u8, comptime handler: anytype) Route {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    const ps = info.param_types;
    if (ps.len == 0 or ps.len > 2) @compileError(pattern ++ ": a handler takes its context, after its app's state if it has one");
    const Ctx = @typeInfo(ps[ps.len - 1] orelse @compileError(pattern ++ ": the context can't be anytype")).pointer.child;
    if (!context.isContext(Ctx)) @compileError(pattern ++ ": a handler's last parameter is a *http.Context(...)");
    const App = if (ps.len == 2) ps[0].? else void;
    if (App != void and @typeInfo(App) != .pointer) @compileError(pattern ++ ": a handler's state is a pointer");
    const Returned = info.return_type.?;
    const Result = switch (@typeInfo(Returned)) {
        .error_union => |e| e.payload,
        else => Returned,
    };
    const names = comptime endpoint.paramNames(pattern);
    endpoint.checkParams(pattern, names, Ctx.web_spec.params);
    const rest = comptime endpoint.catchAll(pattern);

    const S = struct {
        fn run(app: ?*anyopaque, c: *Call, captures: []const []const u8) anyerror!void {
            const arena = c.response.arena;
            var why: []const u8 = "";
            var ctx: Ctx = .{
                .params = try endpoint.decodeParams(Ctx.web_spec.params, names, rest, captures, arena),
                .query = endpoint.decodeQuery(Ctx.web_spec.query, c.request.rawQuery(), arena, &why) catch |err| return refuse(c, err, why),
                .body = if (comptime Ctx.web_spec.body == endpoint.BodyStream) c.body.? else decodeBody(Ctx.web_spec, &c.request, arena, &why) catch |err| return refuse(c, err, why),
                .request = &c.request,
                .response = &c.response,
                .arena = arena,
                .io = c.io,
                .call = c,
            };
            const returned = if (App == void) handler(&ctx) else handler(@as(App, @ptrCast(@alignCast(app.?))), &ctx);
            const result = if (@typeInfo(Returned) == .error_union) try returned else returned;
            if (Result == context.Reply) try c.response.reply(result) else if (Result != void) try c.response.json(200, result);
        }
    };
    return .{ .App = App, .Ctx = Ctx, .Result = Result, .thunk = S.run, .max_body = Ctx.web_spec.max_body };
}

/// Where a request's path leads: a route that takes its method, or with
/// `target` null, a path that routes have with other methods.
pub const Found = struct {
    node: *const Router.Node,
    target: ?*const Router.Target,
    /// The `:params`' segments, still encoded: slices of the request's target.
    captures: [max_params][]const u8 = undefined,
    n: usize = 0,

    /// Points the captures into `to`, a copy of the target they were found in.
    pub fn rebase(self: *Found, from: []const u8, to: []const u8) void {
        for (self.captures[0..self.n]) |*c| c.* = to[c.ptr - from.ptr ..][0..c.len];
    }

    /// The route's, or for a method the path has no route for, its others'.
    pub fn middleware(self: *const Found) []const Middleware {
        if (self.target) |t| return t.middleware;
        for (self.node.targets.values) |t| if (t) |other| return other.middleware;
        return &.{};
    }

    /// Answers `req` into `res`: its route's handler, an error with its
    /// status; for a method the path takes no route for, OPTIONS gets 204
    /// and the rest 405, both with `Allow`.
    pub fn run(self: *const Found, c: *Call) void {
        self.call(c) catch |err| self.failWith(c, err);
    }

    /// `run`, leaving a handler's error to the caller (`failWith`).
    pub fn call(self: *const Found, c: *Call) anyerror!void {
        const target = self.target orelse return Router.allow(self.node, c.request.method, &c.response);
        const rest: Rest = .{ .target = target, .captures = self.captures[0..self.n], .middleware = target.middleware };
        return rest.run(c);
    }

    /// Its `before` middleware, until one answers: whether one did.
    pub fn before(self: *const Found, c: *Call) bool {
        for (self.middleware()) |m| if (m.before) |hook| {
            hook(m.ctx, c) catch |err| self.failWith(c, err);
            if (c.response.answered) return true;
        };
        return false;
    }

    /// The route's own answer for `err` (`Scope.errors`), or its status
    /// (`statusOf`), unless something answered already: that stands.
    pub fn failWith(self: *const Found, c: *Call, err: anyerror) void {
        const res = &c.response;
        if (res.answered) return;
        for (self.errors()) |e| if (e.err == err) return res.problem(e.status, e.detail);
        const status = context.statusOf(err);
        if (status == 500) log.err("{t} {s}: {t}", .{ c.request.method, c.request.path(), err });
        res.fail(status);
    }

    /// The route's, or for a method the path has no route for, its others'.
    pub fn errors(self: *const Found) []const ErrorAnswer {
        if (self.target) |t| return t.errors;
        for (self.node.targets.values) |t| if (t) |other| return other.errors;
        return &.{};
    }
};

/// How an app's own error answers (`Scope.errors`): as a problem with this
/// status and detail.
pub const ErrorAnswer = struct { err: anyerror, status: u16, detail: ?[]const u8 = null };

/// A blocking scope's `max_running` and `max_waiting`.
pub const Gate = struct {
    running: std.Io.Semaphore,
    /// Running and waiting, at most: past it, 503.
    room: u32,
    in: std.atomic.Value(u32) = .init(0),

    /// Any loop: false when there's no room.
    pub fn enter(g: *Gate) bool {
        if (g.in.fetchAdd(1, .monotonic) < g.room) return true;
        g.leave();
        return false;
    }

    pub fn leave(g: *Gate) void {
        _ = g.in.fetchSub(1, .monotonic);
    }
};

/// The way left to a handler: its `around` middleware, then it (`Next`).
const Rest = struct {
    target: *const Router.Target,
    captures: []const []const u8,
    middleware: []const Middleware,

    fn run(self: *const Rest, c: *Call) anyerror!void {
        for (self.middleware, 0..) |m, i| if (m.around) |around| {
            const more: Rest = .{ .target = self.target, .captures = self.captures, .middleware = self.middleware[i + 1 ..] };
            return around(m.ctx, .{ .call = c, .rest = &more, .run_rest = runErased });
        };
        return self.target.thunk(self.target.app, c, self.captures);
    }

    fn runErased(rest: *const anyopaque, c: *Call) anyerror!void {
        const self: *const Rest = @ptrCast(@alignCast(rest));
        return self.run(c);
    }
};

pub const Router = struct {
    /// Holds the tree, and the paths its segments point into.
    arena: std.heap.ArenaAllocator,
    root: Node = .{},
    /// What was added, in order, for `addAll`.
    entries: std.ArrayList(Entry) = .empty,
    /// One per `Io` that `blocking` scopes run on.
    reapers: std.ArrayList(*Reaper) = .empty,

    pub const Target = struct {
        thunk: Thunk,
        app: ?*anyopaque,
        max_body: usize,
        middleware: []const Middleware = &.{},
        /// Its handler runs as a task on this one's `io`, off the loop
        /// (`Scope.blocking`).
        runs_on: ?*Reaper = null,
        /// Nanoseconds a blocking handler has before it's canceled and the
        /// answer is 504.
        deadline_ns: ?u64 = null,
        /// How many of its scope's blocking handlers run at once, and wait to.
        gate: ?*Gate = null,
        /// Its scope's own errors' answers, the innermost scope's first.
        errors: []const ErrorAnswer = &.{},
        /// Its body is read as it arrives (`endpoint.BodyStream`): the handler starts at the head.
        streams_body: bool = false,
        /// A WebSocket route's hooks, its handler the upgrade's `open` (`Scope.ws`).
        ws_hooks: ?*const websocket.Hooks = null,
    };
    /// `method` null: a WebSocket route's.
    const Entry = struct { method: ?Method, path: []const u8, target: Target };

    pub const Node = struct {
        segment: []const u8 = "",
        statics: std.ArrayList(*Node) = .empty,
        param: ?*Node = null,
        /// `*name`'s: what's left of the path, whatever it holds.
        rest: ?*Node = null,
        targets: std.EnumArray(Method, ?Target) = .initFill(null),
        /// A WebSocket upgrade's route, beside its path's methods'.
        ws: ?Target = null,
    };

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .arena = .init(gpa) };
    }

    /// After the servers using it have stopped, which waits for blocking
    /// handlers' tasks. Each `Io` outlives the router.
    pub fn deinit(self: *Router) void {
        for (self.reapers.items) |r| r.stop();
        self.arena.deinit();
    }

    fn reaperFor(self: *Router, io: std.Io) !*Reaper {
        for (self.reapers.items) |r| {
            if (r.io.userdata == io.userdata and r.io.vtable == io.vtable) return r;
        }
        const a = self.arena.allocator();
        try self.reapers.ensureUnusedCapacity(a, 1);
        const r = try a.create(Reaper);
        r.* = .{ .io = io };
        try r.start();
        self.reapers.appendAssumeCapacity(r);
        return r;
    }

    /// Routes added through this are under `prefix`, a path known at run
    /// time: `router.scope(opts.rooms_path).get("/:name", ...)`.
    pub fn scope(self: *Router, prefix: []const u8) Scope {
        return .{ .router = self, .prefix = prefix };
    }

    pub fn on(self: *Router, comptime method: Method, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.scope("").on(method, pattern, app, handler);
    }
    pub fn get(self: *Router, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.GET, pattern, app, handler);
    }
    pub fn post(self: *Router, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.POST, pattern, app, handler);
    }
    pub fn put(self: *Router, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.PUT, pattern, app, handler);
    }
    pub fn patch(self: *Router, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.PATCH, pattern, app, handler);
    }
    pub fn delete(self: *Router, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.DELETE, pattern, app, handler);
    }
    /// `Scope.ws`, outside any scope.
    pub fn ws(self: *Router, comptime pattern: []const u8, app: anytype, comptime H: type) !void {
        return self.scope("").ws(pattern, app, H);
    }
    /// `Scope.fallback` for every path: the transport's static files and 404 never come.
    pub fn fallback(self: *Router, app: anytype, comptime handler: anytype) !void {
        return self.scope("").fallback(app, handler);
    }
    pub fn bind(self: *Router, comptime e: endpoint.Endpoint, app: anytype, comptime handler: anytype) !void {
        return self.scope("").bind(e, app, handler);
    }

    /// `other`'s routes too; `error.DuplicateRoute` when one's method and
    /// path are taken here already.
    pub fn addAll(self: *Router, other: *const Router) !void {
        return self.scope("").addAll(other);
    }

    /// `path` is the router's own; `method` null for a WebSocket route.
    fn insert(self: *Router, method: ?Method, path: []const u8, target: Target) !void {
        const node = try self.nodeAt(path);
        const slot = if (method) |m| node.targets.getPtr(m) else &node.ws;
        if (slot.* != null) return error.DuplicateRoute;
        slot.* = target;
        try self.entries.append(self.arena.allocator(), .{ .method = method, .path = path, .target = target });
    }

    fn nodeAt(self: *Router, path: []const u8) !*Node {
        var node = &self.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| node = try child(self.arena.allocator(), node, seg);
        return node;
    }

    /// Where a WebSocket upgrade to `req`'s path leads; null when no route takes one.
    pub fn findUpgrade(self: *const Router, req: *const Request) ?Found {
        var found = self.lookup(true, req) orelse return null;
        found.target = &found.node.ws.?;
        return found;
    }

    fn lookup(self: *const Router, comptime upgrade: bool, req: *const Request) ?Found {
        var found: Found = .{ .node = undefined, .target = null };
        found.node = match(upgrade, &self.root, std.mem.tokenizeScalar(u8, req.path(), '/'), &found) orelse return null;
        return found;
    }

    fn child(a: std.mem.Allocator, node: *Node, seg: []const u8) !*Node {
        if (seg[0] == ':' or seg[0] == '*') {
            const slot = if (seg[0] == ':') &node.param else &node.rest;
            if (slot.* == null) {
                slot.* = try a.create(Node);
                slot.*.?.* = .{};
            }
            return slot.*.?;
        }
        for (node.statics.items) |c| if (std.mem.eql(u8, c.segment, seg)) return c;
        const c = try a.create(Node);
        c.* = .{ .segment = seg };
        try node.statics.append(a, c);
        return c;
    }

    /// Where `req`'s path and method lead; null when no route has the path.
    pub fn find(self: *const Router, req: *const Request) ?Found {
        var found = self.lookup(false, req) orelse return null;
        found.target = targetOf(found.node, req.method);
        return found;
    }

    /// A GET route answers HEAD too.
    fn targetOf(node: *const Node, method: Method) ?*const Target {
        if (node.targets.getPtrConst(method).*) |*t| return t;
        if (method == .HEAD) if (node.targets.getPtrConst(.GET).*) |*t| return t;
        return null;
    }

    /// Static segments before params, then a catch-all, trying the next
    /// way when one leads nowhere; `segs` is copied for that.
    /// `upgrade`: a node with a WebSocket route, not a method's.
    fn match(comptime upgrade: bool, node: *const Node, segs: std.mem.TokenIterator(u8, .scalar), found: *Found) ?*const Node {
        var rest = segs;
        const seg = rest.next() orelse {
            if (upgrade) {
                if (node.ws != null) return node;
            } else for (node.targets.values) |t| if (t != null) return node;
            return catchAll(node, segs, found);
        };
        for (node.statics.items) |c| if (std.mem.eql(u8, c.segment, seg)) {
            if (match(upgrade, c, rest, found)) |f| return f;
        };
        if (node.param) |p| if (found.n < max_params) {
            found.captures[found.n] = seg;
            found.n += 1;
            if (match(upgrade, p, rest, found)) |f| return f;
            found.n -= 1;
        };
        return catchAll(node, segs, found);
    }

    /// `node`'s catch-all, which takes `segs` on, empty or not.
    fn catchAll(node: *const Node, segs: std.mem.TokenIterator(u8, .scalar), found: *Found) ?*const Node {
        const r = node.rest orelse return null;
        if (found.n == max_params) return null;
        found.captures[found.n] = segs.rest();
        found.n += 1;
        return r;
    }

    /// 405, or 204 for OPTIONS, with the methods the path takes.
    fn allow(node: *const Node, method: Method, res: *Response) !void {
        var names: [std.enums.values(Method).len][]const u8 = undefined;
        var n: usize = 0;
        for (std.enums.values(Method)) |m| if (targetOf(node, m) != null) {
            names[n] = @tagName(m);
            n += 1;
        };
        try res.setHeader("Allow", try std.mem.join(res.arena, ", ", names[0..n]));
        // Through the error path, so a scope's `errors` may word it. OPTIONS, unanswered, is a 204.
        if (method != .OPTIONS) return error.MethodNotAllowed;
    }
};

pub const Scope = struct {
    router: *Router,
    prefix: []const u8,
    /// Run around each route added through it (`with`).
    middleware: []const Middleware = &.{},
    /// Bodies up to this, whatever the routes' `Spec` says: a limit known
    /// at run time (`limit`).
    max_body: ?usize = null,
    /// Where its handlers run, off the loop (`blocking`).
    runs_on: ?*Reaper = null,
    deadline_ns: ?u64 = null,
    gate: ?*Gate = null,
    /// Its own errors' answers (`errors`).
    answers: []const ErrorAnswer = &.{},

    pub const BlockingOptions = struct {
        /// A handler that hasn't returned by then is canceled, and the
        /// request answered 504. Null: none.
        deadline: ?std.Io.Duration = null,
        /// At most this many of the scope's handlers at once, whatever the
        /// `Io` takes. Null: as many as it takes.
        max_running: ?u32 = null,
        /// With `max_running`, how many more wait their turn; past them,
        /// 503. A wait is canceled as running would be.
        max_waiting: u32 = 64,
    };

    /// Its routes' handlers run as tasks on `io`, off the event loop, so
    /// they may block: a database query, a file read. They do their I/O
    /// with `ctx.io`. `before` middleware still runs on the loop.
    ///
    /// Each request in flight is a task until its handler returns; one
    /// `io` refuses (`std.Io.Threaded`'s `concurrent_limit`) is a 503. A
    /// handler whose client leaves is canceled: its `io` calls fail with
    /// `error.Canceled`, which it returns. The handler shares nothing with
    /// the loop: what the loop owns, a game's state say, it must not touch.
    ///
    /// The first scope on an `io` starts a thread that collects and cancels
    /// its tasks. `io` outlives the router.
    pub fn blocking(self: Scope, io: std.Io, opts: BlockingOptions) !Scope {
        var s = self;
        s.runs_on = try self.router.reaperFor(io);
        s.deadline_ns = if (opts.deadline) |d| @intCast(@max(d.nanoseconds, 0)) else null;
        s.gate = null;
        if (opts.max_running) |n| {
            const g = try self.router.arena.allocator().create(Gate);
            g.* = .{ .running = .{ .permits = n }, .room = n + opts.max_waiting };
            s.gate = g;
        }
        return s;
    }

    /// Its routes answer these errors, from the handler or any middleware,
    /// as problems with their status and detail; others answer with their
    /// status (`statusOf`). An inner scope's come first.
    pub fn errors(self: Scope, answers: []const ErrorAnswer) !Scope {
        var s = self;
        s.answers = try std.mem.concat(self.router.arena.allocator(), ErrorAnswer, &.{ answers, self.answers });
        return s;
    }

    /// Its routes have `middleware` too, after the scope's own.
    pub fn with(self: Scope, middleware: []const Middleware) !Scope {
        var s = self;
        s.middleware = try std.mem.concat(self.router.arena.allocator(), Middleware, &.{ self.middleware, middleware });
        return s;
    }

    pub fn limit(self: Scope, max_body: usize) Scope {
        var s = self;
        s.max_body = max_body;
        return s;
    }

    /// Under `prefix` too, after the scope's own.
    pub fn at(self: Scope, prefix: []const u8) !Scope {
        var s = self;
        s.prefix = try std.mem.concat(self.router.arena.allocator(), u8, &.{ self.prefix, prefix });
        return s;
    }

    /// `other`'s routes, under this scope: its prefix, its middleware first.
    pub fn addAll(self: Scope, other: *const Router) !void {
        const a = self.router.arena.allocator();
        // `other`'s gates, each copied once, so the routes sharing one still do.
        var gates: std.ArrayList(struct { from: *Gate, to: *Gate }) = .empty;
        for (other.entries.items) |e| {
            var target = e.target;
            target.middleware = try std.mem.concat(a, Middleware, &.{ self.middleware, e.target.middleware });
            target.errors = try std.mem.concat(a, ErrorAnswer, &.{ e.target.errors, self.answers });
            if (self.max_body) |n| target.max_body = n;
            // Rehomed: `other`'s reaper goes when it does.
            if (self.runs_on orelse e.target.runs_on) |r| target.runs_on = try self.router.reaperFor(r.io);
            if (self.runs_on != null) {
                target.deadline_ns = self.deadline_ns;
                target.gate = self.gate;
            } else if (e.target.gate) |from| target.gate = for (gates.items) |g| {
                if (g.from == from) break g.to;
            } else copy: {
                const to = try a.create(Gate);
                to.* = .{ .running = .{ .permits = from.running.permits }, .room = from.room };
                try gates.append(a, .{ .from = from, .to = to });
                break :copy to;
            };
            try self.router.insert(e.method, try std.mem.concat(a, u8, &.{ self.prefix, e.path }), target);
        }
    }

    pub fn on(self: Scope, comptime method: Method, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        // A streamed body is read while it arrives: by a handler off the loop.
        const streams = comptime route(pattern, handler).Ctx.web_spec.body == endpoint.BodyStream;
        if (streams and self.runs_on == null) return error.BodyStreamNotBlocking;
        const path = try std.mem.concat(self.router.arena.allocator(), u8, &.{ self.prefix, pattern });
        return self.router.insert(method, path, self.targetFor(pattern, app, handler));
    }

    /// A WebSocket route: an upgrade to `pattern` goes through the scope's
    /// middleware and `H.open`, a handler that accepts by returning; then
    /// `H.ready(app, ws, call)` once it's accepted, `H.message(app, ws,
    /// data, kind)` for each message and `H.close(app, ws, code, reason)`
    /// (`http.WebSocket`). `ready` and `close` may be left out, and `app` is
    /// `{}` when `open` takes none. On the loop: not in a blocking scope.
    pub fn ws(self: Scope, comptime pattern: []const u8, app: anytype, comptime H: type) !void {
        if (self.runs_on != null) return error.WebSocketBlocking;
        var target = self.targetFor(pattern, app, H.open);
        target.ws_hooks = websocket.Hooks.of(comptime route(pattern, H.open).App, H);
        return self.router.insert(null, try std.mem.concat(self.router.arena.allocator(), u8, &.{ self.prefix, pattern }), target);
    }

    /// What a path under the scope's prefix that no route has leads to, any
    /// method: an API's own 404 say, in place of the transport's (static
    /// files, a 404). It's a last `*` for each method the prefix's own
    /// catch-all, if any, doesn't take; `error.DuplicateRoute` when it takes
    /// them all.
    pub fn fallback(self: Scope, app: anytype, comptime handler: anytype) !void {
        const path = try std.mem.concat(self.router.arena.allocator(), u8, &.{ self.prefix, "/*fallback" });
        const target = self.targetFor("/", app, handler);
        var added = false;
        for (std.enums.values(Method)) |m| {
            self.router.insert(m, path, target) catch |err| switch (err) {
                error.DuplicateRoute => continue,
                else => return err,
            };
            added = true;
        }
        if (!added) return error.DuplicateRoute;
    }

    fn targetFor(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) Router.Target {
        const r = comptime route(pattern, handler);
        const App = @TypeOf(app);
        if (r.App == void) {
            if (App != void) @compileError(pattern ++ ": its handler takes no state; pass {}");
        } else if (App != r.App) {
            @compileError(pattern ++ ": its handler takes " ++ @typeName(r.App) ++ ", not " ++ @typeName(App));
        }
        const ptr: ?*anyopaque = if (App == void) null else @ptrCast(@constCast(app));
        return .{
            .thunk = r.thunk,
            .app = ptr,
            .max_body = self.max_body orelse r.max_body,
            .middleware = self.middleware,
            .runs_on = self.runs_on,
            .deadline_ns = self.deadline_ns,
            .gate = self.gate,
            .errors = self.answers,
            .streams_body = r.Ctx.web_spec.body == endpoint.BodyStream,
        };
    }
    pub fn get(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.GET, pattern, app, handler);
    }
    pub fn post(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.POST, pattern, app, handler);
    }
    pub fn put(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.PUT, pattern, app, handler);
    }
    pub fn patch(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.PATCH, pattern, app, handler);
    }
    pub fn delete(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.DELETE, pattern, app, handler);
    }

    /// `handler` as endpoint `e` (`http.endpoint`), checked against its
    /// contract: the handler takes `*http.ContextOf(e)` and returns `e.result`.
    pub fn bind(self: Scope, comptime e: endpoint.Endpoint, app: anytype, comptime handler: anytype) !void {
        const r = comptime route(e.path, handler);
        if (r.Ctx != ContextOf(e)) @compileError(e.path ++ ": a handler bound to it takes *http.ContextOf(its endpoint)");
        if (r.Result != e.result) @compileError(e.path ++ ": its handler returns " ++ @typeName(r.Result) ++ ", not the endpoint's " ++ @typeName(e.result));
        return self.on(e.method, e.path, app, handler);
    }
};

/// The context a handler bound to endpoint `e` takes.
pub fn ContextOf(comptime e: endpoint.Endpoint) type {
    return context.Context(e.spec);
}
