# Running it in production

- **Request IDs:** take `X-Request-Id` from a trusted proxy or make one,
  echo it back, and log it. `trusted_proxies` already says whose headers
  to believe.
- **Logs:** `access_log` writes a fixed line. Wanted: JSON lines,
  configurable fields, the request ID, the handler's time.
- **Metrics:** requests, statuses and latency per route, Prometheus-style,
  and Threaded's busy count for blocking scopes.
- **Tracing:** read and pass on `traceparent`, with OpenTelemetry export as
  an option rather than a dependency.
- **Auth built-ins:** `Bearer` compares against one fixed token. Wanted:
  Basic auth, JWT verification (HS256 and ES256 from std.crypto), and a
  token lookup that can block (`blocking.md`, phase 3).
- **Health and readiness:** trivial routes, but a readiness that flips
  during a drain (`server.md`) is worth having built in.
