# Streaming, and connections that stay open

## Responses

**In:** `ctx.stream(status, type)` in a blocking handler: each `write` a
trip to the loop, waiting on `onHttpWritable` once 64 KiB is queued (where
quic-zig's HTTP/1.1 and HTTP/3 both owe it). An error or the deadline cuts
it off with a reset. Left over:

- Streams from the loop, pushed to: a game broadcasting to its SSE
  clients without a task per client. Needs a stream that outlives its
  handler, written from loop code, with a callback when its client
  leaves. This is the shape netcode wants at scale.
- A write is two hops (to the loop and back), about 16 µs; `writer(buf)`
  batches small ones. The loop joins a trip's pieces into one write, so
  one chunk, up to 4 KiB.
- `writable_mark` copies quic-zig's own 64 KiB marks: if quic-zig raises
  them, a stream waits for an `onHttpWritable` that doesn't come, until
  its deadline. `Exchange.write` saying whether one is owed would end the
  copy.
- No assertion that the 4 MiB test takes the wait-for-room path (it did,
  checked by hand on macOS); a counter on `Host` would make it one.
- `after` middleware runs when the head goes, so `access_log` logs a
  stream's status with an empty body.

## Request bodies

`Host` gathers the body up to the route's `max_body` before the handler
runs (`src/quic.zig`), and reserves up to 1 MiB of a known length at the
head. Uploads past memory need the body handed over as it arrives: quic-zig
already delivers it in pieces (`onHttpBody`). A body could be a reader in
the `Spec`, `.body = http.BodyStream`, say.

## SSE

**In:** `ctx.events()`: `send(name, data)` and `comment`, over a stream.
Left over: `id:` and `retry:` fields, and a typed event stream in an
endpoint's contract that the TypeScript client reads with `EventSource`.

## WebSocket and WebTransport routes

quic-zig serves both: WebSockets on HTTP/1.1 (`onWsUpgrade`, `onWsMessage`,
`onWsClose`) and WebTransport on HTTP/3. None of it goes through the router,
so a scope's middleware (auth, CORS, rate limit) doesn't apply to an
upgrade. Wanted: `router.ws("/chat", app, handler)`, with the scope's
`before` middleware run on the upgrade request, and a test client for it.
