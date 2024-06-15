const std = @import("std");
const builtin = @import("builtin");
const algs_and_types = @import("algs_and_types");
const p = algs_and_types.primitives;

const bsp = algs_and_types.BSP;

const log = std.log.scoped(.dungeon);

pub const Error = error{
    NoSpaceForDoor,
    PassageCantBeCreated,
};

pub const Room = p.Region;

pub const Door = enum { opened, closed };

pub const Passage = struct {
    const Turn = struct {
        place: p.Point,
        to_direction: p.Direction,
        pub fn format(
            self: Turn,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Turn(at {any} to {s})", .{ self.place, @tagName(self.to_direction) });
        }
    };

    turns: std.ArrayList(Turn),

    pub fn format(
        self: Passage,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Passage({any})", .{self.turns.items});
    }

    fn deinit(self: Passage) void {
        self.turns.deinit();
    }

    fn turnAt(self: *Passage, place: p.Point, direction: p.Direction) !Turn {
        const turn: Turn = .{ .place = place, .to_direction = direction };
        try self.turns.append(turn);
        return turn;
    }

    fn turnToPoint(self: *Passage, at: p.Point, to: p.Point) !Turn {
        const direction: p.Direction = if (at.row == to.row)
            if (at.col < to.col) .right else .left
        else if (at.row < to.row) .down else .up;
        return try self.turnAt(at, direction);
    }
};

