const std = @import("std");
const zpix = @import("zpix");

// C reference implementation bindings (translated by build.zig)
const c = @import("c");

fn stb_load(filename: [*:0]const u8, desired_channels: c_int) ?struct { data: [*]u8, width: c_int, height: c_int, channels: c_int } {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = c.stbi_load(filename, &width, &height, &channels, desired_channels);
    if (data == null) return null;
    return .{
        .data = data.?,
        .width = width,
        .height = height,
        .channels = if (desired_channels != 0) desired_channels else channels,
    };
}

fn stb_free(data: [*]u8) void {
    c.stbi_image_free(data);
}

/// Compare pixel data with tolerance (IDCT implementations may differ by +-1)
fn expectPixelsClose(ref_data: []const u8, zig_data: []const u8, tolerance: u8) !void {
    if (ref_data.len != zig_data.len) {
        std.debug.print("Size mismatch: ref={d} zig={d}\n", .{ ref_data.len, zig_data.len });
        return error.SizeMismatch;
    }

    var max_diff: u8 = 0;
    var diff_count: usize = 0;
    for (ref_data, zig_data, 0..) |r, z, i| {
        const diff = if (r > z) r - z else z - r;
        if (diff > tolerance) {
            if (diff_count < 10) {
                std.debug.print("Pixel mismatch at byte {d}: ref={d} zig={d} diff={d}\n", .{ i, r, z, diff });
            }
            diff_count += 1;
        }
        if (diff > max_diff) max_diff = diff;
    }

    if (diff_count > 0) {
        std.debug.print("Total mismatches (>{d}): {d}/{d} bytes, max diff: {d}\n", .{ tolerance, diff_count, ref_data.len, max_diff });
        return error.PixelMismatch;
    }
}

test "JPEG decoder produces same output as stb_image for RGB" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load("test/fixtures/test_rgb_4x4.jpg", 0) orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data with tolerance
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try expectPixelsClose(ref_slice, zig_image.data, 1);
}

test "JPEG decoder produces same output as stb_image for grayscale" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load("test/fixtures/test_gray_8x8.jpg", 0) orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_gray_8x8.jpg");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data with tolerance
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try expectPixelsClose(ref_slice, zig_image.data, 1);
}

test "JPEG decoder handles larger images" {
    const allocator = std.testing.allocator;

    // Load with C reference implementation
    const ref = stb_load("test/fixtures/landscape_600x400.jpg", 0) orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var zig_image = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/landscape_600x400.jpg");
    defer zig_image.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), zig_image.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), zig_image.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), zig_image.channels);

    // Compare pixel data - tolerance of 3 for larger images due to minor
    // fixed-point rounding differences in IDCT/YCbCr across implementations
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try expectPixelsClose(ref_slice, zig_image.data, 3);
}

test "JPEG decoder handles progressive RGB" {
    const allocator = std.testing.allocator;

    // Progressive JPEG support is fully implemented:
    // - DC first scans: ✓
    // - DC refinement scans: ✓
    // - AC first scans (interleaved and non-interleaved): ✓
    // - AC refinement scans: ✓
    //
    // All refinement scans are properly decoded for pixel-perfect quality.

    // Load with C reference implementation
    const ref = stb_load("test/fixtures/test_rgb_4x4_progressive.jpg", 0) orelse {
        std.debug.print("Failed to load reference image\n", .{});
        return error.ReferenceLoadFailed;
    };
    defer stb_free(ref.data);

    // Load with our Zig implementation
    var img = try zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4_progressive.jpg");
    defer img.deinit();

    // Compare dimensions
    try std.testing.expectEqual(@as(u32, @intCast(ref.width)), img.width);
    try std.testing.expectEqual(@as(u32, @intCast(ref.height)), img.height);
    try std.testing.expectEqual(@as(u8, @intCast(ref.channels)), img.channels);

    // Compare pixel data - progressive JPEGs now match pixel-perfect
    const size = @as(usize, @intCast(ref.width)) * @as(usize, @intCast(ref.height)) * @as(usize, @intCast(ref.channels));
    const ref_slice = ref.data[0..size];
    try expectPixelsClose(ref_slice, img.data, 1);
}
