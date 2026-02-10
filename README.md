# stbz

A pure Zig image library for generating thumbnails and tiles. Decodes JPEG and PNG, encodes PNG. No C dependencies in the core library.

## Documentation

- **[Usage Guide](docs/USAGE.md)** - API usage and quick start
- **[Architecture](docs/ARCHITECTURE.md)** - Project structure and design
- **[Error Handling](docs/ERROR_HANDLING.md)** - Error handling patterns
- **[Examples](docs/EXAMPLES.md)** - Practical code examples
- **[API Reference](docs/API.md)** - Complete API documentation
- Generate API docs: `zig build docs` (outputs to `zig-out/docs/api`)

## Features

- **Decode**: JPEG (baseline + progressive) and PNG
- **Encode**: PNG
- Crop, resize (bilinear), thumbnail generation
- Rotate (90/180/270) and flip (horizontal/vertical)
- Low-memory streaming API for large images
- CLI tool for image processing

## Format Support

### JPEG (decode only)

| Feature | Status |
|---------|--------|
| Baseline DCT (SOF0) | Yes |
| Extended sequential DCT (SOF1) | Yes |
| Progressive DCT (SOF2) | Yes ✓ |
| Grayscale | Yes |
| YCbCr 4:4:4, 4:2:2, 4:2:0 | Yes |
| Restart markers (DRI) | Yes |
| DC/AC refinement scans | Yes |
| Arithmetic coding | No |

Progressive JPEG support includes all scan types (DC/AC first and refinement scans) for pixel-perfect decoding.

### PNG

| Feature | Decode | Encode |
|---------|--------|--------|
| RGB (8-bit) | Yes | Yes |
| RGBA (8-bit) | Yes | Yes |
| Grayscale (8-bit) | Yes | Yes |
| Grayscale+Alpha (8-bit) | Yes | Yes |
| Adam7 interlacing | Yes | No |
| All filter types (None, Sub, Up, Average, Paeth) | Yes | None only |

Not supported: palette/indexed color, 16-bit depth, 1/2/4-bit depth, ancillary chunks.

## Building

```bash
zig build
```

## Testing

### Running Tests

```bash
zig build test              # Run unit tests (58 tests, fast, no C deps)
zig build integration-test  # Run integration tests (11 tests, vs stb_image)
zig build test-all          # Run all tests (69 tests)
zig build test-large        # Test large image streaming (10000×10000)
zig build bench             # Performance benchmarks
```

**Test organization:**
- **Unit tests** (58 tests, ~70ms): No C dependencies, fast feedback
  - Image operations (18 tests)
  - PNG encoding/streaming (10 tests)
  - JPEG behavioral tests (12 tests)
  - Error handling tests (19 tests)
- **Integration tests** (11 tests, ~210ms): Pixel-perfect comparison vs stb_image
  - PNG comparison (7 tests)
  - JPEG comparison (4 tests)

### Test Fixtures

Test fixtures are located in `test/fixtures/`:

| File | Description | Use Case |
|------|-------------|----------|
| `test_rgb_4x4.png` | 4×4 RGB test pattern | Basic decode verification |
| `test_rgba_4x4.png` | 4×4 RGBA with transparency | Alpha channel testing |
| `test_gray_8x8.png` | 8×8 grayscale | Grayscale decode |
| `test_gray_alpha_8x8.png` | 8×8 grayscale + alpha | Grayscale with transparency |
| `test_interlaced_16x16.png` | 16×16 Adam7 interlaced | Interlaced PNG support |
| `landscape_600x400.png` | 600×400 photo | Real-world testing |
| `landscape_interlaced.png` | 600×400 interlaced | Large interlaced image |
| `test_gray_8x8.jpg` | 8×8 JPEG grayscale | JPEG grayscale |
| `test_rgb_4x4.jpg` | 4×4 JPEG RGB | JPEG YCbCr 4:4:4 |
| `test_rgb_4x4_progressive.jpg` | 4×4 progressive JPEG | Progressive JPEG with refinement scans |
| `landscape_600x400.jpg` | 600×400 JPEG photo | JPEG with subsampling |

### Comparison Testing

The test suite compares stbz output against the C reference implementation (stb_image):

