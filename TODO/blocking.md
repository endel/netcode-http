# Handlers that may block

A handler runs on its event loop's thread, so a database call stalls every
request on that loop, and in the embedded case, the game too. `ctx.offload`
works, but per call: the function it runs can't touch `ctx`, and `before`
middleware (auth that looks a token up) still runs on the loop.

## What std.Io gives us, Zig 0.17.1

Checked 2026-11-08 with spikes, not just by reading the source.

- `std.Io.Threaded` works. From a thread it doesn't own, which is what
  quic-zig's loop is to it:
  - 200 handlers blocking 50 ms each on a TCP round trip took 109 ms in all.
  - `concurrent_limit = 16` turned 34 of 50 simultaneous requests away with
    `ConcurrencyUnavailable`.
  - A handler blocked in a socket read was canceled in 1.3 ms. Threaded
    interrupts the syscall with a signal.
- `std.Io.Evented` doesn't compile on any OS. Uring (Linux) and Dispatch
  (macOS) match on `Operation.net_accept`, which no longer exists. Kqueue
  (BSD) fills `VTable` fields that were renamed. Behind that, Uring has no
  TCP listen, accept, connect or lookup, `net_read` and `net_send` return a
  TODO `NetworkDown`, and `net_write` panics. Dispatch panics on all four.
  Others report the same, and zlay moved back to Threaded.
- zio (github.com/lalinsky/zio, MIT) implements `std.Io` with stackful
  coroutines on io_uring/epoll/kqueue/IOCP: TCP, UDP, DNS, cancellation and
  timeouts. Its main branch targets 0.17, with no 0.17 tag yet. Not stated:
  whether a thread it doesn't own may spawn into it.

So: take whatever `std.Io` the app hands us. Threaded now. zio, or a working
Evented, later: the app passes a different `io` and handlers don't change.

## Gotchas

- Never `io.async` from the loop. When Threaded is out of threads, `async`
  runs the task on the caller (`Threaded.zig`, `fn async`): the loop. Only
  `concurrent` refuses instead.
- A task that posts its answer isn't done with its `Group`. After the
  handler returns, Threaded's worker still decrements the group's count.
  A group freed with its request is a use-after-free, so the group belongs
  to the router, which awaits it in `deinit`.
- `std.Io.Reader`/`Writer` turn `error.Canceled` into `ReadFailed` and
  `WriteFailed`. Whatever cancels a handler has to remember it did, not
  read it off the handler's error, or a deadline answers 500, not 504.
- Threaded is a thread per request in flight, kept in its pool afterwards.
  `concurrent_limit` is both the backpressure and the memory cap.
- Evented backends keep per-thread state. Uring's `concurrent` reads
  `Thread.current()`, which is null on a thread it doesn't own. Spawning
  into one from quic-zig's loop needs a queue and a wakeup of our own.

## Phases

1. **In:** `Scope.blocking(io)`. Its routes' handlers run as `io` tasks,
   started with `Group.concurrent`. Their answers come back through the
   loop's Mailbox. A refusal is 503. `ctx.io` is the scope's `io`, or
   `std.Io.failing` on the loop, so I/O there errors instead of stalling.
   `testing.Client` takes answers made off the loop too.
2. Cancel a handler whose client left, and add per-route deadlines (504).
   Each request needs a cancel handle of its own: a `Future` awaited, or
   canceled, by a reaper task. `Group.cancel` and `Future.cancel` wait for
   the task, so they must not run on the loop.
3. `before` middleware on the `io` for blocking scopes, so auth can query.
4. `ctx.onLoop(func, args)`: run `func` on the loop and wait for it. Lets a
   blocking handler read game state without locks.
5. Retire `Pool` and `ctx.offload` once blocking scopes cover their uses.
6. Spike zio as the `io`. The question is whether quic-zig's loop thread
   may spawn into it, or needs the queue and wakeup above.
7. Maybe: handlers as fibers on the loop thread, reading game state and
   awaiting I/O with no hop. Needs a `std.Io` built on libxev and
   `std.Io.fiber` (110 vtable functions, though most could hop to a
   Threaded pool generically), or quic-zig on zio. 0.16 to 0.17 broke std's
   own backends, so wait for the interface to settle.
