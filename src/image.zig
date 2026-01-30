const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8,
    data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32, channels: u8) !Image {
        const size = @as(usize, width) * @as(usize, height) * @as(usize, channels);
        const data = try allocator.alloc(u8, size);
        @memset(data, 0);
        return Image{
            .width = width,
            .height = height,
            .channels = channels,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn getPixel(self: *const Image, x: u32, y: u32) []const u8 {
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * @as(usize, self.channels);
        return self.data[idx .. idx + self.channels];
    }

    pub fn setPixel(self: *Image, x: u32, y: u32, pixel: []const u8) void {
        std.debug.assert(pixel.len == self.channels);
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * @as(usize, self.channels);
        @memcpy(self.data[idx .. idx + self.channels], pixel);
    }

    pub fn clone(self: *const Image, allocator: Allocator) !Image {
        const new_image = try Image.init(allocator, self.width, self.height, self.channels);
        @memcpy(new_image.data, self.data);
        return new_image;
    }

    pub fn crop(self: *const Image, x: u32, y: u32, crop_width: u32, crop_height: u32) !Image {
        // Validate bounds
        if (x + crop_width > self.width or y + crop_height > self.height) {
            return error.CropOutOfBounds;
        }
        if (crop_width == 0 or crop_height == 0) {
            return error.InvalidCropDimensions;
        }

        var result = try Image.init(self.allocator, crop_width, crop_height, self.channels);
        errdefer result.deinit();

        const src_stride = @as(usize, self.width) * @as(usize, self.channels);
        const dst_stride = @as(usize, crop_width) * @as(usize, self.channels);
        const x_offset = @as(usize, x) * @as(usize, self.channels);

        var row: usize = 0;
        while (row < crop_height) : (row += 1) {
            const src_row = @as(usize, y) + row;
            const src_start = src_row * src_stride + x_offset;
            const dst_start = row * dst_stride;
            @memcpy(result.data[dst_start..][0..dst_stride], self.data[src_start..][0..dst_stride]);
        }

        return result;
    }

    /// Resize image using bilinear interpolation
    pub fn resize(self: *const Image, new_width: u32, new_height: u32) !Image {
        if (new_width == 0 or new_height == 0) {
            return error.InvalidResizeDimensions;
        }

        var result = try Image.init(self.allocator, new_width, new_height, self.channels);
        errdefer result.deinit();

        const src_w = @as(f64, @floatFromInt(self.width));
        const src_h = @as(f64, @floatFromInt(self.height));
        const dst_w = @as(f64, @floatFromInt(new_width));
        const dst_h = @as(f64, @floatFromInt(new_height));

        const x_ratio = src_w / dst_w;
        const y_ratio = src_h / dst_h;

        var dst_y: u32 = 0;
        while (dst_y < new_height) : (dst_y += 1) {
            var dst_x: u32 = 0;
            while (dst_x < new_width) : (dst_x += 1) {
                // Map destination pixel to source coordinates
                const src_x_f = (@as(f64, @floatFromInt(dst_x)) + 0.5) * x_ratio - 0.5;
                const src_y_f = (@as(f64, @floatFromInt(dst_y)) + 0.5) * y_ratio - 0.5;

                // Get the four nearest source pixels
                const x0 = @as(u32, @intFromFloat(@max(0, @floor(src_x_f))));
                const y0 = @as(u32, @intFromFloat(@max(0, @floor(src_y_f))));
                const x1 = @min(x0 + 1, self.width - 1);
                const y1 = @min(y0 + 1, self.height - 1);

                // Calculate interpolation weights
                const x_weight = src_x_f - @floor(src_x_f);
                const y_weight = src_y_f - @floor(src_y_f);

                // Get the four pixels
                const p00 = self.getPixel(x0, y0);
                const p10 = self.getPixel(x1, y0);
                const p01 = self.getPixel(x0, y1);
                const p11 = self.getPixel(x1, y1);

                // Bilinear interpolation for each channel
                var pixel_buf: [4]u8 = undefined;
                for (0..self.channels) |ch| {
                    const v00 = @as(f64, @floatFromInt(p00[ch]));
                    const v10 = @as(f64, @floatFromInt(p10[ch]));
                    const v01 = @as(f64, @floatFromInt(p01[ch]));
                    const v11 = @as(f64, @floatFromInt(p11[ch]));

                    const top = v00 * (1.0 - x_weight) + v10 * x_weight;
                    const bottom = v01 * (1.0 - x_weight) + v11 * x_weight;
                    const value = top * (1.0 - y_weight) + bottom * y_weight;

                    pixel_buf[ch] = @intFromFloat(@round(@max(0, @min(255, value))));
                }

                result.setPixel(dst_x, dst_y, pixel_buf[0..self.channels]);
            }
        }

        return result;
    }

    /// Rotate image 90 degrees clockwise
    pub fn rotate90(self: *const Image) !Image {
        // Width and height swap
        var result = try Image.init(self.allocator, self.height, self.width, self.channels);
        errdefer result.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                // (x, y) -> (height - 1 - y, x) for 90° CW
                const new_x = self.height - 1 - y;
                const new_y = x;
                const pixel = self.getPixel(x, y);
                result.setPixel(new_x, new_y, pixel);
            }
        }

        return result;
    }

    /// Rotate image 180 degrees
    pub fn rotate180(self: *const Image) !Image {
        var result = try Image.init(self.allocator, self.width, self.height, self.channels);
        errdefer result.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                // (x, y) -> (width - 1 - x, height - 1 - y)
                const new_x = self.width - 1 - x;
                const new_y = self.height - 1 - y;
                const pixel = self.getPixel(x, y);
                result.setPixel(new_x, new_y, pixel);
            }
        }

        return result;
    }

    /// Rotate image 270 degrees clockwise (= 90 degrees counter-clockwise)
    pub fn rotate270(self: *const Image) !Image {
        // Width and height swap
        var result = try Image.init(self.allocator, self.height, self.width, self.channels);
        errdefer result.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                // (x, y) -> (y, width - 1 - x) for 90° CCW
                const new_x = y;
                const new_y = self.width - 1 - x;
                const pixel = self.getPixel(x, y);
                result.setPixel(new_x, new_y, pixel);
            }
        }

        return result;
    }

    /// Flip image horizontally (mirror left-right)
    pub fn flipHorizontal(self: *const Image) !Image {
        var result = try Image.init(self.allocator, self.width, self.height, self.channels);
        errdefer result.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const new_x = self.width - 1 - x;
                const pixel = self.getPixel(x, y);
                result.setPixel(new_x, y, pixel);
            }
        }

        return result;
    }

    /// Flip image vertically (mirror top-bottom)
    pub fn flipVertical(self: *const Image) !Image {
        var result = try Image.init(self.allocator, self.width, self.height, self.channels);
        errdefer result.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const new_y = self.height - 1 - y;
                const pixel = self.getPixel(x, y);
                result.setPixel(x, new_y, pixel);
            }
        }

        return result;
    }
};

