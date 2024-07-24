const std = @import("std");
const algs = @import("algs_and_types");
const p = algs.primitives;
const ecs = @import("ecs");
const game = @import("game.zig");

const Render = @import("Render.zig");

const log = std.log.scoped(.GameSession);

const Self = @This();

const Mode = enum { play, pause };

/// Playdate or terminal
runtime: game.AnyRuntime,
/// Collection of the entities of this game session
entities: ecs.EntitiesManager,
/// Collection of the components of the entities
components: ecs.ComponentsManager(game.Components),
/// Aggregates requests of few components for the same entities at once
query: ecs.ComponentsQuery(game.Components) = undefined,
/// Visible area
screen: game.Screen,
/// The pointer to the current dungeon
dungeon: *game.Dungeon,
/// Entity of the player
player: game.Entity = undefined,
/// The current mode of the game
mode: Mode = .play,
play_mode: *game.PlayMode = undefined,
pause_mode: *game.PauseMode = undefined,

pub fn create(runtime: game.AnyRuntime) !*Self {
    const session = try runtime.alloc.create(Self);
    session.* = .{
        .runtime = runtime,
        .screen = game.Screen.init(game.DISPLAY_DUNG_ROWS, game.DISPLAY_DUNG_COLS, game.Dungeon.Region),
        .entities = try ecs.EntitiesManager.init(runtime.alloc),
        .components = try ecs.ComponentsManager(game.Components).init(runtime.alloc),
        .dungeon = try game.Dungeon.createRandom(runtime.alloc, runtime.rand),
    };
    session.query = .{ .entities = &session.entities, .components = &session.components };
    const player_and_position = try initLevel(session.dungeon, &session.entities, &session.components);
    session.player = player_and_position[0];
    session.screen.centeredAround(player_and_position[1]);
    session.play_mode = try game.PlayMode.create(session);
    session.pause_mode = try game.PauseMode.create(session);

    session.play();
    return session;
}

pub fn destroy(self: *Self) void {
    self.entities.deinit();
    self.components.deinit();
    self.dungeon.destroy();
    self.play_mode.destroy();
    self.pause_mode.destroy();
    self.runtime.alloc.destroy(self);
}

pub fn play(session: *Self) void {
    var target = session.player;
    switch (session.mode) {
        .pause => {
            target = session.pause_mode.target;
            session.pause_mode.clear();
        },
        else => {},
    }
    session.mode = .play;
    session.play_mode.refresh(target);
}

pub fn pause(session: *Self) !void {
    session.mode = .pause;
    try session.pause_mode.refresh();
}

pub inline fn tick(session: *Self) !void {
    switch (session.mode) {
        .play => try session.play_mode.tick(),
        .pause => try session.pause_mode.tick(),
    }
}

pub inline fn drawMode(session: *Self) !void {
    switch (session.mode) {
        .play => try session.play_mode.draw(),
        .pause => try session.pause_mode.draw(),
    }
}

pub fn entityAt(session: *game.GameSession, place: p.Point) ?game.Entity {
    for (session.components.arrayOf(game.Position).components.items, 0..) |position, idx| {
        if (position.point.eql(place)) {
            return session.components.arrayOf(game.Position).index_entity.get(@intCast(idx));
        }
    }
    return null;
}

pub fn removeEntity(self: *Self, entity: game.Entity) !void {
    try self.components.removeAllForEntity(entity);
    self.entities.removeEntity(entity);
}

// this is public to reuse in the DungeonsGenerator
pub fn initLevel(
    dungeon: *game.Dungeon,
    entities: *ecs.EntitiesManager,
    components: *ecs.ComponentsManager(game.Components),
) !struct { game.Entity, p.Point } {
    var doors = dungeon.doors.keyIterator();
    while (doors.next()) |at| {
        try addClosedDoor(entities, components, at);
    }

    const player_position = randomEmptyPlace(dungeon, components) orelse unreachable;
    const player = try initPlayer(entities, components, player_position);
    for (0..dungeon.rand.uintLessThan(u8, 10) + 10) |_| {
        try addRat(dungeon, entities, components);
    }

    return .{ player, player_position };
}

fn addClosedDoor(
    entities: *ecs.EntitiesManager,
    components: *ecs.ComponentsManager(game.Components),
    door_at: *p.Point,
) !void {
    const door = try entities.newEntity();
    try components.setToEntity(door, game.Door.closed);
    try components.setToEntity(door, game.Position{ .point = door_at.* });
    try components.setToEntity(door, game.Sprite{ .codepoint = '+' });
    try components.setToEntity(door, game.Description{ .name = "Door" });
}

fn initPlayer(
    entities: *ecs.EntitiesManager,
    components: *ecs.ComponentsManager(game.Components),
    init_position: p.Point,
) !game.Entity {
    const player = try entities.newEntity();
    try components.setToEntity(player, game.Position{ .point = init_position });
    try components.setToEntity(player, game.Sprite{ .codepoint = '@' });
    try components.setToEntity(player, game.Description{ .name = "You" });
    try components.setToEntity(player, game.Health{ .total = 100, .current = 100 });
    try components.setToEntity(player, game.MeleeWeapon{ .max_damage = 3, .move_points = 10 });
    try components.setToEntity(player, game.MovePoints{ .speed = 10, .count = 10 });
    return player;
}

fn addRat(
    dungeon: *game.Dungeon,
    entities: *ecs.EntitiesManager,
    components: *ecs.ComponentsManager(game.Components),
) !void {
    if (randomEmptyPlace(dungeon, components)) |position| {
        const rat = try entities.newEntity();
        try components.setToEntity(rat, game.Position{ .point = position });
        try components.setToEntity(rat, game.Sprite{ .codepoint = 'r' });
        try components.setToEntity(rat, game.Description{ .name = "Rat" });
        try components.setToEntity(rat, game.Health{ .total = 10, .current = 10 });
        try components.setToEntity(rat, game.MeleeWeapon{ .max_damage = 3, .move_points = 5 });
        try components.setToEntity(rat, game.MovePoints{ .speed = 10, .count = 0 });
    }
}

fn randomEmptyPlace(dungeon: *game.Dungeon, components: *const ecs.ComponentsManager(game.Components)) ?p.Point {
    var attempt: u8 = 10;
    while (attempt > 0) : (attempt -= 1) {
        const place = dungeon.randomPlace();
        var is_empty = true;
        for (components.getAll(game.Position)) |position| {
            if (position.point.eql(place)) {
                is_empty = false;
            }
        }
        if (is_empty) return place;
    }
    return null;
}
