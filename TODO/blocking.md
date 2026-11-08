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
- A task that posts its answer isn't done. After the handler returns,
  Threaded's worker still touches its future, so the request can't be
  freed on the answer's post: it waits for the reaper's await or cancel.
- `std.Io.Reader`/`Writer` turn `error.Canceled` into `ReadFailed` and
  `WriteFailed`. Whatever cancels a handler has to remember it did, not
  read it off the handler's error, or a deadline answers 500, not 504.
- Threaded is a thread per request in flight, kept in its pool afterwards.
  `concurrent_limit` is both the backpressure and the memory cap.
- Evented backends keep per-thread state. Uring's `concurrent` reads
  `Thread.current()`, which is null on a thread it doesn't own. Spawning
  into one from quic-zig's loop needs a queue and a wakeup of our own.

## Phases

1. **In:** `Scope.blocking(io)`. Its routes' handlers run as `io` tasks.
   Their answers come back through the loop's Mailbox. A refusal is 503.
   `ctx.io` is the scope's `io`, or `std.Io.failing` on the loop, so I/O
   there errors instead of stalling. `testing.Client` takes answers made
   off the loop too.
2. **In:** a handler whose client left is canceled, and a scope's
   `deadline` cancels one and answers 504. Each request is a `Future`
   collected by a reaper thread per router and `Io` (`src/reaper.zig`),
   since `Future.cancel` waits for the task. Who acts first (the handler
   returning, the deadline, the client leaving) is one atomic state. Each
   request owes the loop two posts: its task's `done` and the reaper's
   `reaped`, which frees it. Left over:
   - quic-zig's HTTP/1.1 never reports a client gone mid-exchange. In the
     `.exchange` phase, end of input (FIN or reset alike, `onSocketEof`)
     only clears keep-alive: it's taken as a half-close that still wants
     its answer. But a client that leaves while it waits (a closed tab,
     curl ^C) sends a FIN, so the fix is to read end of input there as
     gone, as Go's net/http and nginx (499) do, with an opt-out for
     clients that half-close on purpose. Until then `http.Server`, HTTP/1.1
     only, never cancels for a client leaving. HTTP/3 not checked.
   - A handler that never reaches a cancelation point holds the reaper
     while it's canceled: other deadlines and frees wait, answers don't.
     A reaper handing slow cancels to helper threads would fix it.
   - The reaper is a `std.Thread`, calling `Future.cancel` from outside the
     `Io`. Fine for Threaded. Whether zio allows that is part of phase 6.
   - One reaper per router and `Io` means a thread started while routes
     are registered, `Io`s matched by vtable and userdata, and `addAll`
     rehoming routes. An app-owned `http.Blocking.init(io)` passed to
     `blocking(&b, ...)` would drop all three. Worth it by phase 6.
3. **In,** as `around` middleware, which runs where the handler does: on
   the task in a blocking scope, so auth can query. `before` stays on the
   loop at the head, where it can refuse before the body is read.
4. **In:** `ctx.onLoop(func, args)` runs `func` on the loop and waits for
   it, so a blocking handler reaches game state without locks. It calls
   the Mailbox's `expect` off the loop (`Call.loop` says why it's safe).
   A quic-zig `Mailbox.expectWhileOwed`, an atomic add asserting something
   is owed, would make that the Mailbox's promise.
5. **In:** `Pool` and `ctx.offload` are gone. A blocking scope's
   `max_running` and `max_waiting` take the pool's threads and queue, and
   a handler may return an `http.Reply`. netcode still uses them
   (`src/wasm/routes.zig`, `src/wasm/upload.zig`), so before it bumps its
   http pin past this, those routes move into a blocking scope with the
   pool's numbers, and call what they offloaded directly. The guest can
   write into `ctx.response` instead of a `Reply`. What `routes.zig` checks
   first (tally, credit, `pinNewest`) is thread-safe already: no `onLoop`.
6. Spike zio as the `io`. The question is whether quic-zig's loop thread
   may spawn into it, or needs the queue and wakeup above.
7. Maybe: handlers as fibers on the loop thread, reading game state and
   awaiting I/O with no hop. Needs a `std.Io` built on libxev and
   `std.Io.fiber` (110 vtable functions, though most could hop to a
   Threaded pool generically), or quic-zig on zio. 0.16 to 0.17 broke std's
   own backends, so wait for the interface to settle.
