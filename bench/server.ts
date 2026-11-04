// bench/server.zig's routes on Bun.serve, for bench/run.ts.
//   bun bench/server.ts plain <port>   HTTP/1.1, no TLS
//   bun bench/server.ts tls <port>     HTTP/1.1 over TLS, and HTTP/3 on the same port

const [mode, portArg] = process.argv.slice(2);
const port = Number(portArg);

const rooms = Array.from({ length: 20 }, (_, i) => ({
  roomId: "x4Gq9-ZbT",
  name: "battle",
  clients: i % 8,
  maxClients: 8,
  locked: i % 3 === 0,
  metadata: { mode: "deathmatch", map: "de_dust" },
}));
const scores = Array.from({ length: 100 }, (_, i) => ({ player: "player", points: 10_000 - i * 37 }));
const allowed = new Set(["https://game.example"]);

// http.Cors: a listed origin reads the answer, any other is 403.
function cors(req: Request, res: () => Response): Response {
  const origin = req.headers.get("origin");
  if (origin === null) return res();
  if (!allowed.has(origin.toLowerCase())) return new Response("Forbidden\n", { status: 403 });
  const r = res();
  r.headers.set("Access-Control-Allow-Origin", origin);
  r.headers.set("Vary", "Origin");
  return r;
}

const digest = (body: ArrayBuffer) => Response.json({ size: body.byteLength, hash: Bun.hash.wyhash(body, 0n).toString() });

const certs = "../quic-zig/interop/browser/certs/";
Bun.serve({
  port,
  hostname: "127.0.0.1",
  maxRequestBodySize: 8 << 20,
  idleTimeout: 5, // as bench/server.zig's QUIC

  ...(mode === "tls" && {
    tls: { cert: Bun.file(certs + "server.crt"), key: Bun.file(certs + "server.key") },
    http3: true,
  }),
  routes: {
    "/health": () => new Response("ok\n", { headers: { "content-type": "text/plain" } }),
    "/rooms/:name": (req) => cors(req, () => Response.json(rooms)),
    "/scores/:id": (req) => {
      const limit = Number(new URL(req.url).searchParams.get("limit") ?? 10);
      if (!Number.isInteger(limit) || limit < 0 || limit > 255) return new Response("Bad Request\n", { status: 400 });
      return Response.json({ id: Number(req.params.id), top: scores.slice(0, limit) });
    },
    "/scores": {
      POST: async (req) => {
        const body = await req.json();
        let rank = 1;
        for (const s of scores) if (s.points > body.points) rank++;
        return Response.json({ rank });
      },
    },
    "/upload": { PUT: async (req) => digest(await req.arrayBuffer()) },
  },
  fetch: () => new Response("Not Found\n", { status: 404 }),
});
