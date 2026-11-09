//! A `Router` served from quic-zig's `onHttpHead` callbacks: HTTP/1.1 on the
//! TCP listener and HTTP/3 on QUIC alike. `Host` takes the callbacks' names,
//! so a server built on `http1.handlersFor` takes it as its handler, and an
//! embedding one passes its own on (README).
//!
//! A request no route has is passed on inside its head's callback: on
//! HTTP/1.1 to the static files or a 404, on HTTP/3 to a 404.

const std = @import("std");
const event_loop = @import("quic").event_loop;
const Exchange = event_loop.Exchange;
const websocket = @import("../websocket.zig");
const WebSocket = websocket.WebSocket;
const Mailbox = @import("quic").Mailbox;
const reaper_mod = @import("reaper.zig");
const Reaper = reaper_mod.Reaper;
const context = @import("../context.zig");
const Stream = @import("../stream.zig").Stream;
const BodyReader = @import("../stream.zig").BodyReader;
const router_mod = @import("../router.zig");
const Router = router_mod.Router;
const address = @import("../address.zig");

/// A body of known length is reserved up to this much at its head.
const eager_body = 1 << 20;

pub const Host = struct {
    router: *const Router,
    gpa: std.mem.Allocator,
    /// The proxies in front, such as routez: a request from one is the
    /// client its `X-Forwarded-For` names (`Request.client`). List every
    /// proxy on the way in, not just the nearest (`address.parseNetworks`).
    trusted_proxies: []const address.Network = &.{},
    /// Where WebSocket routes' sockets are kept: the app's, one per loop,
    /// since a `Host` may live no longer than a callback. Without one, an
    /// upgrade is declined.
    sockets: ?*websocket.Sockets = null,
    /// Where requests' state is kept between them: the app's, one per loop,
    /// as `sockets` is. Without one, each request's is allocated and freed.
    pendings: ?*Pendings = null,

    /// A request's own, from its head to its answer.
    const Pending = struct {
        arena: std.heap.ArenaAllocator,
        /// Where `release` returns it.
        pool: ?*Pendings,
        next: ?*Pending = null,
        /// Null once the client is gone, while a blocking handler still holds it.
        ex: ?*Exchange,
        call: context.Call,
        found: router_mod.Found,
        body: std.ArrayList(u8) = .empty,
        content_length: ?u64,
        /// A blocking handler's, once it's started.
        off: ?*OffLoop = null,
        /// A streamed body's bytes so far, against `max_body`.
        streamed_len: usize = 0,

        fn destroy(p: *Pending) void {
            const gpa = p.arena.child_allocator;
            p.arena.deinit();
            gpa.destroy(p);
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Pending) <= 512); // smp_allocator's 512 B class, one per request in flight
    }

    /// From here quic-zig's HTTP/1.1 and HTTP/3 alike owe `onHttpWritable`:
    /// their own marks, copied (TODO/streaming.md).
    const writable_mark = 64 * 1024;

    /// A blocking handler's task, in its request's arena. It posts `done`
    /// when the handler returns, and the reaper `task.reaped` once it's
    /// collected, which frees the request.
    const OffLoop = struct {
        p: *Pending,
        reaper: *Reaper,
        task: reaper_mod.Task,
        done: Mailbox.Post = .{ .run = doneOffLoop },
        /// The handler returned an error: a stream it started is cut off.
        failed: bool = false,
        stream: Stream,
    };

    pub fn init(gpa: std.mem.Allocator, router: *const Router) Host {
        return .{ .router = router, .gpa = gpa };
    }

    /// An upgrade to a WebSocket route (`Scope.ws`): its scope's middleware
    /// and `open` decide, then `ready` hears of the socket. False when no
    /// route takes it, `req` left for the caller: an app's own sockets.
    pub fn upgrade(self: *Host, req: *event_loop.WsRequest, path: []const u8) bool {
        const sockets = self.sockets orelse return false;
        const head: context.Request = .{ .method = .GET, .target = path, .headers = req.headers() };
        const found = self.router.findUpgrade(&head) orelse return false;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var call: context.Call = .{ .request = head, .response = .init(arena.allocator()) };
        call.request.client = address.clientOf(req.peerAddress(), head.headers, self.trusted_proxies);
        if (!found.before(&call)) found.run(&call);
        // Answered, or refused with an error: no socket.
        if (call.response.answered) {
            req.reject(call.response.status);
            return true;
        }
        const conn = req.accept(.{ .headers = call.response.headers.items }) catch return true;
        const target = found.target.?;
        const ws = self.gpa.create(WebSocket) catch {
            conn.close(1011, "");
            return true;
        };
        ws.* = .{ .conn = conn, .app = target.app, .hooks = target.ws_hooks.? };
        sockets.map.put(self.gpa, conn.id(), ws) catch {
            self.gpa.destroy(ws);
            conn.close(1011, "");
            return true;
        };
        if (ws.hooks.ready) |ready| ready(ws, &call);
        return true;
    }

    /// A message for a route's socket: false when `conn` isn't one.
    pub fn message(self: *Host, conn: *event_loop.WsConn, data: []const u8, kind: WebSocket.Kind) bool {
        const ws = (self.sockets orelse return false).map.get(conn.id()) orelse return false;
        ws.hooks.message(ws, data, kind);
        return true;
    }

    /// A route's socket closed: false when `conn` isn't one.
    pub fn closed(self: *Host, conn: *event_loop.WsConn, code: u16, reason: []const u8) bool {
        const ws = ((self.sockets orelse return false).map.fetchSwapRemove(conn.id()) orelse return false).value;
        if (ws.hooks.close) |close| close(ws, code, reason);
        self.gpa.destroy(ws);
        return true;
    }

    /// `upgrade`, with no app's own sockets to leave a request to.
    pub fn onWsUpgrade(self: *Host, req: *event_loop.WsRequest, path: []const u8) void {
        if (!self.upgrade(req, path)) req.reject(404);
    }

    pub fn onWsMessage(self: *Host, conn: *event_loop.WsConn, data: []const u8, kind: WebSocket.Kind) void {
        _ = self.message(conn, data, kind);
    }

    pub fn onWsClose(self: *Host, conn: *event_loop.WsConn, code: u16, reason: []const u8) void {
        _ = self.closed(conn, code, reason);
    }

    pub fn onHttpHead(self: *Host, ex: *Exchange) void {
        const method = std.meta.stringToEnum(context.Method, ex.method) orelse return ex.pass();
        // Routed on the head's own slices: a request no route has costs nothing.
        const head: context.Request = .{ .method = method, .target = ex.target, .headers = ex.headers };
        const found = self.router.find(&head) orelse return ex.pass();
        const p = self.acquire() catch return ex.abort();
        const arena = p.arena;
        p.* = .{ .arena = arena, .pool = self.pendings, .ex = ex, .call = .{ .request = head, .response = undefined }, .found = found, .content_length = ex.content_length };
        const a = p.arena.allocator();
        p.call.response = .init(a);
        p.call.request = copyHead(a, &head) catch return fail(p, 500);
        p.call.request.client = address.clientOf(ex.peerAddress(), head.headers, self.trusted_proxies);
        ex.user_data = p;
        if (p.found.before(&p.call)) return answer(p);
        const target = found.target orelse {
            found.run(&p.call);
            return answer(p);
        };
        if ((ex.content_length orelse 0) > target.max_body) return fail(p, 413);
        if (target.streams_body) {
            const reader = a.create(BodyReader) catch return fail(p, 500);
            reader.* = .{ .io = target.runs_on.?.io };
            p.call.body = reader;
            return spawn(p, target.runs_on.?);
        }
        if (ex.content_length) |n| p.body.ensureTotalCapacityPrecise(a, @min(n, eager_body)) catch return fail(p, 500);
    }

    pub fn onHttpBody(_: *Host, ex: *Exchange, data: []const u8) void {
        const p = pendingOf(ex) orelse return;
        if (p.call.body) |reader| {
            if (reader.ended) return;
            p.streamed_len += data.len;
            if (p.streamed_len > p.found.target.?.max_body) return reader.end(error.PayloadTooLarge);
            reader.push(data) catch reader.end(error.OutOfMemory);
            return;
        }
        const a = p.arena.allocator();
        const len = p.body.items.len + data.len;
        if (len > p.found.target.?.max_body) return fail(p, 413);
        // Past what the head reserved: once to its whole length, not by halves in the arena.
        if (len > p.body.capacity) if (p.content_length) |n| p.body.ensureTotalCapacityPrecise(a, @max(n, len)) catch return fail(p, 500);
        p.body.appendSlice(a, data) catch fail(p, 500);
    }

    pub fn onHttpEnd(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        if (p.call.body) |reader| return reader.end(null);
        p.call.request.body = p.body.items;
        if (p.found.target.?.runs_on) |r| return spawn(p, r);
        p.found.run(&p.call);
        answer(p);
    }

    /// What a blocking handler's stream wrote has been read: it may write more.
    pub fn onHttpWritable(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        giveRoom(p, false);
    }

    pub fn onHttpGone(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        p.ex = null;
        giveRoom(p, true);
        if (p.call.body) |reader| reader.end(error.Closed);
        // Still running: cancel it. Otherwise its `done` is on the way.
        if (p.off) |off| {
            if (off.task.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null) off.reaper.end(&off.task);
            return;
        }
        release(p);
    }

    /// The handler as a task on `r.io`. Two posts come back: `done` when it
    /// returns, `task.reaped` when the reaper has collected it.
    fn spawn(p: *Pending, r: *Reaper) void {
        const mailbox = p.ex.?.mailbox orelse return fail(p, 503);
        const target = p.found.target.?;
        if (target.gate) |g| if (!g.enter()) return fail(p, 503);
        const off = p.arena.allocator().create(OffLoop) catch return fail(p, 500);
        off.* = .{ .p = p, .reaper = r, .stream = .{ .call = &p.call, .post = .{ .run = streamOnLoop } }, .task = .{
            .mailbox = mailbox,
            .reaped = .{ .run = reapedOffLoop },
            .deadline = if (target.deadline_ns) |ns| .fromNow(r.io, .{ .raw = .fromNanoseconds(ns), .clock = .awake }) else null,
        } };
        mailbox.expect(); // done
        mailbox.expect(); // task.reaped
        p.call.io = r.io;
        p.call.loop = mailbox;
        p.call.stream = &off.stream;
        // Not `io.async`: with no thread free, Threaded runs that here, on the loop.
        off.task.future = r.io.concurrent(runOffLoop, .{off}) catch {
            mailbox.forget();
            mailbox.forget();
            p.call.io = .failing;
            p.call.loop = null;
            p.call.stream = null;
            if (target.gate) |g| g.leave();
            return fail(p, 503);
        };
        p.off = off;
        if (off.task.deadline != null) r.arm(&off.task);
    }

    fn runOffLoop(off: *OffLoop) void {
        const p = off.p;
        const gate = p.found.target.?.gate;
        const result = if (gate) |g| gated(g, p) else p.found.call(&p.call);
        if (gate) |g| g.leave();
        // Lost to the deadline or the client: the answer is the reaper's, or nobody's.
        if (off.task.state.cmpxchgStrong(.running, .finished, .acq_rel, .acquire) == null) {
            result catch |err| {
                off.failed = true;
                p.found.failWith(&p.call, err);
            };
        }
        off.task.mailbox.post(&off.done);
    }

    /// The handler, once one of the gate's runs is free; waiting, it's canceled as it would be running.
    fn gated(g: *router_mod.Gate, p: *Pending) anyerror!void {
        try g.running.wait(p.call.io);
        defer g.running.post(p.call.io);
        return p.found.call(&p.call);
    }

    fn doneOffLoop(post: *Mailbox.Post) void {
        const off: *OffLoop = @alignCast(@fieldParentPtr("done", post));
        const p = off.p;
        p.call.io = .failing; // `after` runs here, on the loop
        p.call.loop = null;
        const state = off.task.state.load(.acquire);
        if (p.call.response.streamed) {
            // Its head is out: finished whole, or cut off so the client can tell.
            if (p.ex) |ex| {
                ex.user_data = null;
                if (state == .finished and !off.failed) ex.finish() else ex.abort();
            }
            if (state == .finished) off.reaper.end(&off.task);
            return;
        }
        switch (state) {
            .running => unreachable,
            .finished => {
                respond(p);
                off.reaper.end(&off.task);
            },
            .timed_out => {
                p.call.response.reset();
                p.call.response.fail(504);
                respond(p);
            },
            .abandoned => {},
        }
    }

    /// A stream's trip: its head the first time, then its pieces, on the loop.
    fn streamOnLoop(post: *Mailbox.Post) void {
        const s: *Stream = @alignCast(@fieldParentPtr("post", post));
        const p: *Pending = @alignCast(@fieldParentPtr("call", s.call));
        defer s.taken.set(p.call.io);
        pour(p, s) catch {
            s.closed = true;
        };
        if (!s.closed and p.ex.?.bufferedAmount() >= writable_mark) s.room_owed = true else s.room.set(p.call.io);
    }

    fn pour(p: *Pending, s: *Stream) !void {
        const ex = p.ex orelse return error.Closed;
        const res = &p.call.response;
        if (!res.streamed) {
            res.streamed = true;
            res.answered = true;
            var one: [1]context.Header = undefined;
            try ex.sendHead(res.status, try headOf(p, &one), null);
        }
        // One write, one chunk, for what fits here: an event is a handful of pieces.
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        for (s.pieces) |piece| {
            if (len + piece.len > buf.len) {
                if (len > 0) try ex.write(buf[0..len]);
                len = 0;
                if (piece.len > buf.len) {
                    try ex.write(piece);
                    continue;
                }
            }
            @memcpy(buf[len..][0..piece.len], piece);
            len += piece.len;
        }
        if (len > 0) try ex.write(buf[0..len]);
    }

    /// The stream's client caught up, or left: its writer goes on.
    fn giveRoom(p: *Pending, gone: bool) void {
        const s = p.call.stream orelse return;
        if (!s.room_owed) return;
        s.room_owed = false;
        s.closed = gone;
        s.room.set(p.call.io);
    }

    fn reapedOffLoop(post: *Mailbox.Post) void {
        const t: *reaper_mod.Task = @alignCast(@fieldParentPtr("reaped", post));
        const off: *OffLoop = @alignCast(@fieldParentPtr("task", t));
        release(off.p);
    }

    fn pendingOf(ex: *Exchange) ?*Pending {
        return @ptrCast(@alignCast(ex.user_data orelse return null));
    }

    fn fail(p: *Pending, status: u16) void {
        p.call.response.fail(status);
        answer(p);
    }

    /// Sends the answer, then frees the request.
    fn answer(p: *Pending) void {
        respond(p);
        release(p);
    }

    /// Sends the answer, its middleware's `after` first, unless the client left.
    fn respond(p: *Pending) void {
        const ex = p.ex orelse return;
        ex.user_data = null;
        const res = &p.call.response;
        var one: [1]context.Header = undefined;
        ex.respond(res.status, headOf(p, &one) catch return ex.abort(), res.body);
    }

    /// The answer's headers, `after` middleware's included, its Content-Type
    /// first when it has one. Only Content-Type: in `one`, which the
    /// transport encodes before returning, as it does all of them.
    fn headOf(p: *Pending, one: *[1]context.Header) ![]const context.Header {
        for (p.found.middleware()) |m| if (m.after) |after| after(m.ctx, &p.call);
        const res = &p.call.response;
        if (res.headers.items.len == 0) {
            one[0] = .{ .name = "Content-Type", .value = res.content_type orelse return &.{} };
            return one;
        }
        const headers = try p.arena.allocator().alloc(context.Header, res.headers.items.len + 1);
        headers[0] = .{ .name = "Content-Type", .value = res.content_type orelse "" };
        @memcpy(headers[1..], res.headers.items);
        return if (res.content_type == null) headers[1..] else headers;
    }

    /// A request's state: one released before, its arena kept, or a new one.
    fn acquire(self: *Host) !*Pending {
        if (self.pendings) |pool| if (pool.pop()) |p| return p;
        const p = try self.gpa.create(Pending);
        p.arena = .init(self.gpa);
        return p;
    }

    /// Only once nothing holds it: a blocking handler's task is reaped first.
    fn release(p: *Pending) void {
        if (p.call.body) |reader| reader.deinit();
        if (p.pool) |pool| if (pool.keep(p)) return;
        p.destroy();
    }
};

