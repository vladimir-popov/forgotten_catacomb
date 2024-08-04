const std = @import("std");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;
const game = @import("game.zig");

const Render = @import("Render.zig");

const log = std.log.scoped(.action_system);

/// Handles intentions to do some actions
pub fn doActions(session: *game.GameSession) !void {
    var itr = session.query.get2(game.Action, game.Position);
    while (itr.next()) |components| {
        const entity = components[0];
        const action = components[1];
        const position = components[2];
        switch (action.type) {
            .move => |move| {
                _ = try handleMoveAction(session, entity, position, move);
            },
            .open => |door| {
                try session.components.setToEntity(door, game.Door.opened);
                try session.components.setToEntity(
                    door,
                    game.Sprite{ .codepoint = '\'' },
                );
            },
            .close => |door| {
                try session.components.setToEntity(door, game.Door.closed);
                try session.components.setToEntity(
                    door,
                    game.Sprite{ .codepoint = '+' },
                );
            },
            .hit => |enemy| {
                if (session.components.getForEntity(session.player, game.MeleeWeapon)) |weapon| {
                    try session.components.setToEntity(
                        enemy,
                        weapon.damage(session.runtime.rand),
                    );
                }
            },
            else => {},
        }
        try session.components.removeFromEntity(entity, game.Action);
    }
}

fn handleMoveAction(
    session: *game.GameSession,
    entity: game.Entity,
    position: *game.Position,
    move: game.Action.Move,
) !bool {
    const new_position = position.point.movedTo(move.direction);
    if (checkCollision(session, new_position)) |obstacle| {
        try session.components.setToEntity(
            entity,
            game.Collision{ .entity = entity, .obstacle = obstacle, .at = new_position },
        );
        return false;
    }
    try Render.drawSprite(session, &game.Sprite{ .codepoint = '.' }, position, .normal);
    position.point.move(move.direction);
    if (entity != session.player) return true;

    // keep player on the screen:
    const screen = &session.screen;
    const inner_region = screen.innerRegion();
    if (move.direction == .up and position.point.row < inner_region.top_left.row)
        try moveScreen(session, move.direction);
    if (move.direction == .down and position.point.row > inner_region.bottomRightRow())
        try moveScreen(session, move.direction);
    if (move.direction == .left and position.point.col < inner_region.top_left.col)
        try moveScreen(session, move.direction);
    if (move.direction == .right and position.point.col > inner_region.bottomRightCol())
        try moveScreen(session, move.direction);
    return true;
}

fn moveScreen(session: *game.GameSession, direction: p.Direction) !void {
    session.screen.move(direction);
    try Render.redraw(session);
}

fn checkCollision(session: *game.GameSession, position: p.Point) ?game.Collision.Obstacle {
    if (session.dungeon.cellAt(position)) |cell| {
        switch (cell) {
            .nothing, .wall => return .wall,
            .floor, .door => if (session.entityAt(position)) |entity| {
                if (session.components.getForEntity(entity, game.Door)) |door|
                    if (door.* == .closed)
                        return .{ .door = .{ .entity = entity, .state = .closed } }
                    else
                        return null;

                if (session.components.getForEntity(entity, game.Health)) |_|
                    return .{ .enemy = entity };

                return .{ .item = entity };
            } else {
                return null;
            },
        }
    }
    return .wall;
}
