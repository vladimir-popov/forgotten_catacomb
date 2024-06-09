const ecs = @import("ecs");
const game = @import("game");
const cmp = game.components;

const Components = union {
    screen: cmp.Screen,
    dungeon: cmp.Dungeon,
    position: cmp.Position,
    move: cmp.Move,
    sprite: cmp.Sprite,
};

pub const Universe = ecs.Universe(Components, game.AnyRuntime);

pub fn init(runtime: game.AnyRuntime) !Universe {
    var universe: Universe = Universe.init(runtime.alloc, runtime);

    const dungeon = try cmp.Dungeon.initRandom(runtime.alloc, runtime.rand);
    const player_position = dungeon.findRandomPlaceForPlayer(runtime.rand);
    const player = universe.newEntity()
        .withComponent(cmp.Sprite, .{ .letter = "@" })
        .withComponent(cmp.Position, .{ .point = player_position })
        .withComponent(cmp.Move, .{})
        .entity;
    _ = player;
    var screen = cmp.Screen.init(game.DISPLAY_ROWS, game.DISPLAY_COLS, cmp.Dungeon.Region);
    screen.centeredAround(player_position);
    // init level
    _ = universe.newEntity()
        .withComponent(cmp.Screen, screen)
        .withComponent(cmp.Dungeon, dungeon);

    // Initialize systems:
    universe.registerSystem(handleInput);
    universe.registerSystem(handleMove);
    universe.registerSystem(render);

    return universe;
}

pub fn render(universe: *Universe) anyerror!void {
    const screen = &universe.getComponents(cmp.Screen)[0];

    const dungeon = &universe.getComponents(cmp.Dungeon)[0];
    try universe.runtime.drawDungeon(screen, dungeon);

    var itr = universe.queryComponents2(cmp.Sprite, cmp.Position);
    while (itr.next()) |components| {
        const sprite = components[1];
        const position = components[2];
        if (screen.region.containsPoint(position.point)) {
            try universe.runtime.drawSprite(screen, sprite, position);
        }
    }
}

pub fn handleInput(universe: *Universe) anyerror!void {
    const btn = try universe.runtime.readButton();
    if (btn == 0) return;

    const player_entity = universe.getComponents(game.components.Level)[0].player;
    if (universe.getComponent(player_entity, game.components.Move)) |move| {
        if (game.Button.toDirection(btn)) |direction| {
            move.direction = direction;
        }
    }
}