```zig
// Example from test/test_png.zig
test "PNG decoder produces same output as stb_image for RGB" {
    const allocator = std.testing.allocator;

    // Load with C reference (stb_image)
    const ref = stb_load_png("test/fixtures/test_rgb_4x4.png");
    defer stb_free(ref.data);

    // Load with Zig implementation
    var zig_image = try stbz.loadPngFile(allocator, "test/fixtures/test_rgb_4x4.png");
    defer zig_image.deinit();

    // Compare pixel-by-pixel
    try std.testing.expectEqualSlices(u8, ref_slice, zig_image.data);
}
```

**What's tested:**
- Pixel-perfect output matching stb_image for all formats
- Progressive JPEG (all scan types, refinement scans)
- Edge cases (interlacing, different color types, subsampling)
- Error handling (invalid files, truncated data, corrupt markers)
- Image operations (crop, resize, rotate, flip)
- Streaming resize with minimal memory
- Round-trip encoding/decoding
- Memory leak detection

**Adding new test fixtures:**
1. Add image file to `test/fixtures/`
2. Create comparison test in `test/test_png.zig` or `test/test_jpeg.zig`
3. Verify stbz output matches stb_image byte-for-byte

## CLI Usage

```bash
# Crop a region from an image
stbz crop input.png output.png 100 100 200 200

# Resize an image
stbz resize input.png output.png 640 480

# Create a square thumbnail (crops to center, then resizes)
stbz thumbnail input.png thumb.png 128

# Rotate image (90, 180, or 270 degrees clockwise)
stbz rotate input.png output.png 90

# Flip image (h = horizontal, v = vertical)
stbz flip input.png output.png h
```

## Library Usage

### File-based API

```zig
const stbz = @import("stbz");

// Load an image (JPEG or PNG)
var image = try stbz.loadJpegFile(allocator, "photo.jpg");
// or: var image = try stbz.loadPngFile(allocator, "image.png");
defer image.deinit();

// Crop
var cropped = try image.crop(x, y, width, height);
defer cropped.deinit();

// Resize
var resized = try image.resize(new_width, new_height);
defer resized.deinit();

// Save as PNG
try stbz.savePngFile(&resized, "output.png");
```

### Reader/Writer API

For streaming and custom I/O sources:

```zig
const stbz = @import("stbz");

// Decode from any std.Io.Reader
var file = try std.fs.cwd().openFile("input.png", .{});
defer file.close();
var buf: [8192]u8 = undefined;
var file_reader = file.reader(&buf);

var image = try stbz.decodePng(allocator, &file_reader.interface);
defer image.deinit();

// Encode to any std.Io.Writer
var out_file = try std.fs.cwd().createFile("output.png", .{});
defer out_file.close();
var out_buf: [8192]u8 = undefined;
var file_writer = out_file.writer(&out_buf);

try stbz.encodePng(allocator, &image, &file_writer.interface);
try file_writer.interface.flush();
```

### Low-Memory Streaming

For large images on memory-constrained systems, use incremental processing.
**Note:** For typical use cases, prefer the simpler `Image` API (crop, resize, etc).

```zig
// Streaming resize: decompresses PNG row-by-row while resizing
// Memory: O(compressed_size + width) instead of O(width × height)
try stbz.streamingResize(allocator, &reader, &writer, new_width, new_height);

// For custom streaming operations, use the row-based decoder:
var decoder = try stbz.PngStreamingDecoder.init(allocator, &reader, .{});
defer decoder.deinit();

while (try decoder.readRow()) |row_data| {
    // Process one row at a time
    // row_data: []const u8 (width × channels bytes)
}
```

**Memory comparison (4000×3000 RGB image):**
| Operation | Standard API | Streaming API |
|-----------|--------------|---------------|
| Resize | ~36 MB (full decoded image) | ~3.6 MB (compressed + 2 rows) |

**Trade-offs:**
- ✓ Dramatically lower memory usage
- ✓ Works on memory-constrained systems
- ✗ Cannot seek backward (sequential only)
- ✗ More complex API

## Benchmarks

Compare stbz performance against the C reference (stb_image):

```bash
zig build bench                                    # Full comparison table
zig build bench -- png-decode-zig                  # Single benchmark (for memory profiling)
/usr/bin/time -v zig-out/bin/bench png-decode-zig  # Measure peak memory
```

Available individual benchmarks: `png-decode-zig`, `png-decode-c`, `jpeg-decode-zig`, `jpeg-decode-c`, `png-encode-zig`, `png-encode-c`, `resize-zig`, `resize-c`.

## Test Images

The test fixture `landscape_600x400.png` is a photo of Cinque Terre, Italy, sourced from W3Schools and used for testing purposes.

## License

Public domain (same as stb libraries)
