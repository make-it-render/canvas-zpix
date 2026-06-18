//! A Renderer that captures canvas output to an in-memory pixel buffer.
//! Implements the canvas Renderer vtable, enabling headless rendering
//! without a display server. Useful for testing and CI.

pixels: []u8,
width: u16,
height: u16,
allocator: std.mem.Allocator,

const ImageRenderer = @This();

const TileImage = struct {
    size: Renderer.Size,
    pixels: []u8,
    allocator: std.mem.Allocator,
};

pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !ImageRenderer {
    const pixel_count = @as(usize, width) * @as(usize, height) * 4;
    const pixels = try allocator.alloc(u8, pixel_count);
    @memset(pixels, 0);
    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

pub fn deinit(self: *ImageRenderer) void {
    self.allocator.free(self.pixels);
    self.* = undefined;
}

/// Get the type-erased Renderer interface.
pub fn renderer(self: *ImageRenderer) Renderer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Get the raw pixel buffer.
pub fn getPixels(self: *const ImageRenderer) []const u8 {
    return self.pixels;
}

/// Get the RGBA value at a specific pixel coordinate.
pub fn getPixel(self: *const ImageRenderer, x: u16, y: u16) [4]u8 {
    if (x >= self.width or y >= self.height) return .{ 0, 0, 0, 0 };
    const offset = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
    return self.pixels[offset..][0..4].*;
}

/// Save the pixel buffer to a PNG file.
pub fn savePng(self: *const ImageRenderer, io: std.Io, path: []const u8) !void {
    var zpix_img = zpix.Image{
        .width = self.width,
        .height = self.height,
        .channels = 4,
        .data = self.pixels,
        .allocator = self.allocator,
    };
    try zpix.savePngFile(io, &zpix_img, path);
}

const vtable = Renderer.VTable{
    .beginDraw = beginDrawImpl,
    .endDraw = endDrawImpl,
    .clear = clearImpl,
    .createImage = createImageImpl,
    .destroyImage = destroyImageImpl,
    .setPixels = setPixelsImpl,
    .drawImage = drawImageImpl,
};

fn beginDrawImpl(_: *Renderer) anyerror!void {}

fn endDrawImpl(_: *Renderer) anyerror!void {}

fn clearImpl(r: *Renderer, bbox: Renderer.BBox) anyerror!void {
    const self: *ImageRenderer = @ptrCast(@alignCast(r.ptr));

    const x0: usize = if (bbox.x < 0) 0 else @intCast(bbox.x);
    const y0: usize = if (bbox.y < 0) 0 else @intCast(bbox.y);
    const x1 = @min(x0 + @as(usize, bbox.width), @as(usize, self.width));
    const y1 = @min(y0 + @as(usize, bbox.height), @as(usize, self.height));

    const stride = @as(usize, self.width) * 4;
    for (y0..y1) |y| {
        const row_start = y * stride + x0 * 4;
        const row_end = y * stride + x1 * 4;
        @memset(self.pixels[row_start..row_end], 0);
    }
}

fn createImageImpl(r: *Renderer, size: Renderer.Size) anyerror!Renderer.Image {
    const self: *ImageRenderer = @ptrCast(@alignCast(r.ptr));
    const img = try self.allocator.create(TileImage);
    errdefer self.allocator.destroy(img);
    const pixel_count = @as(usize, size.width) * @as(usize, size.height) * 4;
    const pixels = try self.allocator.alloc(u8, pixel_count);
    img.* = .{ .size = size, .pixels = pixels, .allocator = self.allocator };
    return @ptrCast(img);
}

fn destroyImageImpl(_: *Renderer, image: Renderer.Image) void {
    const img: *TileImage = @ptrCast(@alignCast(image));
    img.allocator.free(img.pixels);
    img.allocator.destroy(img);
}

fn setPixelsImpl(_: *Renderer, image: Renderer.Image, pixels: []const u8) void {
    const img: *TileImage = @ptrCast(@alignCast(image));
    const len = @min(pixels.len, img.pixels.len);
    @memcpy(img.pixels[0..len], pixels[0..len]);
}

fn drawImageImpl(r: *Renderer, image: Renderer.Image, bbox: Renderer.BBox) anyerror!void {
    const self: *ImageRenderer = @ptrCast(@alignCast(r.ptr));
    const img: *TileImage = @ptrCast(@alignCast(image));

    // Source dimensions from the tile image.
    const src_w: usize = img.size.width;
    const src_h: usize = img.size.height;
    if (src_w == 0 or src_h == 0) return;

    // Destination bbox on the main buffer.
    const dst_w: usize = bbox.width;
    const dst_h: usize = bbox.height;
    if (dst_w == 0 or dst_h == 0) return;

    const dst_stride: usize = @as(usize, self.width) * 4;
    const src_stride: usize = src_w * 4;

    // Clip destination to the main buffer.
    const dx0: usize = if (bbox.x < 0) 0 else @intCast(bbox.x);
    const dy0: usize = if (bbox.y < 0) 0 else @intCast(bbox.y);
    const dx1 = @min(dx0 + dst_w, @as(usize, self.width));
    const dy1 = @min(dy0 + dst_h, @as(usize, self.height));

    // Source offset for clipping (when bbox.x or bbox.y is negative).
    const src_x_off: usize = if (bbox.x < 0) @intCast(-@as(i32, bbox.x)) else 0;
    const src_y_off: usize = if (bbox.y < 0) @intCast(-@as(i32, bbox.y)) else 0;

    for (dy0..dy1) |dy| {
        const sy = src_y_off + (dy - dy0);
        if (sy >= src_h) break;

        for (dx0..dx1) |dx| {
            const sx = src_x_off + (dx - dx0);
            if (sx >= src_w) break;

            const src_offset = sy * src_stride + sx * 4;
            const dst_offset = dy * dst_stride + dx * 4;

            const src_pixel = img.pixels[src_offset..][0..4];
            const sa = src_pixel[3];

            if (sa == 0) continue;

            if (sa == 255) {
                @memcpy(self.pixels[dst_offset..][0..4], src_pixel);
            } else {
                // Source-over alpha blending.
                const dst_pixel = self.pixels[dst_offset..][0..4];
                const da = dst_pixel[3];

                const sa_f: u16 = sa;
                const inv_sa: u16 = 255 - sa;

                const out_a: u16 = sa_f + ((@as(u16, da) * inv_sa + 127) / 255);

                if (out_a == 0) continue;

                inline for (0..3) |c| {
                    const src_c: u16 = src_pixel[c];
                    const dst_c: u16 = dst_pixel[c];
                    self.pixels[dst_offset + c] = @intCast((src_c * sa_f + dst_c * inv_sa + 127) / 255);
                }
                self.pixels[dst_offset + 3] = @intCast(@min(out_a, 255));
            }
        }
    }
}

const std = @import("std");
const Renderer = @import("canvas").Renderer;
const zpix = @import("zpix");

test "init creates zeroed pixel buffer" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 4, 4);
    defer ir.deinit();

    try std.testing.expectEqual(@as(u16, 4), ir.width);
    try std.testing.expectEqual(@as(u16, 4), ir.height);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), ir.pixels.len);

    for (ir.pixels) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "clear zeroes pixels in bbox" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 4, 4);
    defer ir.deinit();

    // Fill with non-zero data.
    @memset(ir.pixels, 0xFF);

    var r = ir.renderer();
    try r.clear(.{ .x = 1, .y = 1, .width = 2, .height = 2 });

    // (1,1) should be cleared.
    const p11 = ir.getPixel(1, 1);
    try std.testing.expectEqual(@as(u8, 0), p11[0]);
    try std.testing.expectEqual(@as(u8, 0), p11[3]);

    // (0,0) should still be 0xFF.
    const p00 = ir.getPixel(0, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), p00[0]);
}

