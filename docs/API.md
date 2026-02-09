# stbz API Reference

Complete API documentation for the stbz image library.

## Table of Contents

- [Image Type](#image-type)
- [Decoding](#decoding)
- [Encoding](#encoding)
- [Image Operations](#image-operations)
- [Streaming Operations](#streaming-operations)
- [Error Handling](#error-handling)

## Image Type

### `Image`

The core image data structure.

```zig
pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8,  // 1=grayscale, 2=grayscale+alpha, 3=RGB, 4=RGBA
    data: []u8,
    allocator: Allocator,
}
```

**Fields:**
- `width`: Image width in pixels
- `height`: Image height in pixels
- `channels`: Number of color channels (1-4)
- `data`: Raw pixel data in row-major order, interleaved channels
- `allocator`: The allocator used to create this image

**Memory Layout:**

Pixels are stored in row-major order with interleaved channels:
```
[R0G0B0][R1G1B1][R2G2B2]...  // Row 0
[R0G0B0][R1G1B1][R2G2B2]...  // Row 1
...
```

For a pixel at `(x, y)`, the data starts at index: `(y * width + x) * channels`

### `Image.init`

Create a new image with zero-initialized pixel data.

```zig
pub fn init(allocator: Allocator, width: u32, height: u32, channels: u8) !Image
```

**Parameters:**
- `allocator`: Memory allocator to use
- `width`: Image width in pixels
- `height`: Image height in pixels
- `channels`: Number of channels (1-4)

**Returns:** A new `Image` with all pixels initialized to 0

**Errors:** `Allocator.Error` if allocation fails

**Example:**
```zig
const stbz = @import("stbz");

var img = try stbz.Image.init(allocator, 640, 480, 3); // 640x480 RGB
defer img.deinit();
```

### `Image.deinit`

Free the image's pixel data.

```zig
pub fn deinit(self: *Image) void
```

**Note:** You MUST call `deinit()` on every image to avoid memory leaks.

### `Image.getPixel`

Get a pixel value at the specified coordinates.

```zig
pub fn getPixel(self: *const Image, x: u32, y: u32) []const u8
```

**Parameters:**
- `x`: X coordinate (0 to width-1)
- `y`: Y coordinate (0 to height-1)

**Returns:** Slice of length `channels` containing the pixel data

**Panics:** If coordinates are out of bounds (in debug builds)

**Example:**
```zig
const pixel = img.getPixel(10, 20);
const red = pixel[0];
const green = pixel[1];
const blue = pixel[2];
```

### `Image.setPixel`

Set a pixel value at the specified coordinates.

```zig
pub fn setPixel(self: *Image, x: u32, y: u32, pixel: []const u8) void
```

**Parameters:**
- `x`: X coordinate (0 to width-1)
- `y`: Y coordinate (0 to height-1)
- `pixel`: Slice of length `channels` containing new pixel data

**Panics:** If coordinates are out of bounds or pixel length doesn't match channels

**Example:**
```zig
const red_pixel = [_]u8{ 255, 0, 0 };
img.setPixel(10, 20, &red_pixel);
```

## Decoding

### `decodePng`

Decode a PNG image from any `std.Io.Reader`.

```zig
pub fn decodePng(allocator: Allocator, reader: *std.Io.Reader) !Image
```

**Parameters:**
- `allocator`: Memory allocator
- `reader`: PNG data source

**Returns:** Decoded `Image`

**Errors:**
- `DecodeError.InvalidSignature` - Not a valid PNG file
- `DecodeError.UnsupportedColorType` - Unsupported color type
- `DecodeError.UnsupportedBitDepth` - Only 8-bit is supported
- `DecodeError.DecompressionFailed` - Zlib decompression failed
- `Allocator.Error` - Memory allocation failed
- `std.Io.Reader.Error` - I/O error

**Supported formats:**
- RGB, RGBA, Grayscale, Grayscale+Alpha
- 8-bit depth only
- Adam7 interlacing supported
- All filter types (None, Sub, Up, Average, Paeth)

**Example:**
```zig
var file = try std.fs.cwd().openFile("image.png", .{});
defer file.close();
var buf: [8192]u8 = undefined;
var file_reader = file.reader(&buf);

var img = try stbz.decodePng(allocator, &file_reader.interface);
defer img.deinit();
```

### `loadPngFile`

Convenience function to load a PNG from a file path.

```zig
pub fn loadPngFile(allocator: Allocator, path: []const u8) !Image
```

**Example:**
```zig
var img = try stbz.loadPngFile(allocator, "photo.png");
defer img.deinit();
```

### `loadPngMemory`

Decode a PNG from a memory buffer.

```zig
pub fn loadPngMemory(allocator: Allocator, data: []const u8) !Image
```

**Example:**
```zig
const png_data = try std.fs.cwd().readFileAlloc(allocator, "photo.png", 10_000_000);
defer allocator.free(png_data);

var img = try stbz.loadPngMemory(allocator, png_data);
defer img.deinit();
```

### `decodeJpeg`

Decode a JPEG image from any `std.Io.Reader`.

```zig
pub fn decodeJpeg(allocator: Allocator, reader: *std.Io.Reader) !Image
```

**Supported formats:**
- Baseline DCT (SOF0)
- Grayscale
- YCbCr with 4:4:4, 4:2:2, 4:2:0 chroma subsampling
- Restart markers (DRI)

**Not supported:**
- Progressive JPEG (SOF2)
- Arithmetic coding

**Example:**
```zig
var img = try stbz.loadJpegFile(allocator, "photo.jpg");
defer img.deinit();
```

### `loadJpegFile`

Convenience function to load a JPEG from a file path.

```zig
pub fn loadJpegFile(allocator: Allocator, path: []const u8) !Image
```

### `loadJpegMemory`

Decode a JPEG from a memory buffer.

```zig
pub fn loadJpegMemory(allocator: Allocator, data: []const u8) !Image
```

## Encoding

### `encodePng`

Encode an image to PNG format using any `std.Io.Writer`.

```zig
pub fn encodePng(allocator: Allocator, img: *const Image, writer: *std.Io.Writer) !void
```

**Parameters:**
- `allocator`: Memory allocator for temporary buffers
- `img`: Image to encode
- `writer`: PNG data destination

**Output format:**
- No filtering (filter type 0)
- Deflate compression
- No interlacing
- No ancillary chunks

**Example:**
```zig
var out_file = try std.fs.cwd().createFile("output.png", .{});
defer out_file.close();
var out_buf: [8192]u8 = undefined;
var file_writer = out_file.writer(&out_buf);

try stbz.encodePng(allocator, &img, &file_writer.interface);
try file_writer.interface.flush();
```

### `savePngFile`

Convenience function to save a PNG to a file path.

```zig
pub fn savePngFile(img: *const Image, path: []const u8) !void
```

**Example:**
```zig
try stbz.savePngFile(&img, "output.png");
```

### `savePngMemory`

Encode a PNG to a memory buffer (returned as owned slice).

```zig
pub fn savePngMemory(allocator: Allocator, img: *const Image) ![]u8
```

**Returns:** Owned slice containing PNG data. Caller must free with `allocator.free()`.

**Example:**
```zig
const png_data = try stbz.savePngMemory(allocator, &img);
defer allocator.free(png_data);
```

## Image Operations

All image operations return a new image and do not modify the original.

### `Image.crop`

Extract a rectangular region from the image.

```zig
pub fn crop(self: *const Image, x: u32, y: u32, crop_width: u32, crop_height: u32) !Image
```

**Parameters:**
- `x`: Starting X coordinate (top-left)
- `y`: Starting Y coordinate (top-left)
- `crop_width`: Width of cropped region
- `crop_height`: Height of cropped region

**Returns:** New `Image` containing the cropped region

**Errors:**
- `error.CropOutOfBounds` - Crop region extends beyond image bounds
- `error.InvalidCropDimensions` - Width or height is 0

**Example:**
```zig
// Crop 200x200 region starting at (100, 100)
var cropped = try img.crop(100, 100, 200, 200);
defer cropped.deinit();
```

### `Image.resize`

Resize the image using bilinear interpolation.

```zig
pub fn resize(self: *const Image, new_width: u32, new_height: u32) !Image
```

**Parameters:**
- `new_width`: Target width
- `new_height`: Target height

**Returns:** New `Image` with specified dimensions

**Errors:**
- `error.InvalidResizeDimensions` - Width or height is 0

**Algorithm:** Fixed-point bilinear interpolation for smooth results

**Example:**
```zig
var resized = try img.resize(640, 480);
defer resized.deinit();
```

### `Image.rotate90`

Rotate the image 90 degrees clockwise.

```zig
pub fn rotate90(self: *const Image) !Image
```

**Returns:** New `Image` rotated 90° CW (width and height are swapped)

**Example:**
```zig
var rotated = try img.rotate90();
defer rotated.deinit();
```

### `Image.rotate180`

Rotate the image 180 degrees.

```zig
pub fn rotate180(self: *const Image) !Image
```

### `Image.rotate270`

Rotate the image 270 degrees clockwise (= 90 degrees counter-clockwise).

```zig
pub fn rotate270(self: *const Image) !Image
```

### `Image.flipHorizontal`

Flip the image horizontally (mirror left-right).

```zig
pub fn flipHorizontal(self: *const Image) !Image
```

### `Image.flipVertical`

Flip the image vertically (mirror top-bottom).

```zig
pub fn flipVertical(self: *const Image) !Image
```

## Streaming Operations

Streaming operations process images with minimal memory usage by working row-by-row.

### Memory Usage Comparison

For a 4000×3000 RGB image:

| Operation | Memory Usage |
|-----------|--------------|
| `Image.resize()` | ~36 MB (full decoded image) |
| `streamingResize()` | ~3.6 MB (compressed PNG + row buffers) |

### `streamingResize`

Resize a PNG with low memory usage using incremental decompression.

```zig
pub fn streamingResize(
    allocator: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    new_width: u32,
    new_height: u32,
) !void
```

**Memory:** O(compressed_size + width × channels)

**Algorithm:** Bilinear interpolation with row-by-row processing

**Example:**
```zig
var in_file = try std.fs.cwd().openFile("large.png", .{});
defer in_file.close();
var out_file = try std.fs.cwd().createFile("resized.png", .{});
defer out_file.close();

var in_buf: [8192]u8 = undefined;
var out_buf: [8192]u8 = undefined;
var reader = in_file.reader(&in_buf);
var writer = out_file.writer(&out_buf);

try stbz.streamingResize(allocator, &reader.interface, &writer.interface, 800, 600);
try writer.interface.flush();
```

### Advanced Streaming Types

#### `PngStreamingDecoder`

Row-by-row PNG decoder for custom processing.

```zig
pub const PngStreamingDecoder = struct {
    pub fn init(allocator: Allocator, reader: *std.Io.Reader, options: InitOptions) !PngStreamingDecoder
    pub fn deinit(self: *PngStreamingDecoder) void
    pub fn readRow(self: *PngStreamingDecoder) !?[]const u8
    pub fn reset(self: *PngStreamingDecoder) void
}
```

**Example:**
```zig
var decoder = try stbz.PngStreamingDecoder.init(allocator, &reader, .{});
defer decoder.deinit();

while (try decoder.readRow()) |row| {
    // Process row (width * channels bytes)
    // Do NOT free the row - it's internal to the decoder
}
```

#### `PngRowWriter`

Row-by-row PNG encoder for custom generation.

```zig
pub const PngRowWriter = struct {
    pub fn init(allocator: Allocator, writer: *std.Io.Writer, width: u32, height: u32, channels: u8) !PngRowWriter
    pub fn deinit(self: *PngRowWriter) void
    pub fn writeRow(self: *PngRowWriter, row: []const u8) !void
    pub fn finish(self: *PngRowWriter) !void
}
```

**Example:**
```zig
var row_writer = try stbz.PngRowWriter.init(allocator, &writer, 640, 480, 3);
defer row_writer.deinit();

for (0..480) |y| {
    var row: [640 * 3]u8 = undefined;
    // Fill row with pixel data...
    try row_writer.writeRow(&row);
}

try row_writer.finish();
try writer.interface.flush();
```

#### `PngInfo`

PNG header information.

```zig
pub const PngInfo = struct {
    width: u32,
    height: u32,
    channels: u8,
}
```

## Error Handling

### Decode Errors

```zig
pub const DecodeError = error{
    InvalidSignature,        // Not a valid PNG/JPEG file
    InvalidChunk,           // Corrupted PNG chunk
    UnsupportedColorType,   // Unsupported PNG color type
    UnsupportedBitDepth,    // Only 8-bit depth supported
    UnsupportedInterlace,   // Invalid interlace method
    InvalidFilter,          // Invalid PNG filter type
    DecompressionFailed,    // Zlib decompression failed
    InvalidImageData,       // Corrupted image data
    CropOutOfBounds,        // Crop region invalid
    InvalidResizeDimensions,// Resize dimensions invalid
};
```

### JPEG-specific Errors

```zig
pub const JpegError = error{
    InvalidSignature,
    InvalidMarker,
    UnsupportedFormat,      // Progressive/arithmetic coding
    InvalidQuantizationTable,
    InvalidHuffmanTable,
    InvalidFrameHeader,
    InvalidScanHeader,
    InvalidData,
    HuffmanDecodeFailed,
    InvalidCoefficientIndex,
    UnsupportedSubsampling,
    UnexpectedEndOfData,
    OutOfMemory,
};
```

### Error Handling Example

```zig
const img = stbz.loadPngFile(allocator, path) catch |err| switch (err) {
    error.InvalidSignature => {
        std.log.err("Not a valid PNG file: {s}", .{path});
        return;
    },
    error.UnsupportedBitDepth => {
        std.log.err("Only 8-bit PNGs are supported", .{});
        return;
    },
    error.OutOfMemory => {
        std.log.err("Out of memory loading {s}", .{path});
        return;
    },
    else => return err,
};
defer img.deinit();
```

## Best Practices

### Memory Management

1. **Always call `deinit()`** on images to avoid leaks
2. **Use `defer img.deinit()`** immediately after creation
3. **Free intermediate results** when chaining operations:

```zig
// Good: frees intermediate image
var cropped = try img.crop(0, 0, 100, 100);
defer cropped.deinit();
var resized = try cropped.resize(50, 50);
defer resized.deinit();

// Also good: explicit cleanup
var cropped = try img.crop(0, 0, 100, 100);
var resized = try cropped.resize(50, 50);
cropped.deinit();
defer resized.deinit();
```

### Performance

1. **Use streaming operations** for large images to minimize memory
2. **Reuse allocators** - don't create a new allocator per operation
3. **Choose appropriate buffer sizes** - 8KB-64KB for file I/O

### Error Handling

1. **Check specific errors** you can handle, propagate others
2. **Use `errdefer`** when cleanup is needed on error paths
3. **Log context** when catching errors at application boundaries

## Platform Support

- Linux, macOS, Windows
- x86_64, ARM64
- Requires Zig 0.15.2 or later

## Thread Safety

`Image` operations are **not thread-safe**. Do not share `Image` instances or streaming decoders/encoders between threads without external synchronization.

Different threads can safely:
- Use separate `Image` instances
- Use separate allocators
- Call pure functions like `decodePng` concurrently with different inputs
