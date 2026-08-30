const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }

    pub fn center(self: Rect) struct { cx: i32, cy: i32 } {
        return .{
            .cx = @as(i32, self.x) + @divTrunc(@as(i32, self.width), 2),
            .cy = @as(i32, self.y) + @divTrunc(@as(i32, self.height), 2),
        };
    }
};

pub const SplitDirection = enum {
    vertical,
    horizontal,
};

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const Node = struct {
    data: NodeData,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub const NodeData = union(enum) {
        leaf: LeafData,
        split: SplitData,
    };

    pub const LeafData = struct {
        id: u32,
    };

    pub const SplitData = struct {
        direction: SplitDirection,
        ratio: f32 = 0.5,
        first: *Node,
        second: *Node,
    };

    pub fn createLeaf(allocator: std.mem.Allocator, id: u32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .data = .{ .leaf = .{ .id = id } },
        };
        return node;
    }

    pub fn createSplit(
        allocator: std.mem.Allocator,
        direction: SplitDirection,
        ratio: f32,
        first: *Node,
        second: *Node,
    ) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .data = .{
                .split = .{
                    .direction = direction,
                    .ratio = ratio,
                    .first = first,
                    .second = second,
                },
            },
        };
        return node;
    }

    pub fn destroy(self: ?*Node, allocator: std.mem.Allocator) void {
        if (self) |n| {
            switch (n.data) {
                .leaf => {},
                .split => |s| {
                    s.first.destroy(allocator);
                    s.second.destroy(allocator);
                },
            }
            allocator.destroy(n);
        }
    }

    pub fn computeLayout(self: *Node, area: Rect) void {
        self.rect = area;
        switch (self.data) {
            .leaf => {},
            .split => |*s| {
                if (s.direction == .vertical) {
                    if (area.width <= 2) {
                        const w1 = @max(1, area.width / 2);
                        const w2 = area.width - w1;
                        s.first.computeLayout(.{ .x = area.x, .y = area.y, .width = w1, .height = area.height });
                        s.second.computeLayout(.{ .x = area.x + w1, .y = area.y, .width = w2, .height = area.height });
                    } else {
                        const avail = area.width - 1;
                        var w1 = @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * s.ratio)));
                        w1 = @max(1, @min(avail - 1, w1));
                        const w2 = avail - w1;
                        s.first.computeLayout(.{ .x = area.x, .y = area.y, .width = w1, .height = area.height });
                        s.second.computeLayout(.{ .x = area.x + w1 + 1, .y = area.y, .width = w2, .height = area.height });
                    }
                } else {
                    if (area.height <= 2) {
                        const h1 = @max(1, area.height / 2);
                        const h2 = area.height - h1;
                        s.first.computeLayout(.{ .x = area.x, .y = area.y, .width = area.width, .height = h1 });
                        s.second.computeLayout(.{ .x = area.x, .y = area.y + h1, .width = area.width, .height = h2 });
                    } else {
                        const avail = area.height - 1;
                        var h1 = @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * s.ratio)));
                        h1 = @max(1, @min(avail - 1, h1));
                        const h2 = avail - h1;
                        s.first.computeLayout(.{ .x = area.x, .y = area.y, .width = area.width, .height = h1 });
                        s.second.computeLayout(.{ .x = area.x, .y = area.y + h1 + 1, .width = area.width, .height = h2 });
                    }
                }
            },
        }
    }

    pub fn findLeaf(self: *Node, id: u32) ?*Node {
        switch (self.data) {
            .leaf => |l| {
                if (l.id == id) return self;
                return null;
            },
            .split => |s| {
                if (s.first.findLeaf(id)) |res| return res;
                return s.second.findLeaf(id);
            },
        }
    }

    pub fn countLeaves(self: *Node) usize {
        switch (self.data) {
            .leaf => return 1,
            .split => |s| return s.first.countLeaves() + s.second.countLeaves(),
        }
    }

    pub fn collectLeaves(self: *Node, list: *std.ArrayList(*Node), allocator: std.mem.Allocator) !void {
        switch (self.data) {
            .leaf => try list.append(allocator, self),
            .split => |s| {
                try s.first.collectLeaves(list, allocator);
                try s.second.collectLeaves(list, allocator);
            },
        }
    }

    pub fn splitLeaf(
        allocator: std.mem.Allocator,
        root_ptr: **Node,
        target_id: u32,
        new_id: u32,
        direction: SplitDirection,
    ) !*Node {
        const root = root_ptr.*;
        if (root.data == .leaf and root.data.leaf.id == target_id) {
            const new_leaf = try Node.createLeaf(allocator, new_id);
            const old_leaf = root;
            const split_node = try Node.createSplit(allocator, direction, 0.5, old_leaf, new_leaf);
            root_ptr.* = split_node;
            return new_leaf;
        }

        return splitLeafRecursive(allocator, root, target_id, new_id, direction);
    }

    fn splitLeafRecursive(
        allocator: std.mem.Allocator,
        parent: *Node,
        target_id: u32,
        new_id: u32,
        direction: SplitDirection,
    ) !*Node {
        switch (parent.data) {
            .leaf => return error.TargetNotFound,
            .split => |*s| {
                if (s.first.data == .leaf and s.first.data.leaf.id == target_id) {
                    const new_leaf = try Node.createLeaf(allocator, new_id);
                    const old_leaf = s.first;
                    const split_node = try Node.createSplit(allocator, direction, 0.5, old_leaf, new_leaf);
                    s.first = split_node;
                    return new_leaf;
                }
                if (s.second.data == .leaf and s.second.data.leaf.id == target_id) {
                    const new_leaf = try Node.createLeaf(allocator, new_id);
                    const old_leaf = s.second;
                    const split_node = try Node.createSplit(allocator, direction, 0.5, old_leaf, new_leaf);
                    s.second = split_node;
                    return new_leaf;
                }

                if (s.first.findLeaf(target_id) != null) {
                    return splitLeafRecursive(allocator, s.first, target_id, new_id, direction);
                } else if (s.second.findLeaf(target_id) != null) {
                    return splitLeafRecursive(allocator, s.second, target_id, new_id, direction);
                }
                return error.TargetNotFound;
            },
        }
    }

    pub fn closeLeaf(allocator: std.mem.Allocator, root_ptr: **Node, target_id: u32) bool {
        const root = root_ptr.*;
        if (root.data == .leaf) {
            if (root.data.leaf.id == target_id) {
                allocator.destroy(root);
                return true;
            }
            return false;
        }

        return closeLeafRecursive(allocator, root_ptr, root, target_id);
    }

    fn closeLeafRecursive(allocator: std.mem.Allocator, parent_slot: **Node, current: *Node, target_id: u32) bool {
        switch (current.data) {
            .leaf => return false,
            .split => |*s| {
                if (s.first.data == .leaf and s.first.data.leaf.id == target_id) {
                    const sibling = s.second;
                    allocator.destroy(s.first);
                    allocator.destroy(current);
                    parent_slot.* = sibling;
                    return true;
                }
                if (s.second.data == .leaf and s.second.data.leaf.id == target_id) {
                    const sibling = s.first;
                    allocator.destroy(s.second);
                    allocator.destroy(current);
                    parent_slot.* = sibling;
                    return true;
                }

                if (s.first.findLeaf(target_id) != null) {
                    return closeLeafRecursive(allocator, &s.first, s.first, target_id);
                } else if (s.second.findLeaf(target_id) != null) {
                    return closeLeafRecursive(allocator, &s.second, s.second, target_id);
                }
                return false;
            },
        }
    }

    pub fn resizePane(self: *Node, target_id: u32, dir: Direction, delta: f32) bool {
        return resizeRecursive(self, target_id, dir, delta);
    }

    fn resizeRecursive(node: *Node, target_id: u32, dir: Direction, delta: f32) bool {
        switch (node.data) {
            .leaf => return false,
            .split => |*s| {
                const in_first = s.first.findLeaf(target_id) != null;
                const in_second = s.second.findLeaf(target_id) != null;

                if (!in_first and !in_second) return false;

                if (in_first and resizeRecursive(s.first, target_id, dir, delta)) return true;
                if (in_second and resizeRecursive(s.second, target_id, dir, delta)) return true;

                if (s.direction == .vertical and (dir == .left or dir == .right)) {
                    if (in_first) {
                        if (dir == .right) s.ratio += delta else s.ratio -= delta;
                    } else {
                        if (dir == .right) s.ratio -= delta else s.ratio += delta;
                    }
                    s.ratio = @max(0.1, @min(0.9, s.ratio));
                    return true;
                } else if (s.direction == .horizontal and (dir == .up or dir == .down)) {
                    if (in_first) {
                        if (dir == .down) s.ratio += delta else s.ratio -= delta;
                    } else {
                        if (dir == .down) s.ratio -= delta else s.ratio += delta;
                    }
                    s.ratio = @max(0.1, @min(0.9, s.ratio));
                    return true;
                }

                return false;
            },
        }
    }

    pub fn findAdjacentLeaf(self: *Node, current_id: u32, dir: Direction, allocator: std.mem.Allocator) ?u32 {
        var leaves = std.ArrayList(*Node).empty;
        defer leaves.deinit(allocator);
        self.collectLeaves(&leaves, allocator) catch return null;

        var current_node: ?*Node = null;
        for (leaves.items) |leaf| {
            if (leaf.data.leaf.id == current_id) {
                current_node = leaf;
                break;
            }
        }
        const cur = current_node orelse return null;
        const cur_c = cur.rect.center();

        var best_id: ?u32 = null;
        var min_dist: i64 = std.math.maxInt(i64);

        for (leaves.items) |leaf| {
            if (leaf.data.leaf.id == current_id) continue;
            const other_c = leaf.rect.center();

            var valid = false;
            var dist: i64 = 0;

            const dx: i64 = @as(i64, other_c.cx) - @as(i64, cur_c.cx);
            const dy: i64 = @as(i64, other_c.cy) - @as(i64, cur_c.cy);

            switch (dir) {
                .right => {
                    if (leaf.rect.x >= cur.rect.x + cur.rect.width or dx > 0) {
                        valid = true;
                        dist = dx * dx + dy * dy * 4;
                    }
                },
                .left => {
                    if (leaf.rect.x + leaf.rect.width <= cur.rect.x or dx < 0) {
                        valid = true;
                        dist = dx * dx + dy * dy * 4;
                    }
                },
                .down => {
                    if (leaf.rect.y >= cur.rect.y + cur.rect.height or dy > 0) {
                        valid = true;
                        dist = dx * dx * 4 + dy * dy;
                    }
                },
                .up => {
                    if (leaf.rect.y + leaf.rect.height <= cur.rect.y or dy < 0) {
                        valid = true;
                        dist = dx * dx * 4 + dy * dy;
                    }
                },
            }

            if (valid and dist < min_dist) {
                min_dist = dist;
                best_id = leaf.data.leaf.id;
            }
        }

        return best_id;
    }
};

