const std = @import("std");
const p = @import("primitives.zig");

const log = std.log.scoped(.bitmap);

pub fn BitMap(comptime rows_count: u8, cols_count: u8) type {
    comptime {
        std.debug.assert(rows_count > 0);
        std.debug.assert(cols_count > 0);
    }
    return struct {
        pub const Error = error{
            WrongColumnsCountInString,
            WrongRowsCountInString,
        };

        const Self = @This();

        pub const rows: u8 = rows_count;
        pub const cols: u8 = cols_count;

        bitsets: std.ArrayList(std.DynamicBitSet),

        pub fn initEmpty(alloc: std.mem.Allocator) !Self {
            var self: Self = .{ .bitsets = std.ArrayList(std.DynamicBitSet).init(alloc) };
            for (0..rows) |_| {
                try self.bitsets.append(try std.DynamicBitSet.initEmpty(alloc, cols));
            }
            return self;
        }

        pub fn initFull(alloc: std.mem.Allocator) !Self {
            var self: Self = .{ .bitsets = std.ArrayList(std.DynamicBitSet).init(alloc) };
            for (0..rows) |_| {
                try self.bitsets.append(try std.DynamicBitSet.initFull(alloc, cols));
            }
            return self;
        }

        pub fn deinit(self: Self) void {
            for (self.bitsets.items) |*bs| {
                bs.deinit();
            }
            self.bitsets.deinit();
        }

        pub fn parse(comptime symbol: u8, alloc: std.mem.Allocator, str: []const u8) !Self {
            var self: Self = .{ .bitsets = std.ArrayList(std.DynamicBitSet).init(alloc) };
            try self.bitsets.append(try std.DynamicBitSet.initEmpty(alloc, cols));
            var r: u8 = 1;
            var c: u8 = 1;
            for (str) |char| {
                switch (char) {
                    '\n' => {
                        if (c > cols + 1) {
                            log.err(
                                "Total columns count is {d}, but found {d} char '{c}' in the parsed string\n{s}\n",
                                .{ cols, c, char, str },
                            );
                            return Error.WrongColumnsCountInString;
                        }
                        try self.bitsets.append(try std.DynamicBitSet.initEmpty(alloc, cols));
                        r += 1;
                        c = 0;
                    },
                    symbol => {
                        self.set(r, c);
                    },
                    else => {
                        self.unset(r, c);
                    },
                }
                c += 1;
            }
            if (r < rows) {
                log.err(
                    "Total rows count is {d}, but found {d} lines in the parsed string\n{s}\n",
                    .{ rows, r, str },
                );
                return Error.WrongRowsCountInString;
            }
            return self;
        }

        pub inline fn isSet(self: Self, row: u8, col: u8) bool {
            return self.bitsets.items[row - 1].isSet(col - 1);
        }

        pub inline fn set(self: *Self, row: u8, col: u8) void {
            self.bitsets.items[row - 1].set(col - 1);
        }

        pub inline fn setAt(self: *Self, point: p.Point) void {
            self.set(point.row, point.col);
        }

        pub inline fn unset(self: *Self, row: u8, col: u8) void {
            self.bitsets.items[row - 1].unset(col - 1);
        }

        pub inline fn unsetAt(self: *Self, point: p.Point) void {
            self.unset(point.row, point.col);
        }

        pub inline fn setRowValue(
            self: *Self,
            row: u8,
            from_col: u8,
            count: u8,
            value: bool,
        ) void {
            self.bitsets.items[row - 1].setRangeValue(
                .{ .start = from_col - 1, .end = from_col + count - 1 },
                value,
            );
        }

        pub fn setRegionValue(self: *Self, region: p.Region, value: bool) void {
            if (region.top_left.row > rows) {
                return;
            }
            if (region.top_left.col > cols) {
                return;
            }
            const to_row = @min(rows, region.bottomRightRow()) + 1;
            const to_col = @min(cols, region.bottomRightCol());
            for (region.top_left.row..to_row) |r| {
                self.bitsets.items[r - 1].setRangeValue(
                    .{ .start = region.top_left.col - 1, .end = to_col },
                    value,
                );
            }
        }
    };
}

test "parse BitMap" {
    // given:
    const str =
        \\###
        \\# #
        \\###
    ;

    // when:
    var bitmap = try BitMap(3, 3).parse('#', std.testing.allocator, str);

    // then:
    for (0..3) |r| {
        for (0..3) |c| {
            const expected = !(r == 1 and c == 1);
            try std.testing.expectEqual(expected, bitmap.isSet(@intCast(r + 1), @intCast(c + 1)));
        }
    }
}

test "unset a region" {
    // given:
    var bitmap = try BitMap(10, 10).initFull(std.testing.allocator);
    const region = p.Region{ .top_left = .{ .row = 2, .col = 2 }, .rows = 5, .cols = 5 };

    // when:
    bitmap.setRegionValue(region, false);

    // then:
    for (bitmap.bitsets.items, 1..) |row, r| {
        for (0..10) |c_idx| {
            const cell = row.isSet(c_idx);
            const expect = !region.containsPoint(.{ .row = @intCast(r), .col = @intCast(c_idx + 1) });
            try std.testing.expectEqual(expect, cell);
        }
    }
}
