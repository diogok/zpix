pub const MAX_DIMENSION: u32 = 16384;

/// Upper bound on file size when reading an entire image into memory.
/// 256 MiB is generous for any sane image at MAX_DIMENSION; anything larger
/// is almost certainly malicious or corrupt.
pub const MAX_FILE_SIZE: usize = 256 * 1024 * 1024;

width: u32,
height: u32,
channels: u8,
data: []u8,
allocator: Allocator,

pub fn init(allocator: Allocator, width: u32, height: u32, channels: u8) !@This() {
    if (width == 0 or height == 0 or width > MAX_DIMENSION or height > MAX_DIMENSION)
        return error.InvalidImageDimensions;
    const size = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const data = try allocator.alloc(u8, size);
    @memset(data, 0);
    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .data = data,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.data);
    self.* = undefined;
}

pub fn getPixel(self: *const @This(), x: u32, y: u32) []const u8 {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * @as(usize, self.channels);
    return self.data[idx .. idx + self.channels];
}

pub fn setPixel(self: *@This(), x: u32, y: u32, pixel: []const u8) void {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    std.debug.assert(pixel.len == self.channels);
    const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * @as(usize, self.channels);
    @memcpy(self.data[idx .. idx + self.channels], pixel);
}

pub fn crop(self: *const @This(), x: u32, y: u32, crop_width: u32, crop_height: u32) !@This() {
    // Validate bounds
    if (@as(u64, x) + @as(u64, crop_width) > @as(u64, self.width) or
        @as(u64, y) + @as(u64, crop_height) > @as(u64, self.height))
    {
        return error.CropOutOfBounds;
    }
    if (crop_width == 0 or crop_height == 0) {
        return error.InvalidCropDimensions;
    }

    var result = try @This().init(self.allocator, crop_width, crop_height, self.channels);
    errdefer result.deinit();

    const src_stride = @as(usize, self.width) * @as(usize, self.channels);
    const dst_stride = @as(usize, crop_width) * @as(usize, self.channels);
    const x_offset = @as(usize, x) * @as(usize, self.channels);

    for (0..crop_height) |row| {
        const src_row = @as(usize, y) + row;
        const src_start = src_row * src_stride + x_offset;
        const dst_start = row * dst_stride;
        @memcpy(result.data[dst_start..][0..dst_stride], self.data[src_start..][0..dst_stride]);
    }

    return result;
}