test "tree single pane layout" {
    const testing = std.testing;
    const root = try Node.createLeaf(testing.allocator, 1);
    defer root.destroy(testing.allocator);

    const full_area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    root.computeLayout(full_area);

    try testing.expectEqual(@as(u16, 0), root.rect.x);
    try testing.expectEqual(@as(u16, 0), root.rect.y);
    try testing.expectEqual(@as(u16, 80), root.rect.width);
    try testing.expectEqual(@as(u16, 24), root.rect.height);
}

test "tree basic split, layout and close" {
    const testing = std.testing;
    var root = try Node.createLeaf(testing.allocator, 1);
    defer root.destroy(testing.allocator);

    try testing.expectEqual(@as(usize, 1), root.countLeaves());

    const new_node = try Node.splitLeaf(testing.allocator, &root, 1, 2, .vertical);
    _ = new_node;
    try testing.expectEqual(@as(usize, 2), root.countLeaves());

    const area = Rect{ .x = 0, .y = 0, .width = 81, .height = 24 };
    root.computeLayout(area);

    const l1 = root.findLeaf(1).?;
    const l2 = root.findLeaf(2).?;
    try testing.expectEqual(@as(u16, 0), l1.rect.x);
    try testing.expectEqual(@as(u16, 40), l1.rect.width);
    try testing.expectEqual(@as(u16, 41), l2.rect.x);
    try testing.expectEqual(@as(u16, 40), l2.rect.width);

    const closed = Node.closeLeaf(testing.allocator, &root, 1);
    try testing.expect(closed);
    try testing.expectEqual(@as(usize, 1), root.countLeaves());
    try testing.expect(root.findLeaf(2) != null);
}

