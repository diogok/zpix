const std = @import("std");
const zpix = @import("zpix");

test "JPEG encode round-trip: RGB image" {
    const allocator = std.testing.allocator;

    // Create a fresh RGB test image (avoid double-lossy by not loading from JPEG)
    var img = try zpix.Image.init(allocator, 16, 16, 3);
    defer img.deinit();

    for (0..16) |y| {
        for (0..16) |x| {
            const idx = (y * 16 + x) * 3;
            img.data[idx] = @intCast(x * 16); // R
            img.data[idx + 1] = @intCast(y * 16); // G
            img.data[idx + 2] = 128; // B
        }
    }

    // Encode to JPEG at high quality
    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 95);
    defer allocator.free(jpeg_data);

    // Verify JPEG signature
    try std.testing.expectEqual(@as(u8, 0xFF), jpeg_data[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), jpeg_data[1]);

    // Decode back
    var decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer decoded.deinit();

    // Verify dimensions
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqual(img.channels, decoded.channels);

    // Verify pixels are close (JPEG is lossy, YCbCr conversion adds error)
    var total_diff: u64 = 0;
    for (img.data, decoded.data) |a, b| {
        const diff: u64 = if (a > b) a - b else b - a;
        total_diff += diff;
    }
    const avg_diff = total_diff / img.data.len;
    try std.testing.expect(avg_diff <= 5);
}

test "JPEG encode round-trip: grayscale image" {
    const allocator = std.testing.allocator;

    // Create a grayscale test image
    var img = try zpix.Image.init(allocator, 16, 16, 1);
    defer img.deinit();

    // Fill with a gradient pattern
    for (0..16) |y| {
        for (0..16) |x| {
            img.data[y * 16 + x] = @intCast(x * 16 + y);
        }
    }

    // Encode to JPEG
    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 95);
    defer allocator.free(jpeg_data);

    // Decode back
    var decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer decoded.deinit();

    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqual(@as(u8, 1), decoded.channels);

    // Verify average pixel difference is small
    var total_diff: u64 = 0;
    for (img.data, decoded.data) |a, b| {
        const diff: u64 = if (a > b) a - b else b - a;
        total_diff += diff;
    }
    const avg_diff = total_diff / img.data.len;
    try std.testing.expect(avg_diff <= 5);
}

test "JPEG encode: higher quality produces larger output" {
    const allocator = std.testing.allocator;

    // Create a test image with varied content
    var img = try zpix.Image.init(allocator, 32, 32, 3);
    defer img.deinit();

    for (0..32) |y| {
        for (0..32) |x| {
            const idx = (y * 32 + x) * 3;
            img.data[idx] = @intCast(x * 8);
            img.data[idx + 1] = @intCast(y * 8);
            img.data[idx + 2] = @intCast((x + y) * 4);
        }
    }

    const low_q = try zpix.saveJpegMemory(allocator, &img, 10);
    defer allocator.free(low_q);

    const high_q = try zpix.saveJpegMemory(allocator, &img, 95);
    defer allocator.free(high_q);

    // Higher quality should produce larger output
    try std.testing.expect(high_q.len > low_q.len);
}

test "JPEG encode round-trip: larger image" {
    const allocator = std.testing.allocator;

    // Double-lossy test: load JPEG, re-encode, decode
    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/landscape_600x400.jpg");
    defer img.deinit();

    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 90);
    defer allocator.free(jpeg_data);

    var decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer decoded.deinit();

    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);

    // For a double-lossy round-trip, average difference is typically higher
    var total_diff: u64 = 0;
    for (img.data, decoded.data) |a, b| {
        const diff: u64 = if (a > b) a - b else b - a;
        total_diff += diff;
    }
    const avg_diff = total_diff / img.data.len;
    // Double-lossy at quality 90 should still be reasonable
    try std.testing.expect(avg_diff <= 15);
}

test "JPEG encode: non-multiple-of-8 dimensions" {
    const allocator = std.testing.allocator;

    // Create image with dimensions not divisible by 8
    var img = try zpix.Image.init(allocator, 13, 11, 3);
    defer img.deinit();

    for (0..11) |y| {
        for (0..13) |x| {
            const idx = (y * 13 + x) * 3;
            img.data[idx] = @intCast(x * 19);
            img.data[idx + 1] = @intCast(y * 23);
            img.data[idx + 2] = 128;
        }
    }

    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 90);
    defer allocator.free(jpeg_data);

    var decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 13), decoded.width);
    try std.testing.expectEqual(@as(u32, 11), decoded.height);
}

