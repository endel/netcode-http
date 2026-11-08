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

**In:** `.body = endpoint.BodyStream`: a blocking handler, started at the
head, reads pieces as the loop queues them (`BodyReader`), each its own
`smp_allocator` allocation freed once read. Left over:

- Bounded by `max_body`: quic-zig's `Exchange` can't pause a body, so a
  reader slower than the upload lets its pieces pile up to that. With
  `pauseBody`/`resumeBody` on `Exchange` (HTTP/1.1's `RawConn.pauseReading`
  and HTTP/3's `Session.pauseRequestBody` exist), the cap could become
  only the unread backlog's.
- Multipart parts streamed to disk instead of gathered.
- A Zig client that streams a body.

## SSE

**In:** `ctx.events()`: `send(name, data)` and `comment`, over a stream.
Left over: `id:` and `retry:` fields, and a typed event stream in an
endpoint's contract that the TypeScript client reads with `EventSource`.

## WebSocket and WebTransport routes

**In:** `Scope.ws(pattern, app, H)`: the upgrade through the scope's
middleware and `H.open`, a handler, then `ready`, `message` and `close`
on the loop. Left over:

- WebTransport: the same for quic-zig's `onConnectRequest(session, id,
  path, headers)`, `acceptSessionWithHeaders` or `rejectSession` after
  `open`, and the session then the app's. Not done: no HTTP/3 client here
  to test it end to end.
- A refusal is only its status (`WsRequest.reject`): a `before`'s
  `WWW-Authenticate` doesn't go with a 401. A quic-zig `rejectWith(status,
  headers)` would carry it.
- Sockets are found by `WsConn.id` in the app's `Sockets` map, since a
  `Host` may be rebuilt per callback (netcode's is). A `user_data` slot on
  quic-zig's `WsConn`, as `Exchange` has, would drop the map.
- Per-socket state is `ws.data: ?*anyopaque`; a typed `H.State` the route
  allocates could replace it.
- A WebSocket test client in `http.testing`, so routes are tested
  without a socket.
- `Sec-WebSocket-Protocol`: `open` can't choose one yet.
