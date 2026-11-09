//! A directory's files under a scope's prefix (`Scope.static`), over
//! HTTP/1.1 and HTTP/3 alike. The handler picks the file and its answer on
//! the loop; the transport sends it a piece at a time as the client takes
//! them (`Response.file`).

const std = @import("std");
const context = @import("context.zig");
const Header = context.Header;

/// What `Scope.static` serves. The app keeps it as long as the router.
pub const Files = struct {
    /// What the files are read with, on the loop's thread: reads block, as
    /// they do in most servers, short for files in the page cache.
    io: std.Io,
    /// The directory, relative to the working directory or absolute.
    root: []const u8,
    /// On every file's answer and 304: `Cache-Control`, say.
    headers: []const Header = &.{},
    /// `name.br` or `name.gz` in place of `name`, when it's there and the
    /// client takes that encoding.
    precompressed: bool = false,
    /// A name that starts with a dot (`.git`, `.env`) is 404 unless this.
    dotfiles: bool = false,

    pub const Ctx = context.Context(.{ .params = struct { path: []const u8 } });

    /// `error.FileNotFound` and the like when `root` isn't a directory.
    pub fn check(self: *const Files) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{});
        dir.close(self.io);
    }

    /// The route `Scope.static` adds: `ctx.params.path` under `root`, a
    /// directory's `index.html`, a 404 for anything else.
    pub fn serve(self: *const Files, ctx: *Ctx) !void {
        // The transport reads the file from the loop: there's none to come back to.
        if (ctx.call.loop != null) return error.StaticBlocking;
        const a = ctx.arena;
        const decoded = std.Uri.percentDecodeInPlace(try a.dupe(u8, ctx.params.path));
        var rel: std.ArrayList(u8) = .empty;
        var segs = std.mem.tokenizeScalar(u8, decoded, '/');
        while (segs.next()) |seg| {
            if (seg[0] == '.' and (!self.dotfiles or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))) return error.NotFound;
            if (std.mem.indexOfAny(u8, seg, "\\\x00") != null) return error.NotFound;
            try rel.appendSlice(a, "/");
            try rel.appendSlice(a, seg);
        }
        const dir_path = decoded.len == 0 or decoded[decoded.len - 1] == '/';
        const path = try std.mem.concat(a, u8, &.{ self.root, rel.items, if (dir_path) "/index.html" else "" });
        var file, var stat = open(self.io, path) orelse return error.NotFound;
        var handed = false;
        defer if (!handed) file.close(self.io);
        switch (stat.kind) {
            .file => {},
            // Named without its slash, its index.html's relative links would miss.
            .directory => if (!dir_path) return redirect(ctx) else return error.NotFound,
            else => return error.NotFound,
        }

        var coding: ?[]const u8 = null;
        if (self.precompressed) {
            try ctx.setHeader("Vary", "Accept-Encoding");
            const accepted = ctx.request.header("accept-encoding") orelse "";
            for ([_][2][]const u8{ .{ "br", ".br" }, .{ "gzip", ".gz" } }) |c| if (accepts(accepted, c[0])) {
                const z_file, const z_stat = open(self.io, try std.mem.concat(a, u8, &.{ path, c[1] })) orelse continue;
                if (z_stat.kind != .file) {
                    z_file.close(self.io);
                    continue;
                }
                file.close(self.io);
                file = z_file;
                stat = z_stat;
                coding = c[0];
                break;
            };
        }

        const mtime_us: u64 = @intCast(@max(0, @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_us)));
        const etag = try std.fmt.allocPrint(a, "\"{x}-{x}{s}{s}\"", .{ stat.size, mtime_us, if (coding != null) "-" else "", coding orelse "" });
        try ctx.setHeader("ETag", etag);
        try ctx.setHeader("Accept-Ranges", "bytes");
        for (self.headers) |h| try ctx.setHeader(h.name, h.value);
        if (ctx.request.header("if-none-match")) |tags| if (matches(tags, etag)) return ctx.response.empty(304);
        if (coding) |c| try ctx.setHeader("Content-Encoding", c);

        var start: u64 = 0;
        var end: u64 = stat.size;
        var status: u16 = 200;
        // If-Range names the version the client has the start of: another's range would splice two.
        const same = if (ctx.request.header("if-range")) |tag| std.mem.eql(u8, tag, etag) else true;
        if (ctx.request.header("range")) |r| if (same) {
            const range = rangeOf(r, stat.size) catch {
                try ctx.setHeader("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{stat.size}));
                return ctx.response.fail(416);
            };
            if (range) |got| {
                start, end = got;
                status = 206;
                try ctx.setHeader("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ start, end - 1, stat.size }));
            }
        };

        const body = try a.create(Body);
        body.* = .{ .file = file, .io = self.io, .offset = start, .len = end - start };
        ctx.response.sendFile(status, mimeType(path), body);
        handed = true;
    }
};

