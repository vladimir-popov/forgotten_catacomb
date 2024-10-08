const std = @import("std");
const api = @import("api.zig");
const g = @import("game");
const c = g.components;
const p = g.primitives;

const Allocator = @import("Allocator.zig");

const log = std.log.scoped(.playdate_runtime);

const Self = @This();

const LastButton = struct {
    const Btn = struct {
        game_button: g.Button.GameButton,
        is_pressed: bool,
        pressed_at: u32,
        pressed_count: u8,
    };

    button: ?Btn = null,

    fn handleEvent(
        button: api.PDButtons,
        down: c_int,
        when: u32,
        ptr: ?*anyopaque,
    ) callconv(.C) c_int {
        const self: *LastButton = @ptrCast(@alignCast(ptr));
        const is_pressed = down > 0;
        if (g.Button.GameButton.fromCode(button)) |game_button| {
            if (self.button) |*current_button| {
                return self.handleEventWithCurrentButton(current_button, game_button, is_pressed, when);
            } else if (is_pressed) {
                // the first press:
                self.button = .{
                    .game_button = game_button,
                    .is_pressed = true,
                    .pressed_at = when,
                    .pressed_count = 1,
                };
            } else {
                self.button = null;
            }
        }
        return 0;
    }

    fn handleEventWithCurrentButton(
        self: *LastButton,
        current_button: *Btn,
        game_button: g.Button.GameButton,
        is_pressed: bool,
        when: u32,
    ) callconv(.C) c_int {
        // event for the same button
        if (current_button.game_button == game_button) {
            if (is_pressed) {
                // the current button pressed again
                current_button.is_pressed = true;
                current_button.pressed_at = when;
                if ((when - current_button.pressed_at) < g.DOUBLE_PUSH_DELAY_MS) {
                    current_button.pressed_count += 1;
                } else {
                    current_button.pressed_count = 1;
                }
            } else {
                current_button.is_pressed = false;
            }
        } else {
            // event for another button
            if (!current_button.is_pressed and is_pressed) {
                self.button = .{
                    .game_button = game_button,
                    .is_pressed = true,
                    .pressed_at = when,
                    .pressed_count = 1,
                };
            } else {
                self.button = null;
            }
        }
        return 0;
    }
};

var cheat: ?g.Cheat = null;

playdate: *api.PlaydateAPI,
alloc: std.mem.Allocator,
text_font: ?*api.LCDFont,
sprites_font: ?*api.LCDFont,
last_button: *LastButton,

pub fn init(playdate: *api.PlaydateAPI) !Self {
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

    const alloc = Allocator.allocator(playdate);
    const last_button = try alloc.create(LastButton);
    errdefer alloc.destroy(last_button);

    playdate.graphics.setFont(sprites_font);
    playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeCopy);
    playdate.system.setSerialMessageCallback(serialMessageCallback);
    playdate.system.setButtonCallback(LastButton.handleEvent, last_button, 4);

    return .{
        .playdate = playdate,
        .alloc = alloc,
        .text_font = text_font,
        .sprites_font = sprites_font,
        .last_button = last_button,
    };
}

pub fn deinit(self: *Self) void {
    self.playdate.realloc(0, self.text_font);
    self.playdate.realloc(0, self.sprites_font);
}

