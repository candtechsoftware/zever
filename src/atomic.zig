const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub fn MpscQueue(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        buffer: [cap]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init() Self {
            return .{};
        }

        pub fn enqueue(self: *Self, item: T) bool {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);

            if (tail - head >= cap) return false;

            const pos = tail % cap;
            self.buffer[pos] = item;

            _ = self.tail.fetchAdd(1, .release);
            return true;
        }

        pub fn dequeue(self: *Self) ?T {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);

            if (head == tail) return null;

            const pos = head % cap;
            const item = self.buffer[pos];

            _ = self.head.fetchAdd(1, .release);

            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }
    };
}