test "tree directional navigation" {
    const testing = std.testing;
    var root = try Node.createLeaf(testing.allocator, 1);
    defer root.destroy(testing.allocator);

    _ = try Node.splitLeaf(testing.allocator, &root, 1, 2, .vertical);
    _ = try Node.splitLeaf(testing.allocator, &root, 2, 3, .horizontal);

    const area = Rect{ .x = 0, .y = 0, .width = 81, .height = 25 };
    root.computeLayout(area);

    try testing.expectEqual(@as(?u32, 2), root.findAdjacentLeaf(1, .right, testing.allocator));
    try testing.expectEqual(@as(?u32, 1), root.findAdjacentLeaf(2, .left, testing.allocator));
    try testing.expectEqual(@as(?u32, 3), root.findAdjacentLeaf(2, .down, testing.allocator));
    try testing.expectEqual(@as(?u32, 2), root.findAdjacentLeaf(3, .up, testing.allocator));
}

test "tree nested 2x2 grid (4 panes) navigation" {
    const testing = std.testing;
    var root = try Node.createLeaf(testing.allocator, 1);
    defer root.destroy(testing.allocator);

    _ = try Node.splitLeaf(testing.allocator, &root, 1, 2, .vertical);
    _ = try Node.splitLeaf(testing.allocator, &root, 1, 3, .horizontal);
    _ = try Node.splitLeaf(testing.allocator, &root, 2, 4, .horizontal);

    const full_area = Rect{ .x = 0, .y = 0, .width = 81, .height = 25 };
    root.computeLayout(full_area);

    try testing.expectEqual(@as(usize, 4), root.countLeaves());

    try testing.expectEqual(@as(?u32, 2), root.findAdjacentLeaf(1, .right, testing.allocator));
    try testing.expectEqual(@as(?u32, 3), root.findAdjacentLeaf(1, .down, testing.allocator));

    try testing.expectEqual(@as(?u32, 3), root.findAdjacentLeaf(4, .left, testing.allocator));
    try testing.expectEqual(@as(?u32, 2), root.findAdjacentLeaf(4, .up, testing.allocator));
}

test "tree pane resizing updates ratios and layout dimensions" {
    const testing = std.testing;
    var root = try Node.createLeaf(testing.allocator, 1);
    defer root.destroy(testing.allocator);

    _ = try Node.splitLeaf(testing.allocator, &root, 1, 2, .vertical);

    const full_area = Rect{ .x = 0, .y = 0, .width = 81, .height = 24 };
    root.computeLayout(full_area);

    const initial_w1 = root.findLeaf(1).?.rect.width;
    try testing.expectEqual(@as(u16, 40), initial_w1);

    const resized = root.resizePane(1, .right, 0.1);
    try testing.expect(resized);

    root.computeLayout(full_area);
    const new_w1 = root.findLeaf(1).?.rect.width;
    try testing.expect(new_w1 > initial_w1);
}