/// A file's bytes on their way out (`Response.file`): `len` from `offset`,
/// read by the transport as the client takes them. It closes the file.
pub const Body = struct {
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    len: u64,

    pub fn close(self: *Body) void {
        self.file.close(self.io);
    }
};

fn open(io: std.Io, path: []const u8) ?struct { std.Io.File, std.Io.File.Stat } {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    const s = f.stat(io) catch {
        f.close(io);
        return null;
    };
    return .{ f, s };
}

fn redirect(ctx: *Files.Ctx) !void {
    const q = ctx.request.rawQuery();
    try ctx.setHeader("Location", try std.mem.concat(ctx.arena, u8, &.{ ctx.request.path(), "/", if (q.len > 0) "?" else "", q }));
    ctx.response.empty(301);
}

/// Whether `header`, an Accept-Encoding, takes `coding` (at a q above 0).
fn accepts(header: []const u8, coding: []const u8) bool {
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |item| {
        var parts = std.mem.splitScalar(u8, item, ';');
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, parts.first(), " \t"), coding)) continue;
        const q = std.mem.trim(u8, parts.rest(), " \t");
        return !(std.mem.startsWith(u8, q, "q=0") and std.mem.trim(u8, q[3..], ".0").len == 0);
    }
    return false;
}

/// Whether `tags`, an If-None-Match, names `etag` (compared weakly) or is `*`.
fn matches(tags: []const u8, etag: []const u8) bool {
    var it = std.mem.splitScalar(u8, tags, ',');
    while (it.next()) |item| {
        const tag = std.mem.trim(u8, item, " \t");
        if (std.mem.eql(u8, tag, "*")) return true;
        if (std.mem.eql(u8, if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag, etag)) return true;
    }
    return false;
}

/// A Range header against `size` bytes: the one range it names, as
/// [start, end); null for the whole file, as for several ranges, another
/// unit or one that doesn't parse (RFC 9110 §14.2).
fn rangeOf(header: []const u8, size: u64) error{Unsatisfiable}!?[2]u64 {
    if (!std.mem.startsWith(u8, header, "bytes=")) return null;
    const spec = std.mem.trim(u8, header["bytes=".len..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const first = spec[0..dash];
    const last = spec[dash + 1 ..];
    if (first.len == 0) {
        const n = std.fmt.parseInt(u64, last, 10) catch return null;
        if (n == 0 or size == 0) return error.Unsatisfiable;
        return .{ size - @min(n, size), size };
    }
    const start = std.fmt.parseInt(u64, first, 10) catch return null;
    var end = size;
    if (last.len > 0) {
        const n = std.fmt.parseInt(u64, last, 10) catch return null;
        if (n < start) return null;
        end = n +| 1;
    }
    if (start >= size) return error.Unsatisfiable;
    return .{ start, @min(end, size) };
}

pub fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".map", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml" },
        .{ ".csv", "text/csv; charset=utf-8" },
        .{ ".pdf", "application/pdf" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".ogg", "audio/ogg" },
        .{ ".wav", "audio/wav" },
        .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".glb", "model/gltf-binary" },
        .{ ".gltf", "model/gltf+json" },
        .{ ".ktx2", "image/ktx2" },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}

test "a range: one, a suffix, open-ended; several or garbage is the whole file; past the end is unsatisfiable" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual([2]u64{ 2, 5 }, (try rangeOf("bytes=2-4", 10)).?);
    try expectEqual([2]u64{ 7, 10 }, (try rangeOf("bytes=-3", 10)).?);
    try expectEqual([2]u64{ 0, 10 }, (try rangeOf("bytes=-30", 10)).?);
    try expectEqual([2]u64{ 4, 10 }, (try rangeOf("bytes=4-", 10)).?);
    try expectEqual([2]u64{ 4, 10 }, (try rangeOf("bytes=4-99", 10)).?);
    try expectEqual(null, try rangeOf("bytes=0-1,4-5", 10));
    try expectEqual(null, try rangeOf("items=0-1", 10));
    try expectEqual(null, try rangeOf("bytes=5-2", 10));
    try expectEqual(null, try rangeOf("bytes=x-", 10));
    try std.testing.expectError(error.Unsatisfiable, rangeOf("bytes=10-", 10));
    try std.testing.expectError(error.Unsatisfiable, rangeOf("bytes=-0", 10));
    try std.testing.expectError(error.Unsatisfiable, rangeOf("bytes=-5", 0));
}

test "an encoding is taken unless absent or at q=0" {
    try std.testing.expect(accepts("gzip, deflate, br", "br"));
    try std.testing.expect(accepts("br;q=0.5", "br"));
    try std.testing.expect(!accepts("br;q=0", "br"));
    try std.testing.expect(!accepts("br;q=0.00", "br"));
    try std.testing.expect(!accepts("gzip", "br"));
}
