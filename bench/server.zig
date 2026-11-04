//! The routes bench/server.ts serves too, for `bench/run.ts` to compare.
//!
//!   bench-server plain <port>   http.Server: HTTP/1.1, no TLS
//!   bench-server tls <port>     quic-zig's server: HTTP/1.1 over TLS and HTTP/3, one port

const std = @import("std");
const quic = @import("quic");
const http = @import("http");
const event_loop = quic.event_loop;

const Room = struct {
    roomId: []const u8,
    name: []const u8,
    clients: u32,
    maxClients: u32,
    locked: bool,
    metadata: struct { mode: []const u8, map: []const u8 },
};
const Score = struct { player: []const u8, points: u32 };

const App = struct {
    pub const protocol: event_loop.Protocol = .webtransport;

    router: http.Router,
    host: http.quic.Host,
    pool: *http.Pool,
    cors: http.Cors = .{ .origins = &.{"https://game.example"} },
    room_list: [20]Room,
    scores: [100]Score,

    pub fn onHttpHead(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpHead(ex);
    }
    pub fn onHttpBody(self: *App, ex: *event_loop.Exchange, data: []const u8) void {
        self.host.onHttpBody(ex, data);
    }
    pub fn onHttpEnd(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpEnd(ex);
    }
    pub fn onHttpGone(self: *App, ex: *event_loop.Exchange) void {
        self.host.onHttpGone(ex);
    }

    fn health(_: *App, ctx: *http.Context(.{})) !void {
        ctx.sendOwned(200, "text/plain", "ok\n");
    }

    fn listRooms(self: *App, ctx: *http.Context(.{ .params = struct { name: []const u8 } })) ![]const Room {
        _ = ctx;
        return &self.room_list;
    }

    fn top(self: *App, ctx: *http.Context(.{ .params = struct { id: u32 }, .query = struct { limit: u8 = 10 } })) !struct { id: u32, top: []const Score } {
        return .{ .id = ctx.params.id, .top = self.scores[0..@min(ctx.query.limit, self.scores.len)] };
    }

    fn submit(self: *App, ctx: *http.Context(.{ .body = Score })) !struct { rank: u32 } {
        var rank: u32 = 1;
        for (self.scores) |s| rank += @intFromBool(s.points > ctx.body.points);
        return .{ .rank = rank };
    }

    const Digest = struct { size: usize, hash: u64 };
    const upload_spec: http.Spec = .{ .body = []const u8, .max_body = 8 << 20 };

    fn upload(_: *App, ctx: *http.Context(upload_spec)) !Digest {
        return digest(ctx.body);
    }

    fn uploadOffload(self: *App, ctx: *http.Context(upload_spec)) !void {
        try ctx.offload(self.pool, digest, .{ctx.body});
    }

    fn digest(body: []const u8) Digest {
        return .{ .size = body.len, .hash = std.hash.Wyhash.hash(0, body) };
    }

    fn init(self: *App, gpa: std.mem.Allocator, io: std.Io) !void {
        self.* = .{ .router = .init(gpa), .host = undefined, .pool = undefined, .room_list = undefined, .scores = undefined };
        self.host = .init(gpa, &self.router);
        self.pool = try http.Pool.create(gpa, io, .{ .threads = 1, .max_queued = 1024 });
        for (&self.room_list, 0..) |*r, i| r.* = .{
            .roomId = "x4Gq9-ZbT",
            .name = "battle",
            .clients = @intCast(i % 8),
            .maxClients = 8,
            .locked = i % 3 == 0,
            .metadata = .{ .mode = "deathmatch", .map = "de_dust" },
        };
        for (&self.scores, 0..) |*s, i| s.* = .{ .player = "player", .points = @intCast(10_000 - i * 37) };
        const r = &self.router;
        try r.get("/health", self, health);
        try (try r.scope("/rooms").with(&.{self.cors.middleware()})).get("/:name", self, listRooms);
        try r.get("/scores/:id", self, top);
        try r.post("/scores", self, submit);
        try r.on(.PUT, "/upload", self, upload);
        try r.on(.PUT, "/upload/offload", self, uploadOffload);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var args = quic.sys.argsIterator(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.Usage;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);

    const app = try gpa.create(App);
    try app.init(gpa, init.io);

    if (std.mem.eql(u8, mode, "plain")) {
        _ = try http.Server.create(gpa, &app.router, .{ .port = port, .max_connections = 1024 });
        while (true) quic.sys.sleepNs(std.time.ns_per_s);
    }
    var server = try event_loop.Server(App).init(gpa, app, .{
        .address = "127.0.0.1",
        .port = port,
        .cert_path = "../quic-zig/interop/browser/certs/server.crt",
        .key_path = "../quic-zig/interop/browser/certs/server.key",
        .http1 = .{ .tls = true, .alt_svc = false, .max_connections = 1024 },
        // Bun's 10 s halved on both: oha's HTTP/3 ends a run only once the server closes.
        .max_idle_timeout = 5_000,
    });
    try server.run();
}
