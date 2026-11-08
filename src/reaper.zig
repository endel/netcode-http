//! What a blocking handler's task needs off the loop, since every bit of it
//! may block: collecting the task once it's done, canceling one whose client
//! left or whose deadline passed. One thread per router and `Io`.
//!
//! `Future.cancel` waits for the task to return. A handler canceled in a
//! syscall returns within a millisecond or so; one that never reaches a
//! cancelation point holds the reaper until it returns, and with it others'
//! deadlines and the freeing of requests done meanwhile, not their answers.

const std = @import("std");
const Io = std.Io;
const Mailbox = @import("quic").Mailbox;

pub const State = enum(u8) {
    running,
    /// The handler returned first: its answer stands.
    finished,
    /// The deadline passed first: the answer is 504, the task canceled.
    timed_out,
    /// The client left first: no answer, the task canceled.
    abandoned,
};

/// One handler's task, from its start to its collection.
pub const Task = struct {
    future: Io.Future(void) = undefined,
    /// Who got there first. Set once, from `running`, by the one that did.
    state: std.atomic.Value(State) = .init(.running),
    /// With one, the task is in the reaper's list from its `arm` until it
    /// times out or its `end` comes.
    deadline: ?Io.Clock.Timestamp = null,
    /// Back on the loop once the task is collected; the request may go then.
    reaped: Mailbox.Post,
    mailbox: *Mailbox,

    arm_msg: Msg = .{ .kind = .arm },
    end_msg: Msg = .{ .kind = .end },
    node: std.DoublyLinkedList.Node = .{},
};

const Msg = struct {
    kind: enum { arm, end },
    node: std.SinglyLinkedList.Node = .{},

    fn task(m: *Msg) *Task {
        return switch (m.kind) {
            .arm => @alignCast(@fieldParentPtr("arm_msg", m)),
            .end => @alignCast(@fieldParentPtr("end_msg", m)),
        };
    }
};

pub const Reaper = struct {
    /// The handlers' `Io`, which the reaper waits and cancels on too.
    io: Io,
    /// What the loops sent, newest first.
    inbox: std.atomic.Value(?*std.SinglyLinkedList.Node) = .init(null),
    /// Bumped on a send to an empty inbox: the futex the reaper sleeps on.
    seq: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    /// Tasks with a deadline, and the earliest of them or earlier: the
    /// reaper's thread only.
    live: std.DoublyLinkedList = .{},
    due: ?Io.Clock.Timestamp = null,

    pub fn start(self: *Reaper) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Once nothing is left to send it: the servers have stopped.
    pub fn stop(self: *Reaper) void {
        self.stopping.store(true, .release);
        self.wake();
        self.thread.join();
    }

    /// Any thread: `t` is canceled if its deadline passes first.
    pub fn arm(self: *Reaper, t: *Task) void {
        self.send(&t.arm_msg);
    }

    /// Any thread: `t` returned, or is to be canceled. It's collected and
    /// `t.reaped` posted. Not for one that timed out: the reaper has it.
    pub fn end(self: *Reaper, t: *Task) void {
        self.send(&t.end_msg);
    }

    fn send(self: *Reaper, m: *Msg) void {
        var head = self.inbox.load(.monotonic);
        while (true) {
            m.node.next = head;
            head = self.inbox.cmpxchgWeak(head, &m.node, .release, .monotonic) orelse break;
        }
        // Not empty: whoever sent to it empty wakes the reaper, after its last swap.
        if (head == null) self.wake();
    }

    fn wake(self: *Reaper) void {
        _ = self.seq.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.seq.raw, 1);
    }

    fn run(self: *Reaper) void {
        while (true) {
            const seen = self.seq.load(.acquire);
            self.drain();
            self.expire();
            if (self.stopping.load(.acquire) and self.inbox.load(.acquire) == null) return;
            const timeout: Io.Timeout = if (self.due) |d| .{ .deadline = d } else .none;
            self.io.futexWaitTimeout(u32, &self.seq.raw, seen, timeout) catch {};
        }
    }

    /// What came, oldest first: a task's `arm` before its `end`.
    fn drain(self: *Reaper) void {
        var head = self.inbox.swap(null, .acquire);
        std.SinglyLinkedList.Node.reverse(&head);
        while (head) |n| {
            head = n.next;
            const m: *Msg = @fieldParentPtr("node", n);
            const t = m.task();
            switch (m.kind) {
                .arm => {
                    self.live.prepend(&t.node);
                    if (self.due == null or t.deadline.?.compare(.lt, self.due.?)) self.due = t.deadline;
                },
                .end => {
                    if (t.deadline != null) self.live.remove(&t.node);
                    self.collect(t);
                },
            }
        }
    }

    /// Cancels the tasks whose deadline passed, and finds the next one. All
    /// are claimed before any is canceled, as each cancel waits.
    fn expire(self: *Reaper) void {
        const due = self.due orelse return;
        const now: Io.Clock.Timestamp = .now(self.io, .awake);
        if (due.compare(.gt, now)) return;
        self.due = null;
        var doomed: std.DoublyLinkedList = .{};
        var it = self.live.first;
        while (it) |n| {
            it = n.next;
            const t: *Task = @alignCast(@fieldParentPtr("node", n));
            const at = t.deadline.?;
            if (at.compare(.gt, now)) {
                if (self.due == null or at.compare(.lt, self.due.?)) self.due = at;
                continue;
            }
            // Finished or abandoned: its `end` is on the way.
            if (t.state.cmpxchgStrong(.running, .timed_out, .acq_rel, .acquire) != null) continue;
            self.live.remove(n);
            doomed.prepend(n);
        }
        while (doomed.popFirst()) |n| self.collect(@alignCast(@fieldParentPtr("node", n)));
    }

    fn collect(self: *Reaper, t: *Task) void {
        t.future.cancel(self.io); // a task done already is just awaited
        t.mailbox.post(&t.reaped);
    }
};
