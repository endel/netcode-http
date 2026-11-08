//! A request as a handler sees it, and the answer it builds.

const std = @import("std");
const parser = @import("quic").http1.parser;
const pool = @import("pool.zig");
const json_mod = @import("json.zig");
const Mailbox = @import("quic").Mailbox;
const Address = @import("address.zig").Address;

const endpoint = @import("endpoint");
pub const Method = endpoint.Method;

pub const Header = parser.Header;

/// What arrived. Its slices last as long as the request.
pub const Request = struct {
    method: Method,
    /// Path and query, as received.
    target: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Who sent it: the peer, or behind a trusted proxy the client it names
    /// (`Host.trusted_proxies`).
    client: Address = .{},

    pub fn path(self: *const Request) []const u8 {
        return self.target[0 .. std.mem.indexOfScalar(u8, self.target, '?') orelse self.target.len];
    }

    /// What follows `?`, still encoded; empty without one.
    pub fn rawQuery(self: *const Request) []const u8 {
        const q = std.mem.indexOfScalar(u8, self.target, '?') orelse return "";
        return self.target[q + 1 ..];
    }

    /// The first header named `name`, matched ignoring case.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return parser.getHeader(self.headers, name);
    }
};

pub const statusOf = endpoint.statusOf;

/// The answer, built in the request's arena. The first one sent stands.
pub const Response = struct {
    arena: std.mem.Allocator,
    status: u16 = 204,
    content_type: ?[]const u8 = null,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",
    answered: bool = false,
    /// Its answer comes from work offloaded (`Context.offload`).
    deferred: bool = false,
    /// Its handler runs as a task off the loop (`Scope.blocking`).
    off_loop: bool = false,
    /// Set by a transport that can answer after the handler returns.
    late: ?Late = null,

    pub const Late = struct {
        ctx: *anyopaque,
        /// The answer is in `Response`: send it, on the loop's thread.
        send: *const fn (ctx: *anyopaque) void,
        /// Where offloaded work comes back to.
        mailbox: *Mailbox,
        /// From a blocking handler's task: `post` run on the loop's thread.
        to_loop: *const fn (ctx: *anyopaque, post: *Mailbox.Post) void,
    };

    pub fn init(arena: std.mem.Allocator) Response {
        return .{ .arena = arena };
    }

    /// Unanswered again, its headers dropped: for an answer that replaces
    /// whatever was built so far.
    pub fn reset(self: *Response) void {
        self.* = .{ .arena = self.arena, .late = self.late };
    }

    /// Adds a header to the answer. One that isn't a valid field is
    /// refused: a line break in it would let it add headers of its own.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (!parser.isToken(name) or !parser.isFieldValue(value)) return error.InvalidHeader;
        try self.headers.append(self.arena, .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.arena.dupe(u8, value),
        });
    }

    /// `body` is copied: it may live on the handler's stack.
    pub fn send(self: *Response, status: u16, content_type: []const u8, body: []const u8) !void {
        if (self.answered) return;
        self.answer(status, content_type, try self.arena.dupe(u8, body));
    }

    /// `send` of a body that outlives the answer, the request's arena's say:
    /// not copied.
    pub fn sendOwned(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        if (self.answered) return;
        self.answer(status, content_type, body);
    }

    pub fn json(self: *Response, status: u16, value: anytype) !void {
        if (self.answered) return;
        var out: std.Io.Writer.Allocating = try .initCapacity(self.arena, 256);
        json_mod.write(&out.writer, value) catch return error.OutOfMemory;
        self.answer(status, "application/json", out.written());
    }

    /// `status` with its reason phrase as the body.
    pub fn fail(self: *Response, status: u16) void {
        if (self.answered) return;
        self.answer(status, "text/plain; charset=utf-8", std.fmt.allocPrint(self.arena, "{s}\n", .{parser.reason(status)}) catch "");
    }

    fn answer(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        self.status = status;
        self.content_type = content_type;
        self.body = body;
        self.answered = true;
    }
};

/// A request and its answer on their way through middleware to the handler:
/// what all of them share.
pub const Call = struct {
    request: Request,
    response: Response,
    /// The handler's: a blocking scope's `Io`, `std.Io.failing` on the loop.
    io: std.Io = .failing,
    /// What middleware left for the handler, one per type, in the arena.
    locals: ?*Local = null,

    const Local = struct { key: *const anyopaque, value: *anyopaque, next: ?*Local };

    /// Leaves `value` for the handler (`Context.local`), and for middleware
    /// later on the way; another `T` overwrites it.
    pub fn setLocal(self: *Call, comptime T: type, value: T) !void {
        if (self.local(T)) |slot| {
            slot.* = value;
            return;
        }
        const a = self.response.arena;
        const slot = try a.create(T);
        slot.* = value;
        const l = try a.create(Local);
        l.* = .{ .key = typeKey(T), .value = slot, .next = self.locals };
        self.locals = l;
    }

    /// The `T` middleware left, if any.
    pub fn local(self: *const Call, comptime T: type) ?*T {
        var it = self.locals;
        while (it) |l| : (it = l.next) if (l.key == typeKey(T)) return @ptrCast(@alignCast(l.value));
        return null;
    }
};

/// An address of `T`'s own: what a local is found by.
fn typeKey(comptime T: type) *const anyopaque {
    return &struct {
        const of = T; // the capture makes each T its own struct, and key
        var key: u8 = 0;
    }.key;
}

pub const Spec = endpoint.Spec;

