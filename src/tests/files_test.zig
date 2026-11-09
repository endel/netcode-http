//! A directory's files (`Scope.static`): through the `Host` a server runs,
//! and on servers, HTTP/1.1 to a client that falls behind and HTTP/3.

const std = @import("std");
const quic = @import("quic");
const http = @import("../http.zig");
const sys = quic.sys;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;
const io = std.testing.io;
const support = @import("support.zig");

/// A site in a test's own directory: `root` names it from the working directory.
const Site = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init(files: []const [2][]const u8) !Site {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
            try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        }
        return .{ .tmp = tmp, .root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    }

    fn deinit(self: *Site) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }
};

fn hello(ctx: *http.Context(.{})) !void {
    try ctx.text(200, "route");
}

test "files: an index, types, HEAD, a directory's slash; 404 for what's outside or hidden" {
    var site: Site = try .init(&.{
        .{ "index.html", "<h1>home</h1>" },
        .{ "app.js", "go()" },
        .{ "sub/index.html", "sub" },
        .{ ".env", "secret" },
    });
    defer site.deinit();
    const files: http.Files = .{ .io = io, .root = site.root };
    const dotted: http.Files = .{ .io = io, .root = site.root, .dotfiles = true };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.get("/api/hello", {}, hello);
    try router.static(&files);
    try router.scope("/dotted").static(&dotted);
    try std.testing.expectError(error.StaticBlocking, (try router.scope("/off").blocking(io, .{})).static(&files));
    const nowhere: http.Files = .{ .io = io, .root = "no/such/dir" };
    try std.testing.expectError(error.FileNotFound, router.scope("/gone").static(&nowhere));

    var client: http.testing.Client = .init(gpa, &router);
    defer client.deinit();

    const home = try client.get("/");
    try expectEqual(200, home.status);
    try expectEqualStrings("text/html; charset=utf-8", home.header("content-type").?);
    try expectEqualStrings("<h1>home</h1>", home.body);
    const app = try client.get("/app.js?v=2");
    try expectEqualStrings("text/javascript; charset=utf-8", app.header("content-type").?);
    try expectEqualStrings("go()", app.body);
    try std.testing.expect(app.header("etag") != null);
    try expectEqualStrings("bytes", app.header("accept-ranges").?);
    const head = try client.request(.HEAD, "/app.js", .{});
    try expectEqual(200, head.status);
    try expectEqualStrings("", head.body);
    try expectEqualStrings("route", (try client.get("/api/hello")).body);

    const bare = try client.get("/sub?x=1");
    try expectEqual(301, bare.status);
    try expectEqualStrings("/sub/?x=1", bare.header("location").?);
    try expectEqualStrings("sub", (try client.get("/sub/")).body);

    for ([_][]const u8{ "/nope", "/../index.html", "/%2e%2e/index.html", "/sub/%2E%2E/.env", "/.env", "/a%5cb", "/a%00b" }) |path| {
        const res = try client.get(path);
        expectEqual(404, res.status) catch |err| {
            std.debug.print("{s}: {?d}\n", .{ path, res.status });
            return err;
        };
    }
    try expectEqualStrings("secret", (try client.get("/dotted/.env")).body);
    try expectEqual(404, (try client.get("/dotted/..")).status);
    const posted = try client.post("/app.js", "");
    try expectEqual(405, posted.status);
    try expectEqualStrings("GET, HEAD", posted.header("allow").?);
}

test "files: 304 for the version the client has, 206 for a range, 416 past the end, If-Range on another version" {
    var site: Site = try .init(&.{.{ "data.bin", "0123456789" }});
    defer site.deinit();
    const files: http.Files = .{ .io = io, .root = site.root, .headers = &.{.{ .name = "Cache-Control", .value = "no-cache" }} };
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.static(&files);
    var client: http.testing.Client = .init(gpa, &router);
    defer client.deinit();

    const whole = try client.get("/data.bin");
    try expectEqualStrings("application/octet-stream", whole.header("content-type").?);
    try expectEqualStrings("no-cache", whole.header("cache-control").?);
    const etag = whole.header("etag").?;

    const same = try client.request(.GET, "/data.bin", .{ .headers = &.{.{ .name = "if-none-match", .value = try std.fmt.allocPrint(client.arena.allocator(), "W/\"x\", {s}", .{etag}) }} });
    try expectEqual(304, same.status);
    try expectEqualStrings("", same.body);
    try expectEqualStrings(etag, same.header("etag").?);
    try expectEqualStrings("no-cache", same.header("cache-control").?);
    try std.testing.expect(same.header("content-type") == null);

    const part = try client.request(.GET, "/data.bin", .{ .headers = &.{.{ .name = "range", .value = "bytes=2-4" }} });
    try expectEqual(206, part.status);
    try expectEqualStrings("234", part.body);
    try expectEqualStrings("bytes 2-4/10", part.header("content-range").?);
    const tail = try client.request(.GET, "/data.bin", .{ .headers = &.{.{ .name = "range", .value = "bytes=-3" }} });
    try expectEqualStrings("789", tail.body);

    const past = try client.request(.GET, "/data.bin", .{ .headers = &.{.{ .name = "range", .value = "bytes=20-" }} });
    try expectEqual(416, past.status);
    try expectEqualStrings("bytes */10", past.header("content-range").?);

    const other = try client.request(.GET, "/data.bin", .{ .headers = &.{
        .{ .name = "range", .value = "bytes=2-4" },
        .{ .name = "if-range", .value = "\"older\"" },
    } });
    try expectEqual(200, other.status);
    try expectEqualStrings("0123456789", other.body);
}

