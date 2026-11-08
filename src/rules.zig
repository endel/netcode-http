//! What a decoded value is held to past its type: a struct's `rules`, a
//! limit per field, and its `check` for what spans fields.
//!
//! ```zig
//! const Score = struct {
//!     player: []const u8,
//!     points: u32,
//!     pub const rules = .{ .player = .{ .min_len = 1, .max_len = 32 }, .points = .{ .max = 1_000_000 } };
//!     pub fn check(s: Score) ?[]const u8 {
//!         return if (s.points > 0 and s.player[0] == '_') "a hidden player scores nothing" else null;
//!     }
//! };
//! ```
//!
//! `min` and `max` hold a number, `min_len` and `max_len` a slice's length.
//! Nested structs, slices of them and optionals are checked too.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where a value broke a rule, from the value checked (`.players[1].name`,
/// or "" for the value itself), and how.
pub const Broken = struct { at: []const u8, what: []const u8 };

/// Null when `value` keeps every rule its type and those within it have.
pub fn check(comptime T: type, value: *const T, arena: Allocator) Allocator.Error!?Broken {
    if (comptime !checks(T, &.{})) return null;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            const r = if (@hasDecl(T, "rules")) T.rules else .{};
            comptime validRules(T, @TypeOf(r));
            inline for (s.field_names, s.field_types) |name, F| {
                const v = &@field(value.*, name);
                if (@hasField(@TypeOf(r), name)) {
                    if (try broken(F, v.*, @field(r, name), arena)) |what| return .{ .at = "." ++ name, .what = what };
                }
                if (try check(F, v, arena)) |b| return .{ .at = try std.fmt.allocPrint(arena, "." ++ name ++ "{s}", .{b.at}), .what = b.what };
            }
            if (@hasDecl(T, "check")) if (value.check()) |what| return .{ .at = "", .what = what };
        },
        .optional => |o| if (value.*) |*v| return check(o.child, v, arena),
        .pointer => |p| if (p.size == .slice) for (value.*, 0..) |*v, i| {
            if (try check(p.child, v, arena)) |b| return .{ .at = try std.fmt.allocPrint(arena, "[{d}]{s}", .{ i, b.at }), .what = b.what };
        },
        else => {},
    }
    return null;
}

/// Whether a `T` has anything to check, within it included; `seen` stops a
/// type that holds itself.
fn checks(comptime T: type, comptime seen: []const type) bool {
    for (seen) |s| if (s == T) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            if (@hasDecl(T, "rules") or @hasDecl(T, "check")) break :blk true;
            for (s.field_types) |F| if (checks(F, seen ++ .{T})) break :blk true;
            break :blk false;
        },
        .optional => |o| checks(o.child, seen),
        .pointer => |p| p.size == .slice and checks(p.child, seen),
        else => false,
    };
}

/// How `v` breaks `rule`, if it does.
fn broken(comptime F: type, v: F, comptime rule: anytype, arena: Allocator) Allocator.Error!?[]const u8 {
    if (@typeInfo(F) == .optional) return if (v) |inner| broken(@typeInfo(F).optional.child, inner, rule, arena) else null;
    const R = @TypeOf(rule);
    if (@hasField(R, "min")) if (v < rule.min) return try std.fmt.allocPrint(arena, "at least {d}", .{rule.min});
    if (@hasField(R, "max")) if (v > rule.max) return try std.fmt.allocPrint(arena, "at most {d}", .{rule.max});
    const unit = if (F == []const u8) "byte" else "item";
    if (@hasField(R, "min_len")) if (v.len < rule.min_len) return try std.fmt.allocPrint(arena, "at least {d} {s}{s} long", .{ rule.min_len, unit, plural(rule.min_len) });
    if (@hasField(R, "max_len")) if (v.len > rule.max_len) return try std.fmt.allocPrint(arena, "at most {d} {s}{s} long", .{ rule.max_len, unit, plural(rule.max_len) });
    return null;
}

/// Each rule names a field of `T` and something it can hold that field to.
fn validRules(comptime T: type, comptime R: type) void {
    const info = @typeInfo(R).@"struct";
    for (info.field_names, info.field_types) |field, Rule| {
        const at = @typeName(T) ++ ".rules." ++ field;
        if (!@hasField(T, field)) @compileError(@typeName(T) ++ ".rules: no field " ++ field);
        const F = @FieldType(T, field);
        const V = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        for (@typeInfo(Rule).@"struct".field_names) |k| {
            switch (std.meta.stringToEnum(enum { min, max, min_len, max_len }, k) orelse @compileError(at ++ ": no rule " ++ k)) {
                .min, .max => if (@typeInfo(V) != .int and @typeInfo(V) != .float) @compileError(at ++ "." ++ k ++ ": not a number"),
                .min_len, .max_len => if (@typeInfo(V) != .pointer or @typeInfo(V).pointer.size != .slice) @compileError(at ++ "." ++ k ++ ": not a slice"),
            }
        }
    }
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

const Player = struct {
    name: []const u8,
    level: ?u8 = null,
    pub const rules = .{ .name = .{ .min_len = 1, .max_len = 8 }, .level = .{ .max = 99 } };
};

const Team = struct {
    players: []const Player,
    captain: u8,
    pub const rules = .{ .players = .{ .min_len = 1 } };
    pub fn check(t: Team) ?[]const u8 {
        return if (t.captain >= t.players.len) "the captain isn't one of the players" else null;
    }
};

const Thread = struct {
    text: []const u8,
    replies: []const Thread = &.{},
    pub const rules = .{ .text = .{ .min_len = 1 } };
};

test "rules hold a value's fields, nested ones and what spans them, and say where one broke" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expect = std.testing.expectEqualDeep;

    const ok: Team = .{ .players = &.{ .{ .name = "ann" }, .{ .name = "bob", .level = 7 } }, .captain = 1 };
    try std.testing.expectEqual(null, try check(Team, &ok, a));
    const nameless: Team = .{ .players = &.{ .{ .name = "ann" }, .{ .name = "" } }, .captain = 0 };
    try expect(Broken{ .at = ".players[1].name", .what = "at least 1 byte long" }, (try check(Team, &nameless, a)).?);
    const high: Team = .{ .players = &.{.{ .name = "ann", .level = 100 }}, .captain = 0 };
    try expect(Broken{ .at = ".players[0].level", .what = "at most 99" }, (try check(Team, &high, a)).?);
    const empty: Team = .{ .players = &.{}, .captain = 0 };
    try expect(Broken{ .at = ".players", .what = "at least 1 item long" }, (try check(Team, &empty, a)).?);
    const stray: Team = .{ .players = &.{.{ .name = "ann" }}, .captain = 3 };
    try expect(Broken{ .at = "", .what = "the captain isn't one of the players" }, (try check(Team, &stray, a)).?);

    // A type that holds itself.
    const thread: Thread = .{ .text = "hi", .replies = &.{.{ .text = "" }} };
    try expect(Broken{ .at = ".replies[0].text", .what = "at least 1 byte long" }, (try check(Thread, &thread, a)).?);
}
