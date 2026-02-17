const std = @import("std");

pub const TokenKind = enum {
    lparen,
    rparen,
    ident,
    int_lit,
    float_lit,
    string_lit,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    col: u32,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.pos < self.source.len) return self.source[self.pos];
        return null;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == ';') {
                // Skip line comment
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .text = "", .line = self.line, .col = self.col };
        }

        const start_line = self.line;
        const start_col = self.col;
        const c = self.source[self.pos];

        if (c == '(') {
            self.advance();
            return .{ .kind = .lparen, .text = "(", .line = start_line, .col = start_col };
        }
        if (c == ')') {
            self.advance();
            return .{ .kind = .rparen, .text = ")", .line = start_line, .col = start_col };
        }

        // String literal
        if (c == '"') {
            const start = self.pos;
            self.advance(); // skip opening quote
            while (self.pos < self.source.len and self.source[self.pos] != '"') {
                if (self.source[self.pos] == '\\') self.advance(); // skip escape
                self.advance();
            }
            if (self.pos < self.source.len) self.advance(); // skip closing quote
            return .{ .kind = .string_lit, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
        }

        // Number or negative number
        if (c >= '0' and c <= '9' or (c == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] >= '0' and self.source[self.pos + 1] <= '9')) {
            const start = self.pos;
            var is_float = false;
            if (c == '-') self.advance();
            while (self.pos < self.source.len) {
                const d = self.source[self.pos];
                if (d >= '0' and d <= '9') {
                    self.advance();
                } else if (d == '.' and !is_float) {
                    is_float = true;
                    self.advance();
                } else {
                    break;
                }
            }
            const kind: TokenKind = if (is_float) .float_lit else .int_lit;
            return .{ .kind = kind, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
        }

        // Identifier (anything else until whitespace or parens)
        const start = self.pos;
        while (self.pos < self.source.len) {
            const d = self.source[self.pos];
            if (d == ' ' or d == '\t' or d == '\n' or d == '\r' or d == '(' or d == ')' or d == ';') break;
            self.advance();
        }
        return .{ .kind = .ident, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
    }
};

test "lexer basics" {
    var lex = Lexer.init("(fn add ((a i32)) i32 (+ a 1))");
    const expected = [_]TokenKind{ .lparen, .ident, .ident, .lparen, .lparen, .ident, .ident, .rparen, .rparen, .ident, .lparen, .ident, .ident, .int_lit, .rparen, .rparen, .eof };
    for (expected) |exp| {
        const tok = lex.next();
        try std.testing.expectEqual(exp, tok.kind);
    }
}

test "lexer comments" {
    var lex = Lexer.init(";; comment\n(+ 1 2)");
    try std.testing.expectEqual(TokenKind.lparen, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
    try std.testing.expectEqual(TokenKind.int_lit, lex.next().kind);
    try std.testing.expectEqual(TokenKind.int_lit, lex.next().kind);
    try std.testing.expectEqual(TokenKind.rparen, lex.next().kind);
}

test "lexer floats" {
    var lex = Lexer.init("3.14 -2.5");
    const t1 = lex.next();
    try std.testing.expectEqual(TokenKind.float_lit, t1.kind);
    try std.testing.expectEqualStrings("3.14", t1.text);
    const t2 = lex.next();
    try std.testing.expectEqual(TokenKind.float_lit, t2.kind);
    try std.testing.expectEqualStrings("-2.5", t2.text);
}
