const std = @import("std");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;
const game = @import("game.zig");
const dung = @import("BspDungeon.zig");

// coz zig uses u21 for utf8 symbols
pub const Codepoint = u21;

/// Describes how and where something should look.
pub const Sprite = struct {
    // The sprite and position are merged together for better performance
    position: p.Point,
    codepoint: Codepoint,
    pub fn deinit(_: *@This()) void {}
};

pub const Description = struct {
    name: []const u8,
    description: []const u8 = "",

    pub fn deinit(_: *@This()) void {}
};

pub const Door = enum {
    opened,
    closed,
    pub fn deinit(_: *@This()) void {}
};

pub const Animation = struct {
    pub const Presets = struct {
        pub const hit: [1]Codepoint = [_]Codepoint{'*'};
        pub const miss: [1]Codepoint = [_]Codepoint{'.'};
    };

    /// Frames of the animation. One frame per render circle will be shown.
    frames: []const Codepoint,
    /// Where the animation should be played
    position: p.Point,

    pub fn deinit(_: *@This()) void {}
};

/// The intension to perform an action.
/// Describes what some entity is going to do.
pub const Action = struct {
    pub const Move = struct {
        direction: p.Direction,
        keep_moving: bool = false,
    };
    pub const Type = union(enum) {
        /// Skip the round
        wait,
        /// An entity is going to move in the direction
        move: Move,
        /// An entity is going to open a door
        open: game.Entity,
        /// An entity is going to close a door
        close: game.Entity,
        /// An entity which should be hit
        hit: game.Entity,
        /// An entity is going to take the item
        take: game.Entity,
    };

    type: Type,

    move_points: u8,

    pub fn deinit(_: *@This()) void {}
};

/// Intersection of two objects
pub const Collision = struct {
    pub const Obstacle = union(enum) {
        wall,
        door: struct { entity: game.Entity, state: game.Door },
        item: game.Entity,
        enemy: game.Entity,
    };

    /// Who met obstacle
    entity: game.Entity,
    /// With what exactly collision happened
    obstacle: Obstacle,
    /// Where the collision happened
    at: p.Point,

    pub fn deinit(_: *@This()) void {}
};

pub const Health = struct {
    total: u8,
    current: i16,
    pub fn deinit(_: *@This()) void {}
};

/// This is only **intension** to make a damage.
/// The real damage will be counted in the DamageSystem
pub const Damage = struct {
    /// Damage amount
    amount: u8,
    pub fn deinit(_: *@This()) void {}
};

/// Move points are used to calculate a turn of the entity.
/// Any could be done only if the entity has enough move points.
pub const MovePoints = struct {
    /// Current count of move points of the entity
    count: u8,
    /// How many move points are needed for the single action
    speed: u8 = 10,

    pub inline fn subtract(self: *MovePoints, amount: u8) void {
        if (amount > self.count) self.count = 0 else self.count -= amount;
    }

    pub inline fn add(self: *MovePoints, amount: u8) void {
        if (255 - self.count < amount) self.count += amount;
    }

    pub fn deinit(_: *@This()) void {}
};

pub const MeleeWeapon = struct {
    max_damage: u8,
    move_points: u8,

    pub fn damage(self: MeleeWeapon, rand: std.Random) Damage {
        return .{ .amount = rand.uintAtMost(u8, self.max_damage) };
    }

    pub fn deinit(_: *@This()) void {}
};

pub const Components = union {
    sprite: Sprite,
    door: Door,
    animation: Animation,
    move: Action,
    description: Description,
    health: Health,
    damage: Damage,
    collision: Collision,
    move_points: MovePoints,
    melee: MeleeWeapon,
};
