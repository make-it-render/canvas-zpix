//! A decoded image holding RGBA pixel data.
//! Provides convenience methods for drawing onto a canvas Surface.

pixels: []const u8,
width: u16,
height: u16,
allocator: std.mem.Allocator,

/// Load an image from a file path (PNG or JPEG, auto-detected).
pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
    var zpix_img = try zpix.loadFile(allocator, path);
    defer zpix_img.deinit();
    return initFromZpix(allocator, &zpix_img);
}

/// Load an image from a memory buffer (PNG or JPEG, auto-detected).
pub fn initFromMemory(allocator: std.mem.Allocator, data: []const u8) !@This() {
    const format = zpix.detectFormat(data);
    var zpix_img = switch (format) {
        .png => try zpix.loadPngMemory(allocator, data),
        .jpeg => try zpix.loadJpegMemory(allocator, data),
        .unknown => return error.UnsupportedFormat,
    };
    defer zpix_img.deinit();
    return initFromZpix(allocator, &zpix_img);
}

/// Convert a zpix Image to an RGBA canvas Image.
fn initFromZpix(allocator: std.mem.Allocator, zpix_img: *zpix.Image) !@This() {
    if (zpix_img.width > std.math.maxInt(u16) or zpix_img.height > std.math.maxInt(u16))
        return error.ImageTooLarge;
    const width: u16 = @intCast(zpix_img.width);
    const height: u16 = @intCast(zpix_img.height);
    const pixel_count = @as(usize, width) * @as(usize, height);

    const rgba = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(rgba);

    switch (zpix_img.channels) {
        4 => {
            // Already RGBA — direct copy.
            @memcpy(rgba, zpix_img.data[0 .. pixel_count * 4]);
        },
        3 => {
            // RGB → RGBA: insert alpha=255.
            for (0..pixel_count) |i| {
                rgba[i * 4 + 0] = zpix_img.data[i * 3 + 0];
                rgba[i * 4 + 1] = zpix_img.data[i * 3 + 1];
                rgba[i * 4 + 2] = zpix_img.data[i * 3 + 2];
                rgba[i * 4 + 3] = 255;
            }
        },
        2 => {
            // Grayscale+Alpha → RGBA.
            for (0..pixel_count) |i| {
                const gray = zpix_img.data[i * 2];
                rgba[i * 4 + 0] = gray;
                rgba[i * 4 + 1] = gray;
                rgba[i * 4 + 2] = gray;
                rgba[i * 4 + 3] = zpix_img.data[i * 2 + 1];
            }
        },
        1 => {
            // Grayscale → RGBA.
            for (0..pixel_count) |i| {
                const gray = zpix_img.data[i];
                rgba[i * 4 + 0] = gray;
                rgba[i * 4 + 1] = gray;
                rgba[i * 4 + 2] = gray;
                rgba[i * 4 + 3] = 255;
            }
        },
        else => {
            allocator.free(rgba);
            return error.UnsupportedChannelCount;
        },
    }

    return .{
        .pixels = rgba,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

/// Create an Image from pre-decoded RGBA pixel data.
/// Takes ownership of a copy of the pixel data.
pub fn initFromRgba(allocator: std.mem.Allocator, pixels: []const u8, width: u16, height: u16) !@This() {
    const expected_len = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len < expected_len) return error.InvalidPixelData;
    const owned = try allocator.alloc(u8, expected_len);
    @memcpy(owned, pixels[0..expected_len]);
    return .{
        .pixels = owned,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(@constCast(self.pixels));
    self.* = undefined;
}

/// Draw this image onto a surface at the given position.
pub fn draw(self: @This(), surface: *Surface, x: i32, y: i32) void {
    surface.drawImage(self.pixels, self.width, self.height, x, y);
}

/// Draw a rectangular region of this image onto a surface.
/// Extracts the sub-rectangle from the source pixels and draws it at (dst_x, dst_y).
pub fn drawRegion(
    self: @This(),
    surface: *Surface,
    src_x: u16,
    src_y: u16,
    src_w: u16,
    src_h: u16,
    dst_x: i32,
    dst_y: i32,
) void {
    if (src_w == 0 or src_h == 0) return;
    if (src_x + src_w > self.width or src_y + src_h > self.height) return;

    // Build a contiguous sub-image buffer for drawImage.
    // No allocation — use a stack buffer for small regions, otherwise
    // fall back to the allocator.
    const region_len = @as(usize, src_w) * @as(usize, src_h) * 4;
    const stride = @as(usize, self.width) * 4;

    // Try stack allocation for regions up to 256x256 (256 KiB).
    if (region_len <= 256 * 256 * 4) {
        var buf: [256 * 256 * 4]u8 = undefined;
        self.copyRegion(buf[0..region_len], src_x, src_y, src_w, src_h, stride);
        surface.drawImage(buf[0..region_len], src_w, src_h, dst_x, dst_y);
    } else {
        const buf = self.allocator.alloc(u8, region_len) catch return;
        defer self.allocator.free(buf);
        self.copyRegion(buf, src_x, src_y, src_w, src_h, stride);
        surface.drawImage(buf, src_w, src_h, dst_x, dst_y);
    }
}

fn copyRegion(self: @This(), dst: []u8, src_x: u16, src_y: u16, src_w: u16, src_h: u16, stride: usize) void {
    const row_bytes = @as(usize, src_w) * 4;
    for (0..src_h) |row| {
        const src_offset = (@as(usize, src_y) + row) * stride + @as(usize, src_x) * 4;
        const dst_offset = row * row_bytes;
        @memcpy(dst[dst_offset..][0..row_bytes], self.pixels[src_offset..][0..row_bytes]);
    }
}

const std = @import("std");
const canvas = @import("canvas");
const zpix = @import("zpix");
const Surface = canvas.Surface;
const Canvas = canvas.Canvas;
const Renderer = canvas.Renderer;
const ImageRenderer = @import("image_renderer.zig");

test "initFromRgba creates image with correct dimensions" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    var img = try initFromRgba(allocator, &pixels, 2, 2);
    defer img.deinit();

    try std.testing.expectEqual(@as(u16, 2), img.width);
    try std.testing.expectEqual(@as(u16, 2), img.height);
    try std.testing.expectEqual(@as(usize, 16), img.pixels.len);
    try std.testing.expectEqualSlices(u8, &pixels, img.pixels);
}

test "initFromRgba rejects too-short pixel data" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const result = initFromRgba(allocator, &pixels, 2, 2);
    try std.testing.expectError(error.InvalidPixelData, result);
}

