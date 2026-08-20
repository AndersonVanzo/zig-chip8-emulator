const std = @import("std");

pub const Instruction = struct {
    // 16bit word for error messages
    raw: u16,
    // first nibble: which family of instruction this is
    op: u4,
    // second nibble: register index (not always)
    x: u4,
    // third nibble: second register index (also not always)
    y: u4,
    // forth nibble: small immediate (like a sprite's height)
    n: u4,
    // low byte: 8bit immediate
    nn: u8,
    // low 12 bits: address
    nnn: u12,

    pub fn decode(raw: u16) @This() {
        // discards high bits and keeps the low ones
        return .{
            .raw = raw,
            .op = @truncate(raw >> 12),
            .x = @truncate(raw >> 8),
            .y = @truncate(raw >> 4),
            .n = @truncate(raw),
            .nn = @truncate(raw),
            .nnn = @truncate(raw),
        };
    }
};
