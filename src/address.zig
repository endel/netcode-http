//! Where a client connects from, and who may say so for it: the proxies in
//! front of the server, such as routez (`Host.trusted_proxies`).
const std = @import("std");

const log = std.log.scoped(.http);

const ip4_mapped = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

/// An IP address, IPv4 held IPv4-mapped. `{f}` prints it as text:
/// `203.0.113.7`, `2001:db8::1`.
pub const Address = struct {
    bytes: [16]u8 = @splat(0),

    pub fn fromSockaddr(sa: *const std.posix.sockaddr.storage) Address {
        var a: Address = .{};
        switch (sa.family) {
            std.posix.AF.INET => {
                const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(sa));
                a.bytes[0..12].* = ip4_mapped;
                a.bytes[12..16].* = @bitCast(in.addr);
            },
            std.posix.AF.INET6 => {
                const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
                a.bytes = in6.addr;
            },
            else => {},
        }
        return a;
    }

    /// `text` as an IPv4 or IPv6 address, or null.
    pub fn parse(text: []const u8) ?Address {
        const ip = std.Io.net.IpAddress.parse(text, 0) catch return null;
        var a: Address = .{};
        switch (ip) {
            .ip4 => |v4| {
                a.bytes[0..12].* = ip4_mapped;
                a.bytes[12..16].* = v4.bytes;
            },
            .ip6 => |v6| a.bytes = v6.bytes,
        }
        return a;
    }

    pub fn isIp4(a: Address) bool {
        return std.mem.eql(u8, a.bytes[0..12], &ip4_mapped);
    }

    pub fn format(a: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (a.isIp4()) return w.print("{d}.{d}.{d}.{d}", .{ a.bytes[12], a.bytes[13], a.bytes[14], a.bytes[15] });
        const v6: std.Io.net.Ip6Address.Unresolved = .{ .bytes = a.bytes, .interface_name = null };
        try v6.format(w);
    }
};

/// The addresses sharing a prefix: `10.0.0.0/8`, `2001:db8::/32`, or one
/// address alone.
pub const Network = struct {
    base: Address,
    /// Leading bits of the 16 bytes that must match.
    bits: u8,

    pub fn parse(text: []const u8) error{InvalidNetwork}!Network {
        const slash = std.mem.indexOfScalar(u8, text, '/');
        const base = Address.parse(text[0 .. slash orelse text.len]) orelse return error.InvalidNetwork;
        const width: u8 = if (base.isIp4()) 32 else 128;
        const len = if (slash) |i| std.fmt.parseInt(u8, text[i + 1 ..], 10) catch return error.InvalidNetwork else width;
        if (len > width) return error.InvalidNetwork;
        return .{ .base = base, .bits = len + (128 - width) };
    }

    pub fn contains(n: Network, a: Address) bool {
        const whole = n.bits / 8;
        if (!std.mem.eql(u8, n.base.bytes[0..whole], a.bytes[0..whole])) return false;
        const rest: u3 = @intCast(n.bits % 8);
        if (rest == 0) return true;
        const mask = @as(u8, 0xff) << @intCast(8 - @as(u4, rest));
        return (n.base.bytes[whole] ^ a.bytes[whole]) & mask == 0;
    }
};

/// Trusted proxies as text, parsed; an entry that isn't an address or
/// network is logged and refused.
pub fn parseNetworks(gpa: std.mem.Allocator, texts: []const []const u8) ![]Network {
    const out = try gpa.alloc(Network, texts.len);
    errdefer gpa.free(out);
    for (texts, out) |text, *n| n.* = Network.parse(text) catch |err| {
        log.err("trusted_proxies: '{s}' is no address or network", .{text});
        return err;
    };
    return out;
}

/// The client behind a connection from `peer` that sent `headers` (any
/// slice of `.name`/`.value`): `peer` itself, unless that is a trusted
/// proxy and its X-Forwarded-For names another. Each proxy appends the
/// address it heard from, so the last such header is read from the right,
/// and the first address that isn't a trusted proxy is the client. What
/// lies left of it may be the client's own invention and is never read. An
/// entry that isn't an address ends the reading at the last proxy passed.
pub fn clientOf(peer: *const std.posix.sockaddr.storage, headers: anytype, trusted: []const Network) Address {
    if (trusted.len == 0) return .fromSockaddr(peer); // no proxies: no header to look for
    var forwarded_for: ?[]const u8 = null;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) forwarded_for = h.value;
    }
    return resolve(.fromSockaddr(peer), forwarded_for, trusted);
}

