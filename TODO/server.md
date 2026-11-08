# Serving on its own

## A standalone server for real use

`http.Server` is meant for an admin port (`src/server.zig`): HTTP/1.1, no
TLS (`.tls = false`), one thread and loop, 64 connections by default. An app
that is only an API wants one call that serves TLS, HTTP/1.1 and HTTP/3 on
every core. Or failing that, a documented recipe on quic-zig's
`event_loop.Server`.

- Every core: one loop per core under `reuse_port`, which quic-zig already
  supports, with the router shared (it's read-only once built).
- Certificates from files, and reloading them.

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