test "draw calls surface.drawImage with correct arguments" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    var img = try initFromRgba(allocator, &pixels, 2, 2);
    defer img.deinit();

    // Create a 4x4 surface buffer and draw the 2x2 image at (1,1).
    const buf = try allocator.alloc(u8, 4 * 4 * 4);
    defer allocator.free(buf);
    @memset(buf, 0);

    var surface: Surface = .{
        .pixel_buffer = buf,
        .width = 4,
        .height = 4,
        .allocator = allocator,
    };
    img.draw(&surface, 1, 1);

    // Pixel (1,1) should be red (first pixel of the image).
    const offset = (1 * 4 + 1) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, buf[offset..][0..4]);

    // Pixel (2,1) should be green (second pixel of first row).
    const offset2 = (1 * 4 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, buf[offset2..][0..4]);
}

test "drawRegion extracts correct sub-region" {
    const allocator = std.testing.allocator;
    // 3x3 image:
    // R G B
    // C M Y
    // K W X
    const pixels = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   255, 0,   0,   255, 255,
        0,   255, 255, 255, 255, 0,   255, 255, 255, 255, 0,   255,
        0,   0,   0,   255, 255, 255, 255, 255, 128, 128, 128, 255,
    };
    var img = try initFromRgba(allocator, &pixels, 3, 3);
    defer img.deinit();

    // Draw the 2x2 region starting at (1,1) onto a 2x2 surface.
    const buf = try allocator.alloc(u8, 2 * 2 * 4);
    defer allocator.free(buf);
    @memset(buf, 0);

    var surface: Surface = .{
        .pixel_buffer = buf,
        .width = 2,
        .height = 2,
        .allocator = allocator,
    };
    img.drawRegion(&surface, 1, 1, 2, 2, 0, 0);

    // (0,0) should be Magenta (1,1 in source)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 255, 255 }, buf[0..4]);
    // (1,0) should be Yellow (2,1 in source)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 0, 255 }, buf[4..8]);
    // (0,1) should be White (1,2 in source)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, buf[8..12]);
    // (1,1) should be Gray (2,2 in source)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 128, 128, 128, 255 }, buf[12..16]);
}

