const std = @import("std");
const stbz = @import("stbz");

/// Test low-memory streaming operations with large images
/// Run with: zig build test-large
/// Requires: /tmp/large_test.png (create with: convert -size 4000x3000 plasma: PNG24:/tmp/large_test.png)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "/tmp/large_test.png";

    // Check if test image exists
    std.fs.cwd().access(path, .{}) catch {
        std.debug.print("Test image not found: {s}\n", .{path});
        std.debug.print("Create it with: convert -size 4000x3000 plasma: PNG24:{s}\n", .{path});
        return error.TestImageNotFound;
    };

    std.debug.print("Test 1: Standard resize (full image in memory)\n", .{});
    {
        var img = try stbz.loadPngFile(allocator, path);
        defer img.deinit();
        std.debug.print("  Loaded: {}x{} ({} bytes)\n", .{ img.width, img.height, img.data.len });

        var resized = try img.resize(800, 600);
        defer resized.deinit();
        std.debug.print("  Resized: {}x{}\n", .{ resized.width, resized.height });

        try stbz.savePngFile(&resized, "/tmp/large_resize_standard.png");
        std.debug.print("  Saved to /tmp/large_resize_standard.png\n", .{});
    }

    std.debug.print("\nTest 2: Streaming resize (incremental decompression)\n", .{});
    {
        const in_file = try std.fs.cwd().openFile(path, .{});
        defer in_file.close();
        var in_buf: [8192]u8 = undefined;
        var file_reader = in_file.reader(&in_buf);

        const out_file = try std.fs.cwd().createFile("/tmp/large_resize_streaming.png", .{});
        defer out_file.close();
        var out_buf: [8192]u8 = undefined;
        var file_writer = out_file.writer(&out_buf);

        try stbz.streamingResize(allocator, &file_reader.interface, &file_writer.interface, 800, 600);
        try file_writer.interface.flush();
        std.debug.print("  Saved to /tmp/large_resize_streaming.png\n", .{});
    }

    std.debug.print("\nTest 3: Row-by-row decoder\n", .{});
    {
        const in_file = try std.fs.cwd().openFile(path, .{});
        defer in_file.close();
        var in_buf: [8192]u8 = undefined;
        var file_reader = in_file.reader(&in_buf);

        var decoder = try stbz.PngStreamingDecoder.init(allocator, &file_reader.interface, .{});
        defer decoder.deinit();

        std.debug.print("  Decoder initialized: {}x{}, {} channels\n", .{
            decoder.width,
            decoder.height,
            decoder.channels,
        });

        var rows_read: u32 = 0;
        while (try decoder.readRow()) |_| {
            rows_read += 1;
        }
        std.debug.print("  Read {} rows\n", .{rows_read});
    }

    std.debug.print("\nVerifying outputs...\n", .{});
    {
        var resize_standard = try stbz.loadPngFile(allocator, "/tmp/large_resize_standard.png");
        defer resize_standard.deinit();
        std.debug.print("  Standard resize: {}x{}\n", .{ resize_standard.width, resize_standard.height });

        var resize_streaming = try stbz.loadPngFile(allocator, "/tmp/large_resize_streaming.png");
        defer resize_streaming.deinit();
        std.debug.print("  Streaming resize: {}x{}\n", .{ resize_streaming.width, resize_streaming.height });

        // Verify dimensions match
        if (resize_standard.width != resize_streaming.width or
            resize_standard.height != resize_streaming.height or
            resize_standard.channels != resize_streaming.channels)
        {
            std.debug.print("\n  ERROR: Dimensions don't match!\n", .{});
            return error.DimensionMismatch;
        }

        std.debug.print("  ✓ Dimensions match\n", .{});
    }

    std.debug.print("\nAll tests passed!\n", .{});
}
