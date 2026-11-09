//! What the tests that serve on a socket share: a client of a few lines,
//! a handler, and middleware that names its visitor.

const std = @import("std");
const quic = @import("quic");
const http = @import("../http.zig");
const sys = quic.sys;

/// Sends `request` and reads until the server closes.
pub fn fetch(port: u16, request: []const u8, buf: []u8) ![]const u8 {
    return fetchAfter(port, request, buf, 0);
}

/// `fetch`, waiting `ms` before reading: a client that falls behind.
pub fn fetchAfter(port: u16, request: []const u8, buf: []u8, ms: u64) ![]const u8 {
    const fd = try dial(port);
    defer sys.close(fd);
    const out: sys.File = .{ .fd = fd };
    try out.writeAll(request);
    sys.sleepNs(ms * std.time.ns_per_ms);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

/// A TCP connection to the server on `port`.
pub fn dial(port: u16) !std.posix.fd_t {
    const fd = try sys.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr = try quic.sockaddr.Address.parseIp4("127.0.0.1", port);
    if (std.c.connect(fd, &addr.any, addr.getOsSockLen()) != 0) return error.ConnectionRefused;
    return fd;
}

pub fn bodyOf(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

pub fn fetchInto(port: u16, request: []const u8, buf: []u8, len: *usize) void {
    len.* = if (fetch(port, request, buf)) |got| got.len else |_| 0;
}

pub fn hello(ctx: *http.Context(.{})) !void {
    try ctx.text(200, "hello");
}

pub const Visitor = struct { name: []const u8 };

/// At the head: who's visiting, left for the handler.
pub fn nameVisitor(_: ?*const anyopaque, call: *http.Call) !void {
    const name = call.request.header("x-visitor") orelse return error.Unauthorized;
    try call.setLocal(Visitor, .{ .name = name });
}
