# stbz Examples

This document provides practical code examples for common use cases.

## Table of Contents

- [Basic Operations](#basic-operations)
- [Image Transformations](#image-transformations)
- [Working with Pixels](#working-with-pixels)
- [Streaming Operations](#streaming-operations)
- [Error Handling](#error-handling)
- [Real-World Examples](#real-world-examples)

## Basic Operations

### Load and Save PNG

```zig
const std = @import("std");
const stbz = @import("stbz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load PNG
    var img = try stbz.loadPngFile(allocator, "input.png");
    defer img.deinit();

    std.debug.print("Loaded: {}x{} with {} channels\n", .{
        img.width,
        img.height,
        img.channels,
    });

    // Save PNG
    try stbz.savePngFile(&img, "output.png");
}
```

### Load JPEG, Save as PNG

```zig
pub fn convertJpegToPng(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    var img = try stbz.loadJpegFile(allocator, input_path);
    defer img.deinit();

    try stbz.savePngFile(&img, output_path);
}
```

### Load from Memory

```zig
pub fn loadFromBuffer(allocator: Allocator, data: []const u8) !stbz.Image {
    // Auto-detect format based on signature
    if (data.len < 8) return error.InvalidData;

    // PNG signature: 0x89 0x50 0x4E 0x47
    if (std.mem.eql(u8, data[0..4], &[_]u8{0x89, 0x50, 0x4E, 0x47})) {
        return stbz.loadPngMemory(allocator, data);
    }

    // JPEG signature: 0xFF 0xD8
    if (std.mem.eql(u8, data[0..2], &[_]u8{0xFF, 0xD8})) {
        return stbz.loadJpegMemory(allocator, data);
    }

    return error.UnknownFormat;
}
```

## Image Transformations

### Create Thumbnail

```zig
pub fn createThumbnail(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
    max_size: u32,
) !void {
    var img = try stbz.loadPngFile(allocator, input_path);
    defer img.deinit();

    // Calculate dimensions maintaining aspect ratio
    const aspect_ratio = @as(f32, @floatFromInt(img.width)) /
                        @as(f32, @floatFromInt(img.height));

    const new_width: u32 = blk: {
        if (img.width > img.height) {
            break :blk max_size;
        } else {
            break :blk @intFromFloat(@as(f32, @floatFromInt(max_size)) * aspect_ratio);
        }
    };

    const new_height: u32 = blk: {
        if (img.height > img.width) {
            break :blk max_size;
        } else {
            break :blk @intFromFloat(@as(f32, @floatFromInt(max_size)) / aspect_ratio);
        }
    };

    var thumbnail = try img.resize(new_width, new_height);
    defer thumbnail.deinit();

    try stbz.savePngFile(&thumbnail, output_path);
}
```

### Rotate Image 90° Clockwise

```zig
pub fn rotateImage(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    var img = try stbz.loadPngFile(allocator, input_path);
    defer img.deinit();

    var rotated = try img.rotate90();
    defer rotated.deinit();

    try stbz.savePngFile(&rotated, output_path);
}
```

### Crop Center Region

```zig
pub fn cropCenter(
    img: *const stbz.Image,
    crop_width: u32,
    crop_height: u32,
) !stbz.Image {
    if (crop_width > img.width or crop_height > img.height) {
        return error.CropTooLarge;
    }

    const x = (img.width - crop_width) / 2;
    const y = (img.height - crop_height) / 2;

    return img.crop(x, y, crop_width, crop_height);
}
```

### Create Mirror Effect

```zig
pub fn createMirror(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    var img = try stbz.loadPngFile(allocator, input_path);
    defer img.deinit();

    var mirrored = try img.flipHorizontal();
    defer mirrored.deinit();

    try stbz.savePngFile(&mirrored, output_path);
}
```

## Working with Pixels

### Fill with Solid Color

```zig
pub fn createSolidColor(
    allocator: Allocator,
    width: u32,
    height: u32,
    color: [4]u8, // RGBA
) !stbz.Image {
    var img = try stbz.Image.init(allocator, width, height, 4);
    errdefer img.deinit();

    var i: usize = 0;
    while (i < img.data.len) : (i += 4) {
        @memcpy(img.data[i..][0..4], &color);
    }

    return img;
}
```

### Draw Rectangle

```zig
pub fn drawRectangle(
    img: *stbz.Image,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: []const u8,
) void {
    const x_end = @min(x + width, img.width);
    const y_end = @min(y + height, img.height);

    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) {
            img.setPixel(px, py, color);
        }
    }
}
```

### Convert to Grayscale

```zig
pub fn convertToGrayscale(img: *const stbz.Image) !stbz.Image {
    if (img.channels != 3 and img.channels != 4) {
        return error.UnsupportedChannels;
    }

    var gray = try stbz.Image.init(img.allocator, img.width, img.height, 1);
    errdefer gray.deinit();

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));

            // Luminosity method: 0.299*R + 0.587*G + 0.114*B
            const r: u32 = pixel[0];
            const g: u32 = pixel[1];
            const b: u32 = pixel[2];
            const luma: u8 = @intCast((r * 299 + g * 587 + b * 114) / 1000);

            const gray_pixel = [_]u8{luma};
            gray.setPixel(@intCast(x), @intCast(y), &gray_pixel);
        }
    }

    return gray;
}
```

### Apply Brightness Adjustment

```zig
pub fn adjustBrightness(img: *stbz.Image, adjustment: i16) void {
    for (img.data) |*pixel| {
        const new_value = @as(i32, pixel.*) + adjustment;
        pixel.* = @intCast(std.math.clamp(new_value, 0, 255));
    }
}
```

### Create Checkerboard Pattern

```zig
pub fn createCheckerboard(
    allocator: Allocator,
    width: u32,
    height: u32,
    square_size: u32,
) !stbz.Image {
    var img = try stbz.Image.init(allocator, width, height, 4);
    errdefer img.deinit();

    const white = [_]u8{ 255, 255, 255, 255 };
    const black = [_]u8{ 0, 0, 0, 255 };

    for (0..height) |y| {
        for (0..width) |x| {
            const square_x = x / square_size;
            const square_y = y / square_size;
            const is_white = (square_x + square_y) % 2 == 0;

            const color = if (is_white) &white else &black;
            img.setPixel(@intCast(x), @intCast(y), color);
        }
    }

    return img;
}
```

## Streaming Operations

### Generate Thumbnail from Large Image

```zig
pub fn createLargeThumbnail(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
    max_size: u32,
) !void {
    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var in_buf: [65536]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var in_reader = input_file.reader(&in_buf);
    var out_writer = output_file.writer(&out_buf);

    // Use streaming resize to avoid loading entire image
    try stbz.streamingResize(
        allocator,
        &in_reader.interface,
        &out_writer.interface,
        max_size,
        max_size,
    );

    try out_writer.interface.flush();
}
```

### Process Image Row-by-Row

```zig
pub fn processRowByRow(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    // Open input file
    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    var in_buf: [65536]u8 = undefined;
    var in_reader = input_file.reader(&in_buf);

    // Initialize streaming decoder
    var decoder = try stbz.PngStreamingDecoder.init(allocator, &in_reader.interface);
    defer decoder.deinit();

    const width = decoder.width();
    const height = decoder.height();
    const channels = decoder.channels();

    // Open output file
    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var out_buf: [8192]u8 = undefined;
    var out_writer = output_file.writer(&out_buf);

    // Initialize row writer
    var writer = try stbz.PngRowWriter.init(
        allocator,
        &out_writer.interface,
        width,
        height,
        channels,
    );
    defer writer.deinit();

    // Process each row
    const stride = width * channels;
    var row_buffer = try allocator.alloc(u8, stride);
    defer allocator.free(row_buffer);

    while (try decoder.nextRow(row_buffer)) {
        // Process row data here (e.g., apply filters, adjust colors)
        // For this example, just copy as-is
        try writer.writeRow(row_buffer);
    }

    try writer.finish();
    try out_writer.interface.flush();
}
```

## Error Handling

### Robust Image Loading

```zig
pub fn loadImageRobust(
    allocator: Allocator,
    path: []const u8,
) !stbz.Image {
    const img = stbz.loadPngFile(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("Image file not found: {s}", .{path});
                return error.FileNotFound;
            },
            error.InvalidSignature => {
                std.log.err("Not a valid PNG file: {s}", .{path});

                // Try loading as JPEG
                return stbz.loadJpegFile(allocator, path) catch {
                    std.log.err("Not a valid JPEG file either", .{});
                    return error.InvalidSignature;
                };
            },
            error.OutOfMemory => {
                std.log.err("Out of memory loading: {s}", .{path});
                std.log.info("Try using streaming API instead", .{});
                return error.OutOfMemory;
            },
            else => {
                std.log.err("Failed to load image: {}", .{err});
                return err;
            },
        }
    };

    return img;
}
```

### Batch Processing with Error Recovery

```zig
pub fn processBatch(
    allocator: Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
) !void {
    var dir = try std.fs.cwd().openDir(input_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var success_count: usize = 0;
    var error_count: usize = 0;

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Process each file
        processFile(allocator, input_dir, output_dir, entry.name) catch |err| {
            std.log.err("Failed to process {s}: {}", .{entry.name, err});
            error_count += 1;
            continue;
        };

        success_count += 1;
    }

    std.log.info("Processed: {} success, {} errors", .{success_count, error_count});
}

fn processFile(
    allocator: Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    filename: []const u8,
) !void {
    // Build paths
    const input_path = try std.fs.path.join(allocator, &[_][]const u8{input_dir, filename});
    defer allocator.free(input_path);

    const output_path = try std.fs.path.join(allocator, &[_][]const u8{output_dir, filename});
    defer allocator.free(output_path);

    // Load and resize
    var img = try stbz.loadPngFile(allocator, input_path);
    defer img.deinit();

    var resized = try img.resize(800, 600);
    defer resized.deinit();

    try stbz.savePngFile(&resized, output_path);
}
```

## Real-World Examples

### Web Server Thumbnail Generator

```zig
const std = @import("std");
const stbz = @import("stbz");
const httpz = @import("httpz"); // Example HTTP library

pub fn thumbnailHandler(
    allocator: Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    // Get image from request
    const image_data = req.body() orelse return error.NoBody;

    // Load image from memory
    var img = try stbz.loadPngMemory(allocator, image_data);
    defer img.deinit();

    // Generate thumbnail
    var thumbnail = try img.resize(200, 200);
    defer thumbnail.deinit();

    // Save to memory
    const png_data = try stbz.savePngMemory(allocator, &thumbnail);
    defer allocator.free(png_data);

    // Send response
    res.headers.put("Content-Type", "image/png");
    try res.write(png_data);
}
```

### Command-Line Tool

```zig
const std = @import("std");
const stbz = @import("stbz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 5) {
        std.debug.print("Usage: {s} <input> <output> <width> <height>\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];
    const width = try std.fmt.parseInt(u32, args[3], 10);
    const height = try std.fmt.parseInt(u32, args[4], 10);

    // Load image
    var img = try stbz.loadPngFile(allocator, input_path);
    defer img.deinit();

    std.debug.print("Loaded: {}x{}\n", .{img.width, img.height});

    // Resize
    var resized = try img.resize(width, height);
    defer resized.deinit();

    // Save
    try stbz.savePngFile(&resized, output_path);

    std.debug.print("Saved: {}x{} to {s}\n", .{width, height, output_path});
}
```

### Image Comparison Tool

```zig
pub fn compareImages(
    allocator: Allocator,
    path1: []const u8,
    path2: []const u8,
) !void {
    var img1 = try stbz.loadPngFile(allocator, path1);
    defer img1.deinit();

    var img2 = try stbz.loadPngFile(allocator, path2);
    defer img2.deinit();

    // Check dimensions
    if (img1.width != img2.width or img1.height != img2.height) {
        std.debug.print("Images have different dimensions\n", .{});
        std.debug.print("  Image 1: {}x{}\n", .{img1.width, img1.height});
        std.debug.print("  Image 2: {}x{}\n", .{img2.width, img2.height});
        return;
    }

    // Check channels
    if (img1.channels != img2.channels) {
        std.debug.print("Images have different channel counts\n", .{});
        return;
    }

    // Compare pixels
    var diff_count: usize = 0;
    var max_diff: u32 = 0;

    for (0..img1.data.len) |i| {
        const diff = @as(u32, @intCast(@abs(@as(i32, img1.data[i]) - @as(i32, img2.data[i]))));
        if (diff > 0) {
            diff_count += 1;
            max_diff = @max(max_diff, diff);
        }
    }

    if (diff_count == 0) {
        std.debug.print("Images are identical\n", .{});
    } else {
        const total_pixels = img1.data.len;
        const diff_percent = (@as(f64, @floatFromInt(diff_count)) / @as(f64, @floatFromInt(total_pixels))) * 100.0;

        std.debug.print("Images differ:\n", .{});
        std.debug.print("  Different bytes: {} ({d:.2}%)\n", .{diff_count, diff_percent});
        std.debug.print("  Maximum difference: {}\n", .{max_diff});
    }
}
```

### Watermark Overlay

```zig
pub fn addWatermark(
    img: *stbz.Image,
    watermark: *const stbz.Image,
    x: u32,
    y: u32,
    alpha: f32, // 0.0 to 1.0
) void {
    const alpha_u8: u32 = @intFromFloat(alpha * 255.0);

    for (0..watermark.height) |wy| {
        for (0..watermark.width) |wx| {
            const dst_x = x + @as(u32, @intCast(wx));
            const dst_y = y + @as(u32, @intCast(wy));

            if (dst_x >= img.width or dst_y >= img.height) continue;

            const watermark_pixel = watermark.getPixel(@intCast(wx), @intCast(wy));
            const base_pixel = img.getPixel(dst_x, dst_y);

            var blended: [4]u8 = undefined;
            for (0..@min(img.channels, watermark.channels)) |ch| {
                const base: u32 = base_pixel[ch];
                const water: u32 = watermark_pixel[ch];
                blended[ch] = @intCast((base * (255 - alpha_u8) + water * alpha_u8) / 255);
            }

            img.setPixel(dst_x, dst_y, blended[0..img.channels]);
        }
    }
}
```

## See Also

- [USAGE.md](USAGE.md) - Complete API usage guide
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Error handling patterns
- [ARCHITECTURE.md](ARCHITECTURE.md) - Internal architecture
- [API.md](API.md) - Full API reference