/// A handler's view of its request: `params`, `query` and `body` decoded
/// as `spec` says, and the answer it sends.
pub fn Context(comptime spec: Spec) type {
    return struct {
        const Self = @This();
        pub const web_spec = spec;

        params: spec.params,
        query: spec.query,
        body: spec.body,
        request: *const Request,
        response: *Response,
        /// Freed once the request is answered.
        arena: std.mem.Allocator,
        call: *Call,
        /// What the handler does its I/O with: its scope's in a `blocking`
        /// one. On the loop it's `std.Io.failing`, so I/O fails there rather
        /// than stall the loop; time and randomness from it are zeros.
        io: std.Io,

        /// The `T` middleware left (`Call.setLocal`), if any.
        pub fn local(self: *Self, comptime T: type) ?*T {
            return self.call.local(T);
        }

        pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
            return self.response.setHeader(name, value);
        }

        pub fn send(self: *Self, status: u16, content_type: []const u8, body: []const u8) !void {
            return self.response.send(status, content_type, body);
        }

        pub fn text(self: *Self, status: u16, body: []const u8) !void {
            return self.response.send(status, "text/plain; charset=utf-8", body);
        }

        pub fn json(self: *Self, status: u16, value: anytype) !void {
            return self.response.json(status, value);
        }

        /// `send`, of a body that outlives the answer: not copied.
        pub fn sendOwned(self: *Self, status: u16, content_type: []const u8, body: []const u8) void {
            self.response.sendOwned(status, content_type, body);
        }

        /// `func(args)` on the event loop's thread, and what it returns: a
        /// blocking handler's way to the loop's state, a game's say, without
        /// locks. Waits for it; canceled meanwhile, the handler still waits
        /// for `func` to run, then gets `error.Canceled`. On the loop it's a call.
        pub fn onLoop(self: *Self, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) OnLoop(func).Result {
            const res = self.response;
            if (!res.off_loop) return @call(.auto, func, args);
            var job: OnLoop(func) = .{ .args = args, .io = self.io };
            const late = res.late.?;
            late.to_loop(late.ctx, &job.post);
            job.done.wait(self.io) catch |err| {
                job.done.waitUncancelable(self.io); // `job` is on this stack
                return err;
            };
            return job.result;
        }

        /// `func(args)` on one of `on`'s threads, whose result answers back
        /// on the loop: a `Reply` as it is, anything else as JSON (204 for
        /// `void`), an error with its status. The request (its arena, body
        /// and params) stays until then, so `args` may point into it. A full
        /// pool is `error.ServiceUnavailable`. A handler in a `blocking`
        /// scope is off the loop already: it calls `func` itself.
        pub fn offload(self: *Self, on: *pool.Pool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
            const res = self.response;
            if (res.off_loop) return error.AlreadyOffLoop;
            const late = res.late orelse return error.ServiceUnavailable;
            const J = Offload(func);
            const job = try res.arena.create(J);
            job.* = .{ .job = .{ .work = J.work, .post = .{ .run = J.done }, .mailbox = late.mailbox }, .res = res, .args = args };
            late.mailbox.expect();
            if (!on.submit(&job.job)) {
                late.mailbox.forget();
                return error.ServiceUnavailable;
            }
            res.deferred = true;
        }
    };
}

/// An answer whole, for offloaded work that picks its own status and body.
pub const Reply = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8,
    /// Each checked as `Response.setHeader` checks it: one that isn't a
    /// valid field fails the answer with 500.
    headers: []const Header = &.{},
};

fn OnLoop(comptime func: anytype) type {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return struct {
        post: Mailbox.Post = .{ .run = run },
        args: std.meta.ArgsTuple(@TypeOf(func)),
        io: std.Io,
        result: R = undefined,
        done: std.Io.Event = .unset,

        /// What `Context.onLoop` returns: `func`'s result, and its errors and the wait's.
        pub const Result = switch (@typeInfo(R)) {
            .error_union => |eu| (eu.error_set || std.Io.Cancelable)!eu.payload,
            else => std.Io.Cancelable!R,
        };

        /// On the loop's thread.
        fn run(p: *Mailbox.Post) void {
            const self: *@This() = @alignCast(@fieldParentPtr("post", p));
            self.result = @call(.auto, func, self.args);
            self.done.set(self.io);
        }
    };
}

fn Offload(comptime func: anytype) type {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return struct {
        job: pool.Job,
        res: *Response,
        args: std.meta.ArgsTuple(@TypeOf(func)),
        result: R = undefined,

        fn work(j: *pool.Job) void {
            const self: *@This() = @fieldParentPtr("job", j);
            self.result = @call(.auto, func, self.args);
        }

        /// On the loop's thread. The job lives in the request's arena,
        /// which sending the answer frees.
        fn done(p: *Mailbox.Post) void {
            const j: *pool.Job = @fieldParentPtr("post", p);
            const self: *@This() = @fieldParentPtr("job", j);
            const res = self.res;
            defer res.late.?.send(res.late.?.ctx);
            const value = switch (@typeInfo(R)) {
                .error_union => self.result catch |err| return res.fail(statusOf(err)),
                else => self.result,
            };
            if (@TypeOf(value) == Reply) {
                for (value.headers) |h| res.setHeader(h.name, h.value) catch {
                    res.reset();
                    return res.fail(500);
                };
                return res.send(value.status, value.content_type, value.body) catch res.fail(500);
            }
            if (@TypeOf(value) != void) res.json(200, value) catch res.fail(500);
        }
    };
}

pub fn isContext(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "web_spec");
}


test "a header that would split the head is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var res: Response = .init(arena.allocator());
    try res.setHeader("X-Ok", "fine");
    try std.testing.expectError(error.InvalidHeader, res.setHeader("X-Bad", "a\r\nSet-Cookie: x"));
    try std.testing.expectError(error.InvalidHeader, res.setHeader("Bad Name", "a"));
    try std.testing.expectEqual(1, res.headers.items.len);
}
