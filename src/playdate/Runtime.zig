const std = @import("std");
const api = @import("api.zig");
const game = @import("game");
const algs = @import("algs_and_types");
const p = algs.primitives;
const Allocator = @import("Allocator.zig");

const log = std.log.scoped(.runtime);

const Self = @This();

const ButtonsLog = struct {
    button: api.PDButtons = 0,
    pressed_at: u32 = 0,
    released_at: u32 = 0,
    release_count: u16 = 0,
};

playdate: *api.PlaydateAPI,
alloc: std.mem.Allocator,
prng: std.rand.Xoshiro256,
text_font: ?*api.LCDFont,
sprites_font: ?*api.LCDFont,
button_log: ButtonsLog = .{},

pub fn create(playdate: *api.PlaydateAPI) !*Self {
    const err: ?*[*c]const u8 = null;

    const text_font = playdate.graphics.loadFont("Roobert-11-Mono-Condensed.pft", err) orelse {
        const err_msg = err orelse "Unknown error.";
        std.debug.panic("Error on load font for text: {s}", .{err_msg});
    };
    errdefer _ = playdate.system.realloc(text_font, 0);

    const sprites_font = playdate.graphics.loadFont("sprites-font.pft", err) orelse {
        const err_msg = err orelse "Unknown error.";
        std.debug.panic("Error on load font for sprites: {s}", .{err_msg});
    };
    errdefer _ = playdate.system.realloc(sprites_font, 0);

    playdate.graphics.setFont(sprites_font);
    playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeCopy);

    var millis: c_uint = undefined;
    _ = playdate.system.getSecondsSinceEpoch(&millis);

    const alloc = Allocator.allocator(playdate);
    const runtime = try alloc.create(Self);
    runtime.* = .{
        .playdate = playdate,
        .alloc = alloc,
        .prng = std.Random.DefaultPrng.init(@intCast(millis)),
        .text_font = text_font,
        .sprites_font = sprites_font,
    };

    return runtime;
}

pub fn destroy(self: *Self) void {
    self.playdate.realloc(0, self.text_font);
    self.playdate.realloc(0, self.sprites_font);
    self.alloc.destroy(self);
}

pub fn any(self: *Self) game.AnyRuntime {
    return .{
        .context = self,
        .alloc = self.alloc,
        .rand = self.prng.random(),
        .vtable = &.{
            .currentMillis = currentMillis,
            .readPushedButtons = readPushedButtons,
            .clearScreen = clearScreen,
            .drawUI = drawUI,
            .drawDungeon = drawDungeon,
            .drawSprite = drawSprite,
            .drawText = drawText,
        },
    };
}

// ======== Private methods: ==============

fn currentMillis(ptr: *anyopaque) c_uint {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.playdate.system.getCurrentTimeMilliseconds();
}

fn readPushedButtons(ptr: *anyopaque) anyerror!?game.Buttons {
    const self: *Self = @ptrCast(@alignCast(ptr));

    var current_buttons: api.PDButtons = 0;
    var pressed_buttons: api.PDButtons = 0;
    var released_buttons: api.PDButtons = 0;
    self.playdate.system.getButtonState(&current_buttons, &pressed_buttons, &released_buttons);

    if (pressed_buttons > 0) {
        self.button_log.pressed_at = self.playdate.system.getCurrentTimeMilliseconds();
    } else if (current_buttons > 0) {
        const hold_delay = self.playdate.system.getCurrentTimeMilliseconds() - self.button_log.pressed_at;
        if (hold_delay > game.Buttons.HOLD_DELAY_MS)
            return .{ .code = current_buttons, .state = .hold };
    } else if (released_buttons > 0) {
        self.button_log.release_count = if (released_buttons == self.button_log.button)
            self.button_log.release_count + 1
        else
            1;
        const now = self.playdate.system.getCurrentTimeMilliseconds();
        self.button_log.button = released_buttons;
        const delay = now - self.button_log.released_at;
        self.button_log.released_at = now;
        if (self.button_log.release_count > 1 and delay < game.Buttons.DOUBLE_PUSH_DELAY_MS)
            return .{ .code = current_buttons, .state = .double_pushed }
        else
            return .{ .code = released_buttons, .state = .pushed };
    }
    return null;
}

fn clearScreen(ptr: *anyopaque) anyerror!void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    self.playdate.graphics.clear(@intFromEnum(api.LCDSolidColor.ColorBlack));
}

fn drawUI(ptr: *anyopaque) anyerror!void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    // separate dung and stats:
    const x = (game.DISPLAY_DUNG_COLS + 1) * game.FONT_WIDTH;
    self.playdate.graphics.drawLine(x, 0, x, game.DISPLPAY_HEGHT, 1, @intFromEnum(api.LCDSolidColor.ColorWhite));
    self.playdate.graphics.drawLine(x + 2, 0, x + 2, game.DISPLPAY_HEGHT, 1, @intFromEnum(api.LCDSolidColor.ColorWhite));
    self.playdate.system.drawFPS(1, 1);
}

fn drawDungeon(ptr: *anyopaque, screen: *const game.Screen, dungeon: *const game.Dungeon) anyerror!void {
    var itr = dungeon.cellsInRegion(screen.region) orelse return;
    var position = .{ .point = screen.region.top_left };
    var sprite = game.Sprite{ .codepoint = undefined };
    while (itr.next()) |cell| {
        sprite.codepoint = switch (cell) {
            .floor => '.',
            .wall => '#',
            else => ' ',
        };
        try drawSprite(ptr, screen, &sprite, &position, .normal);
        position.point.move(.right);
        if (!screen.region.containsPoint(position.point)) {
            position.point.col = screen.region.top_left.col;
            position.point.move(.down);
        }
    }
}

fn drawSprite(
    ptr: *anyopaque,
    screen: *const game.Screen,
    sprite: *const game.Sprite,
    position: *const game.Position,
    mode: game.AnyRuntime.DrawingMode,
) anyerror!void {
    if (screen.region.containsPoint(position.point)) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const y: c_int = game.FONT_HEIGHT * @as(c_int, position.point.row - screen.region.top_left.row + 1);
        const x: c_int = game.FONT_WIDTH * @as(c_int, position.point.col - screen.region.top_left.col + 1);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(sprite.codepoint, &buf);
        if (mode == .inverted) {
            self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeInverted);
            _ = self.playdate.graphics.drawText(&buf, len, .UTF8Encoding, x, y);
            self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeCopy);
        } else {
            _ = self.playdate.graphics.drawText(&buf, len, .UTF8Encoding, x, y);
        }
    }
}

fn drawText(ptr: *anyopaque, text: []const u8, absolute_position: p.Point) !void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    // choose the font for text:
    self.playdate.graphics.setFont(self.text_font);
    self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeFillWhite);
    // draw label:
    _ = self.playdate.graphics.drawText(
        text.ptr,
        text.len,
        .UTF8Encoding,
        @as(c_int, absolute_position.col) * game.FONT_WIDTH,
        @as(c_int, absolute_position.row) * game.FONT_HEIGHT,
    );
    // revert font for sprites:
    self.playdate.graphics.setFont(self.sprites_font);
    self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeCopy);
}
