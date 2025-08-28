const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var zever = try server.Server.init(allocator, .{ .port = 8080 });
    defer zever.deinit();
    
    try zever.listen();
}
