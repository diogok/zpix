# Architecture

stbz is a pure Zig image library for generating thumbnails and tiles. Decodes JPEG and PNG, encodes PNG. No C dependencies in the core library — C reference headers (stb_image) are only used for comparison tests.

## Source Map

```
src/
├── stbz.zig            Main entry point. Re-exports all public APIs.
├── image.zig            Image struct and operations (crop, resize, rotate, flip).
├── jpeg.zig             JPEG baseline decoder (SOF0, YCbCr, grayscale).
├── png.zig              PNG encoder/decoder (file and reader/writer APIs).
├── decode_context.zig   Shared PNG decoding: chunk parsing, decompression, filters.
├── streaming.zig        Row-by-row streaming operations for low-memory processing.
└── cli.zig              CLI tool (crop, resize, thumbnail, rotate, flip commands).

test/
├── test_jpeg.zig        JPEG comparison tests against C reference (stb_image).
├── test_png.zig         PNG comparison tests against C reference (stb_image).
├── test_large_image.zig Integration tests for streaming on large images.
└── fixtures/            Test images (JPEG and PNG)

reference/
├── stb_image.h          C reference decoder (test-only).
├── stb_image_resize2.h  C reference resizer (test-only).
├── stb_image_write.h    C reference encoder (test-only).
└── ref_impl.c           Thin C wrapper for Zig interop.
```

## Module Dependencies

```
stbz.zig ─────────┬── image.zig
                   ├── jpeg.zig
                   ├── png.zig ──────────── decode_context.zig
                   └── streaming.zig ───┬── png.zig
                                        └── decode_context.zig

cli.zig ──────────────── stbz.zig
```

`decode_context.zig` is the shared foundation — both `png.zig` (full decode) and `streaming.zig` (row-by-row decode) build on it. `jpeg.zig` is self-contained with its own Huffman/IDCT/resampling logic.

## Core Data Structure

```zig
Image {
    width: u32,
    height: u32,
    channels: u8,     // 1=gray, 2=gray+alpha, 3=RGB, 4=RGBA
    data: []u8,       // row-major packed pixels (width × height × channels bytes)
    allocator: Allocator,
}
```

All operations return a new `Image`. Nothing mutates in place. Callers must call `deinit()` to free.

## Three API Tiers

### 1. File API — load the whole image into memory

```zig
const img = try stbz.loadPngFile(allocator, "input.png");
defer img.deinit();
const resized = try img.resize(allocator, 200, 200);
```

Located in `image.zig` and `png.zig`.

### 2. Stream API — works with any `Reader`/`Writer`

```zig
stbz.cropStream(allocator, reader, writer, x, y, w, h);
stbz.resizeStream(allocator, reader, writer, w, h);
```

Still decodes the full image internally, but avoids needing a file path. Located in `streaming.zig`.

### 3. Low-Memory Streaming API

```zig
stbz.streamingResize(allocator, reader, writer, w, h);
```

Processes images with low memory usage using incremental decompression and row-by-row processing. For a 4000×3000 RGB image, memory drops from ~36 MB (full decode) to ~3.6 MB (compressed data + row buffers). Located in `streaming.zig` using `PngStreamingDecoder` from `decode_context.zig`.

## Streaming API Components

| Component | Purpose | Memory |
|---|---|---|
| `streamingResize` | Resize with bilinear interpolation | O(compressed_size + width) |
| `PngStreamingDecoder` | Row-by-row PNG decoding | O(compressed_size + width) |
| `PngRowWriter` | Row-by-row PNG encoding | O(width) |

## Format Support

### JPEG (decode only)

Baseline DCT (SOF0). Grayscale and YCbCr with 4:4:4, 4:2:2, and 4:2:0 chroma subsampling. Restart markers (DRI). Bilinear chroma upsampling matching stb_image. Not supported: progressive (SOF2), arithmetic coding.

### PNG

**Decoding:** RGB, RGBA, grayscale, grayscale+alpha (8-bit). Adam7 interlacing. All filter types (None, Sub, Up, Average, Paeth).

**Encoding:** Same color types. Fixed Huffman compression. Filter type 0 only. No interlacing on encode.

**Not supported:** Palette/indexed color, 16-bit depth, ancillary chunks (gAMA, sRGB, etc.).

## Build & Test

```bash
zig build              # Build library + CLI
zig build test         # Run all tests (unit + C reference comparison)
zig build test-large   # Run large image streaming tests
zig build run          # Run CLI
```

Tests live both inline in source files and in `test/`. The C reference is compiled only for test targets — the library itself is pure Zig.
