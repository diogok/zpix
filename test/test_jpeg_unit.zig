const std = @import("std");
const zpix = @import("zpix");

// Unit tests for JPEG decoder - testing behavior, not just output correctness
// These tests verify edge cases, error handling, and internal logic

test "JPEG decoder rejects files with invalid signature" {
    const allocator = std.testing.allocator;

    // Not a JPEG file (PNG signature)
    const invalid_data = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    const result = zpix.loadJpegMemory(allocator, &invalid_data);

    try std.testing.expectError(error.InvalidSignature, result);
}

test "JPEG decoder rejects truncated SOI marker" {
    const allocator = std.testing.allocator;

    // Only one byte (should be 2 bytes for SOI)
    const truncated = [_]u8{0xFF};

    const result = zpix.loadJpegMemory(allocator, &truncated);

    try std.testing.expectError(error.InvalidSignature, result);
}

test "JPEG decoder rejects file without SOI marker" {
    const allocator = std.testing.allocator;

    // Random data, no SOI marker
    const no_soi = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };

    const result = zpix.loadJpegMemory(allocator, &no_soi);

    try std.testing.expectError(error.InvalidSignature, result);
}

test "JPEG decoder handles minimal valid baseline JPEG" {
    const allocator = std.testing.allocator;

    // Load a real minimal JPEG
    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer img.deinit();

    // Verify it's actually loaded
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
    try std.testing.expect(img.channels > 0);
    try std.testing.expect(img.data.len > 0);
}

test "JPEG decoder handles grayscale image" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_gray_8x8.jpg");
    defer img.deinit();

    // Note: Some grayscale JPEGs are encoded with 3 components (RGB with same values)
    // The decoder returns whatever the file contains
    try std.testing.expect(img.channels == 1 or img.channels == 3);
    try std.testing.expectEqual(@as(usize, 8 * 8 * img.channels), img.data.len);
}

test "JPEG decoder handles RGB (3 components)" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer img.deinit();

    // Should be RGB
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), img.data.len);
}

test "JPEG decoder handles progressive JPEG" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4_progressive.jpg");
    defer img.deinit();

    // Should decode successfully
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
    try std.testing.expect(img.data.len > 0);
}

test "JPEG decoder produces correct dimensions" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
}

test "JPEG decoder allocates correct amount of memory" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/landscape_600x400.jpg");
    defer img.deinit();

    const expected_size = @as(usize, img.width) * @as(usize, img.height) * @as(usize, img.channels);
    try std.testing.expectEqual(expected_size, img.data.len);
}

test "JPEG decoder pixel data is not all zeros" {
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer img.deinit();

    // At least some pixels should be non-zero
    var non_zero_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel != 0) non_zero_count += 1;
    }

    try std.testing.expect(non_zero_count > 0);
}

test "JPEG decoder handles multiple sequential loads" {
    const allocator = std.testing.allocator;

    // Load same file multiple times
    for (0..3) |_| {
        var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
        defer img.deinit();

        try std.testing.expectEqual(@as(u32, 4), img.width);
        try std.testing.expectEqual(@as(u32, 4), img.height);
    }
}

test "JPEG decoder cleans up memory on success" {
    // Use testing allocator to detect leaks
    const allocator = std.testing.allocator;

    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    img.deinit();

    // If there's a leak, testing allocator will catch it
}