/// Resize image using bilinear interpolation (fixed-point integer math)
pub fn resize(self: *const @This(), new_width: u32, new_height: u32) !@This() {
    if (new_width == 0 or new_height == 0) {
        return error.InvalidResizeDimensions;
    }

    var result = try @This().init(self.allocator, new_width, new_height, self.channels);
    errdefer result.deinit();

    const channels: usize = self.channels;
    const src_data = self.data;
    const dst_data = result.data;
    const source_width: usize = self.width;
    const source_height: usize = self.height;
    const destination_width: usize = new_width;
    const destination_height: usize = new_height;
    const src_stride = source_width * channels;
    const dst_stride = destination_width * channels;

    // Fixed-point with 16 fractional bits
    const SHIFT = 16;
    const HALF = 1 << (SHIFT - 1); // 0.5 in fixed-point

    // Map: src_coord = (dst_coord + 0.5) * src_size / dst_size - 0.5
    // In fixed-point: src_fp = ((dst * 2 + 1) * src_size * (1<<(SHIFT-1))) / dst_size - HALF
    // Simplified: use step-based approach

    // Pre-compute x mapping: for each dst_x, store src_x0, src_x1, x_frac
    const x_info = try self.allocator.alloc(XInfo, destination_width);
    defer self.allocator.free(x_info);

    for (0..destination_width) |dst_x| {
        // src_x_fp = ((2*dst_x + 1) * source_width * HALF) / destination_width - HALF
        const numerator: u64 = (@as(u64, 2 * dst_x + 1) * @as(u64, source_width) * @as(u64, HALF));
        const src_x_fp: i64 = @as(i64, @intCast(numerator / @as(u64, destination_width))) - HALF;

        const clamped = std.math.clamp(src_x_fp, 0, @as(i64, @intCast((source_width - 1))) << SHIFT);
        const x0: usize = @intCast(@as(u64, @intCast(clamped)) >> SHIFT);
        const x1 = @min(x0 + 1, source_width - 1);
        const fraction: u32 = @intCast(@as(u64, @intCast(clamped)) & ((1 << SHIFT) - 1));

        x_info[dst_x] = .{ .x0 = x0, .x1 = x1, .frac = fraction };
    }

    for (0..destination_height) |dst_y| {
        const numerator_y: u64 = (@as(u64, 2 * dst_y + 1) * @as(u64, source_height) * @as(u64, HALF));
        const src_y_fp: i64 = @as(i64, @intCast(numerator_y / @as(u64, destination_height))) - HALF;

        const clamped_y = std.math.clamp(src_y_fp, 0, @as(i64, @intCast((source_height - 1))) << SHIFT);
        const y0: usize = @intCast(@as(u64, @intCast(clamped_y)) >> SHIFT);
        const y1 = @min(y0 + 1, source_height - 1);
        const y_frac: u32 = @intCast(@as(u64, @intCast(clamped_y)) & ((1 << SHIFT) - 1));
        const y_inv = @as(u32, (1 << SHIFT)) - y_frac;

        const row0 = src_data[y0 * src_stride ..][0..src_stride];
        const row1 = src_data[y1 * src_stride ..][0..src_stride];
        const dst_row = dst_data[dst_y * dst_stride ..][0..dst_stride];

        for (0..destination_width) |dst_x| {
            const xi = x_info[dst_x];
            const x_inv = @as(u32, (1 << SHIFT)) - xi.frac;

            const off00 = xi.x0 * channels;
            const off10 = xi.x1 * channels;

            inline for (0..4) |ch| {
                if (ch < channels) {
                    const v00: u64 = row0[off00 + ch];
                    const v10: u64 = row0[off10 + ch];
                    const v01: u64 = row1[off00 + ch];
                    const v11: u64 = row1[off10 + ch];

                    const top = v00 * x_inv + v10 * xi.frac;
                    const bot = v01 * x_inv + v11 * xi.frac;
                    const value = (top * y_inv + bot * y_frac + (1 << 31)) >> 32;

                    dst_row[dst_x * channels + ch] = @intCast(value);
                }
            }
        }
    }

    return result;
}

const XInfo = struct {
    x0: usize,
    x1: usize,
    frac: u32,
};

/// Rotate image 90 degrees clockwise
pub fn rotate90(self: *const @This()) !@This() {
    // Width and height swap
    var result = try @This().init(self.allocator, self.height, self.width, self.channels);
    errdefer result.deinit();

    for (0..self.height) |y| {
        for (0..self.width) |x| {
            // (x, y) -> (height - 1 - y, x) for 90° CW
            const new_x = self.height - 1 - @as(u32, @intCast(y));
            const new_y = @as(u32, @intCast(x));
            const pixel = self.getPixel(@intCast(x), @intCast(y));
            result.setPixel(new_x, new_y, pixel);
        }
    }

    return result;
}

/// Rotate image 180 degrees
pub fn rotate180(self: *const @This()) !@This() {
    var result = try @This().init(self.allocator, self.width, self.height, self.channels);
    errdefer result.deinit();

    for (0..self.height) |y| {
        for (0..self.width) |x| {
            // (x, y) -> (width - 1 - x, height - 1 - y)
            const new_x = self.width - 1 - @as(u32, @intCast(x));
            const new_y = self.height - 1 - @as(u32, @intCast(y));
            const pixel = self.getPixel(@intCast(x), @intCast(y));
            result.setPixel(new_x, new_y, pixel);
        }
    }

    return result;
}

/// Rotate image 270 degrees clockwise (= 90 degrees counter-clockwise)
pub fn rotate270(self: *const @This()) !@This() {
    // Width and height swap
    var result = try @This().init(self.allocator, self.height, self.width, self.channels);
    errdefer result.deinit();

    for (0..self.height) |y| {
        for (0..self.width) |x| {
            // (x, y) -> (y, width - 1 - x) for 90° CCW
            const new_x = @as(u32, @intCast(y));
            const new_y = self.width - 1 - @as(u32, @intCast(x));
            const pixel = self.getPixel(@intCast(x), @intCast(y));
            result.setPixel(new_x, new_y, pixel);
        }
    }

    return result;
}

