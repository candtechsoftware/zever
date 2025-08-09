const std = @import("std");
const z = @import("zserver");

pub fn main() !void {
    var app = try z.App.init(.{
        .port = 8080,
    });

    try app.routes(&[_]z.Route{
        .{
            .method = .get,
            .path = "/",
            .handlerFn = indexHandler,
        },
    });
}

pub fn indexHandler(ctx: z.Ctx) !void {
    _ = ctx;
}
