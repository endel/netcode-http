//! A router on a listener of its own, on a thread and event loop of their
//! own: plain HTTP/1.1, an admin port beside a server's public one; or with
//! `tls`, HTTP/1.1 over TLS and HTTP/3 on one port, from quic-zig's server.
//! Its handlers may block that thread only as long as its other requests
//! can wait; longer work goes to a `blocking` scope.
//!
//! ```zig
//! const admin = try http.Server.create(gpa, &router, .{ .port = 4480 });
//! defer admin.destroy();
//! ```

const std = @import("std");
const quic = @import("quic");
const http1 = quic.http1;
const event_loop = quic.event_loop;
const xev = event_loop.Xev;
const Router = @import("router.zig").Router;
const Host = @import("quic.zig").Host;
const Pendings = @import("quic.zig").Pendings;
const address = @import("address.zig");
const Sockets = @import("websocket.zig").Sockets;

pub const Server = struct {
    gpa: std.mem.Allocator,
    host: Host,
    /// Its WebSocket routes' sockets.
    sockets: Sockets = .{},
    /// Its requests' state, between them.
    pendings: Pendings = .{},
    /// The latest a drain may run to, in nanoseconds: `drain`'s grace, or
    /// the past for `destroy`'s stop.
    drain_until: std.atomic.Value(i64) = .init(0),
    /// Carries a drain to the loop's thread.
    wake: xev.Async,
    wake_c: xev.Completion = .{},
    /// Checks a drain until it's done.
    timer: xev.Timer,
    timer_c: xev.Completion = .{},
    /// Null once it has stopped.
    thread: ?std.Thread = null,
    mode: union(enum) {
        plain: struct { loop: xev.Loop, http: http1.Server },
        tls: struct { app: App, server: event_loop.Server(App) },
    },

    pub const Options = struct {
        address: []const u8 = "127.0.0.1",
        /// 0 asks the system for one: `Server.port`.
        port: u16 = 0,
        /// Connections served at once; the rest wait in the listen backlog.
        max_connections: u32 = 64,
        /// `Host.trusted_proxies`: addresses, or networks as `"10.0.0.0/8"`.
        /// `create` fails with `error.InvalidNetwork` on an entry that's neither.
        trusted_proxies: []const []const u8 = &.{},
        /// HTTP/1.1 over TLS and HTTP/3 on one port (TCP and UDP), these
        /// certificates' (PEM). Null: plain HTTP/1.1.
        tls: ?Tls = null,

        pub const Tls = struct { cert_path: []const u8, key_path: []const u8 };
    };

    /// Binds, then serves from a thread of its own until `destroy`.
    pub fn create(gpa: std.mem.Allocator, router: *const Router, opts: Options) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        const trusted = try address.parseNetworks(gpa, opts.trusted_proxies);
        errdefer gpa.free(trusted);
        self.* = .{
            .gpa = gpa,
            .host = .{ .gpa = gpa, .router = router, .trusted_proxies = trusted },
            .wake = try xev.Async.init(),
            .timer = try xev.Timer.init(),
            .mode = undefined,
        };
        errdefer self.wake.deinit();
        self.host.sockets = &self.sockets;
        self.host.pendings = &self.pendings;
        const loop = if (opts.tls) |tls| tls: {
            self.mode = .{ .tls = .{ .app = .{ .host = &self.host }, .server = undefined } };
            const t = &self.mode.tls;
            t.server = try .init(gpa, &t.app, .{
                .address = opts.address,
                .port = opts.port,
                .cert_path = tls.cert_path,
                .key_path = tls.key_path,
                .http1 = .{ .tls = true, .max_connections = opts.max_connections },
            });
            break :tls &t.server.own_loop;
        } else plain: {
            self.mode = .{ .plain = .{ .loop = try xev.Loop.init(.{}), .http = undefined } };
            const p = &self.mode.plain;
            errdefer p.loop.deinit();
            p.http = try http1.Server.init(gpa, .{
                .tls = false,
                .port = opts.port,
                .alt_svc = false,
                .max_connections = opts.max_connections,
            }, .{ .address = opts.address, .quic_port = opts.port });
            errdefer p.http.deinit();
            try p.http.start(&p.loop, http1.handlersFor(Host, &self.host), null);
            break :plain &p.loop;
        };
        errdefer self.stopped();
        // Before its thread starts: the loop is this thread's till then.
        self.wake.wait(loop, &self.wake_c, Server, self, onWake);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Any thread: stops taking connections, and stops once those open are
    /// done, or `grace_ms` has passed. Then `destroy`.
    pub fn drain(self: *Server, grace_ms: u32) void {
        const thread = self.thread orelse return;
        self.drain_until.store(quic.sys.nanoTimestamp() + @as(i64, grace_ms) * std.time.ns_per_ms, .release);
        self.wake.notify() catch {};
        thread.join();
        self.thread = null;
    }

    /// Any thread: stops now, unless drained already. Blocking handlers
    /// still running are waited for.
    pub fn destroy(self: *Server) void {
        self.drain(0);
        self.stopped();
        self.gpa.free(self.host.trusted_proxies);
        self.gpa.destroy(self);
    }

    pub fn port(self: *const Server) u16 {
        return switch (self.mode) {
            .plain => |*p| p.http.port(),
            .tls => |*t| t.server.port(),
        };
    }

    /// What the mode holds, freed once its loop is done.
    fn stopped(self: *Server) void {
        switch (self.mode) {
            .plain => |*p| {
                p.http.deinit();
                p.loop.deinit();
            },
            .tls => |*t| t.server.deinit(),
        }
        self.sockets.deinit(self.gpa);
        self.pendings.deinit();
        self.timer.deinit();
        self.wake.deinit();
    }

    fn run(self: *Server) void {
        switch (self.mode) {
            .plain => |*p| while (!p.http.isStopped()) p.loop.run(.once) catch break,
            .tls => |*t| t.server.run() catch |err| std.log.scoped(.http).err("server: {t}", .{err}),
        }
    }

    fn onWake(self_opt: ?*Server, loop: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
        const self = self_opt orelse return .disarm;
        _ = r catch {};
        switch (self.mode) {
            .plain => |*p| p.http.drain(),
            .tls => |*t| t.server.drain(.{}),
        }
        self.check(loop);
        return .rearm; // a stopped loop ends armed or not
    }

    /// Stops a drain that's done, or past its time; else looks again soon.
    fn check(self: *Server, loop: *xev.Loop) void {
        const drained = switch (self.mode) {
            .plain => |*p| p.http.isDrained(),
            .tls => |*t| t.server.isDrained(),
        };
        if (drained or quic.sys.nanoTimestamp() >= self.drain_until.load(.acquire)) return switch (self.mode) {
            .plain => |*p| p.http.stop(),
            .tls => |*t| t.server.stop(),
        };
        self.timer.run(loop, &self.timer_c, 20, Server, self, onTimer);
    }

    fn onTimer(self_opt: ?*Server, loop: *xev.Loop, _: *xev.Completion, r: xev.Timer.RunError!void) xev.CallbackAction {
        _ = r catch {};
        self_opt.?.check(loop);
        return .disarm;
    }
};

/// The `tls` mode's handler: quic-zig's callbacks handed to the server's `Host`.
const App = struct {
    pub const protocol: event_loop.Protocol = .h3;

    host: *Host,

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
    pub fn onHttpWritable(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpWritable(ex);
    }
    pub fn onWsUpgrade(self: *App, req: *event_loop.WsRequest, path: []const u8) void {
        self.host.onWsUpgrade(req, path);
    }
    pub fn onWsMessage(self: *App, ws: *event_loop.WsConn, data: []const u8, kind: event_loop.WsMessageKind) void {
        self.host.onWsMessage(ws, data, kind);
    }
    pub fn onWsClose(self: *App, ws: *event_loop.WsConn, code: u16, reason: []const u8) void {
        self.host.onWsClose(ws, code, reason);
    }
};
