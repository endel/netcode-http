# Packaging and first impressions

- **The quic-zig pin.** **In:** the build re-exports quic-zig, so an app
  takes it from `http.module("quic")`, or swaps its own in with
  `http.module("http").addImport("quic", ...)`.
- **Zig churn.** **In:** the README says which Zig a release needs and
  that there's no promise across Zig releases before 1.0. Left: a 1.0 API
  in view, and a CI build on each new Zig.
- **Docs and examples.** **In:** `examples/notes.zig`, a CRUD API on a
  store that blocks like a database, built by `zig build test` so it keeps
  compiling. Left: auth and a proxy in an example (the README covers
  `Bearer` and `trusted_proxies`), and the game-loop embedding as a
  runnable one (netcode is it, for now).
- **Test helpers.** `testing.Client` has no cookie jar (`api.md`) and no
  WebSocket client (`streaming.md`).
- **The name.** The repo is `netcode-http` and its description reads "HTTP
  routes for servers built on quic-zig". Both point at games. Candidate
  description: "Typed HTTP router for Zig with HTTP/1.1 and HTTP/3, and
  endpoint contracts shared with a generated TypeScript client". Renaming
  the repo changes the `zig fetch` URL, so only if it is to stand on its
  own. With the first public release (a tag): the owner's call.
