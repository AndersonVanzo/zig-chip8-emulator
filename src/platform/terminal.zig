const std = @import("std");

const Display = @import("../core/Display.zig");

// each character cell holds two vertically stacked pixels
// a terminal cell is about twice as tall as it is wide, so splitting it in
// half vertically makes each chip-8 pixel come out square
const both = "█"; // U+2588 full block
const upper = "▀"; // U+2580 upper half block
const lower = "▄"; // U+2584 lower half block
const neither = " ";

fn cell(top: bool, bottom: bool) []const u8 {
    if (top and bottom) {
        return both;
    }
    if (top) {
        return upper;
    }
    if (bottom) {
        return lower;
    }
    return neither;
}

pub fn render(display: *const Display, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // two display rows per output line, so 32 rows print as 16 lines
    var y: usize = 0;
    while (y < Display.display_height) : (y += 2) {
        for (0..Display.display_width) |x| {
            try writer.writeAll(cell(display.get(x, y), display.get(x, y + 1)));
        }
        try writer.writeByte('\n');
    }
}