fn resolve(peer: Address, forwarded_for: ?[]const u8, trusted: []const Network) Address {
    if (!isTrusted(trusted, peer)) return peer;
    var client = peer;
    var rest = forwarded_for orelse return peer;
    while (rest.len > 0) {
        const comma = std.mem.lastIndexOfScalar(u8, rest, ',');
        const entry = std.mem.trim(u8, rest[if (comma) |i| i + 1 else 0..], " \t");
        rest = rest[0 .. comma orelse 0];
        client = Address.parse(entry) orelse return client;
        if (!isTrusted(trusted, client)) return client;
    }
    return client;
}

fn isTrusted(trusted: []const Network, a: Address) bool {
    for (trusted) |n| if (n.contains(a)) return true;
    return false;
}

const testing = std.testing;

fn expectText(want: []const u8, a: Address) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, try std.fmt.bufPrint(&buf, "{f}", .{a}));
}

test "addresses parse and print, IPv4 as dotted quads" {
    try expectText("203.0.113.7", Address.parse("203.0.113.7").?);
    try expectText("2001:db8::1", Address.parse("2001:db8:0:0::1").?);
    try expectText("::1", Address.parse("::1").?);
    try expectText("1.2.3.4", Address.parse("::ffff:1.2.3.4").?);
    try testing.expectEqual(@as(?Address, null), Address.parse("1.2.3.4:80"));
    try testing.expectEqual(@as(?Address, null), Address.parse("unknown"));

    var sa: std.posix.sockaddr.storage = undefined;
    const in: *std.posix.sockaddr.in = @ptrCast(@alignCast(&sa));
    in.* = .{ .port = 0, .addr = @bitCast([4]u8{ 192, 0, 2, 1 }) };
    try expectText("192.0.2.1", Address.fromSockaddr(&sa));
    const in6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&sa));
    in6.* = .{ .port = 0, .flowinfo = 0, .addr = Address.parse("fe80::2").?.bytes, .scope_id = 0 };
    try expectText("fe80::2", Address.fromSockaddr(&sa));
}

test "a network holds the addresses under its prefix, of its own family" {
    const ten = try Network.parse("10.0.0.0/8");
    try testing.expect(ten.contains(Address.parse("10.200.3.4").?));
    try testing.expect(!ten.contains(Address.parse("11.0.0.1").?));
    try testing.expect(!ten.contains(Address.parse("::a00:1").?));

    const odd = try Network.parse("192.168.1.128/25");
    try testing.expect(odd.contains(Address.parse("192.168.1.200").?));
    try testing.expect(!odd.contains(Address.parse("192.168.1.100").?));

    const one = try Network.parse("127.0.0.1");
    try testing.expect(one.contains(Address.parse("127.0.0.1").?));
    try testing.expect(!one.contains(Address.parse("127.0.0.2").?));

    const v6 = try Network.parse("2001:db8::/32");
    try testing.expect(v6.contains(Address.parse("2001:db8:ffff::9").?));
    try testing.expect(!v6.contains(Address.parse("2001:db9::9").?));

    for ([_][]const u8{ "10.0.0.0/33", "::/129", "10.0.0.0/", "proxy", "" }) |bad| {
        try testing.expectError(error.InvalidNetwork, Network.parse(bad));
    }
}

test "a trusted proxy names its client in X-Forwarded-For, read from the right; anyone else's is ignored" {
    const trusted = [_]Network{ try .parse("127.0.0.1"), try .parse("10.0.0.0/8"), try .parse("::1") };
    const proxy = Address.parse("127.0.0.1").?;
    const stranger = Address.parse("198.51.100.9").?;

    // Not from a proxy: the header is whatever the client wrote.
    try expectText("198.51.100.9", resolve(stranger, "203.0.113.7", &trusted));
    try expectText("198.51.100.9", resolve(stranger, "203.0.113.7", &.{}));
    // From one: the address it appended, past what the client claimed.
    try expectText("127.0.0.1", resolve(proxy, null, &trusted));
    try expectText("203.0.113.7", resolve(proxy, "203.0.113.7", &trusted));
    try expectText("203.0.113.7", resolve(proxy, "6.6.6.6, 203.0.113.7", &trusted));
    // Through two proxies, both trusted.
    try expectText("203.0.113.7", resolve(proxy, "6.6.6.6,203.0.113.7, 10.1.1.1", &trusted));
    try expectText("2001:db8::7", resolve(Address.parse("::1").?, "2001:db8::7", &trusted));
    // Garbage stops the reading at the last proxy it can vouch for.
    try expectText("10.1.1.1", resolve(proxy, "203.0.113.7, junk, 10.1.1.1", &trusted));
    try expectText("127.0.0.1", resolve(proxy, "203.0.113.7, ", &trusted));
    // Every address a proxy: the leftmost.
    try expectText("10.2.2.2", resolve(proxy, "10.2.2.2, 10.1.1.1", &trusted));
}