test "Image.init creates image with correct dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 100, 50, 4);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 100), img.width);
    try std.testing.expectEqual(@as(u32, 50), img.height);
    try std.testing.expectEqual(@as(u8, 4), img.channels);
    try std.testing.expectEqual(@as(usize, 100 * 50 * 4), img.data.len);
}

test "Image.init initializes data to zero" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    for (img.data) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Image.setPixel and getPixel work correctly" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 4);
    defer img.deinit();

    const pixel = [_]u8{ 255, 128, 64, 255 };
    img.setPixel(5, 3, &pixel);

    const retrieved = img.getPixel(5, 3);
    try std.testing.expectEqualSlices(u8, &pixel, retrieved);
}

test "Image.clone creates independent copy" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    const pixel = [_]u8{ 100, 150, 200 };
    img.setPixel(2, 2, &pixel);

    var cloned = try img.clone(allocator);
    defer cloned.deinit();

    // Verify clone has same data
    try std.testing.expectEqualSlices(u8, &pixel, cloned.getPixel(2, 2));

    // Modify original, verify clone is independent
    const new_pixel = [_]u8{ 0, 0, 0 };
    img.setPixel(2, 2, &new_pixel);
    try std.testing.expectEqualSlices(u8, &pixel, cloned.getPixel(2, 2));
}

