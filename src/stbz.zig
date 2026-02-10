const std = @import("std");
const Allocator = std.mem.Allocator;

pub const image = @import("image.zig");
pub const Image = image.Image;
pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
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
