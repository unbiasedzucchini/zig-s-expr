const std = @import("std");

pub const NodeIndex = u32;

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,

    pub fn byteSize(self: ValType) u32 {
        return switch (self) {
            .i32, .f32 => 4,
            .i64, .f64 => 8,
        };
    }

    pub fn alignLog2(self: ValType) u32 {
        return switch (self) {
            .i32, .f32 => 2,
            .i64, .f64 => 3,
        };
    }

    pub fn isFloat(self: ValType) bool {
        return self == .f32 or self == .f64;
    }

    pub fn isInt(self: ValType) bool {
        return self == .i32 or self == .i64;
    }
};

pub const BinOpKind = enum {
    add,
    sub,
    mul,
    div_s,
    rem_s,
    eq,
    ne,
    lt_s,
    gt_s,
    le_s,
    ge_s,
    @"and",
    @"or",
    xor,
    shl,
    shr_s,
};

pub const Param = struct {
    name: []const u8,
    typ: ValType,
};

pub const Node = union(enum) {
    // Literals
    int_literal: i64,
    float_literal: f64,

    // References
    identifier: []const u8,

    // Expressions
    binop: struct {
        op: BinOpKind,
        lhs: NodeIndex,
        rhs: NodeIndex,
    },
    call: struct {
        callee: []const u8,
        args: []const NodeIndex,
    },
    if_expr: struct {
        cond: NodeIndex,
        then_body: NodeIndex,
        else_body: ?NodeIndex,
    },
    block: []const NodeIndex,

    // Statements
    local_var: struct {
        name: []const u8,
        typ: ValType,
        init: NodeIndex,
    },
    local_set: struct {
        name: []const u8,
        expr: NodeIndex,
    },
    while_loop: struct {
        cond: NodeIndex,
        body: []const NodeIndex,
    },
    load: struct {
        typ: ValType,
        addr: NodeIndex,
    },
    store: struct {
        typ: ValType,
        addr: NodeIndex,
        value: NodeIndex,
    },

    // Top-level
    fn_def: struct {
        name: []const u8,
        params: []const Param,
        ret: ?ValType,
        body: []const NodeIndex,
    },
    export_dir: []const u8,
    import_fn: struct {
        module: []const u8,
        name: []const u8,
        params: []const Param,
        ret: ?ValType,
    },
};

pub const Ast = struct {
    nodes: std.ArrayList(Node),
    top_level: std.ArrayList(NodeIndex),

    pub fn init(allocator: std.mem.Allocator) Ast {
        return .{
            .nodes = std.ArrayList(Node).init(allocator),
            .top_level = std.ArrayList(NodeIndex).init(allocator),
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit();
        self.top_level.deinit();
    }

    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(node);
        return idx;
    }

    pub fn getNode(self: *const Ast, idx: NodeIndex) Node {
        return self.nodes.items[idx];
    }
};