/// Flip image horizontally (mirror left-right)
pub fn flipHorizontal(self: *const @This()) !@This() {
    var result = try @This().init(self.allocator, self.width, self.height, self.channels);
    errdefer result.deinit();

    for (0..self.height) |y| {
        for (0..self.width) |x| {
            const new_x = self.width - 1 - @as(u32, @intCast(x));
            const pixel = self.getPixel(@intCast(x), @intCast(y));
            result.setPixel(new_x, @intCast(y), pixel);
        }
    }

    return result;
}

/// Flip image vertically (mirror top-bottom)
pub fn flipVertical(self: *const @This()) !@This() {
    var result = try @This().init(self.allocator, self.width, self.height, self.channels);
    errdefer result.deinit();

    for (0..self.height) |y| {
        for (0..self.width) |x| {
            const new_y = self.height - 1 - @as(u32, @intCast(y));
            const pixel = self.getPixel(@intCast(x), @intCast(y));
            result.setPixel(@intCast(x), new_y, pixel);
        }
    }

    return result;
}

test "init creates image with correct dimensions" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 100, 50, 4);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 100), img.width);
    try std.testing.expectEqual(@as(u32, 50), img.height);
    try std.testing.expectEqual(@as(u8, 4), img.channels);
    try std.testing.expectEqual(@as(usize, 100 * 50 * 4), img.data.len);
}

test "init initializes data to zero" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    for (img.data) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "setPixel and getPixel work correctly" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 4);
    defer img.deinit();

    const pixel = [_]u8{ 255, 128, 64, 255 };
    img.setPixel(5, 3, &pixel);

    const retrieved = img.getPixel(5, 3);
    try std.testing.expectEqualSlices(u8, &pixel, retrieved);
}

test "crop extracts correct region" {
    const Image = @This();
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

test "crop rejects out of bounds" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    // Should fail: crop extends beyond image bounds
    try std.testing.expectError(error.CropOutOfBounds, img.crop(8, 8, 5, 5));
    try std.testing.expectError(error.CropOutOfBounds, img.crop(0, 0, 11, 10));
}

test "crop rejects zero dimensions" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    try std.testing.expectError(error.InvalidCropDimensions, img.crop(0, 0, 0, 5));
    try std.testing.expectError(error.InvalidCropDimensions, img.crop(0, 0, 5, 0));
}

test "resize produces correct dimensions" {
    const Image = @This();
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

test "resize bilinear interpolation blends colors" {
    const Image = @This();
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

test "resize rejects zero dimensions" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    try std.testing.expectError(error.InvalidResizeDimensions, img.resize(0, 10));
    try std.testing.expectError(error.InvalidResizeDimensions, img.resize(10, 0));
}

test "rotate90 rotates clockwise" {
    const Image = @This();
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

test "rotate180 rotates 180 degrees" {
    const Image = @This();
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

test "rotate270 rotates counter-clockwise" {
    const Image = @This();
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

test "flipHorizontal mirrors left-right" {
    const Image = @This();
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

test "flipVertical mirrors top-bottom" {
    const Image = @This();
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

test "init rejects zero width" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidImageDimensions, @This().init(allocator, 0, 10, 3));
}

test "init rejects zero height" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidImageDimensions, @This().init(allocator, 10, 0, 3));
}

test "init rejects oversized dimensions" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidImageDimensions, @This().init(allocator, MAX_DIMENSION + 1, 10, 3));
    try std.testing.expectError(error.InvalidImageDimensions, @This().init(allocator, 10, MAX_DIMENSION + 1, 3));
}

test "init accepts max dimensions" {
    const allocator = std.testing.allocator;
    var img = try @This().init(allocator, 64, 64, 1);
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 64), img.width);
}

test "crop detects u32 overflow" {
    const allocator = std.testing.allocator;
    var img = try @This().init(allocator, 10, 10, 3);
    defer img.deinit();
    try std.testing.expectError(error.CropOutOfBounds, img.crop(0xFFFFFFFF, 0, 2, 2));
    try std.testing.expectError(error.CropOutOfBounds, img.crop(0, 0, 0xFFFFFFFF, 2));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
