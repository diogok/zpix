const std = @import("std");
const Allocator = std.mem.Allocator;

pub const image = @import("image.zig");
pub const Image = image.Image;
pub const png = @import("png.zig");
pub const streaming = @import("streaming.zig");

// Core Reader/Writer based functions
pub const decodePng = png.decode;
pub const encodePng = png.encode;

// Convenience file-based functions
pub const loadPngFile = png.loadFromFile;
pub const loadPngMemory = png.loadFromMemory;
pub const savePngFile = png.saveToFile;
pub const savePngMemory = png.saveToMemory;

// ============================================================================
// Streaming Operations (full image in memory)
// ============================================================================

/// Read PNG from reader, crop, write PNG to writer
pub fn cropStream(
    allocator: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    x: u32,
    y: u32,
    crop_width: u32,
    crop_height: u32,
) !void {
    // Decode input
    var img = try png.decode(allocator, reader);
    defer img.deinit();

    // Crop
    var cropped = try img.crop(x, y, crop_width, crop_height);
    defer cropped.deinit();

    // Encode output
    try png.encode(allocator, &cropped, writer);
}

/// Read PNG from reader, resize, write PNG to writer
pub fn resizeStream(
    allocator: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    new_width: u32,
    new_height: u32,
) !void {
    // Decode input
    var img = try png.decode(allocator, reader);
    defer img.deinit();

    // Resize
    var resized = try img.resize(new_width, new_height);
    defer resized.deinit();

    // Encode output
    try png.encode(allocator, &resized, writer);
}

/// Read PNG from reader, create thumbnail (center crop + resize), write PNG to writer
pub fn thumbnailStream(
    allocator: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    size: u32,
) !void {
    // Decode input
    var img = try png.decode(allocator, reader);
    defer img.deinit();

    // Center crop to square
    const min_dim = @min(img.width, img.height);
    const crop_x = (img.width - min_dim) / 2;
    const crop_y = (img.height - min_dim) / 2;

    var cropped = try img.crop(crop_x, crop_y, min_dim, min_dim);
    defer cropped.deinit();

    // Resize to target size
    var thumbnail = try cropped.resize(size, size);
    defer thumbnail.deinit();

    // Encode output
    try png.encode(allocator, &thumbnail, writer);
}

// ============================================================================
// Low-Memory Streaming Operations (row-by-row processing)
// ============================================================================

/// Streaming crop with minimal memory (only row buffers)
pub const streamingCrop = streaming.streamingCrop;

/// Streaming resize with minimal memory
pub const streamingResize = streaming.streamingResize;

/// Streaming thumbnail with minimal memory
pub const streamingThumbnail = streaming.streamingThumbnail;

/// Row-by-row PNG writer
pub const PngRowWriter = streaming.PngRowWriter;

/// PNG header info
pub const PngInfo = streaming.PngInfo;

test {
    std.testing.refAllDecls(@This());
}

test "cropStream works" {
    const allocator = std.testing.allocator;

    // Create a test image and encode it
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    img.setPixel(2, 2, &red);

    const png_data = try png.saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Decode, crop, re-encode using stream functions
    var input_reader: std.Io.Reader = .fixed(png_data);
    var decoded = try png.decode(allocator, &input_reader);
    defer decoded.deinit();

    var cropped = try decoded.crop(2, 2, 3, 3);
    defer cropped.deinit();

    try std.testing.expectEqual(@as(u32, 3), cropped.width);
    try std.testing.expectEqual(@as(u32, 3), cropped.height);
    try std.testing.expectEqualSlices(u8, &red, cropped.getPixel(0, 0));
}

test "resizeStream works" {
    const allocator = std.testing.allocator;

    // Create a test image
    var img = try Image.init(allocator, 4, 4, 3);
    defer img.deinit();

    const png_data = try png.saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Decode and resize
    var input_reader: std.Io.Reader = .fixed(png_data);
    var decoded = try png.decode(allocator, &input_reader);
    defer decoded.deinit();

    var resized = try decoded.resize(8, 8);
    defer resized.deinit();

    try std.testing.expectEqual(@as(u32, 8), resized.width);
    try std.testing.expectEqual(@as(u32, 8), resized.height);
}