pub fn BspDungeon(comptime rows_count: u8, cols_count: u8) type {
    return struct {
        /// The dungeon. Contains walls, doors, rooms and passages of the level.
        const Self = @This();

        pub const Rows: u8 = rows_count;
        pub const Cols: u8 = cols_count;
        pub const Region: p.Region = .{ .top_left = .{ .row = 1, .col = 1 }, .rows = Rows, .cols = Cols };

        // rows / cols - for terminal it's less than 0.
        // TODO make it as argument
        const SquareRation: f16 = 0.4;

        const BitMap = algs_and_types.BitMap(Rows, Cols);

        /// Possible types of objects inside the dung
        pub const CellEnum = enum {
            nothing,
            floor,
            wall,
            door,
        };

        /// Particular object in the cell of the dung
        pub const Cell = union(CellEnum) {
            nothing,
            floor,
            wall,
            door: Door,
        };

        alloc: std.mem.Allocator,
        rand: std.Random,
        floor: BitMap,
        walls: BitMap,
        objects: BitMap,

        objects_map: std.AutoHashMap(p.Point, Cell),

        // meta data about the dungeon:
        rooms: std.ArrayList(Room),
        passages: std.ArrayList(Passage),

        pub fn destroy(self: *Self) void {
            for (self.passages.items) |passage| {
                passage.deinit();
            }
            self.floor.deinit();
            self.walls.deinit();
            self.objects.deinit();
            self.passages.deinit();
            self.rooms.deinit();
            self.objects_map.deinit();
            self.alloc.destroy(self);
        }

        pub fn createEmpty(alloc: std.mem.Allocator, rand: std.Random) !*Self {
            const instance = try alloc.create(Self);
            instance.* = .{
                .alloc = alloc,
                .rand = rand,
                .rooms = std.ArrayList(Room).init(alloc),
                .passages = std.ArrayList(Passage).init(alloc),
                .floor = try BitMap.initEmpty(alloc),
                .walls = try BitMap.initEmpty(alloc),
                .objects = try BitMap.initEmpty(alloc),
                .objects_map = std.AutoHashMap(p.Point, Cell).init(alloc),
            };
            return instance;
        }

        /// Basic BSP Dungeon generation
        /// https://www.roguebasin.com/index.php?title=Basic_BSP_Dungeon_generation
        pub fn createRandom(alloc: std.mem.Allocator, rand: std.Random) !*Self {
            // this arena is used to build a BSP tree, which can be destroyed
            // right after completing the dungeon.
            var bsp_arena = std.heap.ArenaAllocator.init(alloc);
            defer _ = bsp_arena.deinit();

            const dungeon: *Self = try createEmpty(alloc, rand);

            // BSP helps to mark regions for rooms without intersections
            const root = try bsp.buildTree(&bsp_arena, rand, Rows, Cols, .{});

            // visit every BSP node and generate rooms in the leafs
            var createRooms: TraverseAndCreateRooms = .{ .dungeon = dungeon, .rand = rand };
            try root.traverse(bsp_arena.allocator(), createRooms.handler());

            // fold the BSP tree and binds nodes with the same parent:
            _ = try root.foldModify(
                alloc,
                .{ .ptr = dungeon, .combine = createAndAddPassageBetweenRegions },
            );

            return dungeon;
        }

        pub fn findRandomPlaceForPlayer(self: Self) p.Point {
            const room = self.rand.uintLessThan(usize, self.rooms.items.len);
            return self.rooms.items[room].middle();
        }

        /// For tests only
        fn parse(alloc: std.mem.Allocator, rand: std.Random, str: []const u8) !*Self {
            if (!builtin.is_test) {
                @compileError("The function `parse` is for test purpose only");
            }
            const dungeon = try Self.createEmpty(alloc, rand);
            dungeon.floor = try BitMap.parse('.', alloc, str);
            dungeon.walls = try BitMap.parse('#', alloc, str);
            return dungeon;
        }

        pub inline fn cellAt(self: Self, place: p.Point) ?Cell {
            if (place.row < 1 or place.row > Rows) {
                return null;
            }
            if (place.col < 1 or place.col > Cols) {
                return null;
            }
            if (self.walls.isSet(place.row, place.col)) {
                return .wall;
            }
            if (self.floor.isSet(place.row, place.col)) {
                return .floor;
            }
            if (self.objects.isSet(place.row, place.col)) {
                return self.objects_map.get(place) orelse unreachable;
            }
            return .nothing;
        }

        pub inline fn isCellAt(self: Self, place: p.Point, assumption: CellEnum) bool {
            if (self.cellAt(place)) |cl| {
                return @intFromEnum(cl) == @intFromEnum(assumption);
            } else {
                return false;
            }
        }

        pub fn cellsInRegion(self: *const Self, region: p.Region) ?CellsIterator {
            if (Self.Region.intersect(region)) |reg| {
                return .{
                    .dungeon = self,
                    .region = reg,
                    .cursor = reg.top_left,
                };
            } else {
                return null;
            }
        }

        pub fn cellsAround(self: *const Self, place: p.Point) ?CellsIterator {
            return self.cellsInRegion(.{
                .top_left = .{
                    .row = @max(place.row - 1, 1),
                    .col = @max(place.col - 1, 1),
                },
                .rows = 3,
                .cols = 3,
            });
        }

        pub const CellsIterator = struct {
            dungeon: *const Self,
            region: p.Region,
            cursor: p.Point,

            pub fn next(self: *CellsIterator) ?Cell {
                if (!self.region.containsPoint(self.cursor))
                    return null;

                if (self.dungeon.cellAt(self.cursor)) |cl| {
                    self.cursor.move(.right);
                    if (self.cursor.col > self.region.bottomRightCol()) {
                        self.cursor.col = self.region.top_left.col;
                        self.cursor.row += 1;
                    }
                    return cl;
                }
                return null;
            }
        };

        pub fn openDoor(self: *Self, position: p.Point) void {
            if (self.objects_map.getPtr(position)) |cell_ptr| {
                switch (cell_ptr.*) {
                    .door => {
                        cell_ptr.* = .{ .door = .opened };
                    },
                    else => {},
                }
            }
        }

        fn cleanAt(self: *Self, place: p.Point) void {
            if (!Region.containsPoint(place)) {
                return;
            }
            self.floor.unsetAt(place);
            self.walls.unsetAt(place);
            if (self.objects.isSet(place.row, place.col)) {
                _ = self.objects_map.remove(place);
                self.objects.unsetAt(place);
            }
        }

        fn forceCreateFloorAt(self: *Self, place: p.Point) !void {
            if (!Region.containsPoint(place)) {
                return;
            }
            self.cleanAt(place);
            self.floor.setAt(place);
        }

        fn forceCreateWallAt(self: *Self, place: p.Point) !void {
            if (!Region.containsPoint(place)) {
                return;
            }
            self.cleanAt(place);
            self.walls.setAt(place);
        }

        fn forceCreateDoorAt(self: *Self, place: p.Point, is_open: bool) !void {
            if (!Region.containsPoint(place)) {
                return;
            }
            self.cleanAt(place);
            self.objects.setAt(place);
            try self.objects_map.put(place, .{ .door = if (is_open) .opened else .closed });
        }

        fn createWallAt(self: *Self, place: p.Point) void {
            if (!Region.containsPoint(place)) {
                return;
            }
            if (self.isCellAt(place, .nothing)) {
                self.walls.setAt(place);
            }
        }

        fn createFloorAt(self: *Self, place: p.Point) void {
            if (!Region.containsPoint(place)) {
                return;
            }
            if (self.isCellAt(place, .nothing)) {
                self.floor.setAt(place);
            }
        }

        const TraverseAndCreateRooms = struct {
            dungeon: *Self,
            rand: std.Random,

            fn handler(self: *TraverseAndCreateRooms) bsp.Tree.TraverseHandler {
                return .{ .ptr = self, .handle = TraverseAndCreateRooms.createRoom };
            }

            fn createRoom(ptr: *anyopaque, node: *bsp.Tree) anyerror!void {
                if (!node.isLeaf()) return;
                const self: *TraverseAndCreateRooms = @ptrCast(@alignCast(ptr));
                try self.dungeon.generateAndAddRoom(self.rand, node.value);
            }
        };

        fn generateAndAddRoom(self: *Self, rand: std.Random, region: p.Region) !void {
            const room = try self.generateSimpleRoom(rand, region, .{});
            try self.rooms.append(room);
        }

        /// Configuration of the simple rooms.
        const SimpleRoomOpts = struct {
            /// Minimal rows count in the room
            min_rows: u8 = 5,
            /// Minimal columns count in the room
            min_cols: u8 = 5,
            /// Minimal scale rate to prevent too small rooms
            min_scale: f16 = 0.6,
            /// This is rows/cols ratio of the square.
            /// In case of ascii graphics it's not 1.0
            square_ratio: f16 = SquareRation,

            /// Minimal area of the room
            inline fn minArea(self: SimpleRoomOpts) u8 {
                return self.min_rows * self.min_cols;
            }
        };

        /// Creates floor and walls inside the region with random padding.
        /// Also, the count of rows and columns can be randomly reduced too.
        ///
        /// Example of the room inside the 7x7 region with padding 1
        /// (the room's region includes the '#' cells):
        ///
        ///  ________
        /// |       |
        /// |       |
        /// | ##### |
        /// | #   # |
        /// | ##### |
        /// |       |
        /// |       |
        /// ---------
        fn generateSimpleRoom(self: *Self, rand: std.Random, region: p.Region, opts: SimpleRoomOpts) !Room {
            var room: p.Region = region;
            if (!std.math.approxEqAbs(f16, opts.square_ratio, region.ratio(), 0.1)) {
                // make the region 'more square'
                if (region.ratio() > opts.square_ratio) {
                    room.rows = @max(
                        opts.min_rows,
                        @as(u8, @intFromFloat(@round(@as(f16, @floatFromInt(region.cols)) * opts.square_ratio))),
                    );
                } else {
                    room.cols = @max(
                        opts.min_cols,
                        @as(u8, @intFromFloat(@round(@as(f16, @floatFromInt(region.rows)) / opts.square_ratio))),
                    );
                }
            }
            var scale: f16 = @floatFromInt(1 + rand.uintLessThan(u16, room.area() - opts.minArea()));
            scale = scale / @as(f16, @floatFromInt(room.area()));
            room.scale(@max(opts.min_scale, scale));
            return self.createSimpleRoom(room);
        }

        fn createSimpleRoom(self: *Self, room: p.Region) Room {
            // generate walls:
            for (room.top_left.row..(room.top_left.row + room.rows)) |r| {
                if (r == room.top_left.row or r == room.bottomRightRow()) {
                    self.walls.setRowValue(@intCast(r), room.top_left.col, room.cols, true);
                } else {
                    self.walls.set(@intCast(r), @intCast(room.top_left.col));
                    self.walls.set(@intCast(r), @intCast(room.bottomRightCol()));
                }
            }
            // generate floor:
            var floor = room;
            floor.top_left.row += 1;
            floor.top_left.col += 1;
            floor.rows -= 2;
            floor.cols -= 2;
            self.floor.setRegionValue(floor, true);

            return room;
        }

        fn createAndAddPassageBetweenRegions(
            ptr: *anyopaque,
            r1: *const p.Region,
            r2: *const p.Region,
        ) !p.Region {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const direction: p.Direction = if (r1.top_left.row == r2.top_left.row) .right else .down;
            const door1 = try self.findPlaceForDoorInRegionRnd(r1, direction) orelse
                return Error.NoSpaceForDoor;
            const door2 = try self.findPlaceForDoorInRegionRnd(r2, direction.opposite()) orelse
                return Error.NoSpaceForDoor;

            log.debug("Creating the passage from {any} {s} to {any}", .{ door1, @tagName(direction), door2 });

            const passage = try self.passages.addOne();
            passage.turns = std.ArrayList(Passage.Turn).init(self.alloc);
            _ = try passage.turnAt(door1, direction);
            if (door1.row != door2.row and door1.col != door2.col) {
                // intersection of the passage from the door 1 and region 1
                var middle1: p.Point = if (direction == .left or direction == .right)
                    // left or right
                    .{ .row = door1.row, .col = r1.bottomRightCol() }
                else
                    // up or down
                    .{ .row = r1.bottomRightRow(), .col = door1.col };

                // intersection of the passage from the region 1 and door 2
                var middle2: p.Point = if (direction == .left or direction == .right)
                    // left or right
                    .{ .row = door2.row, .col = r1.bottomRightCol() }
                else
                    // up or down
                    .{ .row = r1.bottomRightRow(), .col = door2.col };

                // try to find better places for turn:
                if (try self.findPlaceForPassageTurn(door1, door2, direction == .left or direction == .right, 0)) |places| {
                    middle1 = places[0];
                    middle2 = places[1];
                }

                var turn = try passage.turnToPoint(middle1, middle2);

                turn = try passage.turnToPoint(middle2, door2);
            }
            _ = try passage.turnAt(door2, direction);

            try self.digPassage(passage);
            try self.forceCreateDoorAt(door1, self.rand.boolean());
            try self.forceCreateDoorAt(door2, self.rand.boolean());

            return r1.unionWith(r2);
        }

        /// Trying to find a line between `from` and `to` with `nothing` cells only.
        /// Gives up after 5 attempt to prevent long search.
        fn findPlaceForPassageTurn(
            self: Self,
            init_from: p.Point,
            init_to: p.Point,
            is_horizontal: bool,
            attempt: u8,
        ) !?struct { p.Point, p.Point } {
            var current_attempt = attempt;
            var stack = std.ArrayList(struct { p.Point, p.Point }).init(self.alloc);
            defer stack.deinit();
            try stack.append(.{ init_from, init_to });
            var middle1: p.Point = undefined;
            var middle2: p.Point = undefined;
            while (stack.popOrNull()) |points| {
                const from = points[0];
                const to = points[0];
                const distance: u8 = if (is_horizontal)
                    to.col - from.col
                else
                    to.row - from.row;

                if (distance > 4 and current_attempt < 5) {
                    if (is_horizontal) {
                        middle1.row = from.row;
                        middle1.col = distance / 2 + from.col;
                        middle2.row = to.row;
                        middle2.col = middle1.col;
                    } else {
                        middle1.row = distance / 2 + from.row;
                        middle1.col = from.col;
                        middle2.row = middle1.row;
                        middle2.col = to.col;
                    }
                    if (self.isFreeLine(middle1, middle2)) {
                        return .{ middle1, middle2 };
                    }
                    current_attempt += 1;
                    try stack.append(.{ from, middle2 });
                    try stack.append(.{ middle1, to });
                }
            }
            return null;
        }

        fn isFreeLine(self: Self, from: p.Point, to: p.Point) bool {
            const direction: p.Direction = if (from.col == to.col and from.row < to.row)
                .down
            else if (from.col == to.col and from.row > to.row)
                .up
            else if (from.row == to.row and from.col < to.col)
                .right
            else if (from.row == to.row and from.col > to.col)
                .left
            else
                unreachable;
            var cursor = from;
            while (!std.meta.eql(cursor, to)) {
                if (self.isCellAt(cursor, .nothing))
                    cursor.move(direction)
                else
                    return false;
            }
            return true;
        }

        fn digPassage(self: *Self, passage: *const Passage) !void {
            var prev: Passage.Turn = passage.turns.items[0];
            for (passage.turns.items[1 .. passage.turns.items.len - 1]) |turn| {
                try self.dig(prev.place, turn.place, prev.to_direction);
                try self.digTurn(turn.place, prev.to_direction, turn.to_direction);
                prev = turn;
            }
            try self.dig(prev.place, passage.turns.getLast().place, prev.to_direction);
        }

        fn dig(self: *Self, from: p.Point, to: p.Point, direction: p.Direction) !void {
            var point = from;
            while (true) {
                self.createWallAt(point.movedTo(direction.rotatedClockwise(false)));
                self.createWallAt(point.movedTo(direction.rotatedClockwise(true)));
                self.createFloorAt(point);
                if (std.meta.eql(point, to))
                    break;
                point.move(direction);
            }
        }

        fn digTurn(self: *Self, at: p.Point, from: p.Direction, to: p.Direction) !void {
            // wrap the corner by walls
            const reg: p.Region = .{ .top_left = at.movedTo(.up).movedTo(.left), .rows = 3, .cols = 3 };
            var itr = reg.cells();
            while (itr.next()) |cl| {
                self.createWallAt(cl);
            }
            // create the floor in the turn
            try self.forceCreateFloorAt(at);
            try self.forceCreateFloorAt(at.movedTo(from.opposite()));
            try self.forceCreateFloorAt(at.movedTo(to));
        }

        fn findPlaceForDoorInRegionRnd(
            self: Self,
            init_region: *const p.Region,
            side: p.Direction,
        ) !?p.Point {
            var stack = std.ArrayList(p.Region).init(self.alloc);
            defer stack.deinit();
            try stack.append(init_region.*);
            while (stack.popOrNull()) |region| {
                const place = switch (side) {
                    .up => p.Point{
                        .row = region.top_left.row,
                        .col = self.rand.intRangeAtMost(u8, region.top_left.col, region.bottomRightCol()),
                    },
                    .down => p.Point{
                        .row = region.bottomRightRow(),
                        .col = self.rand.intRangeAtMost(u8, region.top_left.col, region.bottomRightCol()),
                    },
                    .left => p.Point{
                        .row = self.rand.intRangeAtMost(u8, region.top_left.row, region.bottomRightRow()),
                        .col = region.top_left.col,
                    },
                    .right => p.Point{
                        .row = self.rand.intRangeAtMost(u8, region.top_left.row, region.bottomRightRow()),
                        .col = region.bottomRightCol(),
                    },
                };
                if (self.findPlaceForDoor(side.opposite(), place, region)) |candidate| {
                    if (self.cellAt(candidate)) |cl| {
                        switch (cl) {
                            .wall => {
                                return candidate;
                            },
                            else => {},
                        }
                    }
                }
                // try to find in the different parts of the region:
                var new_regions: [2]?p.Region = .{ null, null };
                if (side == .up or side == .down) {
                    new_regions = if (self.rand.boolean())
                        .{ region.cropVerticallyTo(place.col), region.cropVerticallyAfter(place.col) }
                    else
                        .{ region.cropVerticallyAfter(place.col), region.cropVerticallyTo(place.col) };
                } else {
                    new_regions = if (self.rand.boolean())
                        .{ region.cropHorizontallyTo(place.row), region.cropHorizontallyAfter(place.row) }
                    else
                        .{ region.cropHorizontallyAfter(place.row), region.cropHorizontallyTo(place.row) };
                }
                for (new_regions) |new_region| {
                    if (new_region) |reg| {
                        reg.validate();
                        try stack.append(reg);
                    }
                }
            }
            return null;
        }

        /// Looks for an empty place with the floor.
        /// Starting from the `start`, moves in the `direction` till the first floor cell right after the
        /// single wall.
        /// Returns the found place or null.
        fn findPlaceForDoor(self: Self, direction: p.Direction, start: p.Point, region: p.Region) ?p.Point {
            var place = start;
            while (region.containsPoint(place)) {
                if (self.cellAt(place)) |cl| {
                    switch (cl) {
                        .nothing => {},
                        .door => {
                            return null;
                        },
                        .wall => {
                            if (!self.isCellAt(place.movedTo(direction), .floor)) {
                                return null;
                            }
                            // check that no one door near
                            if (self.isCellAt(place.movedTo(direction.rotatedClockwise(true)), .door)) {
                                return null;
                            }
                            if (self.isCellAt(place.movedTo(direction.rotatedClockwise(false)), .door)) {
                                return null;
                            }
                            return place;
                        },
                        .floor => {
                            return null;
                        },
                    }
                } else {
                    return null;
                }
                place.move(direction);
            }
            return null;
        }
        inline fn contains(self: BspDungeon, point: p.Point) bool {
            return point.row > 0 and point.row <= self.rows and point.col > 0 and point.col <= self.cols;
        }
    };
}

