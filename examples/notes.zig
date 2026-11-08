//! Notes over HTTP: a CRUD API on a store whose every call blocks for a
//! moment, as a database's would, served from a blocking scope. Its
//! contracts give `/openapi.json`.
//!
//!   zig build notes && ./zig-out/bin/notes          # :8080
//!   curl -d '{"title":"milk"}' -H 'content-type: application/json' localhost:8080/notes
//!   curl localhost:8080/notes/1

const std = @import("std");
const http = @import("http");

const Note = struct {
    title: []const u8,
    body: []const u8 = "",
    pub const rules = .{ .title = .{ .min_len = 1, .max_len = 100 }, .body = .{ .max_len = 10_000 } };
};

const Stored = struct { id: u32, title: []const u8, body: []const u8 };

const ById = struct { id: u32 };
const not_found: []const http.endpoint.Failure = &.{.{ .status = 404, .why = "no such note" }};

/// The contracts: a client built with them, Zig or TypeScript, calls these.
pub const Api = struct {
    pub const list = http.endpoint.get("/notes", .{ .query = struct { limit: u16 = 50 }, .result = []const Stored });
    pub const read = http.endpoint.get("/notes/:id", .{ .params = ById, .result = Stored, .errors = not_found });
    pub const create = http.endpoint.post("/notes", .{ .body = Note, .form = true, .result = Stored });
    pub const update = http.endpoint.put("/notes/:id", .{ .params = ById, .body = Note, .result = Stored, .errors = not_found });
    pub const remove = http.endpoint.delete("/notes/:id", .{ .params = ById, .errors = not_found });
};

/// A database stand-in: shared by every task, so behind a mutex, and slow.
const Db = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    notes: std.AutoArrayHashMapUnmanaged(u32, Stored) = .empty,
    next: u32 = 1,

    fn lock(db: *Db, io: std.Io) !void {
        try io.sleep(.fromMilliseconds(2), .awake); // the round trip
        try db.mutex.lock(io);
    }

    fn unlock(db: *Db, io: std.Io) void {
        db.mutex.unlock(io);
    }

    fn own(db: *Db, id: u32, note: Note) !Stored {
        const title = try db.gpa.dupe(u8, note.title);
        errdefer db.gpa.free(title);
        return .{ .id = id, .title = title, .body = try db.gpa.dupe(u8, note.body) };
    }

    fn drop(db: *Db, note: Stored) void {
        db.gpa.free(note.title);
        db.gpa.free(note.body);
    }

    fn list(db: *Db, ctx: *http.ContextOf(Api.list)) ![]const Stored {
        try db.lock(ctx.io);
        defer db.unlock(ctx.io);
        const all = db.notes.values();
        return ctx.arena.dupe(Stored, all[0..@min(all.len, ctx.query.limit)]);
    }

    fn read(db: *Db, ctx: *http.ContextOf(Api.read)) !Stored {
        try db.lock(ctx.io);
        defer db.unlock(ctx.io);
        return db.notes.get(ctx.params.id) orelse error.NotFound;
    }

    fn create(db: *Db, ctx: *http.ContextOf(Api.create)) !Stored {
        try db.lock(ctx.io);
        defer db.unlock(ctx.io);
        const note = try db.own(db.next, ctx.body);
        errdefer db.drop(note);
        try db.notes.put(db.gpa, note.id, note);
        db.next += 1;
        try ctx.setHeader("Location", try std.fmt.allocPrint(ctx.arena, "/notes/{d}", .{note.id}));
        return note;
    }

    fn update(db: *Db, ctx: *http.ContextOf(Api.update)) !Stored {
        try db.lock(ctx.io);
        defer db.unlock(ctx.io);
        const slot = db.notes.getPtr(ctx.params.id) orelse return error.NotFound;
        const note = try db.own(slot.id, ctx.body);
        db.drop(slot.*);
        slot.* = note;
        return note;
    }

    fn remove(db: *Db, ctx: *http.ContextOf(Api.remove)) !void {
        try db.lock(ctx.io);
        defer db.unlock(ctx.io);
        db.drop((db.notes.fetchSwapRemove(ctx.params.id) orelse return error.NotFound).value);
    }
};

fn openapi(ctx: *http.Context(.{})) !void {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    try http.endpoint.openapi.write(Api, &out.writer, .{ .title = "notes", .version = "1.0.0" });
    ctx.sendOwned(200, "application/json", out.written());
}

fn notFound(_: *http.Context(.{})) !void {
    return error.NotFound;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var db: Db = .{ .gpa = gpa };

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.get("/openapi.json", {}, openapi);
    // Off the loop: every handler here waits on the store.
    const notes = try router.scope("").blocking(init.io, .{ .deadline = .fromSeconds(5), .max_running = 64 });
    try notes.bind(Api.list, &db, Db.list);
    try notes.bind(Api.read, &db, Db.read);
    try notes.bind(Api.create, &db, Db.create);
    try notes.bind(Api.update, &db, Db.update);
    try notes.bind(Api.remove, &db, Db.remove);
    try router.fallback({}, notFound); // a problem 404 for anything else

    const server = try http.Server.create(gpa, &router, .{ .port = 8080 });
    defer server.destroy();
    std.log.info("notes on :{d}", .{server.port()});
    while (true) try init.io.sleep(.fromSeconds(60), .awake);
}
