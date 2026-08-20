const std = @import("std");

const Display = @import("Display.zig");
const Instruction = @import("instruction.zig").Instruction;
const font = @import("font.zig");

const Chip8 = @This();

// ROMs load and execution starts here
pub const program_start = 0x200;

// 4kib of addressable memory
memory: [4096]u8,

// 16 general purpose registers V0-VF
//
// VF is also a flag register
// carry, borry and sprite collision land there
v: [16]u8,

// index register, used to point at memory (almost only sprites)
//
// chip-8 address is 12bits, but this is u16 because FX1E adds to I
// and can push it past 0x0FFF
// if it was a u12 it would panic
i: u16,

// program counter
pc: u16,

// return addresses for subroutine calls
stack: [16]u16,

// how many entries of stack are in use
sp: u8,

// counts down at 60hz
delay_timer: u8,

// same as delay_timer but for sound
sound_timer: u8,

// the display (wow unexpected)
display: Display,

pub fn init() Chip8 {
    var machine: Chip8 = .{
        .memory = @splat(0),
        .v = @splat(0),
        .i = 0,
        .pc = program_start,
        .stack = @splat(0),
        .sp = 0,
        .delay_timer = 0,
        .sound_timer = 0,
        .display = Display.init(),
    };

    // install the font where the ROMs expect to find it
    @memcpy(machine.memory[font.base_address..][0..font.sprites.len], &font.sprites);
    return machine;
}

pub const LoadError = error{RomTooLarge};

// copies a ROM into memory
pub fn load(self: *@This(), rom: []const u8) LoadError!void {
    const capacity = self.memory.len - program_start;
    if (rom.len > capacity) {
        return error.RomTooLarge;
    }
    @memcpy(self.memory[program_start..][0..rom.len], rom);
}

pub const StepError = error{
    // something not implemented etc
    UnknownOpcode,
    // just so it doesn't crash while developing
    // maybe can be deleted later
    NotImplemented,
};

pub fn step(self: *@This()) StepError!void {
    // instructions are 2bytes, big endian
    //
    // the `@as(u16, ...)` is necessary because `self.memory[self.pc]` is a u8
    // and shifting a u8 left by 8 would push every bit off the end
    // and since Zig never widens silently we need to do that before shifting
    const raw = (@as(u16, self.memory[self.pc]) << 8) | self.memory[self.pc + 1];

    // advance the pc before executing so the jumps works correctly
    // 1NNN overwrites a pc that already moved, so if we don't do this
    // the jump lands two bytes too far
    self.pc += 2;

    return self.execute(Instruction.decode(raw));
}

fn execute(self: *Chip8, instruction: Instruction) StepError!void {
    switch (instruction.op) {
        0x0 => switch (instruction.nn) {
            // 0OE0 clears the display (CLS)
            0xE0 => self.display.clear(),
            else => return error.UnknownOpcode,
        },
        // 1NNN -> jump
        0x1 => {
            return error.NotImplemented;
        },
        // 6XNN -> set register VX
        0x6 => {
            return error.NotImplemented;
        },
        // 7XNN -> add value to register VX
        0x7 => {
            return error.NotImplemented;
        },
        // ANNN -> set index register I
        0xA => {
            return error.NotImplemented;
        },
        // DXYN -> display/draw
        0xD => {
            return error.NotImplemented;
        },
        else => return error.UnknownOpcode,
    }
}
