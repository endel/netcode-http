//! A blocking handler's streams: its answer as it's made (`Stream`), and
//! events over it (`Events`); a request's body as it arrives (`BodyReader`).

const std = @import("std");
const Mailbox = @import("quic").Mailbox;
const Call = @import("context.zig").Call;

/// A blocking handler's answer as it's made (`Context.stream`): its head,
/// then each `write`, one trip to the loop, waiting while the client is
/// behind. It ends when the handler returns; an error from it, or a
/// deadline passed, cuts it off, so the client can tell.
pub const Stream = struct {
    call: *Call,
    /// Run on the loop by the transport (`Host`): takes `pieces`, then sets
    /// `taken`, and `room` once the client can take more.
    post: Mailbox.Post,
    pieces: []const []const u8 = &.{},
    taken: std.Io.Event = .unset,
    room: std.Io.Event = .unset,
    /// The client left, or the head couldn't go: set before either event.
    closed: bool = false,
    /// A wait was canceled: the stream is done for.
    broken: bool = false,
    /// The loop's own: the client is behind, and `onHttpWritable` will say when it isn't.
    room_owed: bool = false,
    /// What a `writer`'s `error.WriteFailed` was.
    err: ?anyerror = null,

    pub fn write(self: *Stream, bytes: []const u8) !void {
        return self.writeAll(&.{bytes});
    }

    /// `pieces` in one trip to the loop.
    pub fn writeAll(self: *Stream, pieces: []const []const u8) !void {
        if (self.broken) return error.Canceled;
        self.pieces = pieces;
        self.taken = .unset;
        self.room = .unset;
        const loop = self.call.loop.?;
        loop.expect(); // off the loop: see `Call.loop`
        loop.post(&self.post);
        self.taken.waitUncancelable(self.call.io); // a loop turn: `pieces` are the caller's till then
        self.room.wait(self.call.io) catch |err| {
            self.broken = true;
            return err;
        };
        if (self.closed) return error.Closed;
    }

    /// `print`, JSON and the like gather in `buf`, and go in a trip when it
    /// fills or on `flush`. Its `error.WriteFailed` is `err`.
    pub fn writer(self: *Stream, buf: []u8) Writer {
        return .{ .stream = self, .interface = .{ .vtable = &.{ .drain = Writer.drain }, .buffer = buf } };
    }

    pub const Writer = struct {
        stream: *Stream,
        interface: std.Io.Writer,

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            var pieces: [16][]const u8 = undefined;
            pieces[0] = w.buffered();
            var n: usize = 1;
            var taken: usize = 0;
            const head = data[0 .. data.len - 1];
            for (head) |d| {
                if (n == pieces.len) break;
                pieces[n] = d;
                n += 1;
                taken += d.len;
            } else for (0..splat) |_| {
                if (n == pieces.len) break;
                pieces[n] = data[data.len - 1];
                n += 1;
                taken += data[data.len - 1].len;
            }
            self.stream.writeAll(pieces[0..n]) catch |err| {
                self.stream.err = err;
                return error.WriteFailed;
            };
            w.end = 0;
            return taken;
        }
    };
};

/// A body as it arrives (`endpoint.BodyStream`): the loop queues its
/// pieces, a blocking handler reads them. Each is its own allocation, freed
/// once read, so a reader that keeps up holds little of a large upload.
pub const BodyReader = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Piece = null,
    tail: ?*Piece = null,
    /// Into `head`, read so far.
    at: usize = 0,
    ended: bool = false,
    failed: ?anyerror = null,

    /// Its bytes follow it in the same allocation, from `smp_allocator`:
    /// queued on the loop, freed on the reader's thread.
    const Piece = struct {
        next: ?*Piece = null,
        len: usize,

        fn bytes(p: *Piece) []u8 {
            const base: [*]u8 = @ptrCast(p);
            return (base + @sizeOf(Piece))[0..p.len];
        }

        fn free(p: *Piece) void {
            const base: [*]align(@alignOf(Piece)) u8 = @ptrCast(p);
            std.heap.smp_allocator.free(base[0 .. @sizeOf(Piece) + p.len]);
        }
    };

    /// Up to `buf.len` bytes, waiting for some; 0 once the body has ended.
    /// The client leaving or the deadline cancels the wait.
    pub fn read(self: *BodyReader, buf: []u8) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.head == null) {
            if (self.failed) |err| return err;
            if (self.ended) return 0;
            try self.cond.wait(self.io, &self.mutex);
        }
        const p = self.head.?;
        const n = @min(buf.len, p.len - self.at);
        @memcpy(buf[0..n], p.bytes()[self.at..][0..n]);
        self.at += n;
        if (self.at == p.len) {
            self.head = p.next;
            if (self.head == null) self.tail = null;
            self.at = 0;
            p.free();
        }
        return n;
    }

    /// On the loop: `data` queued for the reader.
    pub fn push(self: *BodyReader, data: []const u8) !void {
        const raw = try std.heap.smp_allocator.alignedAlloc(u8, .of(Piece), @sizeOf(Piece) + data.len);
        const p: *Piece = @ptrCast(raw.ptr);
        p.* = .{ .len = data.len };
        @memcpy(p.bytes(), data);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.tail) |t| t.next = p else self.head = p;
        self.tail = p;
        self.cond.signal(self.io);
    }

    /// On the loop: the body ended, or failed with `err`.
    pub fn end(self: *BodyReader, err: ?anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ended = true;
        if (self.failed == null) self.failed = err;
        self.cond.signal(self.io);
    }

    /// Once nothing reads it: what's left freed.
    pub fn deinit(self: *BodyReader) void {
        while (self.head) |p| {
            self.head = p.next;
            p.free();
        }
    }
};

/// Server-sent events (`text/event-stream`), from a blocking handler (`Context.events`).
pub const Events = struct {
    stream: *Stream,

    /// An event, `name` null for a plain message; each line of `data` its
    /// own `data:`. One trip, unless it has more than 20 lines.
    pub fn send(self: Events, name: ?[]const u8, data: []const u8) !void {
        var pieces: [64][]const u8 = undefined;
        var n: usize = 0;
        if (name) |e| {
            pieces[0..3].* = .{ "event: ", e, "\n" };
            n = 3;
        }
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (n + 4 > pieces.len) {
                try self.stream.writeAll(pieces[0..n]);
                n = 0;
            }
            pieces[n..][0..3].* = .{ "data: ", line, "\n" };
            n += 3;
        }
        pieces[n] = "\n";
        try self.stream.writeAll(pieces[0 .. n + 1]);
    }

    /// `: text`, which events' readers skip: keeps a quiet stream from
    /// looking dead to a proxy.
    pub fn comment(self: Events, text: []const u8) !void {
        return self.stream.writeAll(&.{ ": ", text, "\n\n" });
    }
};
