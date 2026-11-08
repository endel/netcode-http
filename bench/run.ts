// http against Bun.serve on netcode's kinds of request, under oha.
//
//   zig build bench -Doptimize=ReleaseFast && bun bench/run.ts [reps] [seconds] [filter]
//
// Starts the servers (bench/server.zig, bench/server.ts), runs each case on
// each server in turn, `reps` times, and prints medians: requests/s, p50 and
// p99, and the server's CPU per request, which holds steadier than requests/s
// on a machine that's busy with other work.
// OHA_H3 names an oha built with HTTP/3 (`cargo install oha --features http3`);
// without one the HTTP/3 cases are skipped. HTTP_BASE names another build of
// bench-server, an earlier commit's say, to run beside the two.

import { $ } from "bun";
import { randomFillSync } from "node:crypto";

const [reps = 3, seconds = 5] = process.argv.slice(2, 4).map(Number);
const filter = process.argv[4] ?? "";
const ohaH3 = process.env.OHA_H3;
const httpBase = process.env.HTTP_BASE;
const upload = `${process.env.TMPDIR ?? "/tmp"}/http-bench-1mib.bin`;
await Bun.write(upload, randomFillSync(new Uint8Array(1 << 20)));

type Proto = "h1" | "tls" | "h3";
type Server = { name: string; base: string; cmd: string[]; proc?: Bun.Subprocess };
const servers: Record<string, Server> = {};
/** `cmd` serving plain HTTP/1.1, or TLS and HTTP/3, on `port`. */
function serve(key: string, name: string, cmd: string[], tls: boolean, port: number) {
  servers[key] = { name, base: `${tls ? "https" : "http"}://127.0.0.1:${port}`, cmd: [...cmd, tls ? "tls" : "plain", String(port)] };
}
const contenders: [string, string[]][] = [
  ["http", ["./zig-out/bin/bench-server"]],
  ["bun", ["bun", "bench/server.ts"]],
  ...(httpBase ? [["http (base)", [httpBase]] as [string, string[]]] : []),
];
contenders.forEach(([name, cmd], i) => {
  serve(`${name} h1`, name, cmd, false, 18181 + i);
  serve(`${name} tls`, name, cmd, true, 18543 + i);
});

type Case = { proto: Proto; name: string; path: string; args?: string[]; c?: number; bunSkips?: boolean };
const origin = ["-H", "Origin: https://game.example"];
const submit = ["-m", "POST", "-H", "content-type: application/json", "-d", '{"player":"ann","points":5000}'];
const put = ["-m", "PUT", "-T", "application/octet-stream", "-D", upload];
const fresh = ["--disable-keepalive"];
const all: Case[] = [
  { proto: "h1", name: "health", path: "/health" },
  { proto: "h1", name: "rooms (CORS, 20-room JSON)", path: "/rooms/battle", args: origin },
  { proto: "h1", name: "scores (param + query)", path: "/scores/7?limit=10" },
  { proto: "h1", name: "submit (JSON body)", path: "/scores", args: submit },
  { proto: "h1", name: "upload 1 MiB", path: "/upload", args: put, c: 16 },
  { proto: "h1", name: "upload 1 MiB, off the loop", path: "/upload/offload", args: put, c: 16, bunSkips: true },
  { proto: "h1", name: "health, a connection each", path: "/health", args: fresh, c: 16 },
  { proto: "tls", name: "health", path: "/health" },
  { proto: "tls", name: "rooms", path: "/rooms/battle", args: origin },
  { proto: "tls", name: "health, a connection each", path: "/health", args: fresh, c: 16 },
  { proto: "tls", name: "upload 1 MiB", path: "/upload", args: put, c: 16 },
  { proto: "h3", name: "health", path: "/health" },
  { proto: "h3", name: "rooms", path: "/rooms/battle", args: origin },
  { proto: "h3", name: "submit", path: "/scores", args: submit },
];
const cases = all.filter((c) => `${c.proto} ${c.name}`.includes(filter) && (c.proto !== "h3" || ohaH3));

/** The servers a case runs on: each contender's, by its protocol. */
const keysOf = (c: Case) =>
  contenders.filter(([name]) => !(c.bunSkips && name === "bun")).map(([name]) => `${name} ${c.proto === "h1" ? "h1" : "tls"}`);

/** CPU seconds the process has used, threads included, and its RSS in MiB. */
async function usage(pid: number): Promise<{ cpu: number; rss: number }> {
  const [time, rss] = (await $`ps -o time=,rss= -p ${pid}`.text()).trim().split(/\s+/);
  return { cpu: time.split(":").reduce((acc, part) => acc * 60 + Number(part), 0), rss: Number(rss) / 1024 };
}

for (const s of Object.values(servers)) s.proc = Bun.spawn(s.cmd, { stdout: "ignore", stderr: "inherit" });
await Bun.sleep(1500);

type Sample = { rps: number; p50: number; p99: number; cpuUs: number; rss: number };
const results = new Map<string, Sample[]>();

async function once(c: Case, key: string, secs: number): Promise<Sample> {
  const s = servers[key];
  const oha = c.proto === "h3" ? [ohaH3!, "--http-version", "3"] : ["oha"];
  const before = await usage(s.proc!.pid);
  const out = await $`${oha} --no-tui --insecure --output-format json -c ${c.c ?? 50} -z ${secs}s ${c.args ?? []} ${s.base + c.path}`.json();
  const after = await usage(s.proc!.pid);
  const ok = out.statusCodeDistribution?.["200"] ?? 0;
  const failed = Object.entries(out.statusCodeDistribution ?? {}).filter(([k]) => k !== "200");
  const errors = Object.entries(out.errorDistribution ?? {}).filter(([k]) => k !== "aborted due to deadline");
  if (failed.length || errors.length) {
    console.error(`  ${c.proto} ${c.name} on ${key}:`, JSON.stringify(Object.fromEntries(failed)), JSON.stringify(Object.fromEntries(errors)));
  }
  return {
    // oha's HTTP/3 counts its wait for the server to close in `total`.
    rps: ok / secs,
    p50: out.latencyPercentiles.p50 * 1e3,
    p99: out.latencyPercentiles.p99 * 1e3,
    cpuUs: ok ? ((after.cpu - before.cpu) * 1e6) / ok : NaN,
    rss: after.rss,
  };
}

try {
  for (let rep = 0; rep < reps; rep++) {
    for (const c of cases) {
      // Alternate who goes first, so neither always runs after the other's load.
      const keys = keysOf(c);
      const order = rep % 2 ? keys.reverse() : keys;
      for (const key of order) {
        if (rep === 0) await once(c, key, 1); // warm: Bun's JIT, both servers' buffers
        const id = `${c.proto} ${c.name}\t${servers[key].name}`;
        results.set(id, [...(results.get(id) ?? []), await once(c, key, seconds)]);
      }
    }
    console.error(`rep ${rep + 1}/${reps} done`);
  }
} finally {
  for (const s of Object.values(servers)) s.proc?.kill();
}

const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const f = (n: number, d = 0) => n.toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: d });
console.log(["case", "server", "req/s", "p50 ms", "p99 ms", "CPU µs/req", "RSS MiB"].join("\t"));
for (const [id, xs] of results) {
  const m = (k: keyof Sample) => median(xs.map((x) => x[k]));
  console.log([id, f(m("rps")), f(m("p50"), 2), f(m("p99"), 2), f(m("cpuUs"), 1), f(m("rss"), 1)].join("\t"));
}