test "files: a precompressed copy for a client that takes its encoding, the file itself for one that doesn't" {
    var site: Site = try .init(&.{
        .{ "app.js", "plain" },
        .{ "app.js.br", "brotli" },
        .{ "app.js.gz", "gzip" },
        .{ "only.css", "css" },
    });
    defer site.deinit();
    const files: http.Files = .{ .io = io, .root = site.root, .precompressed = true };
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.static(&files);
    var client: http.testing.Client = .init(gpa, &router);
    defer client.deinit();

    const br = try client.request(.GET, "/app.js", .{ .headers = &.{.{ .name = "accept-encoding", .value = "gzip, deflate, br" }} });
    try expectEqualStrings("brotli", br.body);
    try expectEqualStrings("br", br.header("content-encoding").?);
    try expectEqualStrings("text/javascript; charset=utf-8", br.header("content-type").?);
    try expectEqualStrings("Accept-Encoding", br.header("vary").?);
    const gz = try client.request(.GET, "/app.js", .{ .headers = &.{.{ .name = "accept-encoding", .value = "gzip, br;q=0" }} });
    try expectEqualStrings("gzip", gz.body);
    try std.testing.expect(!std.mem.eql(u8, br.header("etag").?, gz.header("etag").?));
    const plain = try client.get("/app.js");
    try expectEqualStrings("plain", plain.body);
    try std.testing.expect(plain.header("content-encoding") == null);
    try expectEqualStrings("Accept-Encoding", plain.header("vary").?);
    const css = try client.request(.GET, "/only.css", .{ .headers = &.{.{ .name = "accept-encoding", .value = "br" }} });
    try expectEqualStrings("css", css.body);
}

const ClientLoop = struct {
    loop: quic.event_loop.Xev.Loop,

    pub fn step(self: *ClientLoop) !void {
        try self.loop.run(.no_wait);
        sys.sleepNs(50 * std.time.ns_per_us);
    }
};

test "files on servers: a large one over HTTP/1.1 to a client that falls behind, and over HTTP/3" {
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    var site: Site = try .init(&.{ .{ "big.bin", big }, .{ "small.txt", "over h3" } });
    defer site.deinit();
    const files: http.Files = .{ .io = io, .root = site.root };
    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.static(&files);

    const plain = try http.Server.create(gpa, &router, .{});
    defer plain.destroy();
    const buf = try gpa.alloc(u8, (1 << 20) + 4096);
    defer gpa.free(buf);
    const got = try support.fetchAfter(plain.port(), "GET /big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", buf, 200);
    try std.testing.expect(std.mem.indexOf(u8, got, "Content-Length: 1048576\r\n") != null);
    try std.testing.expect(std.mem.eql(u8, big, support.bodyOf(got)));

    const tls = try http.Server.create(gpa, &router, .{ .tls = .{
        .cert_path = "../quic-zig/interop/browser/certs/server.crt",
        .key_path = "../quic-zig/interop/browser/certs/server.key",
    } });
    defer tls.destroy();
    var client: ClientLoop = .{ .loop = try .init(.{}) };
    defer client.loop.deinit();
    var h3: http.testing.Http3 = .{ .path = "/small.txt" };
    try h3.fetch(gpa, &client.loop, tls.port(), &client);
    try expectEqualStrings("200", &h3.status);
    try expectEqualStrings("over h3", h3.text());
    // Past the transport's mark: the rest goes as the client reads it.
    var h3_big: http.testing.Http3 = .{ .path = "/big.bin", .into = buf };
    try h3_big.fetch(gpa, &client.loop, tls.port(), &client);
    try std.testing.expect(std.mem.eql(u8, big, h3_big.text()));
}
