//! This is the mode in which player are able to look around, get info about
//! entities on the screen, and change the target entity.

const std = @import("std");
const gm = @import("game.zig");
const algs = @import("algs_and_types");
const p = algs.primitives;

const log = std.log.scoped(.pause_mode);

const ExploreMode = @This();
const ArrayOfEntitiesOnScreen = std.ArrayList(struct { gm.Entity, p.Point });

session: *gm.GameSession,
/// Arrays of entities and their positions on the screen
entities_on_screen: ArrayOfEntitiesOnScreen,
/// Highlighted entity
entity_in_focus: ?gm.Entity,

pub fn init(session: *gm.GameSession) !ExploreMode {
    return .{
        .session = session,
        .entities_on_screen = ArrayOfEntitiesOnScreen.init(session.game.runtime.alloc),
        .entity_in_focus = session.player,
    };
}

pub fn deinit(self: *ExploreMode) void {
    self.entities_on_screen.deinit();
}

pub fn refresh(self: *ExploreMode) !void {
    self.entity_in_focus = self.session.player;
    self.entities_on_screen.clearRetainingCapacity();
    var itr = self.session.level.query().get(gm.Position);
    while (itr.next()) |tuple| {
        if (self.session.game.render.screen.region.containsPoint(tuple[1].point)) {
            const item = try self.entities_on_screen.addOne();
            item.* = .{ tuple[0], self.session.game.render.screen.relative(tuple[1].point) };
        }
    }
    try self.session.game.render.redraw(self.session, self.entity_in_focus);
}

pub fn tick(self: *ExploreMode) anyerror!void {
    // Nothing should happened until the player pushes a button
    if (try self.session.game.runtime.readPushedButtons()) |btn| {
        switch (btn.code) {
            gm.Buttons.A => {},
            gm.Buttons.B => {
                try self.session.play(self.entity_in_focus);
                return;
            },
            gm.Buttons.Left, gm.Buttons.Right, gm.Buttons.Up, gm.Buttons.Down => {
                self.chooseNextEntity(btn.toDirection().?);
                try self.session.game.render.drawScene(self.session, self.entity_in_focus);
            },
            else => {},
        }
    }
}

fn chooseNextEntity(self: *ExploreMode, direction: p.Direction) void {
    const target_entity = self.entity_in_focus orelse self.session.player;
    const target_point = self.session.game.render.screen.relative(
        self.session.components.getForEntityUnsafe(target_entity, gm.Position).point,
    );
    var min_distance: u8 = 255;
    for (self.entities_on_screen.items) |tuple| {
        if (target_entity == tuple[0]) continue;

        const d = distance(target_point, tuple[1], direction);
        if (d < min_distance) {
            min_distance = d;
            self.entity_in_focus = tuple[0];
        }
    }
}

/// Calculates the distance between two points in direction with follow logic:
/// 1. calculates the difference with multiplayer between points on the axis related to direction
/// 2. adds the difference between points on the orthogonal axis
inline fn distance(from: p.Point, to: p.Point, direction: p.Direction) u8 {
    switch (direction) {
        .right => {
            if (to.col <= from.col) return 255;
            return ((to.col - from.col) << 2) + sub(to.row, from.row);
        },
        .left => return distance(to, from, .right),
        .down => {
            if (to.row <= from.row) return 255;
            return ((to.row - from.row) << 2) + sub(to.col, from.col);
        },
        .up => return distance(to, from, .down),
    }
}

/// Returns y - x if y > x, or x - y otherwise.
inline fn sub(x: u8, y: u8) u8 {
    return if (y > x) y - x else x - y;
}

/// Iterates over points in follow way:
///      0
///  5 3 1 2 4
/// 10 8 6 7 9
const Iterator = struct {
    init_position: p.Point,
    current_position: p.Point,
    direction: p.Direction,
    region: p.Region,
    side_direction: p.Direction,
    // how far from init_position in the direction
    distance: u8 = 1,
    // how far from the init_position in the side_direction
    range: u8 = 0,

    fn init(init_position: p.Point, direction: p.Direction, region: p.Region) Iterator {
        return .{
            .init_position = init_position,
            .current_position = init_position,
            .direction = direction,
            .side_direction = direction.rotatedClockwise(true),
            .region = region,
        };
    }

    fn next(self: *Iterator) ?p.Point {
        if (self.range == 0) {
            self.current_position = self.init_position;
            self.current_position.moveNTimes(self.direction, self.distance);
            self.range += 1;
        } else {
            self.current_position.moveNTimes(self.side_direction, self.range);
            self.side_direction = self.side_direction.opposite();
            self.range += 1;
        }
        if (!self.region.containsPoint(self.current_position.movedToNTimes(self.side_direction, self.range))) {
            self.distance += 1;
            self.range = 0;
        }
        if (self.region.containsPoint(self.current_position)) return self.current_position else return null;
    }
};