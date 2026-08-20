const std = @import("std");
const emulator = @import("zig_chip8_emulator");

// how many instructions to run before drawing
const cycle_budget = 200;

pub fn main(init: std.process.Init) !void {
    // lives as long as the process lives
    // so nothing allocated from it needs freeing
    const arena = init.arena.allocator();

    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: {s} <rom.ch8>\n", .{args[0]});
        return;
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(4096));
    var machine = emulator.Chip8.init();
    try machine.load(rom);

    for (0..cycle_budget) |_| {
        machine.step() catch |err| {
            std.debug.print("stopped near pc=0x{X:0>3}: {t}", .{ machine.pc, err });
            break;
        };
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try emulator.terminal.render(&machine.display, stdout);
    try stdout.flush();
}
