const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const ValType = ast.ValType;
const MemWidth = ast.MemWidth;
const Param = ast.Param;
const Ast = ast.Ast;
const BinOpKind = ast.BinOpKind;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidType,
    InvalidOperator,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: Lexer,
    tree: Ast,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        return .{
            .lexer = lexer,
            .tree = Ast.init(allocator),
            .current = first,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.tree.deinit();
    }

    fn bump(self: *Parser) Token {
        const tok = self.current;
        self.current = self.lexer.next();
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.current.kind != kind) {
            return error.UnexpectedToken;
        }
        return self.bump();
    }

    fn parseValType(name: []const u8) ParseError!ValType {
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i64")) return .i64;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        return error.InvalidType;
    }

    fn parseBinOp(name: []const u8) ?BinOpKind {
        if (std.mem.eql(u8, name, "+")) return .add;
        if (std.mem.eql(u8, name, "-")) return .sub;
        if (std.mem.eql(u8, name, "*")) return .mul;
        if (std.mem.eql(u8, name, "/")) return .div_s;
        if (std.mem.eql(u8, name, "%")) return .rem_s;
        if (std.mem.eql(u8, name, "==")) return .eq;
        if (std.mem.eql(u8, name, "!=")) return .ne;
        if (std.mem.eql(u8, name, "<")) return .lt_s;
        if (std.mem.eql(u8, name, ">")) return .gt_s;
        if (std.mem.eql(u8, name, "<=")) return .le_s;
        if (std.mem.eql(u8, name, ">=")) return .ge_s;
        if (std.mem.eql(u8, name, "and")) return .@"and";
        if (std.mem.eql(u8, name, "or")) return .@"or";
        if (std.mem.eql(u8, name, "xor")) return .xor;
        if (std.mem.eql(u8, name, "shl")) return .shl;
        if (std.mem.eql(u8, name, "shr")) return .shr_s;
        return null;
    }

    pub fn parseProgram(self: *Parser) ParseError!Ast {
        while (self.current.kind != .eof) {
            const node = try self.parseExpr();
            try self.tree.top_level.append(node);
        }
        return self.tree;
    }

    fn parseExpr(self: *Parser) ParseError!NodeIndex {
        switch (self.current.kind) {
            .int_lit => {
                const tok = self.bump();
                const val = std.fmt.parseInt(i64, tok.text, 0) catch return error.UnexpectedToken;
                return self.tree.addNode(.{ .int_literal = val });
            },
            .float_lit => {
                const tok = self.bump();
                const val = std.fmt.parseFloat(f64, tok.text) catch return error.UnexpectedToken;
                return self.tree.addNode(.{ .float_literal = val });
            },
            .ident => {
                const tok = self.bump();
                return self.tree.addNode(.{ .identifier = tok.text });
            },
            .lparen => return self.parseList(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseList(self: *Parser) ParseError!NodeIndex {
        _ = try self.expect(.lparen);

        if (self.current.kind == .rparen) {
            _ = self.bump();
            // Empty list → empty block
            const items: []const NodeIndex = &.{};
            return self.tree.addNode(.{ .block = items });
        }

        if (self.current.kind != .ident) {
            return error.UnexpectedToken;
        }

        const head = self.current.text;

        // Check special forms
        if (std.mem.eql(u8, head, "fn")) return self.parseFnDef();
        if (std.mem.eql(u8, head, "export")) return self.parseExport();
        if (std.mem.eql(u8, head, "import")) return self.parseImport();
        if (std.mem.eql(u8, head, "var")) return self.parseVar();
        if (std.mem.eql(u8, head, "set")) return self.parseSet();
        if (std.mem.eql(u8, head, "if")) return self.parseIf();
        if (std.mem.eql(u8, head, "while")) return self.parseWhile();
        if (std.mem.eql(u8, head, "block")) return self.parseBlock();
        if (std.mem.eql(u8, head, "memory")) return self.parseMemoryDecl();
        if (std.mem.eql(u8, head, "load")) return self.parseLoadFull();
        if (std.mem.eql(u8, head, "store")) return self.parseStoreFull();
        if (parseNarrowLoad(head)) |width| return self.parseLoadNarrow(width);
        if (parseNarrowStore(head)) |width| return self.parseStoreNarrow(width);

        // Check binary operators
        if (parseBinOp(head)) |op| {
            _ = self.bump(); // consume operator
            const lhs = try self.parseExpr();
            const rhs = try self.parseExpr();
            _ = try self.expect(.rparen);
            return self.tree.addNode(.{ .binop = .{ .op = op, .lhs = lhs, .rhs = rhs } });
        }

        // Function call
        return self.parseCall();
    }

    fn parseFnDef(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "fn"
        const name = (try self.expect(.ident)).text;

        // Parse params: ((a i32) (b i32))
        _ = try self.expect(.lparen);
        var params = std.ArrayList(Param).init(self.allocator);
        while (self.current.kind != .rparen) {
            _ = try self.expect(.lparen);
            const pname = (try self.expect(.ident)).text;
            const ptype_name = (try self.expect(.ident)).text;
            const ptype = try parseValType(ptype_name);
            _ = try self.expect(.rparen);
            try params.append(.{ .name = pname, .typ = ptype });
        }
        _ = try self.expect(.rparen); // close params

        // Parse return type (ident or "void")
        var ret: ?ValType = null;
        if (self.current.kind == .ident) {
            const ret_text = self.current.text;
            if (!std.mem.eql(u8, ret_text, "void")) {
                ret = try parseValType(ret_text);
            }
            _ = self.bump();
        }

        // Parse body expressions
        var body = std.ArrayList(NodeIndex).init(self.allocator);
        while (self.current.kind != .rparen) {
            try body.append(try self.parseExpr());
        }
        _ = try self.expect(.rparen); // close fn

        return self.tree.addNode(.{ .fn_def = .{
            .name = name,
            .params = params.items,
            .ret = ret,
            .body = body.items,
        } });
    }

    fn parseExport(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "export"
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .export_dir = name });
    }

    fn parseImport(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "import"
        const module_tok = (try self.expect(.string_lit));
        const name_tok = (try self.expect(.string_lit));

        // Strip quotes
        const module = module_tok.text[1 .. module_tok.text.len - 1];
        const name = name_tok.text[1 .. name_tok.text.len - 1];

        // Parse params and return type like fn
        _ = try self.expect(.lparen);
        var params = std.ArrayList(Param).init(self.allocator);
        while (self.current.kind != .rparen) {
            _ = try self.expect(.lparen);
            const pname = (try self.expect(.ident)).text;
            const ptype_name = (try self.expect(.ident)).text;
            const ptype = try parseValType(ptype_name);
            _ = try self.expect(.rparen);
            try params.append(.{ .name = pname, .typ = ptype });
        }
        _ = try self.expect(.rparen);

        var ret: ?ValType = null;
        if (self.current.kind == .ident) {
            const ret_text = self.current.text;
            if (!std.mem.eql(u8, ret_text, "void")) {
                ret = try parseValType(ret_text);
            }
            _ = self.bump();
        }
        _ = try self.expect(.rparen);

        return self.tree.addNode(.{ .import_fn = .{
            .module = module,
            .name = name,
            .params = params.items,
            .ret = ret,
        } });
    }

    fn parseVar(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "var"
        const name = (try self.expect(.ident)).text;
        const type_name = (try self.expect(.ident)).text;
        const typ = try parseValType(type_name);
        const init_expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .local_var = .{ .name = name, .typ = typ, .init = init_expr } });
    }

    fn parseSet(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "set"
        const name = (try self.expect(.ident)).text;
        const expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .local_set = .{ .name = name, .expr = expr } });
    }

    fn parseIf(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "if"
        const cond = try self.parseExpr();
        const then_body = try self.parseExpr();
        var else_body: ?NodeIndex = null;
        if (self.current.kind != .rparen) {
            else_body = try self.parseExpr();
        }
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .if_expr = .{ .cond = cond, .then_body = then_body, .else_body = else_body } });
    }

    fn parseWhile(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "while"
        const cond = try self.parseExpr();
        var body = std.ArrayList(NodeIndex).init(self.allocator);
        while (self.current.kind != .rparen) {
            try body.append(try self.parseExpr());
        }
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .while_loop = .{ .cond = cond, .body = body.items } });
    }

    fn parseBlock(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "block"
        var items = std.ArrayList(NodeIndex).init(self.allocator);
        while (self.current.kind != .rparen) {
            try items.append(try self.parseExpr());
        }
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .block = items.items });
    }

    fn parseMemoryDecl(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "memory"
        const pages_tok = try self.expect(.int_lit);
        const pages = std.fmt.parseInt(u32, pages_tok.text, 0) catch return error.UnexpectedToken;
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .memory_decl = pages });
    }

    fn parseNarrowLoad(name: []const u8) ?MemWidth {
        if (std.mem.eql(u8, name, "load8_u")) return .@"8_u";
        if (std.mem.eql(u8, name, "load8_s")) return .@"8_s";
        if (std.mem.eql(u8, name, "load16_u")) return .@"16_u";
        if (std.mem.eql(u8, name, "load16_s")) return .@"16_s";
        return null;
    }

    fn parseNarrowStore(name: []const u8) ?MemWidth {
        if (std.mem.eql(u8, name, "store8")) return .@"8_u"; // width only, no sign
        if (std.mem.eql(u8, name, "store16")) return .@"16_u";
        return null;
    }

    fn parseLoadFull(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "load"
        const type_name = (try self.expect(.ident)).text;
        const typ = try parseValType(type_name);
        const addr = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .load = .{ .typ = typ, .width = .full, .addr = addr } });
    }

    fn parseLoadNarrow(self: *Parser, width: MemWidth) ParseError!NodeIndex {
        _ = self.bump(); // consume "load8_u" etc.
        const addr = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .load = .{ .typ = .i32, .width = width, .addr = addr } });
    }

    fn parseStoreFull(self: *Parser) ParseError!NodeIndex {
        _ = self.bump(); // consume "store"
        const type_name = (try self.expect(.ident)).text;
        const typ = try parseValType(type_name);
        const addr = try self.parseExpr();
        const value = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .store = .{ .typ = typ, .width = .full, .addr = addr, .value = value } });
    }

    fn parseStoreNarrow(self: *Parser, width: MemWidth) ParseError!NodeIndex {
        _ = self.bump(); // consume "store8" etc.
        const addr = try self.parseExpr();
        const value = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .store = .{ .typ = .i32, .width = width, .addr = addr, .value = value } });
    }

    fn parseCall(self: *Parser) ParseError!NodeIndex {
        const callee = self.bump().text;
        var args = std.ArrayList(NodeIndex).init(self.allocator);
        while (self.current.kind != .rparen) {
            try args.append(try self.parseExpr());
        }
        _ = try self.expect(.rparen);
        return self.tree.addNode(.{ .call = .{ .callee = callee, .args = args.items } });
    }
};

test "parse simple function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "(fn add ((a i32) (b i32)) i32 (+ a b))");
    var tree = try parser.parseProgram();
    _ = &tree;
    try std.testing.expectEqual(@as(usize, 1), tree.top_level.items.len);
    const top = tree.getNode(tree.top_level.items[0]);
    switch (top) {
        .fn_def => |fd| {
            try std.testing.expectEqualStrings("add", fd.name);
            try std.testing.expectEqual(@as(usize, 2), fd.params.len);
            try std.testing.expectEqual(ValType.i32, fd.ret.?);
        },
        else => return error.UnexpectedToken,
    }
}
