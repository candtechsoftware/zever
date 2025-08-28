const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const posix = std.posix;

pub const SubmissionQueueEntry = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u8,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    op_flags: u32,
    user_data: u64,
    _pad: [3]u64 = .{ 0, 0, 0 },
};

pub const CompletionRequest = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

pub const Opcode = enum(u8) {
    nop = 0,
    readv = 1,
    writev = 2,
    accept = 13,
    close = 19,
    send = 26,
    recv = 27,
};

pub const IORING_SETUP_IOPOLL = 1 << 0;
pub const IORING_SETUP_SQPOLL = 1 << 1;
pub const IORING_SETUP_SQ_AFF = 1 << 2;
pub const IORING_SETUP_CQSIZE = 1 << 3;

pub const MSG_DONTWAIT = 64;

pub const IOSQE_FIXED_FILE = 1 << 0;
pub const IOSQE_IO_DRAIN = 1 << 1;
pub const IOSQE_IO_LINK = 1 << 2;
pub const IOSQE_IO_HARDLINK = 1 << 3;
pub const IOSQE_ASYNC = 1 << 4;
pub const IOSQE_BUFFER_SELECT = 1 << 5;

const __NR_io_uring_setup = 425;
const __NR_io_uring_enter = 426;
const __NR_io_uring_register = 427;

const IORING_OFF_SQ_RING = 0x00000000;
const IORING_OFF_CQ_RING = 0x08000000;
const IORING_OFF_SQES = 0x10000000;

const IORING_ENTER_GETEVENTS = 1 << 0;
const IORING_ENTER_SQ_WAKEUP = 1 << 1;

const IORING_REGISTER_BUFFERS = 0;

