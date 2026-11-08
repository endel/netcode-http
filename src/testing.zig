//! Calling a router's routes the way a transport would, through the same
//! `Host`, without a socket; and one HTTP/3 request against a real server.
//!
//! ```zig
//! var client: http.testing.Client = .init(std.testing.allocator, &router);
//! defer client.deinit();
//! const res = try client.get("/rooms/tank");
//! try std.testing.expectEqual(200, res.status);
//! ```

const std = @import("std");
const quic = @import("quic");
const Exchange = quic.event_loop.Exchange;
const Loop = quic.event_loop.Xev.Loop;
const Mailbox = quic.Mailbox;
const context = @import("context.zig");
const Router = @import("router.zig").Router;
const Host = @import("quic.zig").Host;
const Pendings = @import("quic.zig").Pendings;
const getHeader = quic.http1.parser.getHeader;
const Address = @import("address.zig").Address;

pub const Answer = struct {
    /// Null when no route had the path, or the client left first (`leave`).
    status: ?u16,
    headers: []const context.Header = &.{},
    body: []const u8 = "",
    /// Reset before it ended: a stream cut off.
    cut: bool = false,

    pub fn header(self: Answer, name: []const u8) ?[]const u8 {
        return getHeader(self.headers, name);
    }
};

pub const Options = struct {
    headers: []const context.Header = &.{},
    body: []const u8 = "",
    /// Who the connection is from: a proxy, say, with `Client.host.trusted_proxies`.
    peer: Address = .{},
    /// The client leaves once its request is sent: a blocking handler still
    /// running is canceled, and `request` returns once its task is collected.
    leave: bool = false,
};

/// Answers live until `deinit`. One made off the loop, a `blocking` scope's,
/// is waited for.
pub const Client = struct {
    host: Host,
    arena: std.heap.ArenaAllocator,
    back: ?*Back = null,
    /// Requests' state, reused as a server's is.
    pendings: Pendings = .{},

    /// Where answers made off the loop come back to: a loop of the client's own.
    const Back = struct {
        loop: Loop,
        mailbox: Mailbox,
    };

    pub fn init(gpa: std.mem.Allocator, router: *const Router) Client {
        return .{ .host = .init(gpa, router), .arena = .init(gpa) };
    }

    pub fn deinit(self: *Client) void {
        if (self.back) |b| {
            b.mailbox.deinit();
            b.loop.deinit();
            self.host.gpa.destroy(b);
        }
        self.pendings.deinit();
        self.arena.deinit();
    }

    fn backOf(self: *Client) !*Back {
        if (self.back) |b| return b;
        const b = try self.host.gpa.create(Back);
        errdefer self.host.gpa.destroy(b);
        b.loop = try .init(.{});
        errdefer b.loop.deinit();
        b.mailbox = try .init();
        b.mailbox.loop = &b.loop;
        self.back = b;
        return b;
    }

    pub fn request(self: *Client, method: context.Method, target: []const u8, opts: Options) !Answer {
        const back = try self.backOf();
        self.host.pendings = &self.pendings; // here: the client may have moved since init
        var fake: Fake = .{ .arena = self.arena.allocator() };
        const in6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&fake.address));
        in6.* = .{ .port = 0, .flowinfo = 0, .addr = opts.peer.bytes, .scope_id = 0 };
        var ex: Exchange = .{
            .method = @tagName(method),
            .target = target,
            .headers = opts.headers,
            .content_length = opts.body.len,
            .head_only = method == .HEAD,
            .impl = &fake,
            .vtable = &Fake.vtable,
            .mailbox = &back.mailbox,
        };
        self.host.onHttpHead(&ex);
        if (ex.passed) return .{ .status = null };
        if (ex.answer != .done and opts.body.len > 0) self.host.onHttpBody(&ex, opts.body);
        if (ex.answer != .done) self.host.onHttpEnd(&ex);
        if (opts.leave and ex.answer != .done) {
            self.host.onHttpGone(&ex);
            while (back.mailbox.watching) try back.loop.run(.once);
            return .{ .status = null };
        }
        while (ex.answer != .done and back.mailbox.watching) try back.loop.run(.once);
        if (ex.answer != .done) return error.Unanswered;
        return .{ .status = fake.status, .headers = fake.headers.items, .body = fake.sent.items, .cut = fake.cut };
    }

    pub fn get(self: *Client, target: []const u8) !Answer {
        return self.request(.GET, target, .{});
    }

    pub fn post(self: *Client, target: []const u8, body: []const u8) !Answer {
        return self.request(.POST, target, .{ .body = body });
    }
};

