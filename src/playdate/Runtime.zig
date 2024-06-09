const std = @import("std");
const api = @import("api.zig");
const game = @import("game");
const tools = @import("tools");
const cmp = game.components;
const Allocator = @import("Allocator.zig");

const Self = @This();

const FONT_HEIGHT: u16 = 16;
const FONT_WIDHT: u16 = 8;

const log = std.log.scoped(.runtime);

playdate: *api.PlaydateAPI,
font: *api.LCDFont,

pub fn init(playdate: *api.PlaydateAPI) Self {
    const err: ?*[*c]const u8 = null;
    const font = playdate.graphics.loadFont("Roobert-11-Mono-Condensed.pft", err) orelse {
        const err_msg = err orelse "Unknown error.";
        std.debug.panic("Error on load font: {s}", .{err_msg});
    };

    playdate.graphics.setDrawMode(api.LCDBitmapDrawMode.DrawModeFillWhite);
    playdate.graphics.setFont(font);

    return .{ .playdate = playdate, .font = font };
}

pub fn deinit(self: Self) void {
    self.playdate.system.realloc(self.font, 0);
}

pub fn any(self: *Self) !game.AnyRuntime {
    var millis: c_uint = undefined;
    _ = self.playdate.system.getSecondsSinceEpoch(&millis);
    var rnd = std.Random.DefaultPrng.init(@intCast(millis));
    return .{
        .context = self,
        .alloc = Allocator.allocator(self.playdate),
        .rand = rnd.random(),
        .vtable = .{
            .readButton = readButton,
            .drawDungeon = drawDungeon,
            .drawSprite = drawSprite,
            .currentMillis = currentMillis,
        },
    };
}

// ======== Private methods: ==============

fn currentMillis(ptr: *anyopaque) i64 {
    var self: *Self = @ptrCast(@alignCast(ptr));
    return self.playdate.system.getCurrentTimeMilliseconds();
}

fn readButton(ptr: *anyopaque) anyerror!game.Button.Type {
    var self: *Self = @ptrCast(@alignCast(ptr));
    var button: api.PDButtons = undefined;
    self.playdate.system.getButtonState(null, &button, null);
    return button;
}

fn drawDungeon(ptr: *anyopaque, screen: *const cmp.Screen, dungeon: *const cmp.Dungeon) anyerror!void {
    var position = game.components.Position{ .point = screen.region.top_left };
    var sprite = game.components.Sprite{ .letter = undefined };
    var itr = dungeon.cellsInRegion(screen.region) orelse return;
    while (itr.next()) |cell| {
        sprite.letter = switch (cell) {
            .nothing => " ",
            .floor => ".",
            .wall => "#",
            .opened_door => "'",
            .closed_door => "+",
        };
        try drawSprite(ptr, screen, &sprite, &position);
        position.point.move(.right);
        if (!screen.region.containsPoint(position.point)) {
            position.point.col = screen.region.top_left.col;
            position.point.move(.down);
        }
    }
}

fn drawSprite(
    ptr: *anyopaque,
    screen: *const cmp.Screen,
    sprite: *const cmp.Sprite,
    position: *const cmp.Position,
) anyerror!void {
    if (screen.region.containsPoint(position.point)) {
        var self: *Self = @ptrCast(@alignCast(ptr));
        const y: c_int = FONT_HEIGHT * (position.point.row - screen.region.top_left.row + 1);
        const x: c_int = FONT_WIDHT * (position.point.col - screen.region.top_left.col + 1);
        _ = self.playdate.graphics.drawText(sprite.letter.ptr, sprite.letter.len, .UTF8Encoding, x, y);
    }
}
