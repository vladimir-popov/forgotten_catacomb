const std = @import("std");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;
const game = @import("game");
const tty = @import("tty.zig");
const utf8 = @import("utf8");

const log = std.log.scoped(.runtime);

const Self = @This();

alloc: std.mem.Allocator,
// used to accumulate the buffer every run-loop circle
arena: std.heap.ArenaAllocator,
rand: std.Random,
buffer: utf8.Buffer,
termios: std.c.termios,
// the last read button through readButton function.
// it is used as a buffer to check ESC outside the readButton function
prev_key: ?tty.Keyboard.Button = null,
pressed_at: i64 = 0,

pub fn init(alloc: std.mem.Allocator, rand: std.Random) !Self {
    const instance = Self{
        .alloc = alloc,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rand = rand,
        .buffer = undefined,
        .termios = tty.Display.enterRawMode(),
    };
    tty.Display.hideCursor();
    return instance;
}

pub fn deinit(self: *Self) void {
    tty.Display.exitFromRawMode();
    tty.Display.showCursor();
    _ = self.arena.reset(.free_all);
}

/// Run the main loop of the game
pub fn run(self: *Self, game_session: anytype) !void {
    tty.Display.clearScreen();
    self.buffer = utf8.Buffer.init(self.arena.allocator());
    while (!self.isExit()) {
        try game_session.*.tick();
        try self.writeBuffer(tty.Display.writer, 1, 1);
        _ = self.arena.reset(.retain_capacity);
        self.buffer = utf8.Buffer.init(self.arena.allocator());
    }
}

fn isExit(self: Self) bool {
    if (self.prev_key) |btn| {
        switch (btn) {
            .control => return btn.control == tty.Keyboard.ControlButton.ESC,
            else => return false,
        }
    } else {
        return false;
    }
}

fn writeBuffer(self: Self, writer: std.io.AnyWriter, rows_pad: u8, cols_pad: u8) !void {
    for (self.buffer.lines.items, rows_pad..) |line, i| {
        try tty.Text.writeSetCursorPosition(writer, @intCast(i), cols_pad);
        _ = try writer.write(line.bytes.items);
    }
}

pub fn any(self: *Self) game.AnyRuntime {
    return .{
        .context = self,
        .alloc = self.alloc,
        .rand = self.rand,
        .vtable = &.{
            .currentMillis = currentMillis,
            .readButtons = readButtons,
            .drawDungeon = drawDungeon,
            .drawSprite = drawSprite,
            .drawHealth = drawHealth,
        },
    };
}

fn currentMillis(_: *anyopaque) i64 {
    return std.time.milliTimestamp();
}

fn readButtons(ptr: *anyopaque) anyerror!?game.AnyRuntime.Buttons {
    var self: *Self = @ptrCast(@alignCast(ptr));
    const prev_key = self.prev_key;
    if (tty.Keyboard.readPressedButton()) |key| {
        self.prev_key = key;
        const known_key_code: ?game.AnyRuntime.Buttons.Code = switch (key) {
            .char => switch (key.char.char) {
                ' ' => game.AnyRuntime.Buttons.A,
                'f' => game.AnyRuntime.Buttons.B,
                'd' => game.AnyRuntime.Buttons.A,
                'h' => game.AnyRuntime.Buttons.Left,
                'j' => game.AnyRuntime.Buttons.Down,
                'k' => game.AnyRuntime.Buttons.Up,
                'l' => game.AnyRuntime.Buttons.Right,
                else => null,
            },
            else => null,
        };
        if (known_key_code) |code| {
            const now = std.time.milliTimestamp();
            const delay = now - self.pressed_at;
            self.pressed_at = now;
            var state: game.AnyRuntime.Buttons.State = .pressed;
            if (key.eql(prev_key)) {
                if (delay < game.AnyRuntime.DOUBLE_PRESS_DELAY_MS)
                    state = .double_pressed
                else if (delay > game.AnyRuntime.HOLD_DELAY_MS)
                    state = .hold;
            }
            return .{ .code = code, .state = state };
        } else {
            self.pressed_at = 0;
            return null;
        }
    }
    return null;
}

fn drawDungeon(ptr: *anyopaque, screen: *const game.Screen, dungeon: *const game.Dungeon) anyerror!void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    const buffer = &self.buffer;
    var itr = dungeon.cellsInRegion(screen.region) orelse return;
    var line = try self.alloc.alloc(u8, screen.region.cols);
    defer self.alloc.free(line);

    var idx: u8 = 0;
    while (itr.next()) |cell| {
        line[idx] = switch (cell) {
            .nothing => ' ',
            .floor => '.',
            .wall => '#',
            .door => |door| if (door == .opened) '\'' else '+',
        };
        idx += 1;
        if (itr.cursor.col == itr.region.top_left.col) {
            idx = 0;
            try buffer.addLine(line);
            @memset(line, 0);
        }
    }
}

fn drawSprite(
    ptr: *anyopaque,
    screen: *const game.Screen,
    sprite: *const game.Sprite,
    position: *const game.Position,
) anyerror!void {
    if (screen.region.containsPoint(position.point)) {
        var self: *Self = @ptrCast(@alignCast(ptr));
        const r = position.point.row - screen.region.top_left.row;
        const c = position.point.col - screen.region.top_left.col;
        try self.buffer.mergeLine(sprite.letter, r, c);
    }
}

fn drawHealth(ptr: *anyopaque, health: *const game.Health) !void {
    // var self: *Self = @ptrCast(@alignCast(ptr));
    _ = ptr;
    _ = health;
}