pub fn runtime(self: *Self) g.Runtime {
    return .{
        .context = self,
        .alloc = self.alloc,
        .vtable = &.{
            .getCheat = getCheat,
            .addMenuItem = addMenuItem,
            .removeAllMenuItems = removeAllMenuItems,
            .currentMillis = currentMillis,
            .readPushedButtons = readPushedButtons,
            .clearDisplay = clearDisplay,
            .drawHorizontalBorderLine = drawHorizontalBorderLine,
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

fn addMenuItem(
    ptr: *anyopaque,
    title: []const u8,
    game_object: *anyopaque,
    callback: g.Runtime.MenuItemCallback,
) ?*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.playdate.system.addMenuItem(title.ptr, callback, game_object).?;
}

fn removeAllMenuItems(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.playdate.system.removeAllMenuItems();
}

fn readPushedButtons(ptr: *anyopaque) anyerror!?g.Button {
    const self: *Self = @ptrCast(@alignCast(ptr));

    if (cheat) |_| return .{ .game_button = .cheat, .state = .pressed };

    if (self.last_button.button) |btn| {
        // handle only released button
        if (!btn.is_pressed) {
            self.last_button.button = null;
            // stop handle held button right after release
            if ((currentMillis(self) - btn.pressed_at) > g.HOLD_DELAY_MS) {
                return null;
            }
            return .{
                .game_button = btn.game_button,
                .state = if (btn.pressed_count > 1)
                    .double_pressed
                else
                    .pressed,
            };
        } else if ((currentMillis(self) - btn.pressed_at) > g.HOLD_DELAY_MS) {
            return .{
                .game_button = btn.game_button,
                .state = .hold,
            };
        }
    }
    return null;
}

fn clearDisplay(ptr: *anyopaque) anyerror!void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    self.playdate.graphics.clear(@intFromEnum(api.LCDSolidColor.ColorBlack));
}

fn drawHorizontalBorderLine(ptr: *anyopaque, row: u8, length: u8) anyerror!void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    const y: c_int = @as(c_int, @intCast(row)) * g.SPRITE_HEIGHT + g.SPRITE_HEIGHT / 2;
    const x: c_int = @as(c_int, @intCast(length)) * g.SPRITE_WIDTH;
    self.playdate.graphics.drawLine(0, y, x, y, 1, @intFromEnum(api.LCDSolidColor.ColorWhite));
    self.playdate.graphics.drawLine(0, y + 2, x, y + 2, 1, @intFromEnum(api.LCDSolidColor.ColorWhite));
}

fn drawDungeon(ptr: *anyopaque, screen: g.Screen, dungeon: g.Dungeon) anyerror!void {
    var itr = dungeon.cellsInRegion(screen.region) orelse return;
    var position = .{ .point = screen.region.top_left };
    var sprite = c.Sprite{ .codepoint = undefined };
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
    screen: g.Screen,
    sprite: *const c.Sprite,
    position: *const c.Position,
    mode: g.Runtime.DrawingMode,
) anyerror!void {
    if (screen.region.containsPoint(position.point)) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const y: c_int = g.SPRITE_HEIGHT * @as(c_int, position.point.row - screen.region.top_left.row);
        const x: c_int = g.SPRITE_WIDTH * @as(c_int, position.point.col - screen.region.top_left.col);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(sprite.codepoint, &buf);
        try self.drawTextWithMode(buf[0..len], mode, x, y);
    }
}

fn drawText(ptr: *anyopaque, text: []const u8, absolute_position: p.Point, mode: g.Runtime.DrawingMode) !void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    // choose the font for text:
    self.playdate.graphics.setFont(self.text_font);
    // draw text:
    const x = @as(c_int, absolute_position.col) * g.SPRITE_WIDTH;
    const y = @as(c_int, absolute_position.row) * g.SPRITE_HEIGHT;
    try self.drawTextWithMode(text, mode, x, y);
    // revert font for sprites:
    self.playdate.graphics.setFont(self.sprites_font);
}

inline fn drawTextWithMode(
    self: *Self,
    text: []const u8,
    mode: g.Runtime.DrawingMode,
    x: c_int,
    y: c_int,
) !void {
    if (mode == .inverted) {
        self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeInverted);
        _ = self.playdate.graphics.drawText(text.ptr, text.len, .UTF8Encoding, x, y);
        self.playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeCopy);
    } else {
        _ = self.playdate.graphics.drawText(text.ptr, text.len, .UTF8Encoding, x, y);
    }
}

fn getCheat(_: *anyopaque) ?g.Cheat {
    const result = cheat;
    cheat = null;
    return result;
}

fn serialMessageCallback(data: [*c]const u8) callconv(.C) void {
    cheat = g.Cheat.parse(std.mem.span(data));
}
