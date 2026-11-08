//! A `Router` served from quic-zig's `onHttpHead` callbacks: HTTP/1.1 on the
//! TCP listener and HTTP/3 on QUIC alike. `Host` takes the callbacks' names,
//! so a server built on `http1.handlersFor` takes it as its handler, and an
//! embedding one passes its own on (README).
//!
//! A request no route has is passed on inside its head's callback: on
//! HTTP/1.1 to the static files or a 404, on HTTP/3 to a 404.

const std = @import("std");
const Exchange = @import("quic").event_loop.Exchange;
const Mailbox = @import("quic").Mailbox;
const reaper_mod = @import("reaper.zig");
const Reaper = reaper_mod.Reaper;
const context = @import("context.zig");
const router_mod = @import("router.zig");
const Router = router_mod.Router;
const address = @import("address.zig");

/// A body of known length is reserved up to this much at its head.
const eager_body = 1 << 20;

pub const Host = struct {
    router: *const Router,
    gpa: std.mem.Allocator,
    /// The proxies in front, such as routez: a request from one is the
    /// client its `X-Forwarded-For` names (`Request.client`). List every
    /// proxy on the way in, not just the nearest (`address.parseNetworks`).
    trusted_proxies: []const address.Network = &.{},

    /// A request's own, from its head to its answer.
    const Pending = struct {
        arena: std.heap.ArenaAllocator,
        /// Null once the client is gone, while a blocking handler still holds it.
        ex: ?*Exchange,
        call: context.Call,
        found: router_mod.Found,
        body: std.ArrayList(u8) = .empty,
        content_length: ?u64,
        /// A blocking handler's, once it's started.
        off: ?*OffLoop = null,
    };

    /// A blocking handler's task, in its request's arena. It posts `done`
    /// when the handler returns, and the reaper `task.reaped` once it's
    /// collected, which frees the request.
    const OffLoop = struct {
        p: *Pending,
        reaper: *Reaper,
        task: reaper_mod.Task,
        done: Mailbox.Post = .{ .run = doneOffLoop },
    };

    pub fn init(gpa: std.mem.Allocator, router: *const Router) Host {
        return .{ .router = router, .gpa = gpa };
    }

    pub fn onHttpHead(self: *Host, ex: *Exchange) void {
        const method = std.meta.stringToEnum(context.Method, ex.method) orelse return ex.pass();
        // Routed on the head's own slices: a request no route has costs nothing.
        const head: context.Request = .{ .method = method, .target = ex.target, .headers = ex.headers };
        const found = self.router.find(&head) orelse return ex.pass();
        const p = self.gpa.create(Pending) catch return ex.abort();
        p.* = .{ .arena = .init(self.gpa), .ex = ex, .call = .{ .request = head, .response = undefined }, .found = found, .content_length = ex.content_length };
        const a = p.arena.allocator();
        p.call.response = .init(a);
        p.call.request = copyHead(a, &head) catch return fail(p, 500);
        p.call.request.client = address.clientOf(ex.peerAddress(), head.headers, self.trusted_proxies);
        p.found.rebase(head.target, p.call.request.target);
        ex.user_data = p;
        for (found.middleware()) |m| if (m.before) |before| {
            before(m.ctx, &p.call) catch |err| p.found.failWith(&p.call, err);
            if (p.call.response.answered) return answer(p);
        };
        const target = found.target orelse {
            found.run(&p.call);
            return answer(p);
        };
        if ((ex.content_length orelse 0) > target.max_body) return fail(p, 413);
        if (ex.content_length) |n| p.body.ensureTotalCapacityPrecise(a, @min(n, eager_body)) catch return fail(p, 500);
    }

    pub fn onHttpBody(_: *Host, ex: *Exchange, data: []const u8) void {
        const p = pendingOf(ex) orelse return;
        const a = p.arena.allocator();
        const len = p.body.items.len + data.len;
        if (len > p.found.target.?.max_body) return fail(p, 413);
        // Past what the head reserved: once to its whole length, not by halves in the arena.
        if (len > p.body.capacity) if (p.content_length) |n| p.body.ensureTotalCapacityPrecise(a, @max(n, len)) catch return fail(p, 500);
        p.body.appendSlice(a, data) catch fail(p, 500);
    }

    pub fn onHttpEnd(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        p.call.request.body = p.body.items;
        if (p.found.target.?.runs_on) |r| return spawn(p, r);
        p.found.run(&p.call);
        answer(p);
    }

    pub fn onHttpGone(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        p.ex = null;
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
        off.* = .{ .p = p, .reaper = r, .task = .{
            .mailbox = mailbox,
            .reaped = .{ .run = reapedOffLoop },
            .deadline = if (target.deadline_ns) |ns| .fromNow(r.io, .{ .raw = .fromNanoseconds(ns), .clock = .awake }) else null,
        } };
        mailbox.expect(); // done
        mailbox.expect(); // task.reaped
        p.call.io = r.io;
        p.call.loop = mailbox;
        // Not `io.async`: with no thread free, Threaded runs that here, on the loop.
        off.task.future = r.io.concurrent(runOffLoop, .{off}) catch {
            mailbox.forget();
            mailbox.forget();
            p.call.io = .failing;
            p.call.loop = null;
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
            result catch |err| p.found.failWith(&p.call, err);
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
        switch (off.task.state.load(.acquire)) {
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
        for (p.found.middleware()) |m| if (m.after) |after| after(m.ctx, &p.call);
        const headers = p.arena.allocator().alloc(context.Header, res.headers.items.len + 1) catch return ex.abort();
        headers[0] = .{ .name = "Content-Type", .value = res.content_type orelse "" };
        @memcpy(headers[1..], res.headers.items);
        ex.respond(res.status, if (res.content_type == null) headers[1..] else headers, res.body);
    }

    fn release(p: *Pending) void {
        const gpa = p.arena.child_allocator;
        p.arena.deinit();
        gpa.destroy(p);
    }
};

/// `head`'s target and headers, copied into one allocation of `a`.
fn copyHead(a: std.mem.Allocator, head: *const context.Request) !context.Request {
    var size = head.target.len;
    for (head.headers) |h| size += h.name.len + h.value.len;
    var bytes = try a.alloc(u8, size);
    const headers = try a.alloc(context.Header, head.headers.len);
    const target = take(&bytes, head.target);
    for (head.headers, headers) |h, *out| out.* = .{ .name = take(&bytes, h.name), .value = take(&bytes, h.value) };
    return .{ .method = head.method, .target = target, .headers = headers };
}

fn take(bytes: *[]u8, s: []const u8) []const u8 {
    @memcpy(bytes.*[0..s.len], s);
    defer bytes.* = bytes.*[s.len..];
    return bytes.*[0..s.len];
}
