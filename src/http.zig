const std = @import("std");

pub const MAX_HEADERS = 32;

pub const Version = enum {
    http10,
    http11,
};

const MethodMap = std.StaticStringMap(std.http.Method).initComptime(.{
    .{ "GET", .GET },
    .{ "POST", .POST },
    .{ "PUT", .PUT },
    .{ "DELETE", .DELETE },
    .{ "PATCH", .PATCH },
    .{ "HEAD", .HEAD },
    .{ "OPTIONS", .OPTIONS },
    .{ "TRACE", .TRACE },
    .{ "CONNECT", .CONNECT },
});

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: std.http.Method,
    uri: []const u8,
    version: Version,
    headers: [MAX_HEADERS]Header,
    header_count: usize = 0,
    body: []const u8,

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.endsWithIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidRequest,
    UnsupportedVersion,
    TooManyHeaders,
    BadContentLength,
    UriTooLong,
    MethoodTooLong,
};

pub const ParseResult = union(enum) {
    complete: Request,
    incomplete,
    err: ParseError,
};

pub fn findEnd(buffer: []const u8) ?usize {
    // TODO fast path
    if (std.mem.indexOf(u8, buffer, "\r\n\r\n")) |pos| {
        return pos + 4;
    }
    return null;
}

test "head_finder" {
    const request1 = "GET / HTTP/1.1\r\nHost: a\r\n\r\nbody";
    try std.testing.expectEqual(@as(?usize, 27), findEnd(request1));

    const request2 = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 18), findEnd(request2));

    const incomplete = "GET / HTTP/1.1\r\nHost: a\r\n\r";
    try std.testing.expectEqual(@as(?usize, null), findEnd(incomplete));
}

pub fn parse(buffer: []const u8) ParseResult {
    // First check if we have a complete request
    const header_end = findEnd(buffer) orelse return .incomplete;
    
    var req: Request = undefined;
    parseRequest(&req, buffer[0..header_end]) catch |err| {
        return .{ .err = err };
    };
    
    return .{ .complete = req };
}

fn parseRequest(req: *Request, head_buffer: []const u8) !void {
    var line_iter = std.mem.splitScalar(u8, head_buffer, '\n');

    const first_line = line_iter.next() orelse return error.InvalidRequest;
    const line = std.mem.trimRight(u8, first_line, "\r");

    var part_iter = std.mem.splitScalar(u8, line, ' ');
    const method_str = part_iter.next() orelse return error.InvalidRequest;
    const uri_str = part_iter.next() orelse return error.InvalidRequest;
    const version_str = part_iter.next() orelse return error.InvalidRequest;

    req.* = .{
        .method = MethodMap.get(method_str) orelse return error.InvalidRequest,
        .uri = uri_str,
        .version = if (std.mem.eql(u8, version_str, "HTTP/1.1")) .http11 else .http10,
        .headers = undefined,
        .header_count = 0,
        .body = &[_]u8{},
    };

    while (line_iter.next()) |header_line| {
        const trimmed_line = std.mem.trimRight(u8, header_line, "\r");
        if (trimmed_line.len == 0) break;

        if (req.header_count >= MAX_HEADERS) return error.TooManyHeaders;

        const colon_pos = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse return error.InvalidRequest;
        const name = trimmed_line[0..colon_pos];
        const value = std.mem.trimLeft(u8, trimmed_line[colon_pos + 1 ..], " ");

        req.headers[req.header_count] = .{ .name = name, .value = value };
        req.header_count += 1;
    }
}

test "request_parser" {
    const head = "POST /submit-form?user=alex HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n\r\n";
    const result = parse(head);
    
    switch (result) {
        .complete => |req| {
            try std.testing.expect(req.method == .POST);
            try std.testing.expectEqualSlices(u8, "/submit-form?user=alex", req.uri);
            try std.testing.expect(req.version == .http11);
            try std.testing.expectEqual(@as(usize, 2), req.header_count);
            try std.testing.expectEqualSlices(u8, "Host", req.headers[0].name);
            try std.testing.expectEqualSlices(u8, "example.com", req.headers[0].value);
            try std.testing.expectEqualSlices(u8, "Content-Type", req.headers[1].name);
            try std.testing.expectEqualSlices(u8, "application/json", req.headers[1].value);
        },
        else => try std.testing.expect(false),
    }
}
