/// This module contains primitive types, such as geometry primitives,
/// enums, and other not domain value objects.
const std = @import("std");

pub const Side = enum {
    left,
    right,
    top,
    bottom,

    pub inline fn opposite(self: Side) Side {
        return switch (self) {
            .top => .bottom,
            .bottom => .top,
            .left => .right,
            .right => .left,
        };
    }

    pub inline fn isHorizontal(self: Side) bool {
        return self == .top or self == .bottom;
    }
};

/// The coordinates of a point. Index begins from 1.
pub const Point = struct {
    row: u8,
    col: u8,

    pub fn movedTo(self: Point, direction: Side) Point {
        var point = self;
        point.move(direction);
        return point;
    }

    pub fn move(self: *Point, direction: Side) void {
        switch (direction) {
            .top => {
                if (self.row > 0) self.row -= 1;
            },
            .bottom => self.row += 1,
            .left => {
                if (self.col > 0) self.col -= 1;
            },
            .right => self.col += 1,
        }
    }
};

/// The region described as its top left corner
/// and count of rows and columns.
///
/// Example of the region 4x6:
///   c:1
/// r:1 *----*
///     |    |
///     |    |
///     *____* r:4
///        c:6
pub const Region = struct {
    /// Top left corner. Index of rows and cols begins from 1.
    top_left: Point,
    /// The count of rows in this region.
    rows: u8,
    /// The count of columns in this region.
    cols: u8,

    pub inline fn isHorizontal(self: Region) bool {
        return self.cols > self.rows;
    }

    pub inline fn bottomRight(self: Region) Point {
        return .{ .row = self.top_left.row + self.rows - 1, .col = self.top_left.col + self.cols - 1 };
    }

    /// Returns true if this region has less rows or columns than passed minimal
    /// values.
    pub inline fn lessThan(self: Region, min_rows: u8, min_cols: u8) bool {
        return self.rows < min_rows or self.cols < min_cols;
    }

    /// Returns the area of this region.
    pub inline fn area(self: Region) u16 {
        return self.rows * self.cols;
    }

    pub inline fn containsPoint(self: Region, point: Point) bool {
        return self.contains(point.row, point.col);
    }

    pub inline fn contains(self: Region, row: u8, col: u8) bool {
        return betweenInclusive(row, self.top_left.row, self.bottomRight().row) and
            betweenInclusive(col, self.top_left.col, self.bottomRight().col);
    }

    inline fn betweenInclusive(v: u8, l: u8, r: u8) bool {
        return l <= v and v <= r;
    }

    /// Returns true if the `other` region doesn't go beyond of this region.
    pub fn containsRegion(self: Region, other: Region) bool {
        if (self.top_left.row > other.top_left.row or self.top_left.col > other.top_left.col)
            return false;
        if (self.top_left.row + self.rows < other.top_left.row + other.rows)
            return false;
        if (self.top_left.col + self.cols < other.top_left.col + other.cols)
            return false;
        return true;
    }

    /// Splits vertically the region in two if it possible. The first one contains the top
    /// left corner and `cols` columns. The second has the other part.
    /// If splitting is impossible, returns null.
    /// ┌───┬───┐
    /// │ 1 │ 2 │
    /// └───┴───┘
    pub fn splitVertically(self: Region, cols: u8) ?struct { Region, Region } {
        if (0 < cols and cols < self.cols) {
            return .{
                Region{
                    .top_left = .{ .row = self.top_left.row, .col = self.top_left.col },
                    .rows = self.rows,
                    .cols = cols,
                },
                Region{
                    .top_left = .{ .row = self.top_left.row, .col = self.top_left.col + cols },
                    .rows = self.rows,
                    .cols = self.cols - cols,
                },
            };
        } else {
            return null;
        }
    }

    /// Splits horizontally the region in two if it possible. The first one contains the top
    /// left corner and `rows` rows. The second has the other part.
    /// If splitting is impossible, returns null.
    /// ┌───┐
    /// │ 1 │
    /// ├───┤
    /// │ 2 │
    /// └───┘
    pub fn splitHorizontally(self: Region, rows: u8) ?struct { Region, Region } {
        if (0 < rows and rows < self.rows) {
            return .{
                Region{
                    .top_left = .{ .row = self.top_left.row, .col = self.top_left.col },
                    .rows = rows,
                    .cols = self.cols,
                },
                Region{
                    .top_left = .{ .row = self.top_left.row + rows, .col = self.top_left.col },
                    .rows = self.rows - rows,
                    .cols = self.cols,
                },
            };
        } else {
            return null;
        }
    }

    /// Cuts all rows before the `row` if it possible.
    ///
    /// ┌---┐
    /// ¦   ¦
    /// ├───┤ < row (exclusive)
    /// │ r │
    /// └───┘
    pub fn cutHorizontallyAfter(self: Region, row: u8) ?Region {
        if (self.top_left.row <= row and row < self.bottomRight().row) {
            // copy original:
            var region = self;
            region.top_left.row = row + 1;
            region.rows -= (row + 1);
            return region;
        } else {
            return null;
        }
    }

    test cutHorizontallyAfter {
        // given:
        const region = Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 5, .cols = 3 };
        // when:
        const result = region.cutHorizontallyAfter(2);
        // then:
        try std.testing.expectEqualDeep(
            Region{ .top_left = .{ .row = 3, .col = 1 }, .rows = 2, .cols = 3 },
            result,
        );
    }

    /// Cuts all cols before the `col` if it possible.
    ///
    /// ┌---┬───┐
    /// ¦   │ r │
    /// └---┴───┘
    ///     ^
    ///     col (exclusive)
    pub fn cutVerticallyAfter(self: Region, col: u8) ?Region {
        if (self.top_left.col <= col and col < self.bottomRight().col) {
            // copy original:
            var region = self;
            region.top_left.col = col + 1;
            region.cols -= (col + 1);
            return region;
        } else {
            return null;
        }
    }

    test cutVerticallyAfter {
        // given:
        const region = Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 3, .cols = 5 };
        // when:
        const result = region.cutVerticallyAfter(2);
        // then:
        try std.testing.expectEqualDeep(
            Region{ .top_left = .{ .row = 1, .col = 3 }, .rows = 3, .cols = 2 },
            result,
        );
    }

    /// Cuts all rows after the `row` (exclusive) if it possible.
    ///
    /// ┌───┐
    /// │ r │
    /// ├───┤ < row (exclusive)
    /// ¦   ¦
    /// └---┘
    pub fn cutHorizontallyTo(self: Region, row: u8) ?Region {
        if (self.top_left.row < row and row <= self.bottomRight().row) {
            // copy original:
            var region = self;
            region.rows -= row;
            return region;
        } else {
            return null;
        }
    }

    test cutHorizontallyTo {
        // given:
        const region = Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 5, .cols = 3 };
        // when:
        const result = region.cutHorizontallyTo(3);
        // then:
        try std.testing.expectEqualDeep(
            Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 2, .cols = 3 },
            result,
        );
    }

    /// Cuts all cols after the `col` (exclusive) if it possible.
    ///
    /// ┌───┬---┐
    /// │ r │   ¦
    /// └───┴---┘
    ///     ^
    ///     col (exclusive)
    pub fn cutVerticallyTo(self: Region, col: u8) ?Region {
        if (self.top_left.col < col and col <= self.bottomRight().col) {
            // copy original:
            var region = self;
            region.cols -= col;
            return region;
        } else {
            return null;
        }
    }

    test cutVerticallyTo {
        // given:
        const region = Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 3, .cols = 5 };
        // when:
        const result = region.cutVerticallyTo(3);
        // then:
        try std.testing.expectEqualDeep(
            Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = 3, .cols = 2 },
            result,
        );
    }

    pub fn unionWith(self: Region, other: Region) Region {
        return .{
            .top_left = .{
                .row = @min(self.top_left.row, other.top_left.row),
                .col = @min(self.top_left.col, other.top_left.col),
            },
            .rows = @max(self.rows, other.rows),
            .cols = @max(self.cols, other.cols),
        };
    }
};
