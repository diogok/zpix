const std = @import("std");
const Allocator = std.mem.Allocator;

pub const image = @import("image.zig");
pub const Image = image.Image;
pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
pub const jpeg_encoder = @import("jpeg_encoder.zig");
pub const streaming = @import("streaming.zig");

// Core Reader/Writer based functions
pub const decodePng = png.decode;
pub const encodePng = png.encode;
pub const decodeJpeg = jpeg.decode;

// Convenience file-based functions
pub const loadPngFile = png.loadFromFile;
pub const loadPngMemory = png.loadFromMemory;
pub const savePngFile = png.saveToFile;
pub const savePngMemory = png.saveToMemory;
pub const loadJpegFile = jpeg.loadFromFile;
pub const loadJpegMemory = jpeg.loadFromMemory;
pub const encodeJpeg = jpeg_encoder.encode;
pub const saveJpegFile = jpeg_encoder.saveToFile;
pub const saveJpegMemory = jpeg_encoder.saveToMemory;

// ============================================================================
// Format Detection and Unified Load/Save
// ============================================================================

pub const ImageFormat = enum { png, jpeg, unknown };

pub const FormatError = error{UnsupportedFormat};

/// Detect image format from magic bytes.
/// Requires at least 8 bytes for reliable detection.
pub fn detectFormat(header: []const u8) ImageFormat {
    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    if (header.len >= 8 and
        header[0] == 0x89 and header[1] == 0x50 and header[2] == 0x4E and header[3] == 0x47 and
        header[4] == 0x0D and header[5] == 0x0A and header[6] == 0x1A and header[7] == 0x0A)
    {
        return .png;
    }
    // JPEG SOI marker: FF D8
    if (header.len >= 2 and header[0] == 0xFF and header[1] == 0xD8) {
        return .jpeg;
    }
    return .unknown;
}

/// Load image from file, auto-detecting format by magic bytes.
pub fn loadFile(allocator: Allocator, path: []const u8) !Image {
    // Read header to detect format, then close and let format-specific
    // loaders re-open the file (they manage their own buffered readers).
    var header: [8]u8 = undefined;
    const bytes_read = blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.read(&header);
    };
    if (bytes_read < 2) return FormatError.UnsupportedFormat;

    const format = detectFormat(header[0..bytes_read]);
    switch (format) {
        .png => return png.loadFromFile(allocator, path),
        .jpeg => return jpeg.loadFromFile(allocator, path),
        .unknown => return FormatError.UnsupportedFormat,
    }
}

/// Save image to file, choosing format by output file extension.
/// JPEG quality defaults to 90.
pub fn saveFile(img: *const Image, path: []const u8) !void {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) {
        return png.saveToFile(img, path);
    } else if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) {
        return jpeg_encoder.saveToFile(img, path, 90);
    } else {
        return FormatError.UnsupportedFormat;
    }
}

// ============================================================================
// Low-Memory Streaming Operations
// ============================================================================
//
// Use these for large images on memory-constrained systems.
// For typical use cases, prefer the simpler Image API.

/// Streaming resize with incremental decompression.
/// Memory: O(compressed_size + width) instead of O(width × height)
/// See streaming.zig for details and trade-offs.
pub const streamingResize = streaming.streamingResize;

/// Streaming PNG decoder - decompresses row-by-row on demand
pub const PngStreamingDecoder = streaming.PngStreamingDecoder;

/// Row-by-row PNG writer for custom streaming operations
pub const PngRowWriter = streaming.PngRowWriter;

test {
    std.testing.refAllDecls(@This());
}

test "detectFormat identifies PNG" {
    const png_header = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqual(ImageFormat.png, detectFormat(&png_header));
}

test "detectFormat identifies JPEG" {
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46 };
    try std.testing.expectEqual(ImageFormat.jpeg, detectFormat(&jpeg_header));
}

test "detectFormat returns unknown for WebP" {
    // RIFF....WEBP
    const webp_header = [_]u8{ 0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(ImageFormat.unknown, detectFormat(&webp_header));
}

test "detectFormat returns unknown for GIF" {
    const gif_header = [_]u8{ 0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x00, 0x00 };
    try std.testing.expectEqual(ImageFormat.unknown, detectFormat(&gif_header));
}

test "detectFormat returns unknown for empty input" {
    try std.testing.expectEqual(ImageFormat.unknown, detectFormat(&[_]u8{}));
}

test "loadFile loads PNG by magic bytes" {
    var img = try loadFile(std.testing.allocator, "test/fixtures/test_rgb_4x4.png");
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
}

test "loadFile loads JPEG by magic bytes" {
    var img = try loadFile(std.testing.allocator, "test/fixtures/test_rgb_4x4.jpg");
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
}
