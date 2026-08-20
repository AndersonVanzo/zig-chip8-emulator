const std = @import("std");

const Display = @import("Display.zig");
const Instruction = @import("instruction.zig").Instruction;
const font = @import("font.zig");

// ROMs load and execution starts here
pub const program_start = 0x200;

pub const Chip8 = struct {
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

    rand: std.Random,

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

    pub fn init(rand: std.Random) Chip8 {
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
            .rand = rand,
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
                // 00E0 clears the display (CLS)
                0xE0 => self.display.clear(),
                // 00EE -> subroutine
                0xEE => {
                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                    self.stack[self.sp] = 0;
                },
                else => return error.UnknownOpcode,
            },
            // 1NNN -> jump
            0x1 => {
                self.pc = instruction.nnn;
            },
            // 2NNN -> subroutine
            0x2 => {
                self.stack[self.sp] = self.pc;
                self.sp += 1;
                self.pc = instruction.nnn;
            },
            // 3XNN -> skip conditionally
            0x3 => {
                if (self.v[instruction.x] == instruction.nn) {
                    self.pc += 2;
                }
            },
            // 4XNN -> skip conditionally
            0x4 => {
                if (self.v[instruction.x] != instruction.nn) {
                    self.pc += 2;
                }
            },
            // 5XY0 -> skip conditionally
            0x5 => switch (instruction.n) {
                0x0 => {
                    if (self.v[instruction.x] == self.v[instruction.y]) {
                        self.pc += 2;
                    }
                },
                else => return error.UnknownOpcode,
            },
            // 6XNN -> set register VX
            0x6 => {
                self.v[instruction.x] = instruction.nn;
            },
            // 7XNN -> add value to register VX
            0x7 => {
                self.v[instruction.x] = self.v[instruction.x] +% instruction.nn;
            },
            0x8 => switch (instruction.n) {
                // 8XY0 -> set VX with value of VY
                0x0 => {
                    self.v[instruction.x] = self.v[instruction.y];
                },
                // 8XY1 -> binary OR
                0x1 => {
                    self.v[instruction.x] = self.v[instruction.x] | self.v[instruction.y];
                    self.v[0xF] = 0;
                },
                // 8XY2 -> binary AND
                0x2 => {
                    self.v[instruction.x] = self.v[instruction.x] & self.v[instruction.y];
                    self.v[0xF] = 0;
                },
                // 8XY3 -> logical XOR
                0x3 => {
                    self.v[instruction.x] = self.v[instruction.x] ^ self.v[instruction.y];
                    self.v[0xF] = 0;
                },
                // 8XY4 -> add
                0x4 => {
                    const result, const overflow = @addWithOverflow(self.v[instruction.x], self.v[instruction.y]);
                    self.v[instruction.x] = result;
                    self.v[0xF] = overflow;
                },
                // 8XY5 -> subtract
                0x5 => {
                    self.v[0xF] = if (self.v[instruction.x] >= self.v[instruction.y]) 1 else 0;
                    const result = self.v[instruction.x] -% self.v[instruction.y];
                    self.v[instruction.x] = result;
                },
                // 8XY6 -> shift
                0x6 => {
                    self.v[instruction.x] = self.v[instruction.y];
                    self.v[0xF] = self.v[instruction.x] & 1;
                    self.v[instruction.x] >>= 1;
                },
                // 8XY7 -> subtract
                0x7 => {
                    self.v[0xF] = if (self.v[instruction.y] >= self.v[instruction.x]) 1 else 0;
                    const result = self.v[instruction.y] -% self.v[instruction.x];
                    self.v[instruction.x] = result;
                },
                // 8XYE -> shift
                0xE => {
                    self.v[instruction.x] = self.v[instruction.y];
                    self.v[0xF] = self.v[instruction.x] >> 7;
                    self.v[instruction.x] <<= 1;
                },
                else => return error.UnknownOpcode,
            },
            // 9XY0 -> skip conditionally
            0x9 => switch (instruction.n) {
                0x0 => {
                    if (self.v[instruction.x] != self.v[instruction.y]) {
                        self.pc += 2;
                    }
                },
                else => return error.UnknownOpcode,
            },
            // ANNN -> set index register I
            0xA => {
                self.i = instruction.nnn;
            },
            // BNNN -> jump with offset
            0xB => {
                self.pc = instruction.nnn + self.v[0x0];
            },
            // CXNN -> random
            0xC => {
                const vx = self.rand.int(u8) & instruction.nn;
                self.v[instruction.x] = vx;
            },
            // DXYN -> display/draw
            0xD => {
                const x = self.v[instruction.x] % Display.display_width;
                const y = self.v[instruction.y] % Display.display_height;
                self.v[0xF] = 0;

                // N bytes starting at I
                // one byte per row
                const sprite = self.memory[self.i..][0..instruction.n];
                for (sprite, 0..) |row_byte, row| {
                    const pixel_y = y + row;
                    // TODO: sprites clip at the bottom, stop if pixel_y is off screen
                    var mask: u8 = 0b1000_0000;
                    for (0..8) |column| {
                        const pixel_x = x + column;
                        // TODO: clip at the right edge too
                        if ((row_byte & mask) != 0) {
                            if (self.display.xorPixel(pixel_x, pixel_y)) {
                                self.v[0xF] = 1;
                            }
                        }
                        // moves one pixel right
                        mask >>= 1;
                    }
                }
            },
            0xE => switch (instruction.nn) {
                // EX9E -> skip if key
                0x9E => {
                    return error.NotImplemented;
                },
                // EXA1 -> skip if key
                0xA1 => {
                    return error.NotImplemented;
                },
                else => return error.UnknownOpcode,
            },
            0xF => switch (instruction.nn) {
                // FX07 -> timer
                0x07 => {
                    self.v[instruction.x] = self.delay_timer;
                },
                // FX15 -> timer
                0x15 => {
                    self.delay_timer = self.v[instruction.x];
                },
                // FX18 -> timer
                0x18 => {
                    self.sound_timer = self.v[instruction.x];
                },
                // FX1E -> add to index
                0x1E => {
                    return error.NotImplemented;
                },
                // FX0A -> get key
                0x0A => {
                    return error.NotImplemented;
                },
                // FX29 -> font character
                0x29 => {
                    return error.NotImplemented;
                },
                // FX33 -> binary-coded decimal conversion
                0x33 => {
                    return error.NotImplemented;
                },
                // FX55 -> store in memory
                0x55 => {
                    return error.NotImplemented;
                },
                // FX65 -> loads form memory
                0x65 => {
                    return error.NotImplemented;
                },
                else => return error.UnknownOpcode,
            },
        }
    }

    // tests ----------------------------------------------------------------------
    fn testMachine(program: []const u8) @This() {
        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
        const rand = prng.random();
        var machine = Chip8.init(rand);
        machine.load(program) catch unreachable;
        return machine;
    }

    test "init starts at 0x200 with the font installed" {
        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
        const rand = prng.random();
        const machine = Chip8.init(rand);
        try std.testing.expectEqual(@as(u16, 0x200), machine.pc);
        try std.testing.expectEqual(@as(u8, 0xF0), machine.memory[font.base_address]);
    }

    test "load rejects a ROM that would not fit" {
        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
        const rand = prng.random();
        var machine = Chip8.init(rand);
        const too_big = [_]u8{0} ** (4096 - program_start + 1);
        try std.testing.expectError(error.RomTooLarge, machine.load(&too_big));
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

    // 0x0 tests ------------------------------------------------------------------
    test "00E0 clears the display" {
        var machine = testMachine(&.{ 0x00, 0xE0 });
        _ = machine.display.xorPixel(10, 10);
        try machine.step();
        try std.testing.expect(!machine.display.get(10, 10));
    }

    test "00EE returns to the address on top of the stack" {
        var machine = testMachine(&.{ 0x00, 0xEE });

        // seed the stack by hand so this test only exercises 00EE
        machine.stack[0] = 0x246;
        machine.sp = 1;

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x246), machine.pc);
        try std.testing.expectEqual(@as(u8, 0), machine.sp);
    }

    test "00EE unwinds nested calls one level at a time" {
        var machine = testMachine(&.{
            // 0x200: 2204 -> call 0x204
            0x22, 0x04,
            // 0x202: filler, only reached after both returns
            0x00, 0x00,
            // 0x204: 2208 -> call 0x208
            0x22, 0x08,
            // 0x206: 00EE -> inner return target, returns again
            0x00, 0xEE,
            // 0x208: 00EE -> return
            0x00, 0xEE,
        });

        try machine.step();
        try machine.step();

        // two calls deep
        try std.testing.expectEqual(@as(u16, 0x208), machine.pc);
        try std.testing.expectEqual(@as(u8, 2), machine.sp);

        // first return: back into the outer subroutine
        try machine.step();
        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);
        try std.testing.expectEqual(@as(u8, 1), machine.sp);

        // second return: back to the top level
        try machine.step();
        try std.testing.expectEqual(@as(u16, 0x202), machine.pc);
        try std.testing.expectEqual(@as(u8, 0), machine.sp);
    }

    // 0x1 tests ------------------------------------------------------------------
    test "1NNN jumps to exactly NNN" {
        var machine = testMachine(&.{ 0x12, 0x28 });
        try machine.step();
        try std.testing.expectEqual(@as(u16, 0x228), machine.pc);
    }

    // 0x2 tests ------------------------------------------------------------------
    test "2NNN then 00EE lands on the instruction after the call" {
        var machine = testMachine(&.{
            // 0x200: 2204 -> call 0x204
            0x22, 0x04,
            // 0x202: 6001 -> V0 = 1, the instruction we should come back to
            0x60, 0x01,
            // 0x204: 00EE -> return
            0x00, 0xEE,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x202), machine.pc);
        try std.testing.expectEqual(@as(u8, 0), machine.sp);

        // and execution actually carries on from there
        try machine.step();
        try std.testing.expectEqual(@as(u8, 1), machine.v[0]);
    }

    test "2NNN jumps to NNN and remembers where to come back to" {
        var machine = testMachine(&.{ 0x22, 0x28 });
        try machine.step();

        // the jump part
        try std.testing.expectEqual(@as(u16, 0x228), machine.pc);

        // one stack entry in use, holding the address of the instruction
        // *after* the call, because step() already advanced pc by 2
        // before execute() ran
        try std.testing.expectEqual(@as(u8, 1), machine.sp);
        try std.testing.expectEqual(@as(u16, 0x202), machine.stack[0]);
    }

    test "2NNN nests, stacking one return address per call" {
        var machine = testMachine(&.{
            // 0x200: 2204 -> call 0x204
            0x22, 0x04,
            // 0x202: filler, never executed
            0x00, 0x00,
            // 0x204: 2208 -> call 0x208
            0x22, 0x08,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x208), machine.pc);
        try std.testing.expectEqual(@as(u8, 2), machine.sp);
        try std.testing.expectEqual(@as(u16, 0x202), machine.stack[0]);
        try std.testing.expectEqual(@as(u16, 0x206), machine.stack[1]);
    }

    test "2NNN leaves the registers alone" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: A123 -> I = 0x123
            0xA1, 0x23,
            // 0x204: 2300 -> call 0x300
            0x23, 0x00,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // a call only touches pc, stack and sp
        try std.testing.expectEqual(@as(u16, 0x300), machine.pc);
        try std.testing.expectEqual(@as(u8, 0x42), machine.v[0]);
        try std.testing.expectEqual(@as(u16, 0x123), machine.i);
    }

    // 0x3 tests ------------------------------------------------------------------
    test "3XNN skips the next instruction when VX equals NN" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 3042 -> V0 == 0x42, so skip
            0x30, 0x42,
            // 0x204: 6099 -> must never run
            0x60, 0x99,
            // 0x206: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();
        try machine.step();

        // pc moved 4: two for the 3XNN itself, two more for the skip
        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);

        // and the skipped instruction really did not run
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    test "3XNN does not skip when VX differs from NN" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 3043 -> V0 != 0x43, so no skip
            0x30, 0x43,
            // 0x204: 6099 -> V0 = 0x99
            0x60, 0x99,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x99), machine.v[0]);
    }

    test "3XNN reads register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: 657F -> V5 = 0x7F, V0 stays 0
            0x65, 0x7F,
            // 0x202: 357F -> compares V5, so skip
            0x35, 0x7F,
            // 0x204: filler, skipped
            0x00, 0x00,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);
    }

    test "3XNN compares the whole byte, not just one nibble" {
        var machine = testMachine(&.{
            // 0x200: 601F -> V0 = 0x1F
            0x60, 0x1F,
            // 0x202: 302F -> same low nibble, different byte, so no skip
            0x30, 0x2F,
            // 0x204: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    test "3XNN skips on a register that is still zero" {
        var machine = testMachine(&.{
            // 0x200: 3300 -> V3 starts at 0, so skip
            0x33, 0x00,
            // 0x202: filler, skipped
            0x00, 0x00,
        });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);
    }

    // 0x4 tests ------------------------------------------------------------------

    test "4XNN skips the next instruction when VX differs from NN" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 4043 -> V0 != 0x43, so skip
            0x40, 0x43,
            // 0x204: 6099 -> must never run
            0x60, 0x99,
            // 0x206: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();
        try machine.step();

        // pc moved 4: two for the 4XNN itself, two more for the skip
        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);

        // and the skipped instruction really did not run
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    test "4XNN does not skip when VX equals NN" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 4042 -> V0 == 0x42, so no skip
            0x40, 0x42,
            // 0x204: 6099 -> V0 = 0x99
            0x60, 0x99,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x99), machine.v[0]);
    }

    test "4XNN reads register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: 657F -> V5 = 0x7F, V0 stays 0
            0x65, 0x7F,
            // 0x202: 4500 -> V5 != 0, so skip
            //         reading V0 instead would compare 0 to 0 and not skip
            0x45, 0x00,
            // 0x204: filler, skipped
            0x00, 0x00,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);
    }

    test "4XNN compares the whole byte, not just one nibble" {
        var machine = testMachine(&.{
            // 0x200: 601F -> V0 = 0x1F
            0x60, 0x1F,
            // 0x202: 402F -> same low nibble, different byte, so skip
            0x40, 0x2F,
            // 0x204: 6099 -> must never run
            0x60, 0x99,
            // 0x206: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    test "4XNN does not skip on a register that is still zero" {
        var machine = testMachine(&.{
            // 0x200: 4300 -> V3 starts at 0, so no skip
            0x43, 0x00,
            // 0x202: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x202), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    // 0x5 tests ------------------------------------------------------------------

    test "5XY0 skips the next instruction when VX equals VY" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 5010 -> V0 == V1, so skip
            0x50, 0x10,
            // 0x206: 6299 -> must never run
            0x62, 0x99,
            // 0x208: 62AA -> V2 = 0xAA
            0x62, 0xAA,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // pc moved 4 over the 5XY0: two for itself, two more for the skip
        try std.testing.expectEqual(@as(u16, 0x208), machine.pc);

        // and the skipped instruction really did not run
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[2]);
    }

    test "5XY0 does not skip when VX differs from VY" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6143 -> V1 = 0x43
            0x61, 0x43,
            // 0x204: 5010 -> V0 != V1, so no skip
            0x50, 0x10,
            // 0x206: 6299 -> V2 = 0x99
            0x62, 0x99,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x99), machine.v[2]);
    }

    test "5XY0 reads registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6001 -> V0 = 1
            0x60, 0x01,
            // 0x202: 6102 -> V1 = 2, so V0 != V1
            0x61, 0x02,
            // 0x204: 657F -> V5 = 0x7F
            0x65, 0x7F,
            // 0x206: 6A7F -> VA = 0x7F
            0x6A, 0x7F,
            // 0x208: 55A0 -> V5 == VA, so skip
            //         comparing V0 to V1 instead would not skip
            0x55, 0xA0,
            // 0x20A: filler, skipped
            0x00, 0x00,
        });

        for (0..5) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x20C), machine.pc);
    }

    test "5XY0 skips when both registers are still zero" {
        var machine = testMachine(&.{
            // 0x200: 5340 -> V3 and V4 both start at 0, so skip
            0x53, 0x40,
            // 0x202: filler, skipped
            0x00, 0x00,
        });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);
    }

    test "5XY0 always skips when X and Y name the same register" {
        var machine = testMachine(&.{
            // 0x200: 6377 -> V3 = 0x77
            0x63, 0x77,
            // 0x202: 5330 -> V3 == V3, so always skip
            0x53, 0x30,
            // 0x204: filler, skipped
            0x00, 0x00,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);
    }

    // 5XY1 tests

    test "5XY1 is not a valid instruction" {
        // the pattern is 5XY0, so anything else in the last slot is unknown
        var machine = testMachine(&.{ 0x50, 0x11 });
        try std.testing.expectError(error.UnknownOpcode, machine.step());
    }

    // 0x6 tests ------------------------------------------------------------------
    test "6XNN sets a register" {
        var machine = testMachine(&.{ 0x6A, 0x2F });
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x2F), machine.v[0xA]);
    }

    // 0x7 tests ------------------------------------------------------------------
    test "7XNN adds, wraps past 255 and leaves VF alone" {
        var machine = testMachine(&.{ 0x60, 0xFF, 0x70, 0x02 });
        try machine.step();
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x01), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0x00), machine.v[0xF]);
    }

    // 0x8 tests ------------------------------------------------------------------

    test "8XY0 copies VY into VX, overwriting what was there" {
        var machine = testMachine(&.{
            // 0x200: 6099 -> V0 = 0x99
            0x60, 0x99,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 8010 -> V0 = V1
            0x80, 0x10,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x42), machine.v[0]);

        // the source register is left alone, this is a copy not a move
        try std.testing.expectEqual(@as(u8, 0x42), machine.v[1]);
    }

    test "8XY0 writes X and reads Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 65AA -> V5 = 0xAA
            0x65, 0xAA,
            // 0x202: 6A33 -> VA = 0x33
            0x6A, 0x33,
            // 0x204: 85A0 -> V5 = VA
            0x85, 0xA0,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x33), machine.v[5]);

        // hardcoding V0/V1 would leave V5 at 0xAA and scribble on these
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[1]);
    }

    test "8XY0 can copy a zero over a nonzero VX" {
        var machine = testMachine(&.{
            // 0x200: 6099 -> V0 = 0x99
            0x60, 0x99,
            // 0x202: 8010 -> V0 = V1, and V1 is still 0
            0x80, 0x10,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    test "8XY0 is a no-op when X and Y name the same register" {
        var machine = testMachine(&.{
            // 0x200: 6377 -> V3 = 0x77
            0x63, 0x77,
            // 0x202: 8330 -> V3 = V3
            0x83, 0x30,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x77), machine.v[3]);
    }

    test "8XY0 does not touch the flag register" {
        var machine = testMachine(&.{
            // 0x200: 6F5A -> VF = 0x5A
            0x6F, 0x5A,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 8010 -> V0 = V1
            0x80, 0x10,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x42), machine.v[0]);

        // only the arithmetic and shift variants write VF
        try std.testing.expectEqual(@as(u8, 0x5A), machine.v[0xF]);
    }

    test "8XY0 advances pc by two, it never skips" {
        var machine = testMachine(&.{ 0x80, 0x10 });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x202), machine.pc);
    }

    // 8XY1 tests

    test "8XY1 ORs VY into VX" {
        var machine = testMachine(&.{
            // 0x200: 60A0 -> V0 = 0b1010_0000
            0x60, 0xA0,
            // 0x202: 6105 -> V1 = 0b0000_0101
            0x61, 0x05,
            // 0x204: 8011 -> V0 = V0 | V1
            0x80, 0x11,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0b1010_0101), machine.v[0]);

        // the source register is left alone
        try std.testing.expectEqual(@as(u8, 0x05), machine.v[1]);
    }

    test "8XY1 resets VF to zero" {
        var machine = testMachine(&.{
            // 0x200: 6F5A -> VF = 0x5A
            0x6F, 0x5A,
            // 0x202: 6001 -> V0 = 1
            0x60, 0x01,
            // 0x204: 8011 -> V0 = V0 | V1
            0x80, 0x11,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // original CHIP-8 clears VF on the bitwise ops
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY1 with zero leaves VX alone" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 8011 -> V0 = V0 | V1, and V1 is still 0
            0x80, 0x11,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x42), machine.v[0]);
    }

    test "8XY1 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 65F0 -> V5 = 0xF0
            0x65, 0xF0,
            // 0x202: 6A0F -> VA = 0x0F
            0x6A, 0x0F,
            // 0x204: 85A1 -> V5 = V5 | VA
            0x85, 0xA1,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0xFF), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY2 tests

    test "8XY2 ANDs VY into VX" {
        var machine = testMachine(&.{
            // 0x200: 60F0 -> V0 = 0b1111_0000
            0x60, 0xF0,
            // 0x202: 613C -> V1 = 0b0011_1100
            0x61, 0x3C,
            // 0x204: 8012 -> V0 = V0 & V1
            0x80, 0x12,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0b0011_0000), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0x3C), machine.v[1]);
    }

    test "8XY2 resets VF to zero" {
        var machine = testMachine(&.{
            // 0x200: 6F5A -> VF = 0x5A
            0x6F, 0x5A,
            // 0x202: 60FF -> V0 = 0xFF
            0x60, 0xFF,
            // 0x204: 8012 -> V0 = V0 & V1
            0x80, 0x12,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY2 with zero clears VX" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF
            0x60, 0xFF,
            // 0x202: 8012 -> V0 = V0 & V1, and V1 is still 0
            0x80, 0x12,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    test "8XY2 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 65FF -> V5 = 0xFF
            0x65, 0xFF,
            // 0x202: 6A3C -> VA = 0x3C
            0x6A, 0x3C,
            // 0x204: 85A2 -> V5 = V5 & VA
            0x85, 0xA2,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x3C), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY3

    test "8XY3 XORs VY into VX" {
        var machine = testMachine(&.{
            // 0x200: 60F0 -> V0 = 0b1111_0000
            0x60, 0xF0,
            // 0x202: 613C -> V1 = 0b0011_1100
            0x61, 0x3C,
            // 0x204: 8013 -> V0 = V0 ^ V1
            0x80, 0x13,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0b1100_1100), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0x3C), machine.v[1]);
    }

    test "8XY3 resets VF to zero" {
        var machine = testMachine(&.{
            // 0x200: 6F5A -> VF = 0x5A
            0x6F, 0x5A,
            // 0x202: 6001 -> V0 = 1
            0x60, 0x01,
            // 0x204: 8013 -> V0 = V0 ^ V1
            0x80, 0x13,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY3 with itself clears the register" {
        var machine = testMachine(&.{
            // 0x200: 6377 -> V3 = 0x77
            0x63, 0x77,
            // 0x202: 8333 -> V3 = V3 ^ V3
            0x83, 0x33,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0), machine.v[3]);
    }

    test "8XY3 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 65FF -> V5 = 0xFF
            0x65, 0xFF,
            // 0x202: 6A0F -> VA = 0x0F
            0x6A, 0x0F,
            // 0x204: 85A3 -> V5 = V5 ^ VA
            0x85, 0xA3,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0xF0), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY4 tests

    test "8XY4 adds VY to VX and clears VF when it fits" {
        var machine = testMachine(&.{
            // 0x200: 6020 -> V0 = 0x20
            0x60, 0x20,
            // 0x202: 6111 -> V1 = 0x11
            0x61, 0x11,
            // 0x204: 8014 -> V0 = V0 + V1
            0x80, 0x14,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x31), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);

        // the source register is left alone
        try std.testing.expectEqual(@as(u8, 0x11), machine.v[1]);
    }

    test "8XY4 wraps and sets VF on overflow" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF
            0x60, 0xFF,
            // 0x202: 6101 -> V1 = 0x01
            0x61, 0x01,
            // 0x204: 8014 -> 0xFF + 0x01 does not fit in a byte
            0x80, 0x14,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // the low byte of the result is kept, VF records the carry
        try std.testing.expectEqual(@as(u8, 0x00), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XY4 keeps the low byte when the sum overflows by more than one" {
        var machine = testMachine(&.{
            // 0x200: 6090 -> V0 = 0x90
            0x60, 0x90,
            // 0x202: 6180 -> V1 = 0x80
            0x61, 0x80,
            // 0x204: 8014 -> 0x90 + 0x80 = 0x110
            0x80, 0x14,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x10), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XY4 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6520 -> V5 = 0x20
            0x65, 0x20,
            // 0x202: 6A11 -> VA = 0x11
            0x6A, 0x11,
            // 0x204: 85A4 -> V5 = V5 + VA
            0x85, 0xA4,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x31), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY5 tests

    test "8XY5 subtracts VY from VX and sets VF when there is no borrow" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6102 -> V1 = 0x02
            0x61, 0x02,
            // 0x204: 8015 -> V0 = V0 - V1
            0x80, 0x15,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x40), machine.v[0]);

        // VF is 1 when the subtraction did NOT borrow, so it reads as "no borrow"
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);

        try std.testing.expectEqual(@as(u8, 0x02), machine.v[1]);
    }

    test "8XY5 wraps and clears VF when it borrows" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 8015 -> 0x02 - 0x42 goes below zero
            0x80, 0x15,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // 0x02 - 0x42 wraps around to 0xC0
        try std.testing.expectEqual(@as(u8, 0xC0), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY5 with equal registers gives zero and no borrow" {
        var machine = testMachine(&.{
            // 0x200: 6033 -> V0 = 0x33
            0x60, 0x33,
            // 0x202: 6133 -> V1 = 0x33
            0x61, 0x33,
            // 0x204: 8015 -> V0 = V0 - V1
            0x80, 0x15,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);

        // equal is still "no borrow", the boundary belongs to VF = 1
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XY5 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6542 -> V5 = 0x42
            0x65, 0x42,
            // 0x202: 6A02 -> VA = 0x02
            0x6A, 0x02,
            // 0x204: 85A5 -> V5 = V5 - VA
            0x85, 0xA5,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x40), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY6 tests

    test "8XY6 copies VY into VX then shifts right" {
        var machine = testMachine(&.{
            // 0x200: 6184 -> V1 = 0b1000_0100
            0x61, 0x84,
            // 0x202: 8016 -> V0 = V1, then V0 >>= 1
            0x80, 0x16,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0b0100_0010), machine.v[0]);

        // the bit that fell off the bottom was 0
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);

        // the source register is left alone
        try std.testing.expectEqual(@as(u8, 0x84), machine.v[1]);
    }

    test "8XY6 puts the shifted-out bit in VF" {
        var machine = testMachine(&.{
            // 0x200: 6185 -> V1 = 0b1000_0101, lowest bit set
            0x61, 0x85,
            // 0x202: 8016 -> V0 = V1, then V0 >>= 1
            0x80, 0x16,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0b0100_0010), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XY6 shifts VY, not the old contents of VX" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF, which must be thrown away
            0x60, 0xFF,
            // 0x202: 6102 -> V1 = 0x02
            0x61, 0x02,
            // 0x204: 8016 -> V0 = V1, then V0 >>= 1
            0x80, 0x16,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // shifting VY gives 0x01 with VF = 0
        // shifting the old VX in place would give 0x7F with VF = 1
        try std.testing.expectEqual(@as(u8, 0x01), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY6 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6A85 -> VA = 0b1000_0101
            0x6A, 0x85,
            // 0x202: 85A6 -> V5 = VA, then V5 >>= 1
            0x85, 0xA6,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0b0100_0010), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XY7 tests

    test "8XY7 subtracts VX from VY and sets VF when there is no borrow" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 8017 -> V0 = V1 - V0, note the order is flipped from 8XY5
            0x80, 0x17,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x40), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);

        try std.testing.expectEqual(@as(u8, 0x42), machine.v[1]);
    }

    test "8XY7 wraps and clears VF when it borrows" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6102 -> V1 = 0x02
            0x61, 0x02,
            // 0x204: 8017 -> 0x02 - 0x42 goes below zero
            0x80, 0x17,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0xC0), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XY7 with equal registers gives zero and no borrow" {
        var machine = testMachine(&.{
            // 0x200: 6033 -> V0 = 0x33
            0x60, 0x33,
            // 0x202: 6133 -> V1 = 0x33
            0x61, 0x33,
            // 0x204: 8017 -> V0 = V1 - V0
            0x80, 0x17,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XY7 uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6502 -> V5 = 0x02
            0x65, 0x02,
            // 0x202: 6A42 -> VA = 0x42
            0x6A, 0x42,
            // 0x204: 85A7 -> V5 = VA - V5
            0x85, 0xA7,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u8, 0x40), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 8XYE tests

    test "8XYE copies VY into VX then shifts left" {
        var machine = testMachine(&.{
            // 0x200: 6121 -> V1 = 0b0010_0001
            0x61, 0x21,
            // 0x202: 801E -> V0 = V1, then V0 <<= 1
            0x80, 0x1E,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0b0100_0010), machine.v[0]);

        // the bit that fell off the top was 0
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);

        // the source register is left alone
        try std.testing.expectEqual(@as(u8, 0x21), machine.v[1]);
    }

    test "8XYE puts the shifted-out bit in VF" {
        var machine = testMachine(&.{
            // 0x200: 6181 -> V1 = 0b1000_0001, highest bit set
            0x61, 0x81,
            // 0x202: 801E -> V0 = V1, then V0 <<= 1
            0x80, 0x1E,
        });

        try machine.step();
        try machine.step();

        // the top bit is dropped, not carried into the result
        try std.testing.expectEqual(@as(u8, 0b0000_0010), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
    }

    test "8XYE shifts VY, not the old contents of VX" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF, which must be thrown away
            0x60, 0xFF,
            // 0x202: 6101 -> V1 = 0x01
            0x61, 0x01,
            // 0x204: 801E -> V0 = V1, then V0 <<= 1
            0x80, 0x1E,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // shifting VY gives 0x02 with VF = 0
        // shifting the old VX in place would give 0xFE with VF = 1
        try std.testing.expectEqual(@as(u8, 0x02), machine.v[0]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0xF]);
    }

    test "8XYE uses registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6A81 -> VA = 0b1000_0001
            0x6A, 0x81,
            // 0x202: 85AE -> V5 = VA, then V5 <<= 1
            0x85, 0xAE,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0b0000_0010), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 1), machine.v[0xF]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // 0x9 tests ------------------------------------------------------------------

    test "9XY0 skips the next instruction when VX differs from VY" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6143 -> V1 = 0x43
            0x61, 0x43,
            // 0x204: 9010 -> V0 != V1, so skip
            0x90, 0x10,
            // 0x206: 6299 -> must never run
            0x62, 0x99,
            // 0x208: 62AA -> V2 = 0xAA
            0x62, 0xAA,
        });

        for (0..3) |_| {
            try machine.step();
        }

        // pc moved 4 over the 9XY0: two for itself, two more for the skip
        try std.testing.expectEqual(@as(u16, 0x208), machine.pc);

        // and the skipped instruction really did not run
        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[2]);
    }

    test "9XY0 does not skip when VX equals VY" {
        var machine = testMachine(&.{
            // 0x200: 6042 -> V0 = 0x42
            0x60, 0x42,
            // 0x202: 6142 -> V1 = 0x42
            0x61, 0x42,
            // 0x204: 9010 -> V0 == V1, so no skip
            0x90, 0x10,
            // 0x206: 6299 -> V2 = 0x99
            0x62, 0x99,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x206), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0x99), machine.v[2]);
    }

    test "9XY0 reads registers X and Y, not V0 and V1" {
        var machine = testMachine(&.{
            // 0x200: 6001 -> V0 = 1
            0x60, 0x01,
            // 0x202: 6101 -> V1 = 1, so V0 == V1
            0x61, 0x01,
            // 0x204: 65AA -> V5 = 0xAA
            0x65, 0xAA,
            // 0x206: 6A33 -> VA = 0x33
            0x6A, 0x33,
            // 0x208: 95A0 -> V5 != VA, so skip
            //         comparing V0 to V1 instead would find them equal and not skip
            0x95, 0xA0,
            // 0x20A: filler, skipped
            0x00, 0x00,
        });

        for (0..5) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x20C), machine.pc);
    }

    test "9XY0 does not skip when both registers are still zero" {
        var machine = testMachine(&.{
            // 0x200: 9340 -> V3 and V4 both start at 0, so no skip
            0x93, 0x40,
            // 0x202: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x202), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    test "9XY0 never skips when X and Y name the same register" {
        var machine = testMachine(&.{
            // 0x200: 6377 -> V3 = 0x77
            0x63, 0x77,
            // 0x202: 9330 -> V3 != V3 is never true, so no skip
            0x93, 0x30,
            // 0x204: 60AA -> V0 = 0xAA
            0x60, 0xAA,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);

        try machine.step();
        try std.testing.expectEqual(@as(u8, 0xAA), machine.v[0]);
    }

    // 9XY1 tests

    test "9XY1 is not a valid instruction" {
        // the pattern is 9XY0, so anything else in the last slot is unknown
        var machine = testMachine(&.{ 0x90, 0x11 });
        try std.testing.expectError(error.UnknownOpcode, machine.step());
    }

    // 0xA tests ------------------------------------------------------------------
    test "ANNN sets the index register" {
        var machine = testMachine(&.{ 0xA2, 0xF0 });
        try machine.step();
        try std.testing.expectEqual(@as(u16, 0x2F0), machine.i);
    }

    // 0xB tests ------------------------------------------------------------------

    test "BNNN jumps to NNN plus V0" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: B300 -> pc = 0x300 + V0
            0xB3, 0x00,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x302), machine.pc);
    }

    test "BNNN with V0 at zero is a plain jump to NNN" {
        var machine = testMachine(&.{
            // 0x200: B246 -> pc = 0x246 + 0
            0xB2, 0x46,
        });

        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x246), machine.pc);
    }

    test "BNNN offsets by V0, not by VX" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: 6310 -> V3 = 0x10
            0x63, 0x10,
            // 0x204: B300 -> pc = 0x300 + V0
            //         reading it as BXNN and offsetting by V3 would land on 0x310
            0xB3, 0x00,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x302), machine.pc);
    }

    test "BNNN carries the offset past a page boundary" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: B2FF -> 0x2FF + 2 crosses into 0x3xx
            0xB2, 0xFF,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x301), machine.pc);
    }

    test "BNNN adds the full byte of V0" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF, the largest offset there is
            0x60, 0xFF,
            // 0x202: B300 -> pc = 0x300 + 0xFF
            0xB3, 0x00,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u16, 0x3FF), machine.pc);
    }

    test "BNNN leaves V0, I and the stack alone" {
        var machine = testMachine(&.{
            // 0x200: 6002 -> V0 = 0x02
            0x60, 0x02,
            // 0x202: A123 -> I = 0x123
            0xA1, 0x23,
            // 0x204: B300 -> pc = 0x300 + V0
            0xB3, 0x00,
        });

        for (0..3) |_| {
            try machine.step();
        }

        try std.testing.expectEqual(@as(u16, 0x302), machine.pc);

        // a jump is not a call, nothing is pushed and nothing else moves
        try std.testing.expectEqual(@as(u8, 0x02), machine.v[0]);
        try std.testing.expectEqual(@as(u16, 0x123), machine.i);
        try std.testing.expectEqual(@as(u8, 0), machine.sp);
    }

    // 0xC tests ------------------------------------------------------------------

    test "CXNN with NN of zero always yields zero" {
        var machine = testMachine(&.{
            // 0x200: C000 -> V0 = random & 0x00
            0xC0, 0x00,
        });

        // masking with zero leaves nothing, so this one is fully deterministic
        for (0..64) |_| {
            machine.pc = 0x200;
            try machine.step();
            try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
        }
    }

    test "CXNN never sets a bit that is clear in NN" {
        var machine = testMachine(&.{
            // 0x200: C0A5 -> V0 = random & 0b1010_0101
            0xC0, 0xA5,
        });

        for (0..64) |_| {
            machine.pc = 0x200;
            try machine.step();

            // every bit outside the mask must be off
            try std.testing.expectEqual(@as(u8, 0), machine.v[0] & ~@as(u8, 0xA5));
        }
    }

    test "CXNN keeps the result inside the mask" {
        var machine = testMachine(&.{
            // 0x200: C00F -> V0 = random & 0x0F
            0xC0, 0x0F,
        });

        for (0..64) |_| {
            machine.pc = 0x200;
            try machine.step();
            try std.testing.expect(machine.v[0] <= 0x0F);
        }
    }

    test "CXNN writes register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: 60FF -> V0 = 0xFF
            0x60, 0xFF,
            // 0x202: 65FF -> V5 = 0xFF
            0x65, 0xFF,
            // 0x204: C50F -> V5 = random & 0x0F
            0xC5, 0x0F,
        });

        try machine.step();
        try machine.step();

        for (0..64) |_| {
            machine.pc = 0x204;
            try machine.step();

            // the mask caps V5 well below the 0xFF it started at
            try std.testing.expect(machine.v[5] <= 0x0F);

            // and V0 is never touched
            try std.testing.expectEqual(@as(u8, 0xFF), machine.v[0]);
        }
    }

    test "CXNN does not always return the same value" {
        var machine = testMachine(&.{
            // 0x200: C0FF -> V0 = random & 0xFF
            0xC0, 0xFF,
        });

        try machine.step();
        const first = machine.v[0];

        var saw_a_different_value = false;
        for (0..64) |_| {
            machine.pc = 0x200;
            try machine.step();
            if (machine.v[0] != first) {
                saw_a_different_value = true;
                break;
            }
        }

        // 64 identical draws would mean the source is not random at all
        try std.testing.expect(saw_a_different_value);
    }

    test "CXNN can produce values above 0x7F" {
        var machine = testMachine(&.{
            // 0x200: C0FF -> V0 = random & 0xFF
            0xC0, 0xFF,
        });

        var saw_high_bit = false;
        for (0..64) |_| {
            machine.pc = 0x200;
            try machine.step();
            if (machine.v[0] > 0x7F) {
                saw_high_bit = true;
                break;
            }
        }

        // catches a source that only ever fills seven bits
        try std.testing.expect(saw_high_bit);
    }

    test "CXNN leaves the flag register and pc alone" {
        var machine = testMachine(&.{
            // 0x200: 6F5A -> VF = 0x5A
            0x6F, 0x5A,
            // 0x202: C0FF -> V0 = random & 0xFF
            0xC0, 0xFF,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x5A), machine.v[0xF]);

        // a plain two byte advance, no skip
        try std.testing.expectEqual(@as(u16, 0x204), machine.pc);
    }

    // 0xD tests ------------------------------------------------------------------
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

    // 0xE tests ------------------------------------------------------------------

    // 0xF tests ------------------------------------------------------------------

    test "FX07 copies the delay timer into VX" {
        var machine = testMachine(&.{
            // 0x200: F007 -> V0 = delay timer
            0xF0, 0x07,
        });
        machine.delay_timer = 0x2A;

        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.v[0]);

        // reading the timer does not consume it
        try std.testing.expectEqual(@as(u8, 0x2A), machine.delay_timer);
    }

    test "FX07 overwrites VX even when the timer is zero" {
        var machine = testMachine(&.{
            // 0x200: 6099 -> V0 = 0x99
            0x60, 0x99,
            // 0x202: F007 -> V0 = delay timer, which is still 0
            0xF0, 0x07,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    test "FX07 writes register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: F507 -> V5 = delay timer
            0xF5, 0x07,
        });
        machine.delay_timer = 0x2A;

        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.v[5]);
        try std.testing.expectEqual(@as(u8, 0), machine.v[0]);
    }

    // FX15 tests
    test "FX15 sets the delay timer from VX" {
        var machine = testMachine(&.{
            // 0x200: 602A -> V0 = 0x2A
            0x60, 0x2A,
            // 0x202: F015 -> delay timer = V0
            0xF0, 0x15,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.delay_timer);

        // the register is the source, it stays put
        try std.testing.expectEqual(@as(u8, 0x2A), machine.v[0]);
    }

    test "FX15 can set the delay timer back to zero" {
        var machine = testMachine(&.{
            // 0x200: F015 -> delay timer = V0, which is still 0
            0xF0, 0x15,
        });
        machine.delay_timer = 0x2A;

        try machine.step();

        try std.testing.expectEqual(@as(u8, 0), machine.delay_timer);
    }

    test "FX15 does not touch the sound timer" {
        var machine = testMachine(&.{
            // 0x200: 602A -> V0 = 0x2A
            0x60, 0x2A,
            // 0x202: F015 -> delay timer = V0
            0xF0, 0x15,
        });
        machine.sound_timer = 0x11;

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.delay_timer);
        try std.testing.expectEqual(@as(u8, 0x11), machine.sound_timer);
    }

    test "FX15 reads register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: 652A -> V5 = 0x2A
            0x65, 0x2A,
            // 0x202: F515 -> delay timer = V5
            0xF5, 0x15,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.delay_timer);
    }

    // FX18 tests
    test "FX18 sets the sound timer from VX" {
        var machine = testMachine(&.{
            // 0x200: 602A -> V0 = 0x2A
            0x60, 0x2A,
            // 0x202: F018 -> sound timer = V0
            0xF0, 0x18,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.sound_timer);
        try std.testing.expectEqual(@as(u8, 0x2A), machine.v[0]);
    }

    test "FX18 does not touch the delay timer" {
        var machine = testMachine(&.{
            // 0x200: 602A -> V0 = 0x2A
            0x60, 0x2A,
            // 0x202: F018 -> sound timer = V0
            0xF0, 0x18,
        });
        machine.delay_timer = 0x11;

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.sound_timer);
        try std.testing.expectEqual(@as(u8, 0x11), machine.delay_timer);
    }

    test "FX18 reads register X, not V0" {
        var machine = testMachine(&.{
            // 0x200: 652A -> V5 = 0x2A
            0x65, 0x2A,
            // 0x202: F518 -> sound timer = V5
            0xF5, 0x18,
        });

        try machine.step();
        try machine.step();

        try std.testing.expectEqual(@as(u8, 0x2A), machine.sound_timer);
    }
};
