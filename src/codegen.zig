const std = @import("std");
const ast = @import("ast.zig");
const wasm = @import("wasm.zig");
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const ValType = ast.ValType;
const BinOpKind = ast.BinOpKind;
const Ast = ast.Ast;
const Param = ast.Param;
const Op = wasm.Op;
const WasmWriter = wasm.WasmWriter;

pub const CodegenError = error{
    UndefinedVariable,
    UndefinedFunction,
    TypeMismatch,
    OutOfMemory,
    Overflow,
};

const LocalInfo = struct {
    index: u32,
    typ: ValType,
};

const FuncInfo = struct {
    index: u32, // function index (imports first, then definitions)
    type_index: u32,
    params: []const Param,
    ret: ?ValType,
};

const TypeSig = struct {
    params: []const ValType,
    ret: ?ValType,
};

pub const Codegen = struct {
    tree: *const Ast,
    allocator: std.mem.Allocator,

    // Module-level
    functions: std.StringHashMap(FuncInfo),
    func_order: std.ArrayList([]const u8), // definition order for defined functions
    exports: std.ArrayList([]const u8),
    type_sigs: std.ArrayList(TypeSig),
    type_map: std.HashMap(u64, u32, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    has_memory: bool,

    // Imports
    imports: std.ArrayList(ImportInfo),
    import_count: u32,

    // Per-function state
    locals: std.StringHashMap(LocalInfo),
    local_types: std.ArrayList(ValType), // non-param locals
    param_count: u32,
    local_count: u32,
    code: WasmWriter,
    block_depth: u32,

    const ImportInfo = struct {
        module: []const u8,
        name: []const u8,
        type_index: u32,
    };

    pub fn init(allocator: std.mem.Allocator, tree: *const Ast) Codegen {
        return .{
            .tree = tree,
            .allocator = allocator,
            .functions = std.StringHashMap(FuncInfo).init(allocator),
            .func_order = std.ArrayList([]const u8).init(allocator),
            .exports = std.ArrayList([]const u8).init(allocator),
            .type_sigs = std.ArrayList(TypeSig).init(allocator),
            .type_map = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .has_memory = false,
            .imports = std.ArrayList(ImportInfo).init(allocator),
            .import_count = 0,
            .locals = std.StringHashMap(LocalInfo).init(allocator),
            .local_types = std.ArrayList(ValType).init(allocator),
            .param_count = 0,
            .local_count = 0,
            .code = WasmWriter.init(allocator),
            .block_depth = 0,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.functions.deinit();
        self.func_order.deinit();
        self.exports.deinit();
        self.type_sigs.deinit();
        self.type_map.deinit();
        self.imports.deinit();
        self.locals.deinit();
        self.local_types.deinit();
        self.code.deinit();
    }

    fn getOrAddType(self: *Codegen, params: []const Param, ret: ?ValType) !u32 {
        // Create a simple hash of the signature
        var hash: u64 = 0;
        for (params) |p| {
            hash = hash *% 31 +% @as(u64, @intFromEnum(p.typ));
        }
        hash = hash *% 31 +% if (ret) |r| @as(u64, @intFromEnum(r)) + 256 else 0;

        if (self.type_map.get(hash)) |idx| {
            return idx;
        }

        const idx: u32 = @intCast(self.type_sigs.items.len);
        var param_types = std.ArrayList(ValType).init(self.allocator);
        for (params) |p| {
            try param_types.append(p.typ);
        }
        try self.type_sigs.append(.{ .params = param_types.items, .ret = ret });
        try self.type_map.put(hash, idx);
        return idx;
    }

    // Pass 1: collect all function signatures and exports
    fn collectDeclarations(self: *Codegen) !void {
        var func_idx: u32 = 0;

        // First pass: collect imports (they get indices first)
        for (self.tree.top_level.items) |top_idx| {
            const node = self.tree.getNode(top_idx);
            switch (node) {
                .import_fn => |imp| {
                    const type_index = try self.getOrAddType(imp.params, imp.ret);
                    try self.imports.append(.{
                        .module = imp.module,
                        .name = imp.name,
                        .type_index = type_index,
                    });
                    try self.functions.put(imp.name, .{
                        .index = func_idx,
                        .type_index = type_index,
                        .params = imp.params,
                        .ret = imp.ret,
                    });
                    func_idx += 1;
                },
                else => {},
            }
        }
        self.import_count = func_idx;

        // Second pass: collect function definitions
        for (self.tree.top_level.items) |top_idx| {
            const node = self.tree.getNode(top_idx);
            switch (node) {
                .fn_def => |fd| {
                    const type_index = try self.getOrAddType(fd.params, fd.ret);
                    try self.functions.put(fd.name, .{
                        .index = func_idx,
                        .type_index = type_index,
                        .params = fd.params,
                        .ret = fd.ret,
                    });
                    try self.func_order.append(fd.name);
                    func_idx += 1;
                },
                .export_dir => |name| {
                    try self.exports.append(name);
                },
                .import_fn => {}, // already handled
                else => {},
            }
        }

        // Check if any load/store ops exist (need memory section)
        self.has_memory = self.checkForMemoryOps();
    }

    fn checkForMemoryOps(self: *Codegen) bool {
        for (self.tree.nodes.items) |node| {
            switch (node) {
                .load, .store => return true,
                else => {},
            }
        }
        return false;
    }

    fn resetFuncState(self: *Codegen) void {
        self.locals.clearRetainingCapacity();
        self.local_types.clearRetainingCapacity();
        self.param_count = 0;
        self.local_count = 0;
        self.code.buf.clearRetainingCapacity();
        self.block_depth = 0;
    }

    fn addParam(self: *Codegen, name: []const u8, typ: ValType) !void {
        try self.locals.put(name, .{ .index = self.param_count, .typ = typ });
        self.param_count += 1;
        self.local_count += 1;
    }

    fn addLocal(self: *Codegen, name: []const u8, typ: ValType) !void {
        try self.locals.put(name, .{ .index = self.local_count, .typ = typ });
        try self.local_types.append(typ);
        self.local_count += 1;
    }

    const CollectError = error{OutOfMemory};

    // Collect locals from function body (pre-pass)
    fn collectLocals(self: *Codegen, nodes: []const NodeIndex) CollectError!void {
        for (nodes) |idx| {
            const node = self.tree.getNode(idx);
            switch (node) {
                .local_var => |lv| {
                    try self.addLocal(lv.name, lv.typ);
                    // Recurse into init
                    try self.collectLocalsFromExpr(lv.init);
                },
                .if_expr => |ie| {
                    try self.collectLocalsFromExpr(ie.then_body);
                    if (ie.else_body) |eb| try self.collectLocalsFromExpr(eb);
                },
                .while_loop => |wl| {
                    try self.collectLocals(wl.body);
                },
                .block => |items| {
                    try self.collectLocals(items);
                },
                else => {},
            }
        }
    }

    fn collectLocalsFromExpr(self: *Codegen, idx: NodeIndex) CollectError!void {
        const node = self.tree.getNode(idx);
        switch (node) {
            .block => |items| try self.collectLocals(items),
            .if_expr => |ie| {
                try self.collectLocalsFromExpr(ie.then_body);
                if (ie.else_body) |eb| try self.collectLocalsFromExpr(eb);
            },
            else => {},
        }
    }

    fn resolveLocal(self: *Codegen, name: []const u8) CodegenError!LocalInfo {
        return self.locals.get(name) orelse error.UndefinedVariable;
    }

    fn resolveFunc(self: *Codegen, name: []const u8) CodegenError!FuncInfo {
        return self.functions.get(name) orelse error.UndefinedFunction;
    }

    const EmitError = CodegenError || std.ArrayList(u8).Writer.Error;

    // Get the type of an expression
    fn typeOfExpr(self: *Codegen, idx: NodeIndex) CodegenError!?ValType {
        const node = self.tree.getNode(idx);
        return switch (node) {
            .int_literal => ValType.i32,
            .float_literal => ValType.f64,
            .identifier => |name| {
                const info = try self.resolveLocal(name);
                return info.typ;
            },
            .binop => |bo| {
                // Comparisons always return i32
                return switch (bo.op) {
                    .eq, .ne, .lt_s, .gt_s, .le_s, .ge_s => ValType.i32,
                    else => try self.typeOfExpr(bo.lhs),
                };
            },
            .call => |c| {
                const fi = try self.resolveFunc(c.callee);
                return fi.ret;
            },
            .if_expr => |ie| {
                if (ie.else_body != null) {
                    return try self.typeOfExpr(ie.then_body);
                }
                return null; // statement form
            },
            .block => |items| {
                if (items.len == 0) return null;
                return try self.typeOfExpr(items[items.len - 1]);
            },
            .load => |ld| ld.typ,
            .local_var, .local_set, .while_loop, .store => null,
            .fn_def, .export_dir, .import_fn => null,
        };
    }

    // Emit code for an expression
    fn emitExpr(self: *Codegen, idx: NodeIndex) EmitError!void {
        const node = self.tree.getNode(idx);
        const w = self.code.writer();
        switch (node) {
            .int_literal => |val| {
                try w.writeByte(Op.i32_const);
                try wasm.encodeSLEB128(w, val);
            },
            .float_literal => |val| {
                try w.writeByte(Op.f64_const);
                try wasm.encodeF64(w, val);
            },
            .identifier => |name| {
                const info = try self.resolveLocal(name);
                try w.writeByte(Op.local_get);
                try wasm.encodeLEB128(w, info.index);
            },
            .binop => |bo| {
                try self.emitExpr(bo.lhs);
                try self.emitExpr(bo.rhs);
                const lhs_type = (try self.typeOfExpr(bo.lhs)) orelse return error.TypeMismatch;
                try w.writeByte(self.getBinOpcode(bo.op, lhs_type));
            },
            .call => |c| {
                for (c.args) |arg| {
                    try self.emitExpr(arg);
                }
                const fi = try self.resolveFunc(c.callee);
                try w.writeByte(Op.call);
                try wasm.encodeLEB128(w, fi.index);
            },
            .if_expr => |ie| {
                try self.emitExpr(ie.cond);
                if (ie.else_body) |eb| {
                    // Expression form: if with result type
                    const result_type = (try self.typeOfExpr(ie.then_body)) orelse ValType.i32;
                    try w.writeByte(Op.@"if");
                    try w.writeByte(@intFromEnum(result_type));
                    self.block_depth += 1;
                    try self.emitExpr(ie.then_body);
                    try w.writeByte(Op.@"else");
                    try self.emitExpr(eb);
                    try w.writeByte(Op.end);
                    self.block_depth -= 1;
                } else {
                    // Statement form: void
                    try w.writeByte(Op.@"if");
                    try w.writeByte(wasm.BLOCK_VOID);
                    self.block_depth += 1;
                    try self.emitExpr(ie.then_body);
                    try w.writeByte(Op.end);
                    self.block_depth -= 1;
                }
            },
            .block => |items| {
                try self.emitBlock(items);
            },
            .local_var => |lv| {
                const info = try self.resolveLocal(lv.name);
                try self.emitExpr(lv.init);
                try w.writeByte(Op.local_set);
                try wasm.encodeLEB128(w, info.index);
            },
            .local_set => |ls| {
                const info = try self.resolveLocal(ls.name);
                try self.emitExpr(ls.expr);
                try w.writeByte(Op.local_set);
                try wasm.encodeLEB128(w, info.index);
            },
            .while_loop => |wl| {
                // block $break
                //   loop $continue
                //     <cond> i32.eqz br_if $break
                //     <body>
                //     br $continue
                //   end
                // end
                try w.writeByte(Op.block);
                try w.writeByte(wasm.BLOCK_VOID);
                self.block_depth += 1;
                try w.writeByte(Op.loop);
                try w.writeByte(wasm.BLOCK_VOID);
                self.block_depth += 1;

                try self.emitExpr(wl.cond);
                try w.writeByte(Op.i32_eqz);
                try w.writeByte(Op.br_if);
                try wasm.encodeLEB128(w, 1); // break out of block

                for (wl.body) |body_idx| {
                    try self.emitExpr(body_idx);
                    const body_type = try self.typeOfExpr(body_idx);
                    if (body_type != null) {
                        try w.writeByte(Op.drop);
                    }
                }

                try w.writeByte(Op.br);
                try wasm.encodeLEB128(w, 0); // continue loop

                try w.writeByte(Op.end); // end loop
                self.block_depth -= 1;
                try w.writeByte(Op.end); // end block
                self.block_depth -= 1;
            },
            .load => |ld| {
                try self.emitExpr(ld.addr);
                try w.writeByte(switch (ld.typ) {
                    .i32 => Op.i32_load,
                    .i64 => Op.i64_load,
                    .f32 => Op.f32_load,
                    .f64 => Op.f64_load,
                });
                try wasm.encodeLEB128(w, ld.typ.alignLog2()); // alignment
                try wasm.encodeLEB128(w, 0); // offset
            },
            .store => |st| {
                try self.emitExpr(st.addr);
                try self.emitExpr(st.value);
                try w.writeByte(switch (st.typ) {
                    .i32 => Op.i32_store,
                    .i64 => Op.i64_store,
                    .f32 => Op.f32_store,
                    .f64 => Op.f64_store,
                });
                try wasm.encodeLEB128(w, st.typ.alignLog2());
                try wasm.encodeLEB128(w, 0);
            },
            .fn_def, .export_dir, .import_fn => {},
        }
    }

    fn emitBlock(self: *Codegen, items: []const NodeIndex) EmitError!void {
        const w = self.code.writer();
        for (items, 0..) |item_idx, i| {
            try self.emitExpr(item_idx);
            if (i < items.len - 1) {
                // Drop non-last values
                const item_type = try self.typeOfExpr(item_idx);
                if (item_type != null) {
                    try w.writeByte(Op.drop);
                }
            }
        }
    }

    fn getBinOpcode(self: *Codegen, op: BinOpKind, typ: ValType) u8 {
        _ = self;
        return switch (typ) {
            .i32 => switch (op) {
                .add => Op.i32_add,
                .sub => Op.i32_sub,
                .mul => Op.i32_mul,
                .div_s => Op.i32_div_s,
                .rem_s => Op.i32_rem_s,
                .eq => Op.i32_eq,
                .ne => Op.i32_ne,
                .lt_s => Op.i32_lt_s,
                .gt_s => Op.i32_gt_s,
                .le_s => Op.i32_le_s,
                .ge_s => Op.i32_ge_s,
                .@"and" => Op.i32_and,
                .@"or" => Op.i32_or,
                .xor => Op.i32_xor,
                .shl => Op.i32_shl,
                .shr_s => Op.i32_shr_s,
            },
            .i64 => switch (op) {
                .add => Op.i64_add,
                .sub => Op.i64_sub,
                .mul => Op.i64_mul,
                .div_s => Op.i64_div_s,
                .rem_s => Op.i64_rem_s,
                .eq => Op.i64_eq,
                .ne => Op.i64_ne,
                .lt_s => Op.i64_lt_s,
                .gt_s => Op.i64_gt_s,
                .le_s => Op.i64_le_s,
                .ge_s => Op.i64_ge_s,
                .@"and" => Op.i64_and,
                .@"or" => Op.i64_or,
                .xor => Op.i64_xor,
                .shl => Op.i64_shl,
                .shr_s => Op.i64_shr_s,
            },
            .f32 => switch (op) {
                .add => Op.f32_add,
                .sub => Op.f32_sub,
                .mul => Op.f32_mul,
                .div_s => Op.f32_div,
                .eq => Op.f32_eq,
                .ne => Op.f32_ne,
                .lt_s => Op.f32_lt,
                .gt_s => Op.f32_gt,
                .le_s => Op.f32_le,
                .ge_s => Op.f32_ge,
                else => Op.nop, // unsupported
            },
            .f64 => switch (op) {
                .add => Op.f64_add,
                .sub => Op.f64_sub,
                .mul => Op.f64_mul,
                .div_s => Op.f64_div,
                .eq => Op.f64_eq,
                .ne => Op.f64_ne,
                .lt_s => Op.f64_lt,
                .gt_s => Op.f64_gt,
                .le_s => Op.f64_le,
                .ge_s => Op.f64_ge,
                else => Op.nop,
            },
        };
    }

    fn emitFunction(self: *Codegen, fd: anytype) ![]u8 {
        self.resetFuncState();

        // Add params
        for (fd.params) |p| {
            try self.addParam(p.name, p.typ);
        }

        // Collect locals (pre-pass)
        try self.collectLocals(fd.body);

        // Emit body
        if (fd.body.len > 0) {
            try self.emitBlock(fd.body);
        }

        // End function
        try self.code.writeByte(Op.end);

        // Build function body with local declarations prefix
        var body_buf = WasmWriter.init(self.allocator);
        const body_w = body_buf.writer();

        // Count distinct local type groups
        if (self.local_types.items.len == 0) {
            try wasm.encodeLEB128(body_w, 0);
        } else {
            // Group consecutive locals of same type
            var groups = std.ArrayList(struct { count: u32, typ: ValType }).init(self.allocator);
            var current_type = self.local_types.items[0];
            var count: u32 = 1;
            for (self.local_types.items[1..]) |t| {
                if (t == current_type) {
                    count += 1;
                } else {
                    try groups.append(.{ .count = count, .typ = current_type });
                    current_type = t;
                    count = 1;
                }
            }
            try groups.append(.{ .count = count, .typ = current_type });

            try wasm.encodeLEB128(body_w, @intCast(groups.items.len));
            for (groups.items) |g| {
                try wasm.encodeLEB128(body_w, g.count);
                try body_w.writeByte(@intFromEnum(g.typ));
            }
        }

        try body_buf.writeAll(self.code.buf.items);

        // Wrap with size prefix
        var result = WasmWriter.init(self.allocator);
        try wasm.encodeLEB128(result.writer(), @intCast(body_buf.buf.items.len));
        try result.writeAll(body_buf.buf.items);
        body_buf.deinit();

        return result.toOwnedSlice();
    }

    pub fn generate(self: *Codegen) ![]u8 {
        try self.collectDeclarations();

        var output = WasmWriter.init(self.allocator);

        // Magic + version
        try output.writeAll(&.{ 0x00, 0x61, 0x73, 0x6D }); // \0asm
        try output.writeAll(&.{ 0x01, 0x00, 0x00, 0x00 }); // version 1

        // Type section (id=1)
        {
            var sec = WasmWriter.init(self.allocator);
            try wasm.encodeLEB128(sec.writer(), @intCast(self.type_sigs.items.len));
            for (self.type_sigs.items) |sig| {
                try sec.writeByte(0x60); // func type
                try wasm.encodeLEB128(sec.writer(), @intCast(sig.params.len));
                for (sig.params) |p| {
                    try sec.writeByte(@intFromEnum(p));
                }
                if (sig.ret) |r| {
                    try wasm.encodeLEB128(sec.writer(), 1);
                    try sec.writeByte(@intFromEnum(r));
                } else {
                    try wasm.encodeLEB128(sec.writer(), 0);
                }
            }
            try output.writeSection(1, sec.buf.items);
            sec.deinit();
        }

        // Import section (id=2) — if there are imports
        if (self.imports.items.len > 0) {
            var sec = WasmWriter.init(self.allocator);
            try wasm.encodeLEB128(sec.writer(), @intCast(self.imports.items.len));
            for (self.imports.items) |imp| {
                // module name
                try wasm.encodeLEB128(sec.writer(), @intCast(imp.module.len));
                try sec.writeAll(imp.module);
                // field name
                try wasm.encodeLEB128(sec.writer(), @intCast(imp.name.len));
                try sec.writeAll(imp.name);
                // kind: function
                try sec.writeByte(0x00);
                try wasm.encodeLEB128(sec.writer(), imp.type_index);
            }
            try output.writeSection(2, sec.buf.items);
            sec.deinit();
        }

        // Function section (id=3)
        {
            var sec = WasmWriter.init(self.allocator);
            try wasm.encodeLEB128(sec.writer(), @intCast(self.func_order.items.len));
            for (self.func_order.items) |name| {
                const fi = self.functions.get(name).?;
                try wasm.encodeLEB128(sec.writer(), fi.type_index);
            }
            try output.writeSection(3, sec.buf.items);
            sec.deinit();
        }

        // Memory section (id=5)
        if (self.has_memory) {
            var sec = WasmWriter.init(self.allocator);
            try wasm.encodeLEB128(sec.writer(), 1); // 1 memory
            try sec.writeByte(0x00); // no max
            try wasm.encodeLEB128(sec.writer(), 1); // 1 initial page
            try output.writeSection(5, sec.buf.items);
            sec.deinit();
        }

        // Export section (id=7)
        if (self.exports.items.len > 0 or self.has_memory) {
            var sec = WasmWriter.init(self.allocator);
            var total_exports: u32 = @intCast(self.exports.items.len);
            if (self.has_memory) total_exports += 1;
            try wasm.encodeLEB128(sec.writer(), total_exports);

            for (self.exports.items) |name| {
                const fi = self.functions.get(name) orelse return error.UndefinedFunction;
                try wasm.encodeLEB128(sec.writer(), @intCast(name.len));
                try sec.writeAll(name);
                try sec.writeByte(0x00); // func export
                try wasm.encodeLEB128(sec.writer(), fi.index);
            }

            if (self.has_memory) {
                const mem_name = "memory";
                try wasm.encodeLEB128(sec.writer(), mem_name.len);
                try sec.writeAll(mem_name);
                try sec.writeByte(0x02); // memory export
                try wasm.encodeLEB128(sec.writer(), 0);
            }

            try output.writeSection(7, sec.buf.items);
            sec.deinit();
        }

        // Code section (id=10)
        {
            var sec = WasmWriter.init(self.allocator);
            try wasm.encodeLEB128(sec.writer(), @intCast(self.func_order.items.len));

            for (self.tree.top_level.items) |top_idx| {
                const node = self.tree.getNode(top_idx);
                switch (node) {
                    .fn_def => |fd| {
                        const func_body = try self.emitFunction(fd);
                        try sec.writeAll(func_body);
                    },
                    else => {},
                }
            }

            try output.writeSection(10, sec.buf.items);
            sec.deinit();
        }

        return output.toOwnedSlice();
    }
};
