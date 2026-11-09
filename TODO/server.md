# Serving on its own

## A standalone server for real use

**In:** `http.Server` with `tls`: quic-zig's server on a thread of its
own, HTTP/1.1 over TLS and HTTP/3 on one port, WebSockets included; and
for either mode `drain(grace_ms)`, which stops once the open connections
are done. Left over:

- Every core. Several servers under `reuse_port` need QUIC's connection
  IDs routed to the server that owns each, and a shared `retry_token_key`
  and reset key. quic-zig has `quic_lb`, `foreign_datagram` and
  `injectDatagram`, and a test where a migrated peer landing on the wrong
  worker is steered to its owner; its `SteerRouter`/`SteerWorker` exist
  only in that test. Exported as a worker pool, `http.Server` takes a
  `workers` count.
- Certificates reloaded without a restart.
- `drain` carries itself to the loop with an `xev.Async` of the server's
  own and checks with a timer: quic-zig's `requestDrain` runs no pass,
  so `onPass` never sees it. A `DrainOptions.grace` in quic-zig, stopping
  by itself, would drop both, and netcode would use it too.

## Timeouts

quic-zig's HTTP/1.1 has a handshake and a keep-alive timeout. Nothing
bounds a slow body, a slow header, or a handler that never answers. The
handler deadline belongs with cancellation (`blocking.md`, phase 2).

## Graceful shutdown

quic-zig's HTTP/1.1 server has `drain()`: stop accepting, close idle
connections. `http.Server` doesn't expose it, and nothing waits a bounded
time for requests in flight before stopping.

## Static files

**In:** `Scope.static(&files)` (README, Files): over HTTP/1.1 and HTTP/3,
ETag and 304, one Range, precompressed `.br` and `.gz`, headers of the
app's choosing, under any prefix. Left over:

- No Last-Modified or If-Modified-Since: the ETag covers what browsers send.
- No sendfile: each piece is read into a buffer and copied out.
- Files are opened and read on the loop, as most servers do. A cold disk
  or a network filesystem stalls the loop meanwhile.
- quic-zig's `static_dir` is still there, HTTP/1.1 only, for apps not on
  this router.

## HTTP/2

Browsers start on HTTP/1.1 until Alt-Svc points them at HTTP/3, and stay
there on networks that block UDP. gRPC needs HTTP/2. Less pressing behind a
proxy that speaks it.
