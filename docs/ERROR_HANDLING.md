# Error Handling Guide

This document explains how to handle errors when using the stbz library.

## Table of Contents

- [Overview](#overview)
- [Error Types](#error-types)
- [Handling Errors](#handling-errors)
- [Common Error Scenarios](#common-error-scenarios)
- [Best Practices](#best-practices)

## Overview

stbz uses Zig's error handling system with explicit, typed errors. All operations that can fail return error unions (`!T`), making errors visible in the type system.

**Key Principles**:
- All errors are explicit and must be handled
- No exceptions or panics in library code
- Errors provide context about what went wrong
- Users can choose to handle or propagate errors

## Error Types

### DecodeError (PNG)

Errors that occur during PNG decoding:

```zig
pub const DecodeError = error{
    InvalidSignature,      // Not a PNG file (missing signature)
    InvalidChunkSize,      // Chunk size exceeds reasonable limits
    UnsupportedColorType,  // Color type not supported
    UnsupportedBitDepth,   // Bit depth not supported
    UnsupportedFilter,     // Unknown filter type
    InvalidImageData,      // Corrupted or invalid pixel data
    InvalidChunk,          // Malformed chunk
    MissingIhdr,          // Missing required IHDR chunk
    MissingIdat,          // Missing required IDAT chunk
    DecompressionFailed,   // Zlib decompression failed
    OutOfMemory,          // Memory allocation failed
};
```

### JpegError

Errors that occur during JPEG decoding:

```zig
pub const JpegError = error{
    InvalidSignature,           // Not a JPEG file (missing SOI marker)
    InvalidMarker,              // Unknown or invalid marker
    UnsupportedFormat,          // Unsupported JPEG format
    InvalidQuantizationTable,   // Malformed quantization table
    InvalidHuffmanTable,        // Malformed Huffman table
    InvalidFrameHeader,         // Malformed SOF header
    InvalidScanHeader,          // Malformed SOS header
    InvalidData,                // Corrupted data stream
    HuffmanDecodeFailed,        // Failed to decode Huffman symbol
    InvalidCoefficientIndex,    // Coefficient index out of bounds
    UnsupportedSubsampling,     // Unsupported chroma subsampling
    UnexpectedEndOfData,        // Premature end of data
    OutOfMemory,                // Memory allocation failed
};
```

### Image Operation Errors

Errors from image manipulation operations:

```zig
// From image.zig
error{
    CropOutOfBounds,          // Crop region exceeds image bounds
    InvalidCropDimensions,    // Crop width or height is zero
    InvalidResizeDimensions,  // Resize width or height is zero
    OutOfMemory,              // Memory allocation failed
}
```

### Standard Library Errors

stbz also propagates standard library errors:

- `std.fs.File.OpenError` - File not found, permission denied, etc.
- `std.fs.File.ReadError` - I/O read errors
- `std.fs.File.WriteError` - I/O write errors
- `Allocator.Error` - Memory allocation errors

## Handling Errors

### Basic Error Handling

Use `try` to propagate errors up the call stack:

```zig
pub fn processImage() !void {
    var img = try stbz.loadPngFile(allocator, "input.png");
    defer img.deinit();

    var resized = try img.resize(800, 600);
    defer resized.deinit();

    try stbz.savePngFile(&resized, "output.png");
}
```

### Catching Specific Errors

Use `catch` to handle specific error cases:

```zig
const img = stbz.loadPngFile(allocator, "input.png") catch |err| switch (err) {
    error.FileNotFound => {
        std.debug.print("File not found\n", .{});
        return err;
    },
    error.InvalidSignature => {
        std.debug.print("Not a valid PNG file\n", .{});
        return err;
    },
    error.OutOfMemory => {
        std.debug.print("Not enough memory\n", .{});
        return err;
    },
    else => return err,
};
defer img.deinit();
```

### Catching All Errors

Use `catch` with a block to handle all errors uniformly:

```zig
const img = stbz.loadPngFile(allocator, "input.png") catch |err| {
    std.debug.print("Failed to load image: {}\n", .{err});
    return err;
};
defer img.deinit();
```

### Error Context with errdefer

Use `errdefer` to cleanup on error:

```zig
pub fn processImages(allocator: Allocator) !void {
    var img1 = try stbz.loadPngFile(allocator, "image1.png");
    errdefer img1.deinit();

    var img2 = try stbz.loadPngFile(allocator, "image2.png");
    errdefer img2.deinit();

    // If anything below fails, both images are cleaned up
    var combined = try combineImages(allocator, &img1, &img2);
    defer combined.deinit();

    img1.deinit();
    img2.deinit();
}
```

### Providing Default Values

Use `catch` to provide a fallback value:

```zig
const img = stbz.loadPngFile(allocator, "optional.png") catch blk: {
    // Create a default image
    break :blk try stbz.Image.init(allocator, 100, 100, 4);
};
defer img.deinit();
```

## Common Error Scenarios

### File Not Found

```zig
const img = stbz.loadPngFile(allocator, "missing.png") catch |err| {
    if (err == error.FileNotFound) {
        std.debug.print("Image file does not exist\n", .{});
        // Maybe create a default image?
        return try stbz.Image.init(allocator, 640, 480, 4);
    }
    return err;
};
defer img.deinit();
```

### Invalid Format

```zig
const img = stbz.loadJpegFile(allocator, "image.jpg") catch |err| {
    if (err == error.InvalidSignature or err == error.UnsupportedFormat) {
        std.debug.print("File is not a valid JPEG\n", .{});
        std.debug.print("Try converting it first or check the file path\n", .{});
        return err;
    }
    return err;
};
defer img.deinit();
```

### Out of Memory

```zig
const img = stbz.loadPngFile(allocator, "huge.png") catch |err| {
    if (err == error.OutOfMemory) {
        std.debug.print("Image too large to load into memory\n", .{});
        std.debug.print("Try using streaming API: stbz.streamingResize()\n", .{});
        return err;
    }
    return err;
};
defer img.deinit();
```

### Corrupt Image Data

```zig
const img = stbz.loadPngFile(allocator, "corrupt.png") catch |err| {
    switch (err) {
        error.InvalidChunkSize,
        error.InvalidImageData,
        error.DecompressionFailed,
        => {
            std.debug.print("Image file is corrupted\n", .{});
            return err;
        },
        else => return err,
    }
};
defer img.deinit();
```

### Operation Out of Bounds

```zig
var img = try stbz.loadPngFile(allocator, "input.png");
defer img.deinit();

// Try to crop beyond image bounds
const cropped = img.crop(1000, 1000, 100, 100) catch |err| {
    if (err == error.CropOutOfBounds) {
        std.debug.print("Crop region extends beyond image bounds\n", .{});
        std.debug.print("Image size: {}x{}\n", .{img.width, img.height});
        return err;
    }
    return err;
};
defer cropped.deinit();
```

## Best Practices

### 1. Always Handle or Propagate Errors

Never ignore errors. Either handle them explicitly or propagate with `try`:

```zig
// Bad: ignoring errors
_ = stbz.loadPngFile(allocator, "input.png");

// Good: propagate errors
var img = try stbz.loadPngFile(allocator, "input.png");

// Good: handle errors
var img = stbz.loadPngFile(allocator, "input.png") catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};
```

### 2. Use errdefer for Cleanup

When a function allocates multiple resources, use `errdefer` to ensure cleanup on error:

```zig
pub fn loadAndProcess(allocator: Allocator) !Image {
    var temp = try stbz.loadPngFile(allocator, "temp.png");
    errdefer temp.deinit();

    var processed = try temp.resize(800, 600);
    errdefer processed.deinit();

    temp.deinit(); // Success, manual cleanup
    return processed;
}
```

### 3. Provide Context in Error Messages

When catching errors, provide helpful context:

```zig
const img = stbz.loadPngFile(allocator, path) catch |err| {
    std.debug.print("Failed to load '{s}': {}\n", .{path, err});
    return err;
};
defer img.deinit();
```

### 4. Use Logging for Diagnostics

For libraries, use scoped logging instead of printing errors:

```zig
const log = std.log.scoped(.my_app);

const img = stbz.loadPngFile(allocator, path) catch |err| {
    log.err("Failed to load image '{s}': {}", .{path, err});
    return err;
};
defer img.deinit();
```

### 5. Document Error Conditions

Document what errors your functions can return:

```zig
/// Loads and resizes an image from a file.
///
/// Returns:
/// - error.FileNotFound if the file doesn't exist
/// - error.InvalidSignature if the file is not a PNG
/// - error.OutOfMemory if allocation fails
/// - error.InvalidResizeDimensions if width or height is zero
pub fn loadAndResize(
    allocator: Allocator,
    path: []const u8,
    width: u32,
    height: u32,
) !Image {
    var img = try stbz.loadPngFile(allocator, path);
    errdefer img.deinit();

    var resized = try img.resize(width, height);
    img.deinit();

    return resized;
}
```

### 6. Validate Input Before Operations

Check preconditions to provide better error messages:

```zig
pub fn safeCrop(img: *const Image, x: u32, y: u32, w: u32, h: u32) !Image {
    if (w == 0 or h == 0) {
        std.debug.print("Crop dimensions must be non-zero\n", .{});
        return error.InvalidCropDimensions;
    }

    if (x + w > img.width or y + h > img.height) {
        std.debug.print("Crop region ({},{} {}x{}) extends beyond image ({}x{})\n",
            .{x, y, w, h, img.width, img.height});
        return error.CropOutOfBounds;
    }

    return img.crop(x, y, w, h);
}
```

### 7. Use Arena Allocators for Batch Operations

Arena allocators simplify error handling by cleaning up everything at once:

```zig
pub fn processBatch(base_allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit(); // Frees everything, even on error

    const allocator = arena.allocator();

    var img1 = try stbz.loadPngFile(allocator, "image1.png");
    var img2 = try stbz.loadPngFile(allocator, "image2.png");
    var img3 = try stbz.loadPngFile(allocator, "image3.png");

    // No need for individual deinit() calls - arena handles it
    // If any operation fails, arena.deinit() cleans up everything
}
```

### 8. Recover Gracefully

When possible, provide fallback behavior:

```zig
pub fn loadImageWithFallback(allocator: Allocator, path: []const u8) !Image {
    return stbz.loadPngFile(allocator, path) catch |err| {
        std.log.warn("Failed to load {s}: {}, using placeholder", .{path, err});
        return createPlaceholderImage(allocator);
    };
}
```

## Testing Error Paths

Always test error conditions:

```zig
test "loadPngFile returns error for invalid signature" {
    const allocator = std.testing.allocator;

    // Create a file with invalid signature
    const invalid_data = [_]u8{0xFF, 0xD8, 0xFF, 0xE0}; // JPEG signature

    const result = stbz.loadPngMemory(allocator, &invalid_data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "crop returns error for out of bounds" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 100, 100, 4);
    defer img.deinit();

    const result = img.crop(90, 90, 20, 20);
    try std.testing.expectError(error.CropOutOfBounds, result);
}
```

## See Also

- [USAGE.md](USAGE.md) - API usage guide
- [EXAMPLES.md](EXAMPLES.md) - Code examples
- [ARCHITECTURE.md](ARCHITECTURE.md) - Internal architecture
