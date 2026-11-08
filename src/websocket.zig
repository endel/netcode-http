//! WebSocket routes (`Scope.ws`): an upgrade goes through its scope's
//! middleware and the route's `open`, an ordinary handler that accepts by
//! returning and refuses with an error; then the socket's messages go to
//! the route's hooks, on the loop.
//!
//! ```zig
//! const Chat = struct {
//!     pub fn open(room: *Room, ctx: *http.Context(.{ .params = struct { id: u32 } })) !void { ... }
//!     pub fn ready(room: *Room, ws: *http.WebSocket, call: *http.Call) void { ... }
//!     pub fn message(room: *Room, ws: *http.WebSocket, data: []const u8, kind: http.WebSocket.Kind) void { ... }
//!     pub fn close(room: *Room, ws: *http.WebSocket, code: u16, reason: []const u8) void { ... }
//! };
//! try router.ws("/rooms/:id", &room, Chat);
//! ```

const std = @import("std");
const event_loop = @import("quic").event_loop;
const Call = @import("context.zig").Call;

/// An accepted WebSocket, until its route's `close`.
pub const WebSocket = struct {
    conn: *event_loop.WsConn,
    /// The app's, for what it keeps per socket.
    data: ?*anyopaque = null,
    app: ?*anyopaque,
    hooks: *const Hooks,

    pub const Kind = event_loop.WsMessageKind;

    /// Unique within the server, never reused.
    pub fn id(self: *const WebSocket) u64 {
        return self.conn.id();
    }

    pub fn send(self: *WebSocket, bytes: []const u8) !void {
        return self.conn.send(bytes);
    }

    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        return self.conn.sendText(text);
    }

    /// Starts the closing handshake; the route's `close` follows.
    pub fn close(self: *WebSocket, code: u16, reason: []const u8) void {
        self.conn.close(code, reason);
    }
};

/// The WebSockets a loop's `Host` accepted, by id, until their close. The
/// app keeps it, one per loop: a `Host` may live no longer than a callback.
pub const Sockets = struct {
    map: std.AutoArrayHashMapUnmanaged(u64, *WebSocket) = .empty,

    /// Once its server has stopped, which closes its sockets first.
    pub fn deinit(self: *Sockets, gpa: std.mem.Allocator) void {
        for (self.map.values()) |ws| gpa.destroy(ws);
        self.map.deinit(gpa);
    }
};

/// A route's `ready`, `message` and `close`, its app's type erased.
pub const Hooks = struct {
    ready: ?*const fn (ws: *WebSocket, call: *Call) void,
    message: *const fn (ws: *WebSocket, data: []const u8, kind: WebSocket.Kind) void,
    close: ?*const fn (ws: *WebSocket, code: u16, reason: []const u8) void,

    /// `H`'s, each taking `App` first unless it's `void`. `message` is
    /// required, `ready` and `close` optional.
    pub fn of(comptime App: type, comptime H: type) *const Hooks {
        const S = struct {
            fn app(ws: *WebSocket) App {
                return @ptrCast(@alignCast(ws.app.?));
            }
            fn ready(ws: *WebSocket, call: *Call) void {
                if (App == void) H.ready(ws, call) else H.ready(app(ws), ws, call);
            }
            fn message(ws: *WebSocket, data: []const u8, kind: WebSocket.Kind) void {
                if (App == void) H.message(ws, data, kind) else H.message(app(ws), ws, data, kind);
            }
            fn close(ws: *WebSocket, code: u16, reason: []const u8) void {
                if (App == void) H.close(ws, code, reason) else H.close(app(ws), ws, code, reason);
            }
            const hooks: Hooks = .{
                .ready = if (@hasDecl(H, "ready")) ready else null,
                .message = message,
                .close = if (@hasDecl(H, "close")) close else null,
            };
        };
        return &S.hooks;
    }
};
