# zpix

A pure Zig image library for generating thumbnails and tiles. Decodes JPEG and PNG, encodes PNG. No C dependencies in the core library.

This was written by AI.

## Documentation

- **[Usage Guide](docs/USAGE.md)** - Library and CLI usage
- **[Architecture](docs/ARCHITECTURE.md)** - Module structure and data flow
- **[Coding Conventions](docs/CODING_CONVENTIONS.md)** - Zig conventions for this project
- Generate API docs: `zig build docs` (outputs to `zig-out/docs/api`)

## Features

- **Decode**: JPEG (baseline + progressive) and PNG
- **Encode**: PNG
- Crop, resize (bilinear), thumbnail generation
- Rotate (90/180/270) and flip (horizontal/vertical)
- JPEG encoding (baseline)
- CLI tool for image processing

## Format Support

### JPEG

| Feature | Decode | Encode |
|---------|--------|--------|
| Baseline DCT (SOF0) | Yes | Yes |
| Extended sequential DCT (SOF1) | Yes | No |
| Progressive DCT (SOF2) | Yes | No |
| Grayscale | Yes | Yes |
| YCbCr 4:4:4, 4:2:2, 4:2:0 | Yes | 4:4:4 only |
| Restart markers (DRI) | Yes | No |
| DC/AC refinement scans | Yes | N/A |
| Arithmetic coding | No | No |

Progressive JPEG decoding includes all scan types (DC/AC first and refinement scans) for pixel-perfect output.

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

## Library Usage

### File-based API

File-based APIs take an `io: std.Io` instance as their first argument. Get
one from "Juicy Main" (`init.io`) or, in tests, from `std.testing.io`.

```zig
const zpix = @import("zpix");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Load any image (auto-detects format by magic bytes)
    var image = try zpix.loadFile(io, allocator, "photo.jpg");
    defer image.deinit();

    // Or load a specific format
    var png_image = try zpix.loadPngFile(io, allocator, "image.png");
    defer png_image.deinit();

    // Crop
    var cropped = try image.crop(x, y, width, height);
    defer cropped.deinit();

    // Resize
    var resized = try image.resize(new_width, new_height);
    defer resized.deinit();

    // Save (auto-detects format by file extension)
    try zpix.saveFile(io, &resized, "output.png");
    try zpix.saveFile(io, &resized, "output.jpg");

    // Or save a specific format
    try zpix.savePngFile(io, &resized, "output.png");
    try zpix.saveJpegFile(io, &resized, "output.jpg", 90); // quality 1-100
}
```

### Memory API

```zig
const zpix = @import("zpix");

// Load/save from memory buffers
var image = try zpix.loadPngMemory(allocator, png_bytes);
defer image.deinit();

const png_output = try zpix.savePngMemory(allocator, &image);
defer allocator.free(png_output);

const jpeg_output = try zpix.saveJpegMemory(allocator, &image, 90);
defer allocator.free(jpeg_output);
```

## CLI Usage

```bash
# Crop a region from an image
zpix crop input.png output.png 100 100 200 200

# Resize an image
zpix resize input.png output.png 640 480

# Create a square thumbnail (crops to center, then resizes)
zpix thumbnail input.png thumb.png 128

# Rotate image (90, 180, or 270 degrees clockwise)
zpix rotate input.png output.png 90

# Flip image (h = horizontal, v = vertical)
zpix flip input.png output.png h
```

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

The test suite compares zpix output against the C reference implementation (stb_image):

```zig
// Example from test/test_png.zig
test "PNG decoder produces same output as stb_image for RGB" {
    const allocator = std.testing.allocator;

    // Load with C reference (stb_image)
    const ref = stb_load_png("test/fixtures/test_rgb_4x4.png");
    defer stb_free(ref.data);

    // Load with Zig implementation
    var zig_image = try zpix.loadPngFile(std.testing.io, allocator, "test/fixtures/test_rgb_4x4.png");
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
- Round-trip encoding/decoding
- Memory leak detection

**Adding new test fixtures:**
1. Add image file to `test/fixtures/`
2. Create comparison test in `test/test_png.zig` or `test/test_jpeg.zig`
3. Verify zpix output matches stb_image byte-for-byte

## Benchmarks

Compare zpix performance against the C reference (stb_image):

```bash
zig build bench                                    # Full comparison table
zig build bench -- png-decode-zig                  # Single benchmark (for memory profiling)
/usr/bin/time -v zig-out/bin/bench png-decode-zig  # Measure peak memory
```

Available individual benchmarks: `png-decode-zig`, `png-decode-c`, `jpeg-decode-zig`, `jpeg-decode-c`, `png-encode-zig`, `png-encode-c`, `resize-zig`, `resize-c`.

## Test Images

The test fixture `landscape_600x400.png` is a photo of Cinque Terre, Italy, sourced from W3Schools and used for testing purposes.

## License

MIT License. See [MIT.txt](MIT.txt) for details.
