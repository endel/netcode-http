# What a general web framework still needs

http started as the HTTP side of a game server: routes sharing quic-zig's
port, certificates and loop. Most of it is already general: typed handlers,
endpoint contracts with a TypeScript client, HTTP/1.1 and HTTP/3, API
middleware, `testing.Client`. The aim is a typed API framework in the class
of Fastify, Hono or Axum, not a full-stack one like Rails.

Surveyed 2026-11-08 against this repo at 882c11d and quic-zig as pinned.

## Order of work

1. `blocking.md`: handlers that may block. The first wall a typical API hits,
   since most of its handlers query a database. Phase 1 is in.
2. `streaming.md`: bodies in and out as they flow, SSE, WebSocket and
   WebTransport routes.
3. `api.md`: structured errors and validation, then middleware that hands
   data to handlers, then cookies and forms.
4. `server.md`: a standalone server with TLS, HTTP/3 and every core. Static
   files and HTTP/2 also live there.

Those four take it from "a router for my server" to "an API framework
someone else could pick". After them, no fixed order:

- `web-app.md`: sessions, CSRF, templates, compression. Only needed if the
  aim goes past APIs.
- `operations.md`: request IDs, logs, metrics, tracing, auth built-ins.
- `packaging.md`: the quic-zig pin, docs, examples, test helpers, naming.

## Out of scope

ORM and migrations, OAuth providers, email, job queues, cron. Libraries of
their own; the framework should make them easy to call (`blocking.md`), not
ship them.
