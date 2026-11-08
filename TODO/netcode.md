# netcode, before its next http bump

netcode pins http by commit, so nothing here breaks it until it bumps past
the commits that changed these. Then:

- **`Pool` and `ctx.offload` are gone** (`src/wasm/routes.zig`,
  `src/wasm/upload.zig`). Those routes move into a blocking scope with
  the pool's numbers, `.max_running = threads, .max_waiting = max_queued`,
  and call what they offloaded directly. The guest can write into
  `ctx.response` instead of a `Reply`. What `routes.zig` checks first
  (tally, credit, `pinNewest`) is thread-safe already: no `onLoop`.
- **`endpoint.decodeQuery` and `decodeBody` take a `why`**
  (`src/wasm/guest.zig`). `null` keeps today's behaviour; `&why` gives the
  reason for the guest's 400, which its `fail()` could send on.
- **A JSON body sent as a `Content-Type` other than JSON is 415.** netcode's
  clients send `application/json` (`endpoint.contentType`); anything posting
  JSON as text, or as a form, has to change.
- **Error answers are `application/problem+json`**, not the reason phrase
  as text. Tests asserting an error's body change, and so does whatever
  reads one.
- **`Host.onHttpWritable`** wants forwarding from an embedding handler, as
  `onHttpGone` is, for blocking handlers' streams.
- **WebSocket routes**, if it takes any: its `Host` needs `.sockets`, an
  `http.Sockets` kept per loop beside the handler, and its `onWsUpgrade`,
  `onWsMessage` and `onWsClose` try `host.upgrade`, `message` and `closed`
  first, its own sockets after.
- **Custom middleware** takes `*http.Call` (`before`, `after`) and
  `http.Next` (`around`). netcode only uses the built-ins, whose
  `.middleware()` is unchanged.
- **quic-zig, once:** it can take quic-zig from `http.module("quic")` and
  drop its own pin, so a bump of this package is the only one.
- **Request state, kept:** a `http.quic.Pendings` per loop beside its
  `Sockets`, as `host.pendings`, saves an allocation and free per request.
  Optional; without it nothing changes.
