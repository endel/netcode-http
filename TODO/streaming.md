# Streaming, and connections that stay open

## Responses

Answers are sent whole (`Exchange.respond`), so SSE, large downloads and
output generated as it goes are out of reach. quic-zig's `Exchange` already
streams: `sendHead`, `write`, `finish`, with `onHttpWritable` for
backpressure (`quic-zig/src/http/exchange.zig`). `Host` only uses `respond`.

Needs a context API (say `ctx.stream(status, headers)` returning a writer)
and a way to wait for `onHttpWritable`. From a blocking handler, every chunk
has to hop to the loop: design it with `blocking.md`.

## Request bodies

`Host` gathers the body up to the route's `max_body` before the handler
runs (`src/quic.zig`), and reserves up to 1 MiB of a known length at the
head. Uploads past memory need the body handed over as it arrives: quic-zig
already delivers it in pieces (`onHttpBody`). A body could be a reader in
the `Spec`, `.body = http.BodyStream`, say.

## SSE

Streaming responses, plus a helper that frames `data:` and `event:` lines,
sends keep-alive comments and closes cleanly. A typed variant could come
from an endpoint's contract, with the TypeScript client reading it.

## WebSocket and WebTransport routes

quic-zig serves both: WebSockets on HTTP/1.1 (`onWsUpgrade`, `onWsMessage`,
`onWsClose`) and WebTransport on HTTP/3. None of it goes through the router,
so a scope's middleware (auth, CORS, rate limit) doesn't apply to an
upgrade. Wanted: `router.ws("/chat", app, handler)`, with the scope's
`before` middleware run on the upgrade request, and a test client for it.