test "drawRegion with zero dimensions is a no-op" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    var img = try initFromRgba(allocator, &pixels, 1, 1);
    defer img.deinit();

    const buf = try allocator.alloc(u8, 2 * 2 * 4);
    defer allocator.free(buf);
    @memset(buf, 0);

    var surface: Surface = .{
        .pixel_buffer = buf,
        .width = 2,
        .height = 2,
        .allocator = allocator,
    };
    img.drawRegion(&surface, 0, 0, 0, 0, 0, 0);

    // Buffer should remain all zeroes.
    for (buf) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "drawRegion out of bounds is a no-op" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    var img = try initFromRgba(allocator, &pixels, 2, 2);
    defer img.deinit();

    const buf = try allocator.alloc(u8, 2 * 2 * 4);
    defer allocator.free(buf);
    @memset(buf, 0);

    var surface: Surface = .{
        .pixel_buffer = buf,
        .width = 2,
        .height = 2,
        .allocator = allocator,
    };
    // Region extends past image bounds.
    img.drawRegion(&surface, 1, 1, 2, 2, 0, 0);

    // Buffer should remain all zeroes (region was out of bounds).
    for (buf) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

// ── Integration tests: encode → decode roundtrip ─────────────────────────

/// Helper: create a 4x4 RGBA zpix image, encode to PNG bytes in memory.
fn createTestPng(allocator: std.mem.Allocator) ![]u8 {
    var zpix_img = try zpix.Image.init(allocator, 4, 4, 4);
    defer zpix_img.deinit();
    // Row 0: red, green, blue, white
    zpix_img.setPixel(0, 0, &[_]u8{ 255, 0, 0, 255 });
    zpix_img.setPixel(1, 0, &[_]u8{ 0, 255, 0, 255 });
    zpix_img.setPixel(2, 0, &[_]u8{ 0, 0, 255, 255 });
    zpix_img.setPixel(3, 0, &[_]u8{ 255, 255, 255, 255 });
    // Row 1: semi-transparent red
    zpix_img.setPixel(0, 1, &[_]u8{ 255, 0, 0, 128 });
    zpix_img.setPixel(1, 1, &[_]u8{ 0, 255, 0, 128 });
    zpix_img.setPixel(2, 1, &[_]u8{ 0, 0, 255, 128 });
    zpix_img.setPixel(3, 1, &[_]u8{ 128, 128, 128, 255 });
    return zpix.savePngMemory(allocator, &zpix_img);
}

/// Helper: create a 4x4 RGB zpix image, encode to JPEG bytes in memory.
fn createTestJpeg(allocator: std.mem.Allocator) ![]u8 {
    var zpix_img = try zpix.Image.init(allocator, 4, 4, 3);
    defer zpix_img.deinit();
    // Fill with solid red
    for (0..4) |y| {
        for (0..4) |x| {
            zpix_img.setPixel(@intCast(x), @intCast(y), &[_]u8{ 255, 0, 0 });
        }
    }
    return zpix.saveJpegMemory(allocator, &zpix_img, 100);
}

test "PNG roundtrip: encode → initFromMemory → verify pixels" {
    const allocator = std.testing.allocator;
    const png_bytes = try createTestPng(allocator);
    defer allocator.free(png_bytes);

    var img = try initFromMemory(allocator, png_bytes);
    defer img.deinit();

    try std.testing.expectEqual(@as(u16, 4), img.width);
    try std.testing.expectEqual(@as(u16, 4), img.height);

    // Verify pixel (0,0) is red
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, img.pixels[0..4]);
    // Verify pixel (1,0) is green
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, img.pixels[4..8]);
    // Verify pixel (2,0) is blue
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, img.pixels[8..12]);
    // Verify pixel (0,1) is semi-transparent red
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 128 }, img.pixels[16..20]);
}