/// A transport that keeps what it's sent.
const Fake = struct {
    arena: std.mem.Allocator,
    status: u16 = 0,
    headers: std.ArrayList(context.Header) = .empty,
    sent: std.ArrayList(u8) = .empty,
    cut: bool = false,
    address: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage),

    const vtable: Exchange.VTable = .{
        .peer = peer,
        .head = head,
        .body = body,
        .end = noop,
        .reset = reset,
        .buffered = buffered,
        .cork = cork,
    };

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn peer(ptr: *anyopaque) *const std.posix.sockaddr.storage {
        return &of(ptr).address;
    }

    fn head(ptr: *anyopaque, status: u16, headers: []const context.Header, _: Exchange.Framing) Exchange.WriteError!void {
        const self = of(ptr);
        self.status = status;
        for (headers) |h| self.headers.append(self.arena, .{
            .name = self.arena.dupe(u8, h.name) catch return error.Closed,
            .value = self.arena.dupe(u8, h.value) catch return error.Closed,
        }) catch return error.Closed;
    }

    fn body(ptr: *anyopaque, data: []const u8) Exchange.WriteError!void {
        const self = of(ptr);
        self.sent.appendSlice(self.arena, data) catch return error.Closed;
    }

    fn noop(_: *anyopaque) void {}

    fn reset(ptr: *anyopaque) void {
        of(ptr).cut = true;
    }

    fn buffered(_: *anyopaque) usize {
        return 0;
    }

    fn cork(_: *anyopaque, _: bool) void {}
};

/// One request over HTTP/3, and its answer.
pub const Http3 = struct {
    pub const protocol: quic.event_loop.Protocol = .h3;

    method: []const u8 = "GET",
    path: []const u8,
    body: ?[]const u8 = null,
    status: [3]u8 = .{ 0, 0, 0 },
    answer: [1024]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    /// Sends it to `port` on `loop`, which a server there runs on, calling
    /// `step(stepper)` until the answer is in.
    pub fn fetch(self: *Http3, gpa: std.mem.Allocator, loop: *quic.event_loop.Xev.Loop, port: u16, stepper: anytype) !void {
        var c = try quic.event_loop.Client(Http3).init(gpa, self, .{ .port = port, .skip_cert_verify = true, .loop = loop });
        defer c.deinit();
        c.start();
        defer {
            c.stop();
            const deadline = quic.sys.nanoTimestamp() + 5 * std.time.ns_per_s;
            while (!c.isStopped() and quic.sys.nanoTimestamp() < deadline) stepper.step() catch break;
        }
        const deadline = quic.sys.nanoTimestamp() + 10 * std.time.ns_per_s;
        while (!self.done) {
            if (quic.sys.nanoTimestamp() > deadline) return error.Timeout;
            try stepper.step();
        }
    }

    pub fn text(self: *const Http3) []const u8 {
        return self.answer[0..self.len];
    }

    pub fn onConnected(self: *Http3, session: *quic.event_loop.ClientSession) void {
        _ = session.sendRequest(&.{
            .{ .name = ":method", .value = self.method },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = ":path", .value = self.path },
        }, self.body) catch {};
    }
    pub fn onHeaders(self: *Http3, _: *quic.event_loop.ClientSession, _: u64, headers: []const quic.qpack.Header) void {
        for (headers) |h| if (std.mem.eql(u8, h.name, ":status")) @memcpy(&self.status, h.value[0..3]);
    }
    pub fn onData(self: *Http3, session: *quic.event_loop.ClientSession, _: u64, _: usize) void {
        while (true) {
            const n = session.recvBody(self.answer[self.len..]);
            if (n == 0) break;
            self.len += n;
        }
    }
    pub fn onFinished(self: *Http3, _: *quic.event_loop.ClientSession, _: u64) void {
        self.done = true;
    }
};
