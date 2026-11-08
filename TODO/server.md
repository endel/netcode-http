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

quic-zig serves `static_dir` on HTTP/1.1 only. A request passed on over
HTTP/3 is a 404. Its `serveStatic` (`quic-zig/src/http1/conn.zig`) has:

- No ETag, Last-Modified or 304.
- No Range, which video and resumed downloads need.
- No Cache-Control, no precompressed `.gz` or `.br`, no sendfile.
- No mount under a route prefix next to the API.
- `Access-Control-Allow-Origin: *`, COOP and COEP on every file. Right for
  the WebTransport demos, surprising for a general server.

Either the router grows static routes, `router.static("/assets", dir)`, or
quic-zig's static path grows these, and serves them over HTTP/3.

## HTTP/2

Browsers start on HTTP/1.1 until Alt-Svc points them at HTTP/3, and stay
there on networks that block UDP. gRPC needs HTTP/2. Less pressing behind a
proxy that speaks it.