test "generate a simple room" {
    // given:
    const Rows = 12;
    const Cols = 12;
    var dungeon = try BspDungeon(Rows, Cols).createEmpty(std.testing.allocator, std.crypto.random);
    defer dungeon.destroy();

    const region = p.Region{ .top_left = .{ .row = 2, .col = 2 }, .rows = 8, .cols = 8 };

    // when:
    const room = try dungeon.generateSimpleRoom(std.crypto.random, region, .{});

    // then:
    try std.testing.expect(region.containsRegion(room));
    for (0..Rows) |r_idx| {
        const r: u8 = @intCast(r_idx + 1);
        for (0..Cols) |c_idx| {
            const c: u8 = @intCast(c_idx + 1);
            errdefer std.debug.print("r:{d} c:{d}\n", .{ r, c });

            const cell = dungeon.cellAt(.{ .row = r, .col = c });
            if (room.containsPoint(.{ .row = r, .col = c })) {
                const expect_wall =
                    (r == room.top_left.row or r == room.bottomRightRow() or
                    c == room.top_left.col or c == room.bottomRightCol());
                if (expect_wall) {
                    try std.testing.expectEqual(.wall, cell);
                } else {
                    try std.testing.expectEqual(.floor, cell);
                }
            } else {
                try std.testing.expectEqual(.nothing, cell);
            }
        }
    }
}

