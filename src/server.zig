const std = @import("std");
const net = std.net;
const os = std.os;
const log = std.log;

const http = @import("http.zig");
const uring = @import("uring.zig");
const MpscQueue = @import("atomic.zig").MpscQueue;

const PORT = 8080;
const QUEUE_DEPTH = 256;
const BUFFER_SIZE = 16 * 1024;
const BUFFER_COUNT = 1024;

pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    queue_depth: u32 = QUEUE_DEPTH,
    buffer_size: u32 = BUFFER_SIZE,
    buffer_count: u32 = BUFFER_COUNT,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    ring: uring.Ring,
    server_socket: net.Server,
    arena: std.heap.ArenaAllocator,
    connections: std.AutoHashMap(std.c.fd_t, *ClientConnection),
    buffer_pool_mem: []u8,
    buffers: [][]u8,
    free_buffers: MpscQueue(u16, BUFFER_COUNT),
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        var self = Server{
            .allocator = allocator,
            .config = config,
            .ring = undefined,
            .server_socket = undefined,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .connections = std.AutoHashMap(std.c.fd_t, *ClientConnection).init(allocator),
            .buffer_pool_mem = undefined,
            .buffers = undefined,
            .free_buffers = undefined,
            .running = false,
        };

        self.ring = try uring.Ring.init(config.queue_depth, 0);

        self.buffer_pool_mem = try allocator.alloc(u8, config.buffer_size * config.buffer_count);
        self.buffers = try allocator.alloc([]u8, config.buffer_count);
        
        self.free_buffers = MpscQueue(u16, BUFFER_COUNT).init();
        
        var iovecs = try allocator.alloc(std.posix.iovec, config.buffer_count);
        defer allocator.free(iovecs);
        
        for (0..config.buffer_count) |i| {
            const start = i * config.buffer_size;
            const end = start + config.buffer_size;
            self.buffers[i] = self.buffer_pool_mem[start..end];
            iovecs[i] = .{ .base = self.buffers[i].ptr, .len = self.buffers[i].len };
            _ = self.free_buffers.enqueue(@intCast(i));
        }


        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.running) {
            self.stop();
        }
        
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.connections.deinit();
        
        self.arena.deinit();
        self.ring.deinit();
        self.allocator.free(self.buffer_pool_mem);
        self.allocator.free(self.buffers);
    }

    pub fn listen(self: *Server) !void {
        log.info("Starting Zig io_uring server...", .{});

        const address = try net.Address.parseIp(self.config.host, self.config.port);
        self.server_socket = try address.listen(.{ .reuse_address = true });
        const server_fd = self.server_socket.stream.handle;
        log.info("Server listening on {s}:{d}", .{ self.config.host, self.config.port });

        self.running = true;

        const req_allocator = self.arena.allocator();
        try self.submitAccept(server_fd, req_allocator);
        _ = try self.ring.submit();
        log.info("Initial accept submitted", .{});

        while (self.running) {
            defer _ = self.arena.reset(.retain_capacity);
            const req_allocator_loop = self.arena.allocator();

            _ = try self.ring.submitAndWait(1);

            var cqe_head = @atomicLoad(u32, self.ring.cq_head, .acquire);
            const cqe_tail = @atomicLoad(u32, self.ring.cq_tail, .acquire);

            while (cqe_head != cqe_tail) : (cqe_head +%= 1) {
                const index = cqe_head & self.ring.cq_mask.*;
                const cqe: *uring.CompletionRequest = @ptrCast(@volatileCast(&self.ring.cqes[index]));
                
                if (cqe.user_data == 0) {
                    log.warn("Received completion event with null user_data, skipping", .{});
                    continue;
                }
                
                const req: *IoRequest = @ptrFromInt(@as(u64, @intCast(cqe.user_data)));

                if (cqe.res < 0) {
                    log.err("Async operation failed for fd {d} (op: {any}): errno {d}", .{ req.fd, req.op, -cqe.res });
                    if (req.op == .recv or req.op == .send) {
                        _ = self.free_buffers.enqueue(req.buffer_index);
                    }
                    if (req.op == .recv or req.op == .send) {
                        if (self.connections.contains(req.fd)) {
                            try self.submitClose(req.fd, req_allocator_loop);
                        }
                    }
                    continue;
                }

                try self.handleCompletion(cqe, req, server_fd, req_allocator_loop);
            }
            
            @atomicStore(u32, self.ring.cq_head, cqe_tail, .release);
            _ = try self.ring.submit();
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
        self.server_socket.deinit();
    }

    fn handleCompletion(self: *Server, cqe: *uring.CompletionRequest, req: *IoRequest, server_fd: std.c.fd_t, req_allocator: std.mem.Allocator) !void {
        switch (req.op) {
            .accept => {
                const client_fd = @as(std.c.fd_t, @intCast(cqe.res));
                log.info("Accepted new connection on fd {d}", .{client_fd});

                const conn = try ClientConnection.init(self.allocator, client_fd);
                try self.connections.put(client_fd, conn);
                try self.submitRecv(client_fd, req_allocator);
                

                if (self.running) {
                    try self.submitAccept(server_fd, req_allocator);
                }
                _ = try self.ring.submit();
                
                log.info("Submitted recv for fd {d} and re-armed accept", .{client_fd});
            },
            .recv => {
                const bytes_read = @as(usize, @intCast(cqe.res));
                log.info("Received {d} bytes on fd {d}", .{ bytes_read, req.fd });
                
                if (bytes_read == 0) { // Client closed connection
                    log.info("Client on fd {d} closed connection.", .{req.fd});
                    try self.submitClose(req.fd, req_allocator);
                    _ = self.free_buffers.enqueue(req.buffer_index);
                    return;
                }

                const conn = self.connections.get(req.fd).?;
                const data = self.buffers[req.buffer_index][0..bytes_read];
                try conn.request_buffer.appendSlice(conn.allocator, data);

                _ = self.free_buffers.enqueue(req.buffer_index);

                const result = http.parse(conn.request_buffer.items);
                switch (result) {
                    .incomplete => {
                        try self.submitRecv(req.fd, req_allocator);
                        _ = try self.ring.submit();
                    },
                    .err => |err| {
                        log.warn("HTTP parse error on fd {d}: {s}", .{ req.fd, @errorName(err) });
                        const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        try self.submitSend(req.fd, response, req_allocator);
                        _ = try self.ring.submit();
                    },
                    .complete => |parsed_req| {
                        log.info("Parsed request from fd {d}: {s} {s}", .{ req.fd, @tagName(parsed_req.method), parsed_req.uri });

                        var headers_json = std.ArrayList(u8){};
                        defer headers_json.deinit(self.allocator);
                        
                        try headers_json.appendSlice(self.allocator, "\"headers\": [");
                        for (parsed_req.headers[0..parsed_req.header_count], 0..) |header, i| {
                            if (i > 0) try headers_json.appendSlice(self.allocator, ",");
                            try std.fmt.format(headers_json.writer(self.allocator), "{{\"name\":\"{s}\",\"value\":\"{s}\"}}", .{ header.name, header.value });
                        }
                        try headers_json.appendSlice(self.allocator, "]");
                        
                        const response_body = try std.fmt.allocPrint(self.allocator,
                            \\{{
                            \\  "method": "{s}",
                            \\  "uri": "{s}",
                            \\  "version": "{s}",
                            \\  {s},
                            \\  "raw_request": "{s}"
                            \\}}
                        , .{ 
                            @tagName(parsed_req.method),
                            parsed_req.uri,
                            if (parsed_req.version == .http11) "HTTP/1.1" else "HTTP/1.0",
                            headers_json.items,
                            conn.request_buffer.items
                        });
                        defer self.allocator.free(response_body);
                        
                        const response = try std.fmt.allocPrint(self.allocator,
                            \\HTTP/1.1 200 OK
                            \\Content-Type: application/json
                            \\Content-Length: {d}
                            \\Connection: keep-alive
                            \\
                            \\{s}
                        , .{ response_body.len, response_body });
                        defer self.allocator.free(response);

                        try self.submitSend(req.fd, response, req_allocator);
                        _ = try self.ring.submit();
                    },
                }
            },
            .send => {
                log.info("Sent {d} bytes to fd {d}", .{ cqe.res, req.fd });
                _ = self.free_buffers.enqueue(req.buffer_index); // Return sent buffer to pool

                if (self.connections.fetchRemove(req.fd)) |entry| {
                    entry.value.deinit();
                    try self.submitClose(req.fd, req_allocator);
                    _ = try self.ring.submit();
                }
            },
            .close => {
                log.info("Closed connection on fd {d}", .{req.fd});
                if (self.connections.fetchRemove(req.fd)) |entry| {
                    entry.value.deinit();
                }
            },
        }
    }

    fn submitAccept(self: *Server, server_fd: std.c.fd_t, req_allocator: std.mem.Allocator) !void {
        const req = try req_allocator.create(IoRequest);
        req.* = .{ .op = .accept, .fd = server_fd, .buffer_index = 0 };

        const sqe = self.ring.getSqe() orelse {
            log.err("Submission queue full, cannot accept.", .{});
            return error.SubmissionQueueFull;
        };

        sqe.* = std.mem.zeroes(@TypeOf(sqe.*));
        sqe.opcode = @intFromEnum(uring.Opcode.accept);
        sqe.fd = server_fd;
        sqe.off = 0; 
        sqe.addr = 0;
        sqe.len = 0; 
        sqe.op_flags = 0;  // No special flags
        sqe.user_data = @intFromPtr(req);
        self.ring.advanceSq(1);
    }

    fn submitRecv(self: *Server, client_fd: std.c.fd_t, req_allocator: std.mem.Allocator) !void {
        const buffer_idx = self.free_buffers.dequeue() orelse {
            log.err("No free buffers left fd {d}", .{client_fd});
            return error.FreeBuffersFull;
        };

        const req = try req_allocator.create(IoRequest);
        req.* = .{ .op = .recv, .fd = client_fd, .buffer_index = buffer_idx };
        
        const sqe = self.ring.getSqe() orelse {
            log.err("Submission queue is full", .{});
            _ = self.free_buffers.enqueue(buffer_idx);
            return;
        };

        sqe.* = std.mem.zeroes(@TypeOf(sqe.*));
        sqe.opcode = @intFromEnum(uring.Opcode.recv);
        sqe.fd = client_fd;
        sqe.off = 0;  // Must be zero for recv
        sqe.addr = @intFromPtr(self.buffers[buffer_idx].ptr);
        sqe.len = @intCast(self.config.buffer_size);
        sqe.op_flags = 0;  // No MSG_* flags needed for basic recv
        sqe.user_data = @intFromPtr(req);
        
        self.ring.advanceSq(1);
        
        log.info("submitRecv: fd={d}, buffer_idx={d}, buf_addr=0x{x}", .{ client_fd, buffer_idx, @intFromPtr(self.buffers[buffer_idx].ptr) });
    }

    fn submitSend(self: *Server, client_fd: std.c.fd_t, data: []const u8, req_allocator: std.mem.Allocator) !void {
        const buffer_idx = self.free_buffers.dequeue() orelse {
            log.err("No free buffers available for send on fd {d}", .{client_fd});
            return;
        };

        const buf = self.buffers[buffer_idx];
        const data_len = @min(data.len, buf.len);
        @memcpy(buf[0..data_len], data[0..data_len]);

        const req = try req_allocator.create(IoRequest);
        req.* = .{ .op = .send, .fd = client_fd, .buffer_index = @intCast(buffer_idx) };

        const sqe = self.ring.getSqe() orelse {
            log.err("Submission queue full, cannot send.", .{});
            _ = self.free_buffers.enqueue(buffer_idx);
            return;
        };
        
        sqe.* = std.mem.zeroes(@TypeOf(sqe.*));
        sqe.opcode = @intFromEnum(uring.Opcode.send);
        sqe.fd = client_fd;
        sqe.off = 0;  
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @intCast(data_len);
        sqe.op_flags = 0;  // No MSG_* flags
        sqe.user_data = @intFromPtr(req);
        
        self.ring.advanceSq(1);
    }

    fn submitClose(self: *Server, client_fd: std.c.fd_t, req_allocator: std.mem.Allocator) !void {
        const req = try req_allocator.create(IoRequest);
        req.* = .{ .op = .close, .fd = client_fd, .buffer_index = 0 };

        const sqe = self.ring.getSqe() orelse {
            log.err("Submission queue full, cannot close.", .{});
            return;
        };
        sqe.* = std.mem.zeroes(@TypeOf(sqe.*));
        sqe.opcode = @intFromEnum(uring.Opcode.close);
        sqe.fd = client_fd;
        sqe.off = 0; 
        sqe.addr = 0;
        sqe.len = 0; 
        sqe.op_flags = 0;
        sqe.user_data = @intFromPtr(req);
        self.ring.advanceSq(1);
    }
};

const OpType = enum {
    accept,
    recv,
    send,
    close,
};

const IoRequest = struct {
    op: OpType,
    fd: std.c.fd_t,
    buffer_index: u16,
};

const ClientConnection = struct {
    fd: std.c.fd_t,
    allocator: std.mem.Allocator,
    request_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, fd: std.c.fd_t) !*ClientConnection {
        const self = try allocator.create(ClientConnection);
        self.* = .{
            .fd = fd,
            .allocator = allocator,
            .request_buffer = try std.ArrayList(u8).initCapacity(allocator, BUFFER_SIZE),
        };
        return self;
    }

    pub fn deinit(self: *ClientConnection) void {
        self.request_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn resetForNextRequest(self: *ClientConnection) void {
        self.request_buffer.clearRetainingCapacity();
    }
};