test "Image.crop extracts correct region" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    // Set some pixels in the region we'll crop
    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };

    img.setPixel(2, 2, &red);
    img.setPixel(3, 2, &green);
    img.setPixel(2, 3, &blue);

    // Crop a 3x3 region starting at (2, 2)
    var cropped = try img.crop(2, 2, 3, 3);
    defer cropped.deinit();

    try std.testing.expectEqual(@as(u32, 3), cropped.width);
    try std.testing.expectEqual(@as(u32, 3), cropped.height);
    try std.testing.expectEqual(@as(u8, 3), cropped.channels);

    // Verify pixels are at correct positions in cropped image
    try std.testing.expectEqualSlices(u8, &red, cropped.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &green, cropped.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &blue, cropped.getPixel(0, 1));
}

test "Image.crop rejects out of bounds" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    // Should fail: crop extends beyond image bounds
    try std.testing.expectError(error.CropOutOfBounds, img.crop(8, 8, 5, 5));
    try std.testing.expectError(error.CropOutOfBounds, img.crop(0, 0, 11, 10));
}

test "Image.crop rejects zero dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    try std.testing.expectError(error.InvalidCropDimensions, img.crop(0, 0, 0, 5));
    try std.testing.expectError(error.InvalidCropDimensions, img.crop(0, 0, 5, 0));
}

test "Image.resize produces correct dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    // Upscale
    var resized = try img.resize(20, 20);
    defer resized.deinit();

    try std.testing.expectEqual(@as(u32, 20), resized.width);
    try std.testing.expectEqual(@as(u32, 20), resized.height);
    try std.testing.expectEqual(@as(u8, 3), resized.channels);
}

test "Image.resize bilinear interpolation blends colors" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 1, 3);
    defer img.deinit();

    // Create a 2x1 image with black (0,0,0) on left and white (255,255,255) on right
    const black = [_]u8{ 0, 0, 0 };
    const white = [_]u8{ 255, 255, 255 };
    img.setPixel(0, 0, &black);
    img.setPixel(1, 0, &white);

    // Resize to 3x1 - middle pixel should be approximately gray
    var resized = try img.resize(3, 1);
    defer resized.deinit();

    const middle = resized.getPixel(1, 0);
    // Middle should be blended - roughly 127-128
    try std.testing.expect(middle[0] > 100 and middle[0] < 160);
    try std.testing.expect(middle[1] > 100 and middle[1] < 160);
    try std.testing.expect(middle[2] > 100 and middle[2] < 160);
}

test "Image.resize rejects zero dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    try std.testing.expectError(error.InvalidResizeDimensions, img.resize(0, 10));
    try std.testing.expectError(error.InvalidResizeDimensions, img.resize(10, 0));
}

