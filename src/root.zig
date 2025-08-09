//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const App = struct {
    config: Config,
    pub fn init(config: Config) !App {
        return .{ .config = config };
    }
    pub const Host = union(enum) {
        localhost,
        addr: []const u8,
    };

    pub const Config = struct { port: u16, host: Host = .localhost };

    pub fn routes(app: *App, rs: []const Route) !void {
        _ = app;
        for (rs) |r| {
            std.debug.print("Routes: {any}\n", .{r});
        }
    }
};

pub const RequestError = error{};
pub const HandlerFn = *const fn (ctx: Ctx) RequestError!void;

pub const Ctx = struct {};
pub const Route = struct {
    method: Method = .get,
    path: []const u8,
    handlerFn: HandlerFn,
    const Method = enum {
        get,
        post,
        delete,
        patch,
    };
};
