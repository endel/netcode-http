//! A router on a listener of its own: HTTP/1.1 on a thread and event loop
//! of their own, for a control or admin port beside a server's public one.
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
const xev = quic.event_loop.Xev;
const Router = @import("router.zig").Router;
const Host = @import("quic.zig").Host;
const address = @import("address.zig");

pub const Server = struct {
    gpa: std.mem.Allocator,
    host: Host,
    loop: xev.Loop,
    http: http1.Server,
    stop_wake: xev.Async,
    stop_c: xev.Completion = .{},
    thread: std.Thread,

    pub const Options = struct {
        address: []const u8 = "127.0.0.1",
        /// 0 asks the system for one: `Server.port`.
        port: u16 = 0,
        /// Connections served at once; the rest wait in the listen backlog.
        max_connections: u32 = 64,
        /// `Host.trusted_proxies`: addresses, or networks as `"10.0.0.0/8"`.
        /// `create` fails with `error.InvalidNetwork` on an entry that's neither.
        trusted_proxies: []const []const u8 = &.{},
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
            .loop = try xev.Loop.init(.{}),
            .http = undefined,
            .stop_wake = undefined,
            .thread = undefined,
        };
        errdefer self.loop.deinit();
        self.http = try http1.Server.init(gpa, .{
            .tls = false,
            .port = opts.port,
            .alt_svc = false,
            .max_connections = opts.max_connections,
        }, .{ .address = opts.address, .quic_port = opts.port });
        errdefer self.http.deinit();
        self.stop_wake = try xev.Async.init();
        errdefer self.stop_wake.deinit();
        try self.http.start(&self.loop, http1.handlersFor(Host, &self.host), null);
        self.stop_wake.wait(&self.loop, &self.stop_c, Server, self, onStop);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Any thread. Blocking handlers still running are waited for.
    pub fn destroy(self: *Server) void {
        self.stop_wake.notify() catch {};
        self.thread.join();
        self.http.deinit();
        self.stop_wake.deinit();
        self.loop.deinit();
        self.gpa.free(self.host.trusted_proxies);
        self.gpa.destroy(self);
    }

    pub fn port(self: *const Server) u16 {
        return self.http.port();
    }

    fn run(self: *Server) void {
        while (!self.http.isStopped()) self.loop.run(.once) catch break;
    }

    fn onStop(self_opt: ?*Server, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
        const self = self_opt orelse return .disarm;
        _ = r catch {};
        self.http.stop();
        return .disarm;
    }
};