test "find a place for door inside the room starting outside" {
    // given:
    const str =
        \\ ####
        \\ #..#
        \\ #..#
        \\ ####
    ;
    var dungeon = try BspDungeon(4, 5).parse(std.testing.allocator, std.crypto.random, str);
    defer dungeon.destroy();
    const region = BspDungeon(4, 5).Region;

    // when:
    const expected = dungeon.findPlaceForDoor(
        .right,
        p.Point{ .row = 2, .col = 1 },
        region,
    );
    const unexpected = dungeon.findPlaceForDoor(
        .right,
        p.Point{ .row = 1, .col = 1 },
        region,
    );

    // then:
    try std.testing.expectEqualDeep(p.Point{ .row = 2, .col = 2 }, expected.?);
    try std.testing.expect(unexpected == null);
}

test "find a place for door inside the room starting on the wall" {
    // given:
    const str =
        \\ ####
        \\ #..#
        \\ #..#
        \\ ####
    ;
    var dungeon = try BspDungeon(4, 5).parse(std.testing.allocator, std.crypto.random, str);
    defer dungeon.destroy();
    const region = BspDungeon(4, 5).Region;

    // when:
    const expected = dungeon.findPlaceForDoor(
        .down,
        p.Point{ .row = 1, .col = 3 },
        region,
    );
    const unexpected = dungeon.findPlaceForDoor(
        .down,
        p.Point{ .row = 1, .col = 1 },
        region,
    );

    // then:
    try std.testing.expectEqualDeep(p.Point{ .row = 1, .col = 3 }, expected.?);
    try std.testing.expect(unexpected == null);
}
test "find a random place for the door on the left side" {
    // given:
    const str =
        \\ ####
        \\ #..#
        \\ #..#
        \\ ####
    ;
    errdefer std.debug.print("{s}\n", .{str});
    const rand = std.crypto.random;
    var dungeon = try BspDungeon(4, 5).parse(std.testing.allocator, rand, str);
    defer dungeon.destroy();
    const region = BspDungeon(4, 5).Region;

    // when:
    const place_left = try dungeon.findPlaceForDoorInRegionRnd(&region, .left);

    // then:
    errdefer std.debug.print("place left {any}\n", .{place_left});
    try std.testing.expectEqual(2, place_left.?.col);
    try std.testing.expect(2 <= place_left.?.row and place_left.?.row <= 3);
}

