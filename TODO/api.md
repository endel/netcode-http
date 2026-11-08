# API essentials

## Errors

A handler's error answers with the status's reason phrase as plain text
(`statusOf`, `Response.fail`). APIs want:

- A JSON body, RFC 9457 `application/problem+json` or a shape of the app's
  choosing.
- A message the handler picks: an error can't carry one in Zig, so
  something like `return ctx.problem(409, "seat taken")`.
- A hook from error to answer, so an app maps its own errors without
  catching them in every handler.
- Errors in the endpoint contract, so the TypeScript client gets typed
  error bodies, not just `HttpError` with a status.

## Validation

A body or query that doesn't decode is a 400 with nothing in it. Wanted:
which field failed and why, in the error body above. Then constraints past
types: length, range, enum, pattern, declared beside the field, perhaps as
a decl on the struct, and checked by the same decode.

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

No parsing of `Cookie`, and nothing to build `Set-Cookie` with its
attributes (HttpOnly, Secure, SameSite, Max-Age, Path, Domain). Signed and
encrypted cookies belong with sessions (`web-app.md`).

## Forms

- `application/x-www-form-urlencoded` into a struct: nearly free, since the
  query decoder already reads `+` as a space (`percentDecode`).
- `multipart/form-data` with file parts, streamed to disk rather than
  gathered (`streaming.md`).

## Content negotiation

Bodies decode as JSON or raw bytes, and answers are JSON. Nothing reads
`Accept` or chooses an encoding from it.

## Router

- `put`, `patch` and `delete` shortcuts on `Router` and `Scope`, beside
  `get` and `post`. `PATCH` in `endpoint` if it's missing.
- An app's own 404 and 405. What no route has goes back to quic-zig: static
  files or its 404.
- A trailing-slash policy (redirect or match).

## Contracts

- OpenAPI from `http.endpoint` contracts, beside the TypeScript writer
  (`src/typescript.zig`). It brings Swagger UI and clients in every other
  language.
- Contracts that also state headers and auth requirements.
- An endpoint whose `result` is `http.Reply` gets a TypeScript client that
  parses the body as a `Reply`. Contracts should say "bytes of this type"
  instead.
