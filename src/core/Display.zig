const std = @import("std");

const Display = @This();

pub const display_width = 64;
pub const display_height = 32;

// one bool per pixel
pixels: [display_width * display_height]bool,

pub fn init() Display {
    // fills the array with `false`
    return .{ .pixels = @splat(false) };
}

pub fn clear(self: *@This()) void {
    self.pixels = @splat(false);
}

pub fn get(self: *const @This(), x: usize, y: usize) bool {
    return self.pixels[y * display_width + x];
}

// flips one pixel and returns it's previous state
//
// drawing over a lit pixel turns it off and vice-versa (basically a XOR)
pub fn xorPixel(self: *@This(), x: usize, y: usize) bool {
    const index = y * display_width + x;
    const was_on = self.pixels[index];
    self.pixels[index] = !was_on;
    return was_on;
}
