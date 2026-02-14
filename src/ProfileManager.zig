const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const rl = @import("raylib");
const Rectangle = rl.Rectangle;

const WindowState = @import("WindowState.zig").WindowState;
const NodeMod = @import("ProfileNode.zig");

pub const ProfileManager = @This();

pub const Config = struct {
    enabled: bool = true,
    max_nodes: usize = 15,
    x: f32 = 100,
    y: f32 = 300,
    w: f32 = 700,
    h: f32 = 240,
};

pub fn Profiler(comptime ZoneId: type, comptime config: Config) type {
    if (@typeInfo(ZoneId) != .@"enum") {
        @compileError("ZoneId must be an enum type");
    }

    const zone_count = @typeInfo(ZoneId).@"enum".fields.len;

    if (zone_count == 0) {
        @compileError("ZoneId must have at least one variant");
    }

    const ProfileNode = NodeMod.Node(ZoneId);

    return struct {
        const Self = @This();

        allocator: Allocator,
        root: *ProfileNode,
        current: *ProfileNode,
        rows: ArrayList(Row),
        scroll_offset: f32 = 0,
        dragging: bool = false,
        offset: rl.Vector2,
        paused: bool = false,
        is_shown: bool = false,

        window: WindowState = .{
            .x = config.x,
            .y = config.y,
            .w = config.w,
            .h = config.h,
        },

        node_pool: [config.max_nodes]ProfileNode = undefined,
        node_pool_count: usize = 0,

        selected_node: ?*ProfileNode = null,

        const Row = struct {
            node: *ProfileNode,
            depth: i32,
        };

        pub fn init(allocator: Allocator, root_zone: ZoneId) !*Self {
            const self = try allocator.create(Self);
            const list = try ArrayList(Row).initCapacity(allocator, config.max_nodes);

            self.* = .{
                .allocator = allocator,
                .root = undefined,
                .current = undefined,
                .rows = list,
                .offset = rl.Vector2.zero(),
            };

            const root_node = self.allocNode().?;
            root_node.* = ProfileNode.init(root_zone, null);
            self.root = root_node;
            self.current = root_node;

            return self;
        }

        fn allocNode(self: *Self) ?*ProfileNode {
            if (self.node_pool_count >= config.max_nodes) return null;
            const node = &self.node_pool[self.node_pool_count];
            self.node_pool_count += 1;
            return node;
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit(self.allocator);
            // Release the manager itself!
            self.allocator.destroy(self);
        }

        pub fn startZone(self: *Self, id: ZoneId) void {
            if (comptime !config.enabled) return;
            const index = @intFromEnum(id);
            if (self.current.children[index] == null) {
                const new_node = self.allocNode() orelse return;
                new_node.* = ProfileNode.init(id, self.current);
                self.current.children[index] = new_node;
            }

            const node = self.current.children[index].?;
            node.count += 1;
            node.start_time = std.time.microTimestamp();
            self.current = node;
        }

        pub fn endZone(self: *Self) void {
            if (comptime !config.enabled) return;
            const now = std.time.microTimestamp();
            const node = self.current;
            const duration = now - node.start_time;

            node.hier_total += duration;
            node.self_total += (duration - node.children_hier_sum);
            node.children_hier_sum = 0;

            if (node.parent) |p| {
                p.children_hier_sum += duration;
                self.current = p;
            }
        }

        /// Reset everything back to the initial state.
        fn resetNode(node: *ProfileNode) void {
            node.hier_total = 0;
            node.self_total = 0;
            node.count = 0;
            node.children_hier_sum = 0;

            for (&node.children) |maybe_child| {
                if (maybe_child) |child| {
                    resetNode(child);
                }
            }
        }

        pub fn nextFrame(self: *Self) void {
            if (comptime !config.enabled) return;
            resetNode(self.root);
            self.current = self.root;
        }

        pub fn handleInput(self: *Self) void {
            if (rl.isKeyPressed(.tab)) {
                self.is_shown = !self.is_shown;
            }

            if (rl.isKeyPressed(.space)) {
                self.paused = !self.paused;
            }

            const mouse_pos = rl.getMousePosition();

            if (rl.isMouseButtonPressed(.left)) {
                const header_rec = Rectangle.init(self.window.x, self.window.y, self.window.w, 20);
                if (rl.checkCollisionPointRec(mouse_pos, header_rec)) {
                    self.dragging = true;
                    self.offset.x = mouse_pos.x - self.window.x;
                    self.offset.y = mouse_pos.y - self.window.y;
                }
            }

            if (self.dragging) {
                self.window.x = mouse_pos.x - self.offset.x;
                self.window.y = mouse_pos.y - self.offset.y;

                if (rl.isMouseButtonReleased(.left)) self.dragging = false;
            }
        }

        pub fn draw(self: *Self) !void {
            if (comptime !config.enabled) return;

            self.handleInput();

            if (!self.is_shown) return;

            const frame_rec = Rectangle.init(self.window.x, self.window.y, self.window.w, self.window.h);
            const header_rec = Rectangle.init(self.window.x, self.window.y, self.window.w, 20);

            const row_h = 20;

            rl.drawRectangleRec(frame_rec, rl.fade(.gray, 0.3));
            rl.drawRectangleRec(header_rec, .black);

            self.rows.clearRetainingCapacity();

            // NOTE: Flattening here!!!
            try flatten(self.root, 0, &self.rows, self.allocator);

            const total_h = @as(f32, @floatFromInt(self.rows.items.len)) * row_h;

            // Scrolling
            const wheel = rl.getMouseWheelMove();
            self.scroll_offset -= wheel * row_h;
            const max_scroll = if (total_h > self.window.h - 20) total_h - (self.window.h - 20) else 0;
            self.scroll_offset = rl.math.clamp(self.scroll_offset, 0, max_scroll);

            rl.beginScissorMode(
                @intFromFloat(self.window.x),
                @intFromFloat(self.window.y + 20),
                @intFromFloat(self.window.w),
                @intFromFloat(self.window.h - 20),
            );

            // Rows
            for (self.rows.items, 0..) |row, i| {
                if (!self.paused) {
                    row.node.updateSmoothing();
                }

                const row_y = @as(f32, @floatFromInt(toUsize(self.window.y + 20) + (i * toUsize(20)))) - self.scroll_offset;

                if (row_y + 20 > self.window.y and row_y < self.window.y + self.window.h) {
                    const color = if (i % 2 == 0) rl.Color.gray else rl.Color.dark_gray;

                    const row_rec = Rectangle.init(self.window.x, row_y, self.window.w, 20);

                    rl.drawRectangleRec(row_rec, color);

                    const prefix = if (row.node.childCount() == 0) " " else if (row.node.collapsed) "+ " else "- ";
                    const label = rl.textFormat("%s", .{prefix.ptr});

                    rl.drawText(
                        label,
                        @as(i32, @intFromFloat(row_rec.x)) + (row.depth * 15),
                        @intFromFloat(row_y + 2),
                        20,
                        .white,
                    );

                    rl.drawText(
                        @tagName(row.node.id),
                        @as(i32, @intFromFloat(row_rec.x + 15)) + (row.depth * 15),
                        @intFromFloat(row_y + 2),
                        20,
                        .white,
                    );

                    rl.drawText(
                        rl.textFormat("%.3fms", .{@as(f32, @floatFromInt(row.node.self_total)) / 1000.0}),
                        toInt(self.window.x + 250),
                        toInt(row_y),
                        20,
                        .green,
                    );
                    rl.drawText(
                        rl.textFormat("%.3fms", .{@as(f32, @floatFromInt(row.node.hier_total)) / 1000.0}),
                        toInt(self.window.x + 350),
                        toInt(row_y),
                        20,
                        .yellow,
                    );
                    rl.drawText(
                        rl.textFormat("%d", .{row.node.count}),
                        toInt(self.window.x + 450),
                        toInt(row_y),
                        20,
                        .red,
                    );
                    rl.drawText(
                        rl.textFormat("%.3fms", .{row.node.smoothed_self}),
                        toInt(self.window.x + 500),
                        toInt(row_y),
                        20,
                        .red,
                    );
                    rl.drawText(
                        rl.textFormat("%.3fms", .{row.node.smoothed_hier}),
                        toInt(self.window.x + 600),
                        toInt(row_y),
                        20,
                        .maroon,
                    );

                    if (rl.checkCollisionPointRec(rl.getMousePosition(), row_rec)) {
                        rl.drawRectangleRec(row_rec, rl.fade(.red, 0.3));
                        if (rl.isMouseButtonPressed(.left)) {
                            row.node.collapsed = !row.node.collapsed;
                            self.selected_node = row.node;
                        }
                    }
                }
            }

            rl.endScissorMode();

            rl.drawText("Self", toInt(self.window.x + 250), toInt(self.window.y), 20, .white);
            rl.drawText("Hier", toInt(self.window.x + 350), toInt(self.window.y), 20, .white);
            rl.drawText("Total", toInt(self.window.x + 450), toInt(self.window.y), 20, .white);

            self.drawGraph(self.window.x, self.window.y + self.window.h + 20, self.window.w, 100);
        }

        fn drawGraph(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
            if (self.selected_node == null) return;

            const rec = Rectangle.init(x, y, w, h);
            rl.drawRectangleRec(rec, .black);

            var max_val: f64 = 0.1;
            var prev: ?rl.Vector2 = null;

            for (self.selected_node.?.history) |val| {
                if (val > max_val) max_val = val;
            }

            for (0..self.selected_node.?.history.len) |i| {
                const actual_index = (self.selected_node.?.history_index + i) % 512;
                const val = self.selected_node.?.history[actual_index];

                const x_start = x + (@as(f32, @floatFromInt(i)) / 511) * w;
                const normalized = val / max_val;
                const y_start = y + h - (@as(f32, @floatCast(normalized)) * h);

                const current = rl.Vector2.init(x_start, y_start);

                if (prev) |p| {
                    rl.drawLineEx(p, current, 1, .white);

                    const scan_x = x + (@as(f32, @floatFromInt(self.selected_node.?.history_index)) / 512.0) * w;
                    rl.drawLineEx(
                        rl.Vector2.init(scan_x, y),
                        rl.Vector2.init(scan_x, y + h),
                        1,
                        .white,
                    );
                }
                prev = current;
            }
        }

        pub fn flatten(node: *ProfileNode, depth: i32, list: *ArrayList(Row), allocator: Allocator) !void {
            try list.append(allocator, .{ .node = node, .depth = depth });

            if (!node.collapsed) {
                for (node.children) |maybe_child| {
                    if (maybe_child) |child| {
                        try flatten(child, depth + 1, list, allocator);
                    }
                }
            }
        }
    };
}

pub fn toInt(val: f32) i32 {
    return @intFromFloat(val);
}
pub fn toUsize(val: f32) usize {
    return @intFromFloat(val);
}