test "createImage, setPixels, drawImage blits onto main buffer" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 4, 4);
    defer ir.deinit();

    var r = ir.renderer();

    const img = try r.createImage(.{ .width = 2, .height = 2 });
    defer r.destroyImage(img);

    // Set tile pixels to solid red.
    const red_pixels = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255,
        255, 0, 0, 255, 255, 0, 0, 255,
    };
    r.setPixels(img, &red_pixels);

    // Draw at (1,1) with 2x2 bbox.
    try r.drawImage(img, .{ .x = 1, .y = 1, .width = 2, .height = 2 });

    // (1,1) should be red.
    const p11 = ir.getPixel(1, 1);
    try std.testing.expectEqual(@as(u8, 255), p11[0]);
    try std.testing.expectEqual(@as(u8, 0), p11[1]);
    try std.testing.expectEqual(@as(u8, 0), p11[2]);
    try std.testing.expectEqual(@as(u8, 255), p11[3]);

    // (2,2) should be red.
    const p22 = ir.getPixel(2, 2);
    try std.testing.expectEqual(@as(u8, 255), p22[0]);
    try std.testing.expectEqual(@as(u8, 0), p22[1]);
    try std.testing.expectEqual(@as(u8, 0), p22[2]);
    try std.testing.expectEqual(@as(u8, 255), p22[3]);

    // (0,0) should be transparent.
    const p00 = ir.getPixel(0, 0);
    try std.testing.expectEqual(@as(u8, 0), p00[0]);
    try std.testing.expectEqual(@as(u8, 0), p00[3]);
}

test "drawImage with alpha blending" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 2, 2);
    defer ir.deinit();

    // Fill the main buffer with opaque white.
    for (0..ir.pixels.len / 4) |i| {
        ir.pixels[i * 4 + 0] = 255;
        ir.pixels[i * 4 + 1] = 255;
        ir.pixels[i * 4 + 2] = 255;
        ir.pixels[i * 4 + 3] = 255;
    }

    var r = ir.renderer();

    const img = try r.createImage(.{ .width = 1, .height = 1 });
    defer r.destroyImage(img);

    // 50% alpha red.
    const semi_red = [_]u8{ 255, 0, 0, 128 };
    r.setPixels(img, &semi_red);

    try r.drawImage(img, .{ .x = 0, .y = 0, .width = 1, .height = 1 });

    const p = ir.getPixel(0, 0);
    // Alpha should be 255 (opaque base + anything = opaque).
    try std.testing.expectEqual(@as(u8, 255), p[3]);
    // Red channel should be blended: (255*128 + 255*127 + 127) / 255 = 255.
    try std.testing.expectEqual(@as(u8, 255), p[0]);
    // Green/blue: (0*128 + 255*127 + 127) / 255 ~ 127.
    try std.testing.expect(p[1] >= 126 and p[1] <= 128);
    try std.testing.expect(p[2] >= 126 and p[2] <= 128);
}

test "getPixel out of bounds returns zeroes" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 2, 2);
    defer ir.deinit();

    @memset(ir.pixels, 0xFF);

    const p = ir.getPixel(10, 10);
    try std.testing.expectEqual(@as(u8, 0), p[0]);
    try std.testing.expectEqual(@as(u8, 0), p[3]);
}

test "beginDraw and endDraw are no-ops" {
    const allocator = std.testing.allocator;
    var ir = try ImageRenderer.init(allocator, 2, 2);
    defer ir.deinit();

    var r = ir.renderer();
    try r.beginDraw();
    try r.endDraw();
}
