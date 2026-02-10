# stbz Architecture

This document describes the architecture, design decisions, and internal structure of the stbz image library.

## Table of Contents

- [Project Overview](#project-overview)
- [Module Structure](#module-structure)
- [Design Principles](#design-principles)
- [PNG Implementation](#png-implementation)
- [JPEG Implementation](#jpeg-implementation)
- [Streaming Architecture](#streaming-architecture)
- [Memory Management](#memory-management)
- [Testing Strategy](#testing-strategy)

## Project Overview

stbz is a pure Zig image library that provides:
- PNG decoding and encoding
- JPEG decoding (baseline and progressive)
- Image manipulation operations
- Low-memory streaming operations

**Goals**:
- Pixel-perfect compatibility with stb_image
- Zero C dependencies (except for testing)
- Memory-efficient streaming operations
- Explicit error handling
- Custom allocator support

## Module Structure

```
stbz/
├── src/
│   ├── stbz.zig           # Main entry point (public API)
│   ├── image.zig           # Image data structure and operations
│   ├── png.zig             # PNG decoder/encoder (high-level)
│   ├── decode_context.zig  # PNG decoding context (shared)
│   ├── jpeg.zig            # JPEG decoder (baseline + progressive)
│   ├── streaming.zig       # Low-memory streaming operations
│   └── cli.zig             # Command-line interface
├── test/
│   ├── test_png.zig        # PNG integration tests vs stb_image
│   ├── test_jpeg.zig       # JPEG integration tests vs stb_image
│   ├── test_jpeg_unit.zig  # JPEG unit tests (no C dependency)
│   ├── test_error_handling.zig  # Error path tests
│   ├── bench.zig           # Performance benchmarks
│   └── fixtures/           # Test images
└── reference/
    └── ref_impl.c          # C reference (stb_image wrapper)
```

### Module Responsibilities

#### `stbz.zig` (Main Entry Point)
- Re-exports public API from all modules
- Provides convenience functions for common operations
- Documentation hub for the library

#### `image.zig` (Core Data Structure)
- `Image` struct: width, height, channels, data buffer
- Pixel access: `getPixel`, `setPixel`
- Transformations: resize, crop, rotate, flip
- Uses bilinear interpolation for resizing (fixed-point math)

#### `png.zig` (PNG Format)
- High-level functions: `loadFromFile`, `saveToFile`, etc.
- Low-level functions: `decode`, `encode` (work with readers/writers)
- Delegates to `decode_context.zig` for shared decoding logic
- Encoder uses zlib compression with default settings

#### `decode_context.zig` (PNG Decoding)
- `PngDecodeContext`: shared state for PNG decoding
- Chunk parsing (IHDR, IDAT, PLTE, tRNS, etc.)
- Filter application (None, Sub, Up, Average, Paeth)
- Interlacing support (Adam7)
- Used by both regular decoder and streaming decoder

#### `jpeg.zig` (JPEG Format)
- Baseline DCT (SOF0) and Progressive DCT (SOF2) support
- Huffman decoding with fast lookup tables
- IDCT using fixed-point integer math
- Chroma upsampling (bilinear interpolation)
- Component-based architecture for flexible color spaces

#### `streaming.zig` (Low-Memory Operations)
- `PngStreamingDecoder`: row-by-row decompression
- `PngRowWriter`: row-by-row compression
- `streamingResize`: combined decode + resize + encode
- Memory: O(width) instead of O(width × height)

#### `cli.zig` (Command-Line Tool)
- File format conversion
- Basic image operations
- Demonstration of library usage

### Module Dependencies

```
stbz.zig ─────────┬── image.zig
                   ├── jpeg.zig
                   ├── png.zig ──────────── decode_context.zig
                   └── streaming.zig ───┬── png.zig
                                        └── decode_context.zig

cli.zig ──────────────── stbz.zig
```

## Design Principles

### 1. Explicit Resource Management

All allocations are explicit and must be freed:

```zig
var img = try Image.init(allocator, width, height, channels);
defer img.deinit();
```

**Rationale**: Zig's philosophy of explicit control. No hidden allocations.

### 2. Custom Allocator Support

Every function that allocates takes an `Allocator` parameter:

```zig
pub fn loadPngFile(allocator: Allocator, path: []const u8) !Image
```

**Rationale**: Allows users to control allocation strategy (arena, pool, etc.).

### 3. Reader/Writer Abstraction

Core decoding/encoding works with `std.Io.Reader` and `std.Io.Writer`:

```zig
pub fn decode(allocator: Allocator, reader: *std.Io.Reader) !Image
pub fn encode(allocator: Allocator, img: *const Image, writer: *std.Io.Writer) !void
```

**Rationale**: Decouples I/O from format handling. Works with files, memory, network, etc.

### 4. Error Handling

All errors are explicit and typed:

```zig
pub const DecodeError = error{
    InvalidSignature,
    InvalidChunkSize,
    UnsupportedColorType,
    // ...
};
```

**Rationale**: Users can handle specific error cases or propagate with `try`.

### 5. Transformation Returns New Images

Operations like `resize()` return new `Image` instances:

```zig
var resized = try img.resize(800, 600);
defer resized.deinit();
```

**Rationale**: Simpler API, no in-place mutation concerns, composable operations.

### 6. Zero-Copy Where Possible

When reading images, we minimize copying:
- PNG decoder reads directly into final image buffer
- Streaming operations process data in-place

**Rationale**: Performance and memory efficiency.

## PNG Implementation

### Decoding Pipeline

```
Reader → Signature Check → Chunk Parsing → Decompression → Filter Removal → Image
```

1. **Signature Check**: Verify 8-byte PNG signature
2. **Chunk Parsing**: Read chunks (IHDR, IDAT, PLTE, etc.)
3. **IDAT Decompression**: Zlib decompress concatenated IDAT chunks
4. **Filter Removal**: Apply PNG filters (Sub, Up, Average, Paeth)
5. **Image Construction**: Build final `Image` struct

### Filter Types

PNG uses 5 filter types to improve compression:

- **None (0)**: No filtering
- **Sub (1)**: Difference from left pixel
- **Up (2)**: Difference from pixel above
- **Average (3)**: Difference from average of left and above
- **Paeth (4)**: Difference from Paeth predictor (a, b, c)

Filters are applied per-scanline and must be reversed during decoding.

### Interlacing (Adam7)

PNG supports 7-pass interlaced images for progressive display:

```
Pass 1: Every 8th pixel (starting at 0, 0)
Pass 2: Every 8th pixel (starting at 4, 0)
Pass 3: Every 4th pixel (starting at 0, 4)
...
Pass 7: Every remaining pixel
```

Each pass is decoded separately, then scattered into the final image.

### Encoding

PNG encoding uses a simplified approach:
- IHDR chunk: width, height, bit depth, color type
- IDAT chunk: zlib-compressed image data (no filtering yet)
- IEND chunk: end marker

**Note**: Currently no filter optimization. All scanlines use Filter 0 (None).

## JPEG Implementation

### Decoding Pipeline

```
Reader → Marker Parsing → Huffman/Quantization Tables → Scan Decoding → IDCT → Upsampling → YCbCr→RGB → Image
```

1. **Marker Parsing**: Read JPEG markers (SOI, SOF, DHT, DQT, SOS, EOI)
2. **Table Setup**: Build Huffman and quantization tables
3. **Scan Decoding**: Decode entropy-coded data (baseline or progressive)
4. **IDCT**: Inverse Discrete Cosine Transform (8x8 blocks)
5. **Upsampling**: Bilinear chroma upsampling (for 4:2:2, 4:2:0)
6. **Color Conversion**: YCbCr to RGB (fixed-point math)

### Huffman Decoding

Fast two-tier lookup:
- **Fast path**: 9-bit lookup table for codes ≤9 bits
- **Slow path**: Binary search for longer codes

```zig
const HuffmanTable = struct {
    fast: [512]u16,      // Fast lookup: bits → (length << 8 | symbol)
    symbols: [256]u8,    // Symbol list
    code_of: [256]u32,   // Code for each symbol
    size_of: [256]u8,    // Length for each symbol
    // ...
};
```

### IDCT (Inverse Discrete Cosine Transform)

Uses fixed-point integer math (12-bit fractional precision) to match stb_image:

```zig
// Fixed-point constants (x * 4096 + 0.5)
const f2f0_298 = 1229;  // 0.298 * 4096
const f2f2_053 = 8410;  // 2.053 * 4096
// ...
```

**Critical**: Must use POSITIVE constants only due to Zig 0.15.2 compiler bug with runtime * negative constant. Express negatives via subtraction.

### Progressive JPEG

Progressive JPEG encodes images in multiple scans:
- **DC scans**: Coarse image (DC coefficients only)
- **AC scans**: Refinement (AC coefficients in multiple passes)
- **Spectral selection**: Subset of frequencies per scan
- **Successive approximation**: Most significant bits first

Key implementation details:
- Coefficient buffers stored per component
- Refinement scans modify existing coefficients
- EOB run handling differs between first and refinement scans

### Chroma Upsampling

JPEG often uses chroma subsampling (4:2:0, 4:2:2) to reduce file size. During decoding, chroma channels must be upsampled to match luma resolution.

**stb_image uses bilinear interpolation** (not nearest-neighbor):

```zig
pub fn resampleRowHV2(...) {
    // Vertical + horizontal 2x upsampling
    // Interpolates between 4 source pixels
}
```

### YCbCr to RGB Conversion

Fixed-point conversion (16-bit fractional precision):

```zig
const cb = @as(i32, @intCast(cb_val)) - 128;
const cr = @as(i32, @intCast(cr_val)) - 128;
const y = @as(i32, @intCast(y_val));

const r = y + ((cr * 91881) >> 16);
const g = (y - ((cb * 22554) >> 16) - ((cr * 46802) >> 16)) & 0xffff0000;
const b = y + ((cb * 116130) >> 16);
```

**Note**: Green channel needs `& 0xffff0000` mask to match stb_image.

## Streaming Architecture

### Problem

Loading a 10000x10000 PNG requires ~400MB of memory. For resizing to 800x600, we only need 1.9MB output.

### Solution

Process image row-by-row:
1. Decode rows on-demand from compressed stream
2. Accumulate rows in small buffer
3. Resize rows incrementally
4. Encode output rows immediately

**Memory**: O(input_width + output_width) instead of O(input_width × input_height)

### PngStreamingDecoder

```zig
pub const PngStreamingDecoder = struct {
    ctx: PngDecodeContext,
    decompressor: std.compress.zlib.Decompressor,
    current_pass: usize,
    rows_decoded: usize,
    prev_row_buf: []u8,
    compressed_buf: []u8,
    // ...
};
```

**Key insight**: PNG compression is not row-aligned, but filters are. We buffer compressed data and decompress on-demand.

### PngRowWriter

```zig
pub const PngRowWriter = struct {
    compressor: std.compress.zlib.Compressor,
    filter_buf: []u8,
    prev_row: []u8,
    rows_written: usize,
    // ...
};
```

Compresses rows incrementally and writes IDAT chunks.

## Memory Management

### Allocation Patterns

1. **Image Buffer**: Single allocation for pixel data (`width * height * channels`)
2. **Temporary Buffers**: Allocated in decoder, freed before returning
3. **Streaming Buffers**: Allocated once, reused for entire operation

### Memory Safety

- All allocations checked with `try`
- `errdefer` used to cleanup on error
- No manual memory management (no malloc/free)
- Zig's safety checks catch buffer overflows in debug builds

### Performance Considerations

- Large allocations use `allocator.alloc()` (not stack)
- Temporary buffers freed immediately after use
- Arena allocators work well for batch operations

## Testing Strategy

### Unit Tests

Fast, no C dependencies. Test behavior and edge cases:

```zig
test "Image.crop extracts correct region" { ... }
test "JPEG Huffman decoding handles edge cases" { ... }
```

Run with: `zig build test`

### Integration Tests

Compare output against stb_image (C reference):

```zig
test "PNG decoding matches stb_image" {
    const zig_img = try stbz.loadPngFile(...);
    const c_img = loadReferenceImage(...);
    try expectImagesEqual(zig_img, c_img);
}
```

Run with: `zig build integration-test`

### Test Organization

- **Unit tests** (`zig build test`): Fast tests with no C dependencies
  - Located in `src/*.zig` and `test/test_jpeg_unit.zig`, `test/test_error_handling.zig`
  - Tests behavior, edge cases, error handling

- **Integration tests** (`zig build integration-test`): Pixel-perfect comparison vs stb_image
  - Located in `test/test_png.zig` and `test/test_jpeg.zig`
  - Compares output byte-for-byte against C reference implementation

### Test Fixtures

- Small images (4x4, 8x8): Test edge cases
- Medium images (64x64, 256x256): Test correctness
- Large images (4096x4096): Test performance
- Corrupt images: Test error handling

### Coverage Goals

- All format features tested (interlacing, progressive, subsampling, etc.)
- All error paths tested (invalid headers, corrupt data, etc.)
- Performance benchmarked against stb_image

## Design Trade-offs

### Pixel-Perfect vs. Performance

**Choice**: Pixel-perfect compatibility with stb_image

**Trade-off**: Sometimes less optimal (e.g., fixed-point math, specific IDCT constants)

**Rationale**: Compatibility is critical for drop-in replacement

### Streaming vs. Simplicity

**Choice**: Provide both simple API and streaming API

**Trade-off**: More code, more complexity

**Rationale**: Simple API for common cases, streaming for constrained environments

### Error Handling

**Choice**: Explicit error types, no panics

**Trade-off**: More verbose calling code

**Rationale**: Libraries should never crash user applications

## See Also

- [USAGE.md](USAGE.md) - How to use the API
- [API.md](API.md) - Complete API reference
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Error handling guide
- [EXAMPLES.md](EXAMPLES.md) - Code examples
