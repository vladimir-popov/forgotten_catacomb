/// Set of methods to draw the game.
/// Comparing with `AnyRuntime`, this module contains methods
/// to draw objects from the game domain.
const std = @import("std");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;
const game = @import("game.zig");

const log = std.log.scoped(.render);

/// Fills the screen by the background color
pub inline fn clearScreen(session: *const game.GameSession) !void {
    try session.runtime.clearScreen();
}

/// Draws the walls and floor
pub inline fn drawDungeon(session: *const game.GameSession) !void {
    try session.runtime.drawDungeon(&session.screen, session.dungeon);
}

/// Draws the single sprite
pub inline fn drawSprite(
    session: *const game.GameSession,
    sprite: *const game.Sprite,
    position: *const game.Position,
    mode: game.AnyRuntime.DrawingMode,
) !void {
    try session.runtime.drawSprite(&session.screen, sprite, position, mode);
}

/// Clears the screen and draw all from scratch.
/// Removes completed animations.
pub fn redraw(session: *game.GameSession) !void {
    try clearScreen(session);
    try drawUI(session);
    try drawDungeon(session);
    try drawVisibleSprites(session);
    try drawAnimationsFrame(session);
}

/// Draws border of the UI and the right pane
pub fn drawUI(session: *const game.GameSession) !void {
    try session.runtime.drawUI();
    // Draw the right area (stats)
    if (session.components.getForEntity(session.player, game.Health)) |health| {
        var buf = [_]u8{0} ** game.STATS_COLS;
        try session.runtime.drawText(
            try std.fmt.bufPrint(&buf, "HP: {d}", .{health.current}),
            .{ .row = 2, .col = game.DISPLAY_DUNG_COLS + 2 },
        );
    }
}

/// Draw sprites inside the screen
pub fn drawVisibleSprites(session: *const game.GameSession) !void {
    var itr = session.query.get2(game.Position, game.Sprite);
    while (itr.next()) |tuple| {
        if (session.screen.region.containsPoint(tuple[1].point)) {
            try session.runtime.drawSprite(&session.screen, tuple[2], tuple[1], .normal);
        }
    }
}

pub fn drawEntity(session: *const game.GameSession, entity: game.Entity, mode: game.AnyRuntime.DrawingMode) !void {
    if (session.components.getForEntity(entity, game.Sprite)) |entity_sprite| {
        const position = session.components.getForEntityUnsafe(entity, game.Position);
        try session.runtime.drawSprite(&session.screen, entity_sprite, position, mode);
    }
}

/// Draws a single frame from the every animation.
/// Removes the animation if the last frame was drawn.
pub fn drawAnimationsFrame(session: *game.GameSession) !void {
    const now: c_uint = session.runtime.currentMillis();
    var itr = session.query.get2(game.Position, game.Animation);
    while (itr.next()) |components| {
        const position = components[1];
        const animation = components[2];
        if (animation.frame(now)) |frame| {
            if (frame > 0 and session.screen.region.containsPoint(position.point)) {
                try session.runtime.drawSprite(
                    &session.screen,
                    &.{ .codepoint = frame },
                    position,
                    .normal,
                );
            }
        } else {
            try session.components.removeFromEntity(components[0], game.Animation);
        }
    }
}

pub fn drawEntityName(session: *const game.GameSession, name: []const u8) !void {
    try session.runtime.drawText(name, .{
        .row = 5,
        .col = game.DISPLAY_DUNG_COLS + 2,
    });
}

pub fn drawEnemyHP(session: *const game.GameSession, hp: *const game.Health) !void {
    var buf: [3]u8 = undefined;
    const len = std.fmt.formatIntBuf(&buf, hp.current, 10, .lower, .{});
    try session.runtime.drawText(buf[0..len], .{
        .row = 6,
        .col = game.DISPLAY_DUNG_COLS + 2,
    });
}
