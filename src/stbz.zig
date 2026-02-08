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
// Low-Memory Streaming Operations (row-by-row processing)
// ============================================================================

/// Streaming crop with minimal memory - O(width) memory
pub const streamingCrop = streaming.streamingCrop;

/// Streaming resize - keeps all decoded rows in memory
/// For lower memory usage, see streamingResizeLowMem
pub const streamingResize = streaming.streamingResize;

/// Streaming resize with 2-row sliding window - O(width) memory
/// Inspired by libvips' demand-driven architecture
pub const streamingResizeLowMem = streaming.streamingResizeLowMem;

/// Ultra-low memory resize with incremental decompression
/// Memory: O(compressed_size + width * 4) - decompresses on demand
pub const streamingResizeUltraLowMem = streaming.streamingResizeUltraLowMem;

/// Streaming thumbnail - keeps cropped rows in memory
pub const streamingThumbnail = streaming.streamingThumbnail;

/// Streaming PNG decoder - decompresses row-by-row
pub const PngStreamingDecoder = streaming.PngStreamingDecoder;

/// Row-by-row PNG writer
pub const PngRowWriter = streaming.PngRowWriter;

/// PNG header info
pub const PngInfo = streaming.PngInfo;

test {
    std.testing.refAllDecls(@This());
}