test "JPEG encode: RGBA input drops alpha" {
    const allocator = std.testing.allocator;

    var img = try zpix.Image.init(allocator, 8, 8, 4);
    defer img.deinit();

    for (0..8) |y| {
        for (0..8) |x| {
            const idx = (y * 8 + x) * 4;
            img.data[idx] = 200; // R
            img.data[idx + 1] = 100; // G
            img.data[idx + 2] = 50; // B
            img.data[idx + 3] = 128; // A (should be ignored)
        }
    }

    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 90);
    defer allocator.free(jpeg_data);

    var decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer decoded.deinit();

    // JPEG doesn't support alpha, should decode as 3-channel
    try std.testing.expectEqual(@as(u8, 3), decoded.channels);
    try std.testing.expectEqual(@as(u32, 8), decoded.width);
    try std.testing.expectEqual(@as(u32, 8), decoded.height);
}

test "JPEG encode: output has valid JFIF structure" {
    const allocator = std.testing.allocator;

    var img = try zpix.Image.init(allocator, 8, 8, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 75);
    defer allocator.free(jpeg_data);

    // Check SOI marker
    try std.testing.expectEqual(@as(u8, 0xFF), jpeg_data[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), jpeg_data[1]);

    // Check APP0 marker follows
    try std.testing.expectEqual(@as(u8, 0xFF), jpeg_data[2]);
    try std.testing.expectEqual(@as(u8, 0xE0), jpeg_data[3]);

    // Check EOI at end
    try std.testing.expectEqual(@as(u8, 0xFF), jpeg_data[jpeg_data.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), jpeg_data[jpeg_data.len - 1]);
}

test "JPEG encode comparison: zpix encode, C stb_image decode" {
    const allocator = std.testing.allocator;

    // Create a synthetic test image
    var img = try zpix.Image.init(allocator, 16, 16, 3);
    defer img.deinit();

    for (0..16) |y| {
        for (0..16) |x| {
            const idx = (y * 16 + x) * 3;
            img.data[idx] = @intCast(x * 16);
            img.data[idx + 1] = @intCast(y * 16);
            img.data[idx + 2] = @intCast((x ^ y) * 16);
        }
    }

    // Encode with zpix
    const jpeg_data = try zpix.saveJpegMemory(allocator, &img, 90);
    defer allocator.free(jpeg_data);

    // Decode with C stb_image
    var c_width: c_int = 0;
    var c_height: c_int = 0;
    var c_channels: c_int = 0;
    const c_pixels = stb_load_from_memory(jpeg_data.ptr, @intCast(jpeg_data.len), &c_width, &c_height, &c_channels);
    if (c_pixels == null) {
        return error.CReferenceDecodeFailed;
    }
    defer stb_free(c_pixels.?);

    try std.testing.expectEqual(@as(c_int, 16), c_width);
    try std.testing.expectEqual(@as(c_int, 16), c_height);

    // Also decode with zpix to compare
    var zpix_decoded = try zpix.loadJpegMemory(allocator, jpeg_data);
    defer zpix_decoded.deinit();

    // Compare zpix decode vs C decode
    const pixel_count = @as(usize, @intCast(c_width)) * @as(usize, @intCast(c_height)) * @as(usize, @intCast(c_channels));
    const c_data = c_pixels.?[0..pixel_count];

    var max_diff: u32 = 0;
    for (zpix_decoded.data[0..pixel_count], c_data) |a, b| {
        const diff: u32 = if (a > b) a - b else b - a;
        if (diff > max_diff) max_diff = diff;
    }
    // Both decoders should produce similar results from the same JPEG
    // Different IDCT implementations may produce slightly different results
    try std.testing.expect(max_diff <= 3);
}

// C reference functions
extern fn stb_load_png_from_memory(buffer: [*]const u8, len: c_int, width: *c_int, height: *c_int, channels: *c_int) ?[*]u8;
extern fn stb_free(data: [*]u8) void;

fn stb_load_from_memory(buffer: [*]const u8, len: c_int, width: *c_int, height: *c_int, channels: *c_int) ?[*]u8 {
    return stb_load_png_from_memory(buffer, len, width, height, channels);
}