test "JPEG roundtrip: encode → initFromMemory → verify pixels (lossy)" {
    const allocator = std.testing.allocator;
    const jpeg_bytes = try createTestJpeg(allocator);
    defer allocator.free(jpeg_bytes);

    var img = try initFromMemory(allocator, jpeg_bytes);
    defer img.deinit();

    try std.testing.expectEqual(@as(u16, 4), img.width);
    try std.testing.expectEqual(@as(u16, 4), img.height);

    // JPEG is lossy and has no alpha — verify red channel is high, alpha is 255
    // (RGB→RGBA conversion adds alpha=255)
    try std.testing.expect(img.pixels[0] > 200); // R high
    try std.testing.expect(img.pixels[3] == 255); // A = 255 (added by conversion)
}

test "PNG load → draw to surface → verify compositing" {
    const allocator = std.testing.allocator;
    const png_bytes = try createTestPng(allocator);
    defer allocator.free(png_bytes);

    var img = try initFromMemory(allocator, png_bytes);
    defer img.deinit();

    // Create a 6x6 surface and draw the 4x4 image at (1,1)
    const buf = try allocator.alloc(u8, 6 * 6 * 4);
    defer allocator.free(buf);
    @memset(buf, 0);

    var surface: Surface = .{
        .pixel_buffer = buf,
        .width = 6,
        .height = 6,
        .allocator = allocator,
    };
    img.draw(&surface, 1, 1);

    // (0,0) should be transparent black (outside image)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, buf[0..4]);
    // (1,1) should be red (first pixel of image)
    const offset_1_1 = (1 * 6 + 1) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, buf[offset_1_1..][0..4]);
    // (2,1) should be green
    const offset_2_1 = (1 * 6 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, buf[offset_2_1..][0..4]);
}

test "full pipeline: draw scene → ImageRenderer → PNG → reload → verify" {
    const allocator = std.testing.allocator;

    // 1. Render a scene to ImageRenderer
    var img_renderer = try ImageRenderer.init(allocator, 8, 8);
    defer img_renderer.deinit();
    var canv = Canvas.init(allocator, img_renderer.renderer());
    defer canv.deinit();

    const surface = try canv.createSurface(.{ .width = 8, .height = 8 });
    surface.setFillColor(.{ 255, 0, 0, 255 });
    surface.fillRect(0, 0, 4, 4); // Red square in top-left
    surface.setFillColor(.{ 0, 0, 255, 255 });
    surface.fillRect(4, 0, 4, 4); // Blue square in top-right
    try canv.draw();

    // 2. Verify ImageRenderer has the pixels
    const red_pixel = img_renderer.getPixel(1, 1);
    try std.testing.expectEqual(@as(u8, 255), red_pixel[0]);
    try std.testing.expectEqual(@as(u8, 0), red_pixel[2]);
    const blue_pixel = img_renderer.getPixel(5, 1);
    try std.testing.expectEqual(@as(u8, 0), blue_pixel[0]);
    try std.testing.expectEqual(@as(u8, 255), blue_pixel[2]);

    // 3. Encode to PNG in memory
    var zpix_img = zpix.Image{
        .width = img_renderer.width,
        .height = img_renderer.height,
        .channels = 4,
        .data = img_renderer.pixels,
        .allocator = allocator,
    };
    const png_bytes = try zpix.savePngMemory(allocator, &zpix_img);
    defer allocator.free(png_bytes);

    // 4. Reload from PNG bytes
    var loaded = try initFromMemory(allocator, png_bytes);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u16, 8), loaded.width);
    try std.testing.expectEqual(@as(u16, 8), loaded.height);

    // 5. Verify pixels survived the roundtrip
    // (1,1) should be red
    const loaded_offset_1_1: usize = (1 * 8 + 1) * 4;
    try std.testing.expectEqual(@as(u8, 255), loaded.pixels[loaded_offset_1_1]);
    try std.testing.expectEqual(@as(u8, 0), loaded.pixels[loaded_offset_1_1 + 2]);
    // (5,1) should be blue
    const loaded_offset_5_1: usize = (1 * 8 + 5) * 4;
    try std.testing.expectEqual(@as(u8, 0), loaded.pixels[loaded_offset_5_1]);
    try std.testing.expectEqual(@as(u8, 255), loaded.pixels[loaded_offset_5_1 + 2]);
}

test "initFromMemory rejects unknown format" {
    const allocator = std.testing.allocator;
    const garbage = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    const result = initFromMemory(allocator, &garbage);
    try std.testing.expectError(error.UnsupportedFormat, result);
}
