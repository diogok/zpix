const std = @import("std");
const stbz = @import("stbz");

// C reference implementation bindings
const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
});

fn stb_load_png(filename: [*:0]const u8) ?struct { data: [*]u8, width: c_int, height: c_int, channels: c_int } {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = c.stbi_load(filename, &width, &height, &channels, 0);
    if (data == null) return null;
    return .{ .data = data.?, .width = width, .height = height, .channels = channels };
}

fn stb_free(data: [*]u8) void {
    c.stbi_image_free(data);
}

test "PNG decoder produces same output as stb_image for RGB" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/test_rgb_4x4.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_rgb_4x4.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}

test "PNG decoder produces same output as stb_image for RGBA" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/test_rgba_4x4.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_rgba_4x4.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}

test "Resize produces correctly sized output" {
    const allocator = std.testing.allocator;

    // Load an image
    var img = try stbz.loadPngFile(allocator, "test/fixtures/test_rgb_4x4.png");
    defer img.deinit();

    // Test upscaling
    {
        var resized = try img.resize(8, 8);
        defer resized.deinit();

        try std.testing.expectEqual(@as(u32, 8), resized.width);
        try std.testing.expectEqual(@as(u32, 8), resized.height);
        try std.testing.expectEqual(img.channels, resized.channels);
        try std.testing.expectEqual(@as(usize, 8 * 8 * 3), resized.data.len);
    }

    // Test downscaling
    {
        var resized = try img.resize(2, 2);
        defer resized.deinit();

        try std.testing.expectEqual(@as(u32, 2), resized.width);
        try std.testing.expectEqual(@as(u32, 2), resized.height);
    }

    // Test same size (should still work)
    {
        var resized = try img.resize(4, 4);
        defer resized.deinit();

        try std.testing.expectEqual(@as(u32, 4), resized.width);
        try std.testing.expectEqual(@as(u32, 4), resized.height);
    }

    // Test non-square resize
    {
        var resized = try img.resize(8, 2);
        defer resized.deinit();

        try std.testing.expectEqual(@as(u32, 8), resized.width);
        try std.testing.expectEqual(@as(u32, 2), resized.height);
    }
}

test "PNG decoder handles interlaced (Adam7) images" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/test_interlaced_16x16.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_interlaced_16x16.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}

test "PNG decoder handles grayscale images" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/test_gray_8x8.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_gray_8x8.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}

test "PNG decoder handles grayscale+alpha images" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/test_gray_alpha_8x8.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_gray_alpha_8x8.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}

test "PNG decoder handles large interlaced images" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load_png("test/fixtures/landscape_interlaced.png") orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/landscape_interlaced.png");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data byte-by-byte
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}
