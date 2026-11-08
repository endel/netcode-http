# Packaging and first impressions

- **The quic-zig pin.** A project that also depends on quic-zig must pin the
  same commit, or the build fails with "file exists in modules". Fine for
  netcode and routez, but a wall for anyone else.
- **Zig churn.** It follows Zig releases (0.17 now) with no promise across
  them. Say which Zig each release needs, and keep a 1.0 API in view.
- **Docs and examples.** A CRUD app on a database (needs `blocking.md`),
  auth, behind a proxy, serving its own TLS and HTTP/3 (`server.md`), and
  embedded in a game loop as today.
- **Test helpers.** `testing.Client` has no cookie jar (`api.md`) and no
  WebSocket client (`streaming.md`).
- **The name.** The repo is `netcode-http` and its description reads "HTTP
  routes for servers built on quic-zig". Both point at games. Candidate
  description: "Typed HTTP router for Zig with HTTP/1.1 and HTTP/3, and
  endpoint contracts shared with a generated TypeScript client". Renaming
  the repo changes the `zig fetch` URL, so only if it is to stand on its
  own.