/// Requests' state, kept between them so a request costs no allocation
/// (`Host.pendings`). The app keeps it, one per loop: a `Host` may live no
/// longer than a callback. The Hosts sharing one share their `gpa`.
pub const Pendings = struct {
    free: ?*Host.Pending = null,
    len: u32 = 0,
    /// At most this many kept; past it, a request's state is freed.
    max: u32 = 256,

    /// What each keeps of its arena: past it, a large request's memory is freed.
    const kept_bytes = 8 * 1024 - 64; // with the arena's header, inside smp_allocator's 8 KiB class

    /// Once its server has stopped, every request released.
    pub fn deinit(self: *Pendings) void {
        while (self.pop()) |p| p.destroy();
    }

    fn pop(self: *Pendings) ?*Host.Pending {
        const p = self.free orelse return null;
        self.free = p.next;
        self.len -= 1;
        return p;
    }

    /// False when it's full: the caller frees `p`.
    fn keep(self: *Pendings, p: *Host.Pending) bool {
        if (self.len == self.max) return false;
        _ = p.arena.reset(.{ .retain_with_limit = kept_bytes });
        p.next = self.free;
        self.free = p;
        self.len += 1;
        return true;
    }
};

/// `head`'s target and headers, copied into one allocation of `a`.
fn copyHead(a: std.mem.Allocator, head: *const context.Request) !context.Request {
    var size = head.target.len;
    for (head.headers) |h| size += h.name.len + h.value.len;
    const array = head.headers.len * @sizeOf(context.Header);
    const block = try a.alignedAlloc(u8, .of(context.Header), array + size);
    const headers = std.mem.bytesAsSlice(context.Header, block[0..array]);
    var bytes: []u8 = block[array..];
    const target = take(&bytes, head.target);
    for (head.headers, headers) |h, *out| out.* = .{ .name = take(&bytes, h.name), .value = take(&bytes, h.value) };
    return .{ .method = head.method, .target = target, .headers = headers };
}

fn take(bytes: *[]u8, s: []const u8) []const u8 {
    @memcpy(bytes.*[0..s.len], s);
    defer bytes.* = bytes.*[s.len..];
    return bytes.*[0..s.len];
}
