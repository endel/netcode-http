//! HTTP routes for servers built on quic-zig, to embed in one that already
//! runs an event loop (a game server, say) or to serve on their own.
//!
//! ```zig
//! fn score(game: *Game, ctx: *http.Context(.{ .params = struct { id: u64 } })) !Score {
//!     return game.scores.get(ctx.params.id) orelse error.NotFound;
//! }
//!
//! var router: http.Router = .init(gpa);
//! defer router.deinit();
//! try router.get("/scores/:id", &game, score);
//! ```
//!
//! Handlers run on the thread that serves the request, inside its event
//! loop: they must not block it. A `blocking` scope's run as tasks on a
//! `std.Io` instead, where they may (`Scope.blocking`).

const std = @import("std");
const router = @import("router.zig");
const context = @import("context.zig");
const middleware = @import("middleware.zig");

pub const Router = router.Router;
pub const Scope = router.Scope;
/// How an app's own error answers (`Scope.errors`).
pub const ErrorAnswer = router.ErrorAnswer;
pub const statusOf = context.statusOf;

pub const Context = context.Context;
/// What a handler bound to an endpoint takes (`Router.bind`).
pub const ContextOf = router.ContextOf;
/// Endpoints' contracts, for code a server and its clients share.
pub const endpoint = @import("endpoint");
pub const Spec = context.Spec;
pub const Request = context.Request;
pub const Response = context.Response;
pub const Method = context.Method;
pub const Header = context.Header;

pub const Reply = context.Reply;
/// The JSON answers are written in, for a body built by hand (`Reply`).
pub const json = @import("json.zig");

/// Client addresses, and the proxies trusted to name them.
pub const address = @import("address.zig");
pub const Address = address.Address;

pub const Middleware = middleware.Middleware;
/// An accepted WebSocket, a `Scope.ws` route's.
pub const WebSocket = @import("websocket.zig").WebSocket;
/// A request and its answer, as middleware and the handler share them.
pub const Call = context.Call;
/// The way on from `around` middleware.
pub const Next = middleware.Next;
pub const Bearer = middleware.Bearer;
pub const Cors = middleware.Cors;
pub const RateLimit = middleware.RateLimit;
pub const access_log = middleware.access_log;

/// Serving a router from quic-zig's listeners.
pub const quic = @import("serve/host.zig");
/// A router on a listener of its own.
pub const Server = @import("serve/server.zig").Server;
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = context;
    _ = address;
    _ = @import("tests/router_test.zig");
    _ = @import("tests/e2e_test.zig");
    _ = @import("tests/server_test.zig");
    _ = @import("tests/blocking_test.zig");
    _ = middleware;
}
