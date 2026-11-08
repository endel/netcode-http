# What a general web framework still needs

http started as the HTTP side of a game server: routes sharing quic-zig's
port, certificates and loop. Most of it is already general: typed handlers,
endpoint contracts with a TypeScript client, HTTP/1.1 and HTTP/3, API
middleware, `testing.Client`. The aim is a typed API framework in the class
of Fastify, Hono or Axum, not a full-stack one like Rails.

Surveyed 2026-11-08 against this repo at 882c11d and quic-zig as pinned.

## Order of work

Item by item. API breaks go early, before anyone outside netcode
depends on the API. What netcode changes for them before its next bump is
in `netcode.md`.

### 1. Finish blocking scopes (`blocking.md`)

1. **In.** Cancellation and deadlines. A handler whose client left still holds its
   task, so under a slow database the abandoned ones use up the `Io`'s
   room and everything else is 503. The per-request cancel handle is
   reused for streaming.
2. **In.** `ctx.onLoop(func, args)`. Small, and what makes blocking scopes usable
   for netcode: game state read without locks.
3. **In.** Middleware rework (`api.md`): typed locals handed to the handler,
   middleware around the handler, and `before` on the `io` in blocking
   scopes. One break to the middleware API instead of three.
4. **In.** Retire `Pool` and `ctx.offload`, once 1-3 cover what they're for.
   netcode has to move off them before its next bump (`netcode.md`).

### 2. API essentials (`api.md`)

Independent of 1.

5. **In.** Structured errors: `problem+json`, a message the handler picks, an
   error-to-answer hook.
6. **In.** Validation with field-level messages, through 5's body.
7. **In.** Typed errors in endpoint contracts for the TypeScript client, then
   OpenAPI, once the error shapes have settled.
8. **In.** Small ones together: `put`/`patch`/`delete` shortcuts, cookies,
   urlencoded forms, an app's own 404 and 405.

### 3. Streaming (`streaming.md`)

9. **In.** Streaming responses and SSE, sending from blocking handlers over 1's
   cancel handle.
10. **In.** Streaming request bodies (bounded by `max_body` until quic-zig's
    `Exchange` can pause one, `streaming.md`), then multipart on top, into
    `.form` bodies with `File` fields.
11. **Half in.** WebSocket routes are in; WebTransport's waits on a way to
    test it (`streaming.md`). WebSocket and WebTransport routes, so 3's middleware runs on upgrades.

### 4. Standing alone (`server.md`, `packaging.md`)

12. **Half in:** a standalone server with TLS, HTTP/3 and a graceful drain in
    one call; every core and slow-body timeouts left (`server.md`).
13. **In:** the quic-zig pin, a CRUD example, the Zig version policy
    (`packaging.md`). Then a first public release, maybe the rename.

### Later, unordered

Per request, after the router's cost was measured against raw quic-zig
(0.3 µs, 2026-11-08): a bodiless request answered inside its head's
callback, with no copy of the head (HTTP/3 needs quic-zig to say a
request's stream ended with its head); `find` writing into the request's
`Pending`, not copying `Found` three times; a buffer of the `Pending`'s own
before its arena, whose allocations are atomic in Zig 0.17.

Static files, compression, request IDs, logs and metrics, HTTP/2,
`web-app.md`, the zio spike (`blocking.md` phase 6), handlers as fibers on
the loop (phase 7).

## Out of scope

ORM and migrations, OAuth providers, email, job queues, cron. Libraries of
their own; the framework should make them easy to call (`blocking.md`), not
ship them.