test "Image.rotate90 rotates clockwise" {
    const allocator = std.testing.allocator;

    // Create a 3x2 image (width=3, height=2)
    var img = try Image.init(allocator, 3, 2, 3);
    defer img.deinit();

    // Set pixels with distinct colors
    // Row 0: R G B
    // Row 1: C M Y
    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const cyan = [_]u8{ 0, 255, 255 };
    const magenta = [_]u8{ 255, 0, 255 };
    const yellow = [_]u8{ 255, 255, 0 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(2, 0, &blue);
    img.setPixel(0, 1, &cyan);
    img.setPixel(1, 1, &magenta);
    img.setPixel(2, 1, &yellow);

    var rotated = try img.rotate90();
    defer rotated.deinit();

    // After 90° CW rotation, 3x2 becomes 2x3
    // Expected layout:
    // C R
    // M G
    // Y B
    try std.testing.expectEqual(@as(u32, 2), rotated.width);
    try std.testing.expectEqual(@as(u32, 3), rotated.height);

    try std.testing.expectEqualSlices(u8, &cyan, rotated.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &red, rotated.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &magenta, rotated.getPixel(0, 1));
    try std.testing.expectEqualSlices(u8, &green, rotated.getPixel(1, 1));
    try std.testing.expectEqualSlices(u8, &yellow, rotated.getPixel(0, 2));
    try std.testing.expectEqualSlices(u8, &blue, rotated.getPixel(1, 2));
}

test "Image.rotate180 rotates 180 degrees" {
    const allocator = std.testing.allocator;

    var img = try Image.init(allocator, 2, 2, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const white = [_]u8{ 255, 255, 255 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(0, 1, &blue);
    img.setPixel(1, 1, &white);

    var rotated = try img.rotate180();
    defer rotated.deinit();

    // Same dimensions
    try std.testing.expectEqual(@as(u32, 2), rotated.width);
    try std.testing.expectEqual(@as(u32, 2), rotated.height);

    // Pixels should be reversed
    try std.testing.expectEqualSlices(u8, &white, rotated.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &blue, rotated.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &green, rotated.getPixel(0, 1));
    try std.testing.expectEqualSlices(u8, &red, rotated.getPixel(1, 1));
}

test "Image.rotate270 rotates counter-clockwise" {
    const allocator = std.testing.allocator;

    var img = try Image.init(allocator, 3, 2, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const cyan = [_]u8{ 0, 255, 255 };
    const magenta = [_]u8{ 255, 0, 255 };
    const yellow = [_]u8{ 255, 255, 0 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(2, 0, &blue);
    img.setPixel(0, 1, &cyan);
    img.setPixel(1, 1, &magenta);
    img.setPixel(2, 1, &yellow);

    var rotated = try img.rotate270();
    defer rotated.deinit();

    // After 270° CW (= 90° CCW), 3x2 becomes 2x3
    // Expected layout:
    // B Y
    // G M
    // R C
    try std.testing.expectEqual(@as(u32, 2), rotated.width);
    try std.testing.expectEqual(@as(u32, 3), rotated.height);

    try std.testing.expectEqualSlices(u8, &blue, rotated.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &yellow, rotated.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &green, rotated.getPixel(0, 1));
    try std.testing.expectEqualSlices(u8, &magenta, rotated.getPixel(1, 1));
    try std.testing.expectEqualSlices(u8, &red, rotated.getPixel(0, 2));
    try std.testing.expectEqualSlices(u8, &cyan, rotated.getPixel(1, 2));
}

test "Image.flipHorizontal mirrors left-right" {
    const allocator = std.testing.allocator;

    var img = try Image.init(allocator, 3, 2, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const cyan = [_]u8{ 0, 255, 255 };
    const magenta = [_]u8{ 255, 0, 255 };
    const yellow = [_]u8{ 255, 255, 0 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(2, 0, &blue);
    img.setPixel(0, 1, &cyan);
    img.setPixel(1, 1, &magenta);
    img.setPixel(2, 1, &yellow);

    var flipped = try img.flipHorizontal();
    defer flipped.deinit();

    // Same dimensions
    try std.testing.expectEqual(@as(u32, 3), flipped.width);
    try std.testing.expectEqual(@as(u32, 2), flipped.height);

    // Each row reversed
    try std.testing.expectEqualSlices(u8, &blue, flipped.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &green, flipped.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &red, flipped.getPixel(2, 0));
    try std.testing.expectEqualSlices(u8, &yellow, flipped.getPixel(0, 1));
    try std.testing.expectEqualSlices(u8, &magenta, flipped.getPixel(1, 1));
    try std.testing.expectEqualSlices(u8, &cyan, flipped.getPixel(2, 1));
}

test "Image.flipVertical mirrors top-bottom" {
    const allocator = std.testing.allocator;

    var img = try Image.init(allocator, 2, 3, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const cyan = [_]u8{ 0, 255, 255 };
    const magenta = [_]u8{ 255, 0, 255 };
    const yellow = [_]u8{ 255, 255, 0 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(0, 1, &blue);
    img.setPixel(1, 1, &cyan);
    img.setPixel(0, 2, &magenta);
    img.setPixel(1, 2, &yellow);

    var flipped = try img.flipVertical();
    defer flipped.deinit();

    // Same dimensions
    try std.testing.expectEqual(@as(u32, 2), flipped.width);
    try std.testing.expectEqual(@as(u32, 3), flipped.height);

    // Rows reversed
    try std.testing.expectEqualSlices(u8, &magenta, flipped.getPixel(0, 0));
    try std.testing.expectEqualSlices(u8, &yellow, flipped.getPixel(1, 0));
    try std.testing.expectEqualSlices(u8, &blue, flipped.getPixel(0, 1));
    try std.testing.expectEqualSlices(u8, &cyan, flipped.getPixel(1, 1));
    try std.testing.expectEqualSlices(u8, &red, flipped.getPixel(0, 2));
    try std.testing.expectEqualSlices(u8, &green, flipped.getPixel(1, 2));
}
