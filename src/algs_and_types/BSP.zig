const std = @import("std");
const p = @import("primitives.zig");
const BinaryTree = @import("BinaryTree.zig");

pub const Tree = BinaryTree.Node(p.Region);

pub const MinRegion = struct {
    min_rows: u8 = 22,// 12,
    min_cols: u8 = 40,// 30,
    square_ratio: f16 = 0.3,

    fn validateRegion(self: MinRegion, region: p.Region) void {
        if (region.rows < self.min_rows) {
            std.debug.panic("The {any} has less than {d} min rows.\n", .{
                region,
                self.min_rows,
            });
        }
        if (region.cols < self.min_cols) {
            std.debug.panic("The {any} has less than {d} min cols.\n", .{
                region,
                self.min_cols,
            });
        }
    }
};

/// Builds graph of regions splitting the original region with `rows` and `cols`
/// on smaller regions with minimum `min_rows` or `min_cols`. A region from any
/// node contains regions of its children.
///
/// To free memory with returned graph, the arena should be freed.
pub fn buildTree(
    arena: *std.heap.ArenaAllocator,
    rand: std.Random,
    rows: u8,
    cols: u8,
    opts: MinRegion,
) !*Tree {
    const region = p.Region{ .top_left = .{ .row = 1, .col = 1 }, .rows = rows, .cols = cols };
    opts.validateRegion(region);

    const alloc = arena.allocator();
    var splitter = Splitter{ .rand = rand, .opts = opts };
    var root: *Tree = try Tree.root(alloc, region, compare);
    try root.split(alloc, splitter.handler());

    return root;
}

fn compare(_: u8, _: p.Region, _: p.Region) i8 {
    return 0;
}

const Splitter = struct {
    rand: std.Random,
    opts: MinRegion,

    fn handler(self: *Splitter) Tree.SplitHandler {
        return .{ .ptr = self, .split = split };
    }

    fn split(ptr: *anyopaque, node: *Tree) anyerror!?struct { p.Region, p.Region } {
        const self: *Splitter = @ptrCast(@alignCast(ptr));
        const region: p.Region = node.value;

        const is_vertical = region.ratio() < self.opts.square_ratio;

        if (is_vertical) {
            if (divideRnd(self.rand, region.cols, self.opts.min_rows)) |cols| {
                return region.splitVertically(cols);
            }
        } else {
            if (divideRnd(self.rand, region.rows, self.opts.min_rows)) |rows| {
                return region.splitHorizontally(rows);
            }
        }
        return null;
    }

    /// Randomly divides the `value` to two parts which are not less than `min`,
    /// or return null if it is impossible.
    inline fn divideRnd(rand: std.Random, value: u8, min: u8) ?u8 {
        return if (value > min * 2)
            min + rand.uintLessThan(u8, value - min * 2)
        else if (value == 2 * min)
            min
        else
            null;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "build tree" {
    // given:
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.reset(.free_all);
    var rand = std.Random.DefaultPrng.init(0);
    const opts: MinRegion = .{ .min_rows = 2, .min_cols = 2 };

    // when:
    const root = try buildTree(&arena, rand.random(), 9, 7, opts);

    // then:
    var validate = ValidateNodes{ .opts = opts };
    try root.traverse(validate.bspNodeHandler());
}

/// Utility for test
const ValidateNodes = struct {
    opts: MinRegion,
    min_ratio: f16 = 0.2,

    fn bspNodeHandler(self: *ValidateNodes) Tree.TraverseHandler {
        return .{ .ptr = self, .handle = validate };
    }

    fn validate(ptr: *anyopaque, node: *Tree) anyerror!void {
        const self: *ValidateNodes = @ptrCast(@alignCast(ptr));

        try self.validateNode("root", null, node);
        if (node.left) |left| {
            try self.validateNode("left", node, left);
        }
        if (node.right) |right| {
            try self.validateNode("right", node, right);
        }
    }

    fn validateNode(
        self: *ValidateNodes,
        name: []const u8,
        root: ?*Tree,
        node: *Tree,
    ) !void {
        if (root) |rt| {
            expect(rt.value.containsRegion(node.value)) catch |err| {
                std.debug.print(
                    "The {s} region {any} doesn't contained in the root {any}\n",
                    .{ name, node.value, rt.value },
                );
                return err;
            };
        }
        if (node.value.rows < self.opts.min_rows) {
            std.debug.print("The {s} {any} has less than {d} min rows.\n", .{
                name,
                node.value,
                self.opts.min_rows,
            });
            return error.TestUnexpectedResult;
        }
        if (node.value.cols < self.opts.min_cols) {
            std.debug.print("The {s} {any} has less than {d} min cols.\n", .{
                name,
                node.value,
                self.opts.min_cols,
            });
            return error.TestUnexpectedResult;
        }
        if (node.value.ratio() < self.min_ratio) {
            std.debug.print("The {s} {any} has lower ratio {d} than {d}.\n", .{
                name,
                node.value,
                node.value.ratio(),
                self.min_ratio,
            });
            return error.TestUnexpectedResult;
        }
    }
};
