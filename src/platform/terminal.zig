const std = @import("std");

const Display = @import("../core/Display.zig");

// filled block for a lit pixel
const on = "█";
const off = " ";

pub fn render(display: *const Display, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..Display.display_height) |y| {
        for (0..Display.display_width) |x| {
            try writer.writeAll(if (display.get(x, y)) on else off);
        }
        try writer.writeByte('\n');
    }
}
