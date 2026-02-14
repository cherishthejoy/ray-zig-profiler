pub fn Node(comptime ZoneId: type) type {
    const ZONE_COUNT = @typeInfo(ZoneId).@"enum".fields.len;

    return struct {
        const Self = @This();

        id: ZoneId,
        count: u32 = 0,
        hier_total: i64 = 0,
        self_total: i64 = 0,
        start_time: i64 = 0,
        children_hier_sum: i64 = 0,

        history: [512]f64 = [_]f64{0} ** 512,
        history_index: usize = 0,

        smoothed_hier: f64 = 0,
        smoothed_self: f64 = 0,

        parent: ?*Self = null,
        children: [ZONE_COUNT]?*Self = [_]?*Self{null} ** ZONE_COUNT,

        collapsed: bool = false,

        pub fn init(id: ZoneId, parent: ?*Self) Self {
            return .{
                .id = id,
                .parent = parent,
            };
        }

        pub fn updateSmoothing(self: *Self) void {
            const alpha: f64 = 0.03;

            const target_hier = @as(f64, @floatFromInt(self.hier_total)) / 1000.0;
            const target_self = @as(f64, @floatFromInt(self.self_total)) / 1000.0;

            self.smoothed_self += (target_self - self.smoothed_self) * alpha;
            self.smoothed_hier += (target_hier - self.smoothed_hier) * alpha;

            self.history[self.history_index] = self.smoothed_self;
            self.history_index = (self.history_index + 1) % 512;
        }

        pub fn childCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.children) |child| {
                if (child != null) count += 1;
            }
            return count;
        }
    };
}
