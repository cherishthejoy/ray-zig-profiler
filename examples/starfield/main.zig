const std = @import("std");
// const foo = @import("foo");
const rl = @import("raylib");

const pr = @import("profile");

const Zones = enum {
    Frame,
    Update,
    Render,
    Text,
};

const Profiler = pr.Profiler(Zones, .{ .max_nodes = 5 });

const width = 1600;
const height = 900;

const STAR_COUNT = 1000;
var speed: f32 = 10.0 / 9.0;

const Starfield = struct {
    const Self = @This();

    draw_line: bool = true,

    pub fn init() Self {
        return .{};
    }

    pub fn input(self: *Self) void {
        const mouse_move = rl.getMouseWheelMove();
        if (mouse_move != 0) speed += 2.0 * mouse_move / 9.0;
        if (speed < 0.0) speed = 0.1 else if (speed > 2.0) speed = 2.0;

        if (rl.isKeyPressed(.space)) self.draw_line = !self.draw_line;
    }

    pub fn update(self: *Self, star_pos: []rl.Vector3, screen_pos: []rl.Vector2) void {
        self.input();

        const dt = rl.getFrameTime();
        for (0..STAR_COUNT) |i| {
            star_pos[i].z -= dt * speed;

            screen_pos[i] = rl.Vector2.init(
                width * 0.5 + star_pos[i].x / star_pos[i].z,
                height * 0.5 + star_pos[i].y / star_pos[i].z,
            );

            if ((star_pos[i].z < 0.0) or (screen_pos[i].x < 0) or (screen_pos[i].y < 0.0) or (screen_pos[i].x > width) or (screen_pos[i].y > height)) {
                star_pos[i].x = @floatFromInt(rl.getRandomValue((-width * 0.5), width * 0.5));
                star_pos[i].y = @floatFromInt(rl.getRandomValue((-height * 0.5), height * 0.5));
                star_pos[i].z = 1.0;
            }
        }
    }

    pub fn draw(self: *Self, star_pos: []rl.Vector3, screen_pos: []rl.Vector2, pf: *Profiler) void {
        for (0..STAR_COUNT) |i| {
            if (self.draw_line) {
                const t = rl.math.clamp(star_pos[i].z + (1.0 / 32.0), 0.0, 1.0);

                if ((t - star_pos[i].z) > 1e-3) {
                    const start_pos = rl.Vector2.init(
                        width * 0.5 + star_pos[i].x / t,
                        height * 0.5 + star_pos[i].y / t,
                    );

                    rl.drawLineV(start_pos, screen_pos[i], .white);
                }
            } else {
                const radius = rl.math.lerp(star_pos[i].z, 1.0, 5.0);
                rl.drawCircleV(screen_pos[i], radius, .white);
            }
        }

        pf.startZone(.Text);
        rl.drawText(
            rl.textFormat("[MOUSE WHEEL] Current speed: %.f", .{9.0 * speed / 2.0}),
            10,
            40,
            20,
            .white,
        );

        const line = if (self.draw_line) "Lines" else "Circles";

        rl.drawText(
            rl.textFormat("[SPACE] Current draw mode: %s", .{line.ptr}),
            10,
            70,
            20,
            .white,
        );

        rl.drawFPS(10, 10);
        pf.endZone();
    }
};

pub fn main() anyerror!void {
    rl.initWindow(width, height, "Test");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();

    var profiling = pr.ProfAllocator.init(arena.allocator());
    defer profiling.reportTimeline();
    defer profiling.reportAllocation();

    const allocator = profiling.allocator();

    var prof = try Profiler.init(allocator, .Frame);
    defer prof.deinit();

    var stars: [STAR_COUNT]rl.Vector3 = undefined;
    var stars_screen_pos: [STAR_COUNT]rl.Vector2 = undefined;

    _ = &stars_screen_pos;

    for (0..STAR_COUNT) |i| {
        stars[i].x = @floatFromInt(rl.getRandomValue(
            (-width * 0.5),
            width * 0.5,
        ));
        stars[i].y = @floatFromInt(rl.getRandomValue(
            (-height * 0.5),
            height * 0.5,
        ));
        stars[i].z = 1.0;
    }

    var star_field = Starfield.init();

    while (!rl.windowShouldClose()) {
        prof.nextFrame();
        prof.startZone(.Update);

        star_field.update(&stars, &stars_screen_pos);

        prof.endZone();

        rl.beginDrawing();
        rl.clearBackground(.black);

        prof.startZone(.Render);
        star_field.draw(&stars, &stars_screen_pos, prof);
        prof.endZone();

        try prof.draw();

        rl.endDrawing();
    }
}
