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
    /// What a call returns, sent as JSON; `void` when it answers by itself.
    Result: type,
    thunk: Thunk,
    max_body: usize,
};

/// `handler` is `fn (app: *App, ctx: *http.Context(spec)) !Result`, or
/// without `app`. A `Result` other than `void` is sent as JSON with 200;
/// with `void` the handler answers through `ctx`, and one that doesn't
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
            var ctx: Ctx = .{
                .params = try endpoint.decodeParams(Ctx.web_spec.params, names, rest, captures, arena),
                .query = try endpoint.decodeQuery(Ctx.web_spec.query, c.request.rawQuery(), arena),
                .body = try endpoint.decodeBody(Ctx.web_spec.body, c.request.body, arena),
                .request = &c.request,
                .response = &c.response,
                .arena = arena,
                .io = c.io,
                .call = c,
            };
            const returned = if (App == void) handler(&ctx) else handler(@as(App, @ptrCast(@alignCast(app.?))), &ctx);
            const result = if (@typeInfo(Returned) == .error_union) try returned else returned;
            if (Result != void) try c.response.json(200, result);
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
        self.call(c) catch |err| failWith(c, err);
    }

    /// `run`, leaving a handler's error to the caller (`failWith`).
    pub fn call(self: *const Found, c: *Call) anyerror!void {
        const target = self.target orelse return Router.allow(self.node, c.request.method, &c.response);
        const rest: Rest = .{ .target = target, .captures = self.captures[0..self.n], .middleware = target.middleware };
        return rest.run(c);
    }

    /// `err`'s status as the answer. One after an `offload` leaves the
    /// answer to the work offloaded.
    pub fn failWith(c: *Call, err: anyerror) void {
        const req = &c.request;
        const res = &c.response;
        if (res.deferred) return log.err("{t} {s}: {t} after offload", .{ req.method, req.path(), err });
        const status = context.statusOf(err);
        if (status == 500 and !res.answered) log.err("{t} {s}: {t}", .{ req.method, req.path(), err });
        res.fail(status);
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
    };
    const Entry = struct { method: Method, path: []const u8, target: Target };

    pub const Node = struct {
        segment: []const u8 = "",
        statics: std.ArrayList(*Node) = .empty,
        param: ?*Node = null,
        /// `*name`'s: what's left of the path, whatever it holds.
        rest: ?*Node = null,
        targets: std.EnumArray(Method, ?Target) = .initFill(null),
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
    pub fn bind(self: *Router, comptime e: endpoint.Endpoint, app: anytype, comptime handler: anytype) !void {
        return self.scope("").bind(e, app, handler);
    }

    /// `other`'s routes too; `error.DuplicateRoute` when one's method and
    /// path are taken here already.
    pub fn addAll(self: *Router, other: *const Router) !void {
        return self.scope("").addAll(other);
    }

    /// `path` is the router's own.
    fn insert(self: *Router, method: Method, path: []const u8, target: Target) !void {
        const a = self.arena.allocator();
        var node = &self.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| node = try child(a, node, seg);
        if (node.targets.get(method) != null) return error.DuplicateRoute;
        node.targets.set(method, target);
        try self.entries.append(a, .{ .method = method, .path = path, .target = target });
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
        var found: Found = .{ .node = undefined, .target = null };
        found.node = match(&self.root, std.mem.tokenizeScalar(u8, req.path(), '/'), &found) orelse return null;
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
    fn match(node: *const Node, segs: std.mem.TokenIterator(u8, .scalar), found: *Found) ?*const Node {
        var rest = segs;
        const seg = rest.next() orelse {
            for (node.targets.values) |t| if (t != null) return node;
            return catchAll(node, segs, found);
        };
        for (node.statics.items) |c| if (std.mem.eql(u8, c.segment, seg)) {
            if (match(c, rest, found)) |f| return f;
        };
        if (node.param) |p| if (found.n < max_params) {
            found.captures[found.n] = seg;
            found.n += 1;
            if (match(p, rest, found)) |f| return f;
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
    fn allow(node: *const Node, method: Method, res: *Response) void {
        var names: [std.enums.values(Method).len][]const u8 = undefined;
        var n: usize = 0;
        for (std.enums.values(Method)) |m| if (targetOf(node, m) != null) {
            names[n] = @tagName(m);
            n += 1;
        };
        res.setHeader("Allow", std.mem.join(res.arena, ", ", names[0..n]) catch "") catch {};
        if (method != .OPTIONS) res.fail(405); // unanswered, it's a 204
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

    pub const BlockingOptions = struct {
        /// A handler that hasn't returned by then is canceled, and the
        /// request answered 504. Null: none.
        deadline: ?std.Io.Duration = null,
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
        for (other.entries.items) |e| {
            var target = e.target;
            target.middleware = try std.mem.concat(a, Middleware, &.{ self.middleware, e.target.middleware });
            if (self.max_body) |n| target.max_body = n;
            // Rehomed: `other`'s reaper goes when it does.
            if (self.runs_on orelse e.target.runs_on) |r| target.runs_on = try self.router.reaperFor(r.io);
            if (self.runs_on != null) target.deadline_ns = self.deadline_ns;
            try self.router.insert(e.method, try std.mem.concat(a, u8, &.{ self.prefix, e.path }), target);
        }
    }

    pub fn on(self: Scope, comptime method: Method, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        const r = comptime route(pattern, handler);
        const App = @TypeOf(app);
        if (r.App == void) {
            if (App != void) @compileError(pattern ++ ": its handler takes no state; pass {}");
        } else if (App != r.App) {
            @compileError(pattern ++ ": its handler takes " ++ @typeName(r.App) ++ ", not " ++ @typeName(App));
        }
        const ptr: ?*anyopaque = if (App == void) null else @ptrCast(@constCast(app));
        const path = try std.mem.concat(self.router.arena.allocator(), u8, &.{ self.prefix, pattern });
        return self.router.insert(method, path, .{
            .thunk = r.thunk,
            .app = ptr,
            .max_body = self.max_body orelse r.max_body,
            .middleware = self.middleware,
            .runs_on = self.runs_on,
            .deadline_ns = self.deadline_ns,
        });
    }
    pub fn get(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.GET, pattern, app, handler);
    }
    pub fn post(self: Scope, comptime pattern: []const u8, app: anytype, comptime handler: anytype) !void {
        return self.on(.POST, pattern, app, handler);
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
