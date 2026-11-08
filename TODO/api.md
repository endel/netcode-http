# API essentials

## Errors

**In:** errors answer as RFC 9457 problems, `ctx.problem(status, fmt, args)`
words a detail, a scope's `errors` answers an app's own from handler and
middleware alike, and the TypeScript `HttpError` reads a problem's `title`
and `detail`. Left over:

- Errors in the endpoint contract, so the TypeScript client gets typed
  error bodies (item 7), with a `Problem` type shared by the Zig client.
- quic-zig's own answers (its static 404, 405 and 400s) stay plain text,
  so a path no route has gets a text 405 where a route's gets a problem
  (item 8's own 404 and 405).
- A format other than problems for every error (`{"error": ...}`), if an
  app asks: a router-wide formatter `Response.fail` calls.

## Validation

**In:** a refused query or body says which field and why, in the problem's
detail; a struct's `rules` (`min`, `max`, `min_len`, `max_len`) and `check`
hold decoded values past their types (`src/rules.zig`). Left over:

- A missing JSON field is reported by position, not name: std.json's
  `MissingField` doesn't say which.
- No `pattern` rule: std has no regex. A `check` covers it meanwhile.
- One detail per request: the first rule broken, not all of them.
- The TypeScript client doesn't know the rules; OpenAPI (item 7) could
  carry them as `minLength`, `maximum` and the like.

## Middleware

**In:** every hook gets the request's `http.Call`; `call.setLocal(T, value)`
leaves a value per type for the handler (`ctx.local(T)`); `around` wraps the handler where it runs, on the task in a
blocking scope; `before` can return an error, answered with its status.
Left over:

- Locals are looked up by type at run time: a handler asking for one no
  middleware set gets null, not a compile error. A `Spec` naming the
  locals it needs could check the scope's middleware when routes are
  added, if middleware declared what it sets.
- Writing one means casting `ctx: ?*const anyopaque` by hand, and
  `@constCast` for state it changes (`RateLimit`). A `Middleware.init(&v)`
  reading `before`/`around`/`after` off `v`'s type would do the casts.

## Cookies

**In:** `Request.cookie`, `Response.setCookie` and `clearCookie`, secure by
default. Signed and encrypted cookies belong with sessions (`web-app.md`).

## Forms

**In:** a spec's `.form = true` takes an `application/x-www-form-urlencoded`
body too, read as a query is, rules and details alike (`form.age: at least
13`). A JSON body sent as another `Content-Type` is 415, so a cross-site
form can't post one without a preflight. Left over:

- **In:** `multipart/form-data` into a `.form` body, `endpoint.File`
  fields taking file parts, or its raw parts (`endpoint.Multipart`), from
  the gathered body. Streamed to disk instead waits on quic-zig pausing a
  body (`streaming.md`).

## Content negotiation

Bodies decode as JSON or raw bytes, and answers are JSON. Nothing reads
`Accept` or chooses an encoding from it.

## Router

**In:** `put`, `patch` and `delete` shortcuts (and `endpoint.patch`); a
scope's `fallback` for paths under its prefix no route has; a 405 that
goes through the error path, so `Scope.errors` words it. Left over:

- A trailing-slash policy (redirect or match).
- Outside any fallback, a path no route has still gets quic-zig's text 404
  or 405.
- Static files first and a fallback after (an SPA's `index.html`) needs
  the transport to try them in that order.

## Contracts

**In:** an endpoint's `errors` (the TypeScript method's `@throws`, the Zig
client's `Status.problem`), and OpenAPI 3.1 from the contracts
(`endpoint.openapi`), valid under Redocly's minimal rules. Left over:

- Contracts that also state headers and auth requirements (OpenAPI's
  `security`).
- An endpoint whose `result` is `http.Reply` gets a TypeScript client that
  parses the body as a `Reply`, and OpenAPI a `Reply` schema. Contracts
  should say "bytes of this type" instead.
- Errors are declared, not typed: a TypeScript promise can't type what it
  rejects with, and the set is open (middleware's 401s, any 500). Typed
  would be a context that answers only the failures its endpoint names,
  with a per-endpoint status union for clients. A check at `bind` can't
  do it: `Scope.errors` and `ctx.problem` pick statuses at run time.
