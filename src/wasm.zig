const std = @import("std");

// WASM binary encoding helpers

pub const Op = struct {
    // Control
    pub const @"unreachable": u8 = 0x00;
    pub const nop: u8 = 0x01;
    pub const block: u8 = 0x02;
    pub const loop: u8 = 0x03;
    pub const @"if": u8 = 0x04;
    pub const @"else": u8 = 0x05;
    pub const end: u8 = 0x0B;
    pub const br: u8 = 0x0C;
    pub const br_if: u8 = 0x0D;
    pub const @"return": u8 = 0x0F;
    pub const call: u8 = 0x10;

    // Variables
    pub const local_get: u8 = 0x20;
    pub const local_set: u8 = 0x21;
    pub const local_tee: u8 = 0x22;
    pub const global_get: u8 = 0x23;
    pub const global_set: u8 = 0x24;

    // Memory
    pub const i32_load: u8 = 0x28;
    pub const i64_load: u8 = 0x29;
    pub const f32_load: u8 = 0x2A;
    pub const f64_load: u8 = 0x2B;
    pub const i32_store: u8 = 0x36;
    pub const i64_store: u8 = 0x37;
    pub const f32_store: u8 = 0x38;
    pub const f64_store: u8 = 0x39;

    // Constants
    pub const i32_const: u8 = 0x41;
    pub const i64_const: u8 = 0x42;
    pub const f32_const: u8 = 0x43;
    pub const f64_const: u8 = 0x44;

    // i32 comparison
    pub const i32_eqz: u8 = 0x45;
    pub const i32_eq: u8 = 0x46;
    pub const i32_ne: u8 = 0x47;
    pub const i32_lt_s: u8 = 0x48;
    pub const i32_gt_s: u8 = 0x4A;
    pub const i32_le_s: u8 = 0x4C;
    pub const i32_ge_s: u8 = 0x4E;

    // i32 arithmetic
    pub const i32_add: u8 = 0x6A;
    pub const i32_sub: u8 = 0x6B;
    pub const i32_mul: u8 = 0x6C;
    pub const i32_div_s: u8 = 0x6D;
    pub const i32_rem_s: u8 = 0x6F;
    pub const i32_and: u8 = 0x71;
    pub const i32_or: u8 = 0x72;
    pub const i32_xor: u8 = 0x73;
    pub const i32_shl: u8 = 0x74;
    pub const i32_shr_s: u8 = 0x75;

    // i64 comparison
    pub const i64_eqz: u8 = 0x50;
    pub const i64_eq: u8 = 0x51;
    pub const i64_ne: u8 = 0x52;
    pub const i64_lt_s: u8 = 0x53;
    pub const i64_gt_s: u8 = 0x55;
    pub const i64_le_s: u8 = 0x57;
    pub const i64_ge_s: u8 = 0x59;

    // i64 arithmetic
    pub const i64_add: u8 = 0x7C;
    pub const i64_sub: u8 = 0x7D;
    pub const i64_mul: u8 = 0x7E;
    pub const i64_div_s: u8 = 0x7F;
    pub const i64_rem_s: u8 = 0x81;
    pub const i64_and: u8 = 0x83;
    pub const i64_or: u8 = 0x84;
    pub const i64_xor: u8 = 0x85;
    pub const i64_shl: u8 = 0x86;
    pub const i64_shr_s: u8 = 0x87;

    // f32 comparison
    pub const f32_eq: u8 = 0x5B;
    pub const f32_ne: u8 = 0x5C;
    pub const f32_lt: u8 = 0x5D;
    pub const f32_gt: u8 = 0x5E;
    pub const f32_le: u8 = 0x5F;
    pub const f32_ge: u8 = 0x60;

    // f32 arithmetic
    pub const f32_add: u8 = 0x92;
    pub const f32_sub: u8 = 0x93;
    pub const f32_mul: u8 = 0x94;
    pub const f32_div: u8 = 0x95;

    // f64 comparison
    pub const f64_eq: u8 = 0x61;
    pub const f64_ne: u8 = 0x62;
    pub const f64_lt: u8 = 0x63;
    pub const f64_gt: u8 = 0x64;
    pub const f64_le: u8 = 0x65;
    pub const f64_ge: u8 = 0x66;

    // f64 arithmetic
    pub const f64_add: u8 = 0xA0;
    pub const f64_sub: u8 = 0xA1;
    pub const f64_mul: u8 = 0xA2;
    pub const f64_div: u8 = 0xA3;

    // Misc
    pub const drop: u8 = 0x1A;
};

// Block types
pub const BLOCK_VOID: u8 = 0x40;

pub fn encodeLEB128(writer: anytype, value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try writer.writeByte(byte);
            return;
        }
        try writer.writeByte(byte | 0x80);
    }
}

pub fn encodeSLEB128(writer: anytype, value: i64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7F);
        v >>= 7;
        if ((v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0)) {
            try writer.writeByte(byte);
            return;
        }
        try writer.writeByte(byte | 0x80);
    }
}

pub fn encodeF32(writer: anytype, value: f32) !void {
    const bytes = @as([4]u8, @bitCast(value));
    try writer.writeAll(&bytes);
}

pub fn encodeF64(writer: anytype, value: f64) !void {
    const bytes = @as([8]u8, @bitCast(value));
    try writer.writeAll(&bytes);
}

pub const WasmWriter = struct {
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) WasmWriter {
        return .{ .buf = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *WasmWriter) void {
        self.buf.deinit();
    }

    pub fn writer(self: *WasmWriter) std.ArrayList(u8).Writer {
        return self.buf.writer();
    }

    pub fn writeByte(self: *WasmWriter, byte: u8) !void {
        try self.buf.append(byte);
    }

    pub fn writeAll(self: *WasmWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(bytes);
    }

    pub fn writeLEB(self: *WasmWriter, value: u32) !void {
        try encodeLEB128(self.buf.writer(), value);
    }

    pub fn writeSLEB(self: *WasmWriter, value: i64) !void {
        try encodeSLEB128(self.buf.writer(), value);
    }

    pub fn writeSection(self: *WasmWriter, section_id: u8, content: []const u8) !void {
        try self.writeByte(section_id);
        try self.writeLEB(@intCast(content.len));
        try self.writeAll(content);
    }

    pub fn toOwnedSlice(self: *WasmWriter) ![]u8 {
        return self.buf.toOwnedSlice();
    }
};

test "LEB128 encoding" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try encodeLEB128(buf.writer(), 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, buf.items);
    buf.clearRetainingCapacity();

    try encodeLEB128(buf.writer(), 127);
    try std.testing.expectEqualSlices(u8, &.{0x7F}, buf.items);
    buf.clearRetainingCapacity();

    try encodeLEB128(buf.writer(), 128);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf.items);
}
