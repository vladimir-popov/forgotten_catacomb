const std = @import("std");
const game = @import("game.zig");
const algs = @import("algs_and_types");
const p = algs.primitives;

const Render = @import("Render.zig");

const log = std.log.scoped(.pause_mode);

const PauseMode = @This();

session: *game.GameSession,
entities_on_screen: std.AutoHashMap(p.Point, game.Entity),
target: game.Entity,

pub fn create(session: *game.GameSession) !*PauseMode {
    const self = try session.runtime.alloc.create(PauseMode);
    self.session = session;
    self.target = self.session.player;
    self.entities_on_screen = std.AutoHashMap(p.Point, game.Entity).init(self.session.runtime.alloc);
    try self.refresh();
    return self;
}

pub fn destroy(self: *PauseMode) void {
    self.entities_on_screen.deinit();
    self.session.runtime.alloc.destroy(self);
}

pub fn clear(self: *PauseMode) void {
    self.entities_on_screen.clearAndFree();
}

pub fn refresh(self: *PauseMode) !void {
    self.target = self.session.player;
    self.entities_on_screen.clearRetainingCapacity();
    var itr = self.session.query.get(game.Position);
    while (itr.next()) |tuple| {
        if (self.session.screen.region.containsPoint(tuple[1].point))
            try self.entities_on_screen.put(tuple[1].point, tuple[0]);
    }
    try Render.redraw(self.session);
}

pub fn tick(self: *PauseMode) anyerror!void {
    try self.highlightEntityInFocus();
    // Nothing should happened until the player pushes a button
    if (try self.session.runtime.readPushedButtons()) |btn| {
        switch (btn.code) {
            game.Buttons.A => {},
            game.Buttons.B => {
                try self.session.play();
                return;
            },
            game.Buttons.Left, game.Buttons.Right, game.Buttons.Up, game.Buttons.Down => {
                try self.chooseNextEntity(btn.toDirection().?);
            },
            else => {},
        }
    }
}

pub fn highlightEntityInFocus(self: PauseMode) !void {
    try self.session.runtime.drawText("pause", .{ .row = 1, .col = game.DISPLAY_DUNG_COLS + 2 });
    // highlight entity in focus
    try Render.drawEntity(self.session, self.target, .inverted);
    if (self.session.components.getForEntity(self.target, game.Description)) |description| {
        try Render.drawEntityName(self.session, description.name);
    }
    if (self.session.components.getForEntity(self.target, game.Health)) |hp| {
        try Render.drawEnemyHP(self.session, hp);
    }
}

fn chooseNextEntity(self: *PauseMode, direction: p.Direction) !void {
    const init_position = self.session.components.getForEntityUnsafe(self.target, game.Position).point;
    var itr = Iterator.init(init_position, direction, self.session.screen.region);
    while (itr.next()) |position| {
        if (self.entities_on_screen.get(position)) |entity| {
            try Render.drawEntity(self.session, self.target, .normal);
            self.target = entity;
            return;
        }
    }
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
