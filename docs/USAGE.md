# stbz Usage Guide

stbz is a Zig library for loading, manipulating, and saving PNG and JPEG images. It provides both high-level convenience functions and low-level streaming APIs for memory-constrained environments.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Overview](#api-overview)
  - [Image Operations](#image-operations)
  - [PNG Support](#png-support)
  - [JPEG Support](#jpeg-support)
  - [Streaming Operations](#streaming-operations)
- [Common Patterns](#common-patterns)

## Installation

Add stbz as a dependency in your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .stbz = .{
            .url = "https://github.com/yourusername/stbz/archive/main.tar.gz",
            .hash = "...",
        },
    },
}
```

Then in your `build.zig`:

```zig
const stbz = b.dependency("stbz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("stbz", stbz.module("stbz"));
```

## Quick Start

### Loading and Saving Images

```zig
const std = @import("std");
const stbz = @import("stbz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load a PNG image
    var img = try stbz.loadPngFile(allocator, "input.png");
    defer img.deinit();

    std.debug.print("Image: {}x{} with {} channels\n", .{
        img.width,
        img.height,
        img.channels,
    });

    // Save to JPEG format
    try stbz.savePngFile(&img, "output.png");
}
```

### Basic Image Manipulation

```zig
// Resize image
var resized = try img.resize(800, 600);
defer resized.deinit();

// Rotate image
var rotated = try img.rotate90();
defer rotated.deinit();

// Crop image
var cropped = try img.crop(100, 100, 200, 200);
defer cropped.deinit();

// Flip image
var flipped_h = try img.flipHorizontal();
defer flipped_h.deinit();

var flipped_v = try img.flipVertical();
defer flipped_v.deinit();
```

## API Overview

### Image Operations

The `Image` struct is the core data structure for representing images:

```zig
pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8,  // 1=grayscale, 2=grayscale+alpha, 3=RGB, 4=RGBA
    data: []u8,
    allocator: Allocator,

    // Create new image
    pub fn init(allocator: Allocator, width: u32, height: u32, channels: u8) !Image

    // Free image resources
    pub fn deinit(self: *Image) void

    // Pixel access
    pub fn getPixel(self: *const Image, x: u32, y: u32) []const u8
    pub fn setPixel(self: *Image, x: u32, y: u32, pixel: []const u8) void

    // Transformations
    pub fn resize(self: *const Image, new_width: u32, new_height: u32) !Image
    pub fn crop(self: *const Image, x: u32, y: u32, width: u32, height: u32) !Image
    pub fn rotate90(self: *const Image) !Image
    pub fn rotate180(self: *const Image) !Image
    pub fn rotate270(self: *const Image) !Image
    pub fn flipHorizontal(self: *const Image) !Image
    pub fn flipVertical(self: *const Image) !Image
};
```

**Important**: All transformation methods allocate a new `Image`. Remember to call `deinit()` on both the original and transformed images.

### PNG Support

#### High-Level API (File/Memory)

```zig
// Load PNG from file
pub fn loadPngFile(allocator: Allocator, path: []const u8) !Image

// Load PNG from memory buffer
pub fn loadPngMemory(allocator: Allocator, data: []const u8) !Image

// Save PNG to file
pub fn savePngFile(img: *const Image, path: []const u8) !void

// Save PNG to memory buffer (returns owned slice)
pub fn savePngMemory(allocator: Allocator, img: *const Image) ![]u8
```

#### Low-Level API (Reader/Writer)

```zig
// Decode PNG from any std.Io.Reader
pub fn decodePng(allocator: Allocator, reader: *std.Io.Reader) !Image

// Encode PNG to any std.Io.Writer
pub fn encodePng(allocator: Allocator, img: *const Image, writer: *std.Io.Writer) !void
```

Example with custom reader:

```zig
const file = try std.fs.cwd().openFile("image.png", .{});
defer file.close();

const buf = try allocator.alloc(u8, 65536);
defer allocator.free(buf);
var file_reader = file.reader(buf);

var img = try stbz.decodePng(allocator, &file_reader.interface);
defer img.deinit();
```

### JPEG Support

#### High-Level API (File/Memory)

```zig
// Load JPEG from file
pub fn loadJpegFile(allocator: Allocator, path: []const u8) !Image

// Load JPEG from memory buffer
pub fn loadJpegMemory(allocator: Allocator, data: []const u8) !Image
```

#### Low-Level API (Reader)

```zig
// Decode JPEG from any std.Io.Reader
pub fn decodeJpeg(allocator: Allocator, reader: *std.Io.Reader) !Image
```

**Note**: JPEG encoding is not yet implemented. Use PNG for saving images.

**JPEG Features**:
- Baseline DCT (SOF0)
- Progressive DCT (SOF2)
- Chroma subsampling (4:4:4, 4:2:2, 4:2:0)
- Grayscale and RGB color spaces

### Streaming Operations

For large images on memory-constrained systems, use streaming operations to avoid loading the entire image into memory.

#### Streaming Resize

Decompresses and resizes a PNG image row-by-row:

```zig
// Memory: O(compressed_size + width) instead of O(width × height)
pub fn streamingResize(
    allocator: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    new_width: u32,
    new_height: u32,
) !void
```

Example:

```zig
const input = try std.fs.cwd().openFile("large.png", .{});
defer input.close();
const output = try std.fs.cwd().createFile("thumbnail.png", .{});
defer output.close();

var in_buf: [65536]u8 = undefined;
var out_buf: [8192]u8 = undefined;
var in_reader = input.reader(&in_buf);
var out_writer = output.writer(&out_buf);

try stbz.streamingResize(
    allocator,
    &in_reader.interface,
    &out_writer.interface,
    800,
    600,
);
try out_writer.interface.flush();
```

#### Streaming Decoder

Decode PNG row-by-row with on-demand decompression:

```zig
pub const PngStreamingDecoder = struct {
    // Initialize decoder
    pub fn init(allocator: Allocator, reader: *std.Io.Reader) !PngStreamingDecoder

    // Get image dimensions
    pub fn width(self: *const PngStreamingDecoder) u32
    pub fn height(self: *const PngStreamingDecoder) u32
    pub fn channels(self: *const PngStreamingDecoder) u8

    // Read next row (decompresses on demand)
    pub fn nextRow(self: *PngStreamingDecoder, out_row: []u8) !bool

    // Cleanup
    pub fn deinit(self: *PngStreamingDecoder) void
};
```

Example:

```zig
var decoder = try stbz.PngStreamingDecoder.init(allocator, reader);
defer decoder.deinit();

const width = decoder.width();
const channels = decoder.channels();
const stride = width * channels;

var row_buffer = try allocator.alloc(u8, stride);
defer allocator.free(row_buffer);

while (try decoder.nextRow(row_buffer)) {
    // Process row...
}
```

#### Streaming Writer

Write PNG row-by-row for custom streaming operations:

```zig
pub const PngRowWriter = struct {
    // Initialize writer
    pub fn init(
        allocator: Allocator,
        writer: *std.Io.Writer,
        width: u32,
        height: u32,
        channels: u8,
    ) !PngRowWriter

    // Write next row (compresses and writes to output)
    pub fn writeRow(self: *PngRowWriter, row: []const u8) !void

    // Finish writing (flushes compression, writes IEND)
    pub fn finish(self: *PngRowWriter) !void

    // Cleanup
    pub fn deinit(self: *PngRowWriter) void
};
```

## Common Patterns

### Error Handling

All image operations return errors. Handle them explicitly:

```zig
const img = stbz.loadPngFile(allocator, "input.png") catch |err| {
    std.debug.print("Failed to load image: {}\n", .{err});
    return err;
};
defer img.deinit();
```

See [ERROR_HANDLING.md](ERROR_HANDLING.md) for detailed error handling guide.

### Working with Pixels

```zig
// Read pixel
const pixel = img.getPixel(x, y);
std.debug.print("RGB: ({}, {}, {})\n", .{ pixel[0], pixel[1], pixel[2] });

// Modify pixel
const red_pixel = [_]u8{ 255, 0, 0, 255 }; // RGBA
img.setPixel(x, y, &red_pixel);

// Direct buffer access (advanced)
const stride = img.width * img.channels;
const offset = (y * stride) + (x * img.channels);
const pixel_data = img.data[offset..][0..img.channels];
```

### Creating Images from Scratch

```zig
var img = try stbz.Image.init(allocator, 800, 600, 4);
defer img.deinit();

// Fill with white
@memset(img.data, 255);

// Draw a red square
for (100..200) |y| {
    for (100..200) |x| {
        const red = [_]u8{ 255, 0, 0, 255 };
        img.setPixel(@intCast(x), @intCast(y), &red);
    }
}

try stbz.savePngFile(&img, "output.png");
```

### Custom Allocators

stbz supports custom allocators throughout:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

var img = try stbz.loadPngFile(allocator, "input.png");
// No need to call img.deinit() - arena frees everything
```

### Loading from HTTP Response

```zig
const response = try http_client.get("https://example.com/image.png");
defer response.deinit();

var img = try stbz.loadPngMemory(allocator, response.body);
defer img.deinit();
```

### Progressive Loading (JPEG)

Progressive JPEG images are decoded automatically:

```zig
// Loads both baseline and progressive JPEGs
var img = try stbz.loadJpegFile(allocator, "progressive.jpg");
defer img.deinit();
```

## Performance Tips

1. **Use streaming operations** for large images to reduce memory usage
2. **Reuse allocations** when processing multiple images
3. **Use arena allocators** for batch operations
4. **Build with ReleaseFast** for production: `zig build -Doptimize=ReleaseFast`
5. **Direct buffer access** is faster than `getPixel`/`setPixel` for bulk operations

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - Project structure and design
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Error handling guide
- [EXAMPLES.md](EXAMPLES.md) - More code examples
