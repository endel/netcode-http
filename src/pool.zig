//! Work that would block an event loop, done on threads of its own: a
//! handler hands it over (`ctx.offload`), and its result answers the
//! request back on the loop's thread, through the loop's `quic.Mailbox`.

const std = @import("std");
const Mailbox = @import("quic").Mailbox;

/// One piece of work: `work` runs on a pool thread, then `post` back on
/// the loop's, which frees it.
pub const Job = struct {
    work: *const fn (*Job) void,
    post: Mailbox.Post,
    mailbox: *Mailbox,
    next: ?*Job = null,
};

const Queue = struct {
    head: ?*Job = null,
    tail: ?*Job = null,
    len: u32 = 0,

    fn push(q: *Queue, j: *Job) void {
        j.next = null;
        if (q.tail) |t| t.next = j else q.head = j;
        q.tail = j;
        q.len += 1;
    }

    fn pop(q: *Queue) ?*Job {
        const j = q.head orelse return null;
        q.head = j.next;
        if (q.head == null) q.tail = null;
        q.len -= 1;
        return j;
    }
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: Queue = .{},
    max_queued: u32,
    stopping: bool = false,
    threads: []std.Thread = &.{},

    pub const Options = struct {
        threads: u16 = 1,
        /// Jobs waiting for a thread, past which `submit` refuses more:
        /// a request is turned away (503) rather than kept behind minutes of work.
        max_queued: u32 = 64,
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Pool {
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .max_queued = opts.max_queued };
        self.threads = try gpa.alloc(std.Thread, @max(opts.threads, 1));
        errdefer gpa.free(self.threads);
        var started: usize = 0;
        errdefer {
            self.stop();
            for (self.threads[0..started]) |t| t.join();
        }
        while (started < self.threads.len) : (started += 1) {
            self.threads[started] = try std.Thread.spawn(.{}, run, .{self});
        }
        return self;
    }

    /// Finishes the jobs queued, then joins the threads.
    pub fn destroy(self: *Pool) void {
        self.stop();
        for (self.threads) |t| t.join();
        self.gpa.free(self.threads);
        self.gpa.destroy(self);
    }

    fn stop(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// False when the queue is full: the job is the caller's again.
    pub fn submit(self: *Pool, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.queue.len >= self.max_queued) return false;
        self.queue.push(job);
        self.cond.signal(self.io);
        return true;
    }

    fn run(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue.head == null and !self.stopping) self.cond.waitUncancelable(self.io, &self.mutex);
            const job = self.queue.pop();
            self.mutex.unlock(self.io);
            const j = job orelse return;
            j.work(j);
            j.mailbox.post(&j.post);
        }
    }
};
