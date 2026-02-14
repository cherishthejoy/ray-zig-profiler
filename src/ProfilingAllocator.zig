const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// NOTE: [Self-time] how much time the procedure takes itself
// NOTE: [Hierarchical-time] how much time the procedure takes and whatever it's calling inside
// NOTE: [Count] how many times that procedure is being called

const ProfilingAllocator = @This();

const MAX_ALLOCATIONS = 64;
const TRACE_DEPTH = 8;

backing_allocator: std.mem.Allocator,
allocation_count: usize = 0,
total_bytes_requested: usize = 0,
allocations: [MAX_ALLOCATIONS]AllocationInfo = undefined,

start_time_ns: i128,
peak_bytes: usize = 0,
peak_time_ns: i128,
current_bytes: usize = 0,

const AllocationInfo = struct {
    ptr: [*]u8, // pointer to the allocator
    size: usize, // bytes requested
    freed: bool, // was free() called on this?
    alloc_time_ns: i128,
    free_time_ns: i128,

    trace: std.builtin.StackTrace, // where was this allocated
    trace_addresses: [TRACE_DEPTH]usize = undefined,
};

pub fn init(backing_allocator: std.mem.Allocator) ProfilingAllocator {
    return .{
        .backing_allocator = backing_allocator,
        .start_time_ns = std.time.nanoTimestamp(),
        .peak_time_ns = 0,
    };
}

pub fn allocator(self: *ProfilingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

    const ptr = self.backing_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
    if (self.allocation_count < MAX_ALLOCATIONS) {
        self.allocations[self.allocation_count] = .{
            .ptr = ptr,
            .size = len,
            .freed = false,
            .trace = .{ .instruction_addresses = &self.allocations[self.allocation_count].trace_addresses, .index = 0 },
            .trace_addresses = undefined,
            .alloc_time_ns = std.time.nanoTimestamp(),
            .free_time_ns = 0,
        };
        // NOTE: ret_addr is passed into alloc() by the allocator interface - it's the return
        // address of whoever called alloc.
        std.debug.captureStackTrace(ret_addr, &self.allocations[self.allocation_count].trace);
        self.allocation_count += 1;
    }
    self.current_bytes += len;

    if (self.current_bytes > self.peak_bytes) {
        self.peak_bytes = self.current_bytes;
        self.peak_time_ns = std.time.nanoTimestamp();
    }

    self.total_bytes_requested += len;

    return ptr;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

    for (self.allocations[0..self.allocation_count]) |*info| {
        if (info.ptr == buf.ptr and !info.freed) {
            info.freed = true;
            info.free_time_ns = std.time.nanoTimestamp();
            self.current_bytes -= info.size;
            break;
        }
    }
    self.backing_allocator.rawFree(buf, alignment, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));
    return self.backing_allocator.rawResize(buf, alignment, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));
    return self.backing_allocator.rawRemap(buf, alignment, new_len, ret_addr);
}

pub fn reportAllocation(self: *ProfilingAllocator) void {
    var leaked_count: usize = 0;
    var leaked_bytes: usize = 0;

    std.debug.print("\n=== Leak Report ===\n", .{});
    for (self.allocations[0..self.allocation_count], 0..) |info, i| {
        const status = if (info.freed) "freed" else "LEAKED";
        std.debug.print("[{d}] {d} bytes - {s}\n", .{ i, info.size, status });
        if (!info.freed) {
            leaked_count += 1;
            leaked_bytes += info.size;
            std.debug.dumpStackTrace(info.trace);
        }
    }
    std.debug.print("---------------------------\n", .{});
    std.debug.print("Total: {d} allocations, {d} leaked ({d} bytes)\n", .{ self.allocation_count, leaked_count, leaked_bytes });
}

pub fn reportTimeline(self: *ProfilingAllocator) void {
    std.debug.print("\n=== Allocation Timeline ===\n", .{});

    for (self.allocations[0..self.allocation_count]) |info| {
        const alloc_ms = @as(f64, @floatFromInt(info.alloc_time_ns - self.start_time_ns)) / 1_000_000;
        std.debug.print("[{d:.3}ms] + {d} bytes\n", .{ alloc_ms, info.size });

        if (info.freed) {
            const free_ms = @as(f64, @floatFromInt(info.free_time_ns - self.start_time_ns)) / 1_000_000;
            std.debug.print("[{d:.3}ms] -{d} bytes freed\n", .{ free_ms, info.size });
        }
    }
    std.debug.print("---------------------------------------\n", .{});
    const peak_ms = @as(f64, @floatFromInt(self.peak_time_ns - self.start_time_ns)) / 1_000_000;
    std.debug.print("Peak: {d} bytes at {d:.3}ms\n", .{ self.peak_bytes, peak_ms });
    std.debug.print("Final: {d} bytes | Total allocated: {d} bytes\n", .{ self.current_bytes, self.total_bytes_requested });
}

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
    .remap = remap,
};
