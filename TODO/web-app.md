# Past APIs: web apps

Only needed if http aims at web apps, not just APIs.

- **Sessions:** signed or encrypted cookies, with a pluggable store for
  server-side ones. Builds on cookies (`api.md`).
- **CSRF** protection for cookie-authenticated forms.
- **Templates:** HTML rendering, comptime-checked if it can be. Where an
  API framework ends and a web framework begins.
- **Compression** of answers: gzip with `std.compress.flate`, chosen from
  `Accept-Encoding`. Skipped for small and already compressed bodies.
- **Security headers:** HSTS, CSP, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy`, as one middleware with sane defaults.
- **Redirects:** `ctx.redirect(303, "/next")`, and a trailing-slash
  redirect (`api.md`).
- **Virtual hosts:** routes by `Host`, subdomains as params.
- **URL building:** a route's path from its name and params.
  `endpoint.writeTarget` already does it for contracts.