pub const Ring = struct {
    fd: c.fd_t,
    sq_ring_ptr: [*]volatile u8,
    cq_ring_ptr: [*]volatile u8,
    sqes: [*]volatile SubmissionQueueEntry,
    cqes: [*]volatile CompletionRequest,
    sq_ring_sz: usize,
    cq_ring_sz: usize,

    sq_head: *volatile u32,
    sq_tail: *volatile u32,
    sq_mask: *const u32,
    sq_dropped: *volatile u32,
    sq_array: [*]u32,
    
    sqe_head: u32,
    sqe_tail: u32,

    cq_head: *volatile u32,
    cq_tail: *volatile u32,
    cq_mask: *const u32,

    pub fn init(entries: u32, flags: u32) !Ring {
        const pt = extern struct {
            sq_entries: u32,
            cq_entries: u32,
            flags: u32,
            sq_thread_cpu: u32,
            sq_thread_idle: u32,
            features: u32,
            resv: [4]u32,
            sq_off: extern struct {
                head: u32,
                tail: u32,
                ring_mask: u32,
                ring_entries: u32,
                flags: u32,
                dropped: u32,
                array: u32,
                resv1: u32,
                resv2: u64,
            },
            cq_off: extern struct {
                head: u32,
                tail: u32,
                ring_mask: u32,
                ring_entries: u32,
                overflow: u32,
                cqes: u32,
                resv: [2]u64,
            },
        };
        var p: pt = std.mem.zeroes(pt);
        p.flags = flags;

        const ring_fd = linux.syscall5(@enumFromInt(__NR_io_uring_setup), entries, @intFromPtr(&p), 0, 0, 0);
        if (ring_fd < 0) return std.os.unexpectedErrno(c.errno);

        const sq_ring_sz = p.sq_off.array + p.sq_entries * @sizeOf(u32);
        const cq_ring_sz = p.cq_off.cqes + p.cq_entries * @sizeOf(CompletionRequest);

        const sq_ptr = posix.mmap(null, sq_ring_sz, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED, .POPULATE = true }, @intCast(ring_fd), IORING_OFF_SQ_RING) catch |err| {
            std.log.err("mmap sq_ring failed: {s}", .{@errorName(err)});
            return err;
        };
        const cq_ptr = posix.mmap(null, cq_ring_sz, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED, .POPULATE = true }, @intCast(ring_fd), IORING_OFF_CQ_RING) catch |err| {
            std.log.err("mmap cq_ring failed: {s}", .{@errorName(err)});
            return err;
        };

        return Ring{
            .fd = @intCast(ring_fd),
            .sq_ring_ptr = @ptrCast(sq_ptr.ptr),
            .cq_ring_ptr = @ptrCast(cq_ptr.ptr),
            .sqes = @ptrCast(posix.mmap(null, p.sq_entries * @sizeOf(SubmissionQueueEntry), posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED, .POPULATE = true }, @intCast(ring_fd), IORING_OFF_SQES) catch |err| {
                std.log.err("mmap sqes failed: {s}", .{@errorName(err)});
                return err;
            }),
            .sq_ring_sz = sq_ring_sz,
            .cq_ring_sz = cq_ring_sz,
            .sq_head = @ptrFromInt(@intFromPtr(sq_ptr.ptr) + p.sq_off.head),
            .sq_tail = @ptrFromInt(@intFromPtr(sq_ptr.ptr) + p.sq_off.tail),
            .sq_mask = @ptrFromInt(@intFromPtr(sq_ptr.ptr) + p.sq_off.ring_mask),
            .sq_dropped = @ptrFromInt(@intFromPtr(sq_ptr.ptr) + p.sq_off.dropped),
            .sq_array = @ptrFromInt(@intFromPtr(sq_ptr.ptr) + p.sq_off.array),
            .sqe_head = 0,
            .sqe_tail = 0,
            .cqes = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + p.cq_off.cqes),
            .cq_head = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + p.cq_off.head),
            .cq_tail = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + p.cq_off.tail),
            .cq_mask = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + p.cq_off.ring_mask),
        };
    }

    pub fn deinit(self: *Ring) void {
        _ = posix.munmap(@as([*]align(4096) u8, @alignCast(@ptrCast(@volatileCast(self.sq_ring_ptr))))[0..self.sq_ring_sz]);
        _ = posix.munmap(@as([*]align(4096) u8, @alignCast(@ptrCast(@volatileCast(self.cq_ring_ptr))))[0..self.cq_ring_sz]);
        posix.close(self.fd);
    }

    pub fn getSqe(self: *Ring) ?*SubmissionQueueEntry {
        const head = @atomicLoad(u32, self.sq_head, .acquire);
        const next = self.sqe_tail +% 1;
        if (next -% head > self.sq_mask.* + 1) {
            return null;
        }
        const sqe = &self.sqes[self.sqe_tail & self.sq_mask.*];
        self.sqe_tail = next;
        sqe.* = std.mem.zeroes(SubmissionQueueEntry);
        return @ptrCast(@volatileCast(sqe));
    }

    pub fn advanceSq(self: *Ring, count: u32) void {
        _ = self;
        _ = count;
        // This is now handled by flush_sq
    }
    
    pub fn flush_sq(self: *Ring) u32 {
        if (self.sqe_head != self.sqe_tail) {
            const to_submit = self.sqe_tail -% self.sqe_head;
            var tail = self.sq_tail.*;
            var i: u32 = 0;
            while (i < to_submit) : (i += 1) {
                self.sq_array[tail & self.sq_mask.*] = self.sqe_head & self.sq_mask.*;
                tail +%= 1;
                self.sqe_head +%= 1;
            }
            @atomicStore(u32, self.sq_tail, tail, .release);
        }
        return self.sqe_tail -% @atomicLoad(u32, self.sq_head, .acquire);
    }

    pub fn submit(self: *Ring) !usize {
        const submitted = self.flush_sq();
        const ret = linux.syscall6(@enumFromInt(__NR_io_uring_enter), @intCast(self.fd), submitted, 0, 0, 0, 0);
        if (ret < 0) return std.os.unexpectedErrno(@enumFromInt(@as(u32, @intCast(-ret))));
        return @intCast(ret);
    }

    pub fn submitAndWait(self: *Ring, wait_nr: u32) !usize {
        const submitted = self.flush_sq();
        const ret = linux.syscall6(@enumFromInt(__NR_io_uring_enter), @intCast(self.fd), submitted, wait_nr, IORING_ENTER_GETEVENTS, 0, 0);
        if (ret < 0) return std.os.unexpectedErrno(@enumFromInt(@as(u32, @intCast(-ret))));
        return @intCast(ret);
    }

    pub fn registerBuffers(self: *Ring, iovecs: []const std.posix.iovec) !void {
        const ret = linux.syscall6(@enumFromInt(__NR_io_uring_register), @intCast(self.fd), IORING_REGISTER_BUFFERS, @intFromPtr(iovecs.ptr), iovecs.len, 0, 0);
        if (ret < 0) return std.os.unexpectedErrno(c.errno);
    }

};
