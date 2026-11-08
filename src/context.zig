//! A request as a handler sees it, and the answer it builds.

const std = @import("std");
const parser = @import("quic").http1.parser;
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

    pub fn init(arena: std.mem.Allocator) Response {
        return .{ .arena = arena };
    }

    /// Unanswered again, its headers dropped: for an answer that replaces
    /// whatever was built so far.
    pub fn reset(self: *Response) void {
        self.* = .{ .arena = self.arena };
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

    /// `r` as the answer, its body not copied. A header that isn't a valid
    /// field fails it, keeping only the headers set before.
    pub fn reply(self: *Response, r: Reply) !void {
        const kept = self.headers.items.len;
        for (r.headers) |h| self.setHeader(h.name, h.value) catch |err| {
            self.headers.shrinkRetainingCapacity(kept);
            return err;
        };
        self.sendOwned(r.status, r.content_type, r.body);
    }

    /// `status` as a problem (RFC 9457) with no more to say than its title.
    pub fn fail(self: *Response, status: u16) void {
        self.problem(status, null);
    }

    /// `status` as an RFC 9457 problem: `application/problem+json` with its
    /// reason phrase as the title, and `detail` when there is one.
    pub fn problem(self: *Response, status: u16, detail: ?[]const u8) void {
        if (self.answered) return;
        const p: endpoint.Problem = .{ .title = parser.reason(status), .status = status, .detail = detail };
        const body = std.fmt.allocPrint(self.arena, "{f}", .{std.json.fmt(p, .{ .emit_null_optional_fields = false })}) catch "";
        self.answer(status, "application/problem+json", body);
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
    /// While a blocking handler runs: its loop's Mailbox (`Context.onLoop`).
    /// The request's `done` is owed meanwhile, so its watch is on and an
    /// `expect` off the loop only counts.
    loop: ?*Mailbox = null,
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

        /// Answers `status` as a problem whose detail is `fmt` with `args`,
        /// for the handler to return: `return ctx.problem(409, "seat {d} taken", .{n});`.
        pub fn problem(self: *Self, status: u16, comptime fmt: []const u8, args: anytype) error{Answered} {
            self.response.problem(status, std.fmt.allocPrint(self.arena, fmt, args) catch null);
            return error.Answered;
        }

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
            const loop = self.call.loop orelse return @call(.auto, func, args);
            var job: OnLoop(func) = .{ .args = args, .io = self.io };
            loop.expect(); // off the loop: see `Call.loop`
            loop.post(&job.post);
            job.done.wait(self.io) catch |err| {
                job.done.waitUncancelable(self.io); // `job` is on this stack
                return err;
            };
            return job.result;
        }
    };
}

/// An answer whole: what a handler returns to pick its status, type and
/// headers, rather than answer through its context.
pub const Reply = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    /// Not copied: in the request's arena, or outliving it.
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
