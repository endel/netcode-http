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
        /// Null once the client is gone, while offloaded work still holds it.
        ex: ?*Exchange,
        req: context.Request,
        res: context.Response,
        found: router_mod.Found,
        body: std.ArrayList(u8) = .empty,
        content_length: ?u64,
        /// A blocking handler's task done, back on the loop.
        post: Mailbox.Post = .{ .run = doneOffLoop },
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
        p.* = .{ .arena = .init(self.gpa), .ex = ex, .req = head, .res = undefined, .found = found, .content_length = ex.content_length };
        const a = p.arena.allocator();
        p.res = .init(a);
        if (ex.mailbox) |m| p.res.late = .{ .ctx = p, .send = sendLater, .mailbox = m };
        p.req = copyHead(a, &head) catch return fail(p, 500);
        p.req.client = address.clientOf(ex.peerAddress(), head.headers, self.trusted_proxies);
        p.found.rebase(head.target, p.req.target);
        ex.user_data = p;
        for (found.middleware()) |m| if (m.before) |before| {
            before(m.ctx, &p.req, &p.res);
            if (p.res.answered) return answer(p);
        };
        const target = found.target orelse {
            found.run(&p.req, &p.res);
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
        p.req.body = p.body.items;
        if (p.found.target.?.runs_on) |b| return spawn(p, b);
        p.found.run(&p.req, &p.res);
        if (!p.res.deferred) answer(p);
    }

    pub fn onHttpGone(_: *Host, ex: *Exchange) void {
        const p = pendingOf(ex) orelse return;
        p.ex = null;
        // Work still offloaded, or a task still running, frees it once it answers.
        if (!p.res.deferred and !p.res.off_loop) release(p);
    }

    /// The handler as a task on `b.io`; its answer comes back through the mailbox.
    fn spawn(p: *Pending, b: *Router.Blocking) void {
        const late = p.res.late orelse return fail(p, 503);
        late.mailbox.expect();
        p.res.off_loop = true;
        // Not `io.async`: with no thread free, Threaded runs that here, on the loop.
        b.group.concurrent(b.io, runOffLoop, .{p}) catch {
            late.mailbox.forget();
            p.res.off_loop = false;
            return fail(p, 503);
        };
    }

    fn runOffLoop(p: *Pending) void {
        p.found.run(&p.req, &p.res);
        p.res.late.?.mailbox.post(&p.post);
    }

    fn doneOffLoop(post: *Mailbox.Post) void {
        answer(@fieldParentPtr("post", post));
    }

    fn pendingOf(ex: *Exchange) ?*Pending {
        return @ptrCast(@alignCast(ex.user_data orelse return null));
    }

    /// Offloaded work's answer, on the loop's thread.
    fn sendLater(ctx: *anyopaque) void {
        answer(@ptrCast(@alignCast(ctx)));
    }

    fn fail(p: *Pending, status: u16) void {
        p.res.fail(status);
        answer(p);
    }

    /// Sends the answer, its middleware's `after` first, then frees the request.
    fn answer(p: *Pending) void {
        defer release(p);
        const ex = p.ex orelse return;
        ex.user_data = null;
        const res = &p.res;
        for (p.found.middleware()) |m| if (m.after) |after| after(m.ctx, &p.req, res);
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
