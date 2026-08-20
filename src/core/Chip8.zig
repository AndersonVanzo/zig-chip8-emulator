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
            self.pc = instruction.nnn;
        },
        // 6XNN -> set register VX
        0x6 => {
            self.v[instruction.x] = instruction.nn;
        },
        // 7XNN -> add value to register VX
        0x7 => {
            self.v[instruction.x] = self.v[instruction.x] +% instruction.nn;
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

// tests ----------------------------------------------------------------------

fn testMachine(program: []const u8) @This() {
    var machine = Chip8.init();
    machine.load(program) catch unreachable;
    return machine;
}

test "init starts at 0x200 with the font installed" {
    const machine = Chip8.init();
    try std.testing.expectEqual(@as(u16, 0x200), machine.pc);
    try std.testing.expectEqual(@as(u8, 0xF0), machine.memory[font.base_address]);
}

test "load rejects a ROM that would not fit" {
    var machine = Chip8.init();
    const too_big = [_]u8{0} ** (4096 - program_start + 1);
    try std.testing.expectError(error.RomTooLarge, machine.load(&too_big));
}

test "00E0 clears the display" {
    var machine = testMachine(&.{ 0x00, 0xE0 });
    _ = machine.display.xorPixel(10, 10);
    try machine.step();
    try std.testing.expect(!machine.display.get(10, 10));
}

test "6XNN sets a register" {
    var machine = testMachine(&.{ 0x6A, 0x2F });
    try machine.step();
    try std.testing.expectEqual(@as(u8, 0x2F), machine.v[0xA]);
}

test "7XNN adds, wraps past 255 and leaves VF alone" {
    var machine = testMachine(&.{ 0x60, 0xFF, 0x70, 0x02 });
    try machine.step();
    try machine.step();
    try std.testing.expectEqual(@as(u8, 0x01), machine.v[0]);
    try std.testing.expectEqual(@as(u8, 0x00), machine.v[0xF]);
}

test "ANNN sets the index register" {
    var machine = testMachine(&.{ 0xA2, 0xF0 });
    try machine.step();
    try std.testing.expectEqual(@as(u16, 0x228), machine.pc);
}

test "1NNN jumps to exactly NNN" {
    var machine = testMachine(&.{ 0x12, 0x28 });
    try machine.step();
    try std.testing.expectEqual(@as(u16, 0x228), machine.pc);
}

test "DXYN draws a sprite row and flags collisions" {
    var machine = testMachine(&.{
        // A20A: I = 0x20A (a spare byte past the program, set below)
        0xA2, 0x0A,
        // 6008: V0 = 8
        0x60, 0x08,
        // 6104: V1 = 4
        0x61, 0x04,
        // D011: draw 1 row at (V0, V1)
        0xD0, 0x11,
    });
    machine.memory[0x20A] = 0b1010_0000;

    for (0..4) |_| {
        try machine.step();
    }

    try std.testing.expect(machine.display.get(8, 4));
    try std.testing.expect(!machine.display.get(9, 4));
    try std.testing.expect(machine.display.get(10, 4));
    try std.testing.expect(!machine.display.get(11, 4));
    try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);

    // run the draw again
    // the XOR returns the same pixels to off and flags it
    machine.pc = 0x206;
    try machine.step();
    try std.testing.expect(!machine.display.get(8, 4));
    try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
}

test "DXYN clips at the right edge instead of wrapping" {
    // V0 = 0x3C (60) so an all on 8 pixel row has 4 pixels on screen
    // and 4 pixels clipped off the right edge
    var machine = testMachine(&.{
        0xA2, 0x0A,
        0x60, 0x3C,
        0x61, 0x00,
        0xD0, 0x11,
    });
    machine.memory[0x20A] = 0xFF;

    for (0..4) |_| {
        try machine.step();
    }

    try std.testing.expect(machine.display.get(63, 0));
    // this would be pixel 64, if it wrapped column 0 would be on
    try std.testing.expect(!machine.display.get(0, 0));
}

test "a whole small program draws a font glyph" {
    var machine = testMachine(&.{
        // 00E0: clear
        0x00, 0xE0,
        // A050: I = font address of '0'
        0xA0, 0x50,
        // 6005: V0 = 5 (x)
        0x60, 0x05,
        // 6103: V1 = 3 (y)
        0x61, 0x03,
        // D015: draw 5 rows
        0xD0, 0x15,
        // 120A: jump to self (0x20A)
        0x12, 0x0A,
    });

    for (0..6) |_| {
        try machine.step();
    }

    // the '0' glyph is F0 90 90 90 F0, a hollow rectangle 4 wide, 5 tall,
    // drawn with its top-left corner at (5, 3)

    // top row: four pixels lit, then dark
    try std.testing.expect(machine.display.get(5, 3));
    try std.testing.expect(machine.display.get(8, 3));
    try std.testing.expect(!machine.display.get(9, 3));

    // middle row: only the two sides.
    try std.testing.expect(machine.display.get(5, 4));
    try std.testing.expect(!machine.display.get(6, 4));
    try std.testing.expect(machine.display.get(8, 4));

    // bottom row solid again.
    try std.testing.expect(machine.display.get(5, 7));
    try std.testing.expect(machine.display.get(8, 7));
}
