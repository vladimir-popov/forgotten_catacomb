const std = @import("std");
const ecs = @import("ecs");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;

pub const entities = @import("entities.zig");
pub const components = @import("components.zig");
pub const systems = @import("systems.zig");

// Playdate resolution: h:240 × w:400 pixels
// we expect at least 4x4 sprite to render the whole level map
// and 16x8 to render the game in play mode

/// The maximum rows count in the dungeon
pub const TOTAL_ROWS: u8 = 40;
/// The maximum columns count in the dungeon
pub const TOTAL_COLS: u8 = 100;

/// The rows count to display
pub const DISPLAY_ROWS: u8 = 15;
/// The rows count to display
pub const DISPLAY_COLS: u8 = 40;

const ROWS_PAD = 3;
const COLS_PAD = 7;

const panic = std.debug.panic;

const Self = @This();

pub const Entity = ecs.Entity;

pub const Button = struct {
    pub const Type = c_int;

    pub const None: Type = 0;
    pub const Left: Type = (1 << 0);
    pub const Right: Type = (1 << 1);
    pub const Up: Type = (1 << 2);
    pub const Down: Type = (1 << 3);
    pub const B: Type = (1 << 4);
    pub const A: Type = (1 << 5);

    pub inline fn isMove(btn: Type) bool {
        return (Up | Down | Left | Right) & btn > 0;
    }

    pub inline fn toDirection(btn: Button.Type) ?p.Direction {
        return if (btn & Button.Up > 0)
            p.Direction.up
        else if (btn & Button.Down > 0)
            p.Direction.down
        else if (btn & Button.Left > 0)
            p.Direction.left
        else if (btn & Button.Right > 0)
            p.Direction.right
        else
            null;
    }
};

pub const Components = union {
    screen: components.Screen,
    timers: components.Timers,
    level: components.Level,
    dungeon: components.Dungeon,
    health: components.Health,
    position: components.Position,
    move: components.Move,
    sprite: components.Sprite,
};

pub const AnyRuntime = struct {
    const VTable = struct {
        readButton: *const fn (context: *anyopaque) anyerror!Button.Type,
        drawDungeon: *const fn (
            context: *anyopaque,
            screen: *const components.Screen,
            dungeon: *const components.Dungeon,
        ) anyerror!void,
        drawSprite: *const fn (
            context: *anyopaque,
            screen: *const components.Screen,
            sprite: *const components.Sprite,
            position: *const components.Position,
        ) anyerror!void,
        currentMillis: *const fn (context: *anyopaque) i64,
    };

    context: *anyopaque,
    alloc: std.mem.Allocator,
    rand: std.Random,
    vtable: VTable,

    pub fn currentMillis(self: AnyRuntime) i64 {
        return self.vtable.currentMillis(self.context);
    }

    pub fn readButton(self: AnyRuntime) !Button.Type {
        return try self.vtable.readButton(self.context);
    }

    pub fn drawDungeon(
        self: AnyRuntime,
        screen: *const components.Screen,
        dungeon: *const components.Dungeon,
    ) !void {
        try self.vtable.drawDungeon(self.context, screen, dungeon);
    }

    pub fn drawSprite(
        self: AnyRuntime,
        screen: *const components.Screen,
        sprite: *const components.Sprite,
        position: *const components.Position,
    ) !void {
        try self.vtable.drawSprite(self.context, screen, sprite, position);
    }
};

pub const Universe = ecs.Universe(Components, AnyRuntime);

pub fn init(runtime: AnyRuntime) !Universe {
    var universe: Universe = Universe.init(runtime.alloc, runtime);

    const dungeon = try components.Dungeon.initRandom(runtime.alloc, runtime.rand);
    const player_position = dungeon.findRandomPlaceForPlayer(runtime.rand);
    const player = entities.Player(universe, player_position);
    var screen = components.Screen.init(DISPLAY_ROWS, DISPLAY_COLS, components.Dungeon.Region);
    screen.centeredAround(player_position);
    // init level
    _ = universe.newEntity()
        .withComponent(components.Screen, screen)
        .withComponent(components.Timers, try components.Timers.init(runtime.alloc))
        .withComponent(components.Level, .{ .player = player })
        .withComponent(components.Dungeon, dungeon);

    // Initialize systems:
    universe.registerSystem(systems.Input.handleInput);
    universe.registerSystem(systems.Movement.handleMove);
    universe.registerSystem(systems.Render.render);

    return universe;
}

test {
    std.testing.refAllDecls(Self);
}