test "find a random place for the door on the bottom side" {
    // given:
    const str =
        \\ ####
        \\ #..#
        \\ #..#
        \\ ####
    ;
    errdefer std.debug.print("{s}\n", .{str});
    var dungeon = try BspDungeon(4, 5).parse(std.testing.allocator, std.crypto.random, str);
    defer dungeon.destroy();
    const region = BspDungeon(4, 5).Region;

    // when:
    const place_bottom = try dungeon.findPlaceForDoorInRegionRnd(&region, .down);

    // then:
    errdefer std.debug.print("place bottom {any}\n", .{place_bottom});
    try std.testing.expectEqual(4, place_bottom.?.row);
    try std.testing.expect(3 <= place_bottom.?.col and place_bottom.?.col <= 4);
}

test "create passage between two rooms" {
    // given:
    const Rows = 4;
    const Cols = 12;
    const str =
        \\ ####   ####
        \\ #..#   #..#
        \\ #..#   #..#
        \\ ####   ####
    ;
    errdefer std.debug.print("{s}\n", .{str});
    const rand = std.crypto.random;
    const dungeon = try BspDungeon(Rows, Cols).parse(std.testing.allocator, rand, str);
    defer dungeon.destroy();
    const r1 = p.Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = Rows, .cols = 6 };
    const r2 = p.Region{ .top_left = .{ .row = 1, .col = 7 }, .rows = Rows, .cols = Cols - 6 };

    // when:
    const region = try BspDungeon(Rows, Cols).createAndAddPassageBetweenRegions(dungeon, &r1, &r2);

    // then:
    try std.testing.expectEqualDeep(BspDungeon(Rows, Cols).Region, region);
    const passage: Passage = dungeon.passages.items[0];
    errdefer std.debug.print("Passage: {any}\n", .{passage.turns.items});
    try std.testing.expect(passage.turns.items.len >= 2);
}

test {
    std.testing.refAllDecls(@This());
}
