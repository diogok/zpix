# Architecture

## Module Overview

```
zpix.zig          ← Public API, format detection, unified load/save
├── png.zig       ← PNG decoder/encoder
│   └── decode_context.zig  ← PNG chunk parsing, zlib decompression, filter reconstruction
├── jpeg.zig      ← JPEG decoder (baseline + progressive)
├── jpeg_encoder.zig  ← JPEG encoder (baseline)
├── image.zig     ← Image data structure and operations
└── cli.zig       ← Command-line interface (imports zpix as a module)
```

## Module Dependencies

- **image.zig** — standalone, depends only on `std`
- **decode_context.zig** — used only by `png.zig`; handles PNG-specific parsing
- **png.zig** — imports `image.zig` and `decode_context.zig`
- **jpeg.zig** — imports `image.zig` (completely independent from PNG)
- **jpeg_encoder.zig** — imports `image.zig` (independent from the decoder)
- **zpix.zig** — aggregates all modules into a unified API
- **cli.zig** — imports `zpix` as an external module via `build.zig`

The library has zero C dependencies. stb_image is only linked for integration tests and benchmarks.

## Data Flow

### Decoding (File → Image)

```
zpix.loadFile(io, allocator, path)
  │
  ├─ read first 8 bytes → detectFormat()
  │
  ├─ PNG path: png.loadFromFile(io, allocator, path)
  │   ├─ open file, buffered reader
  │   ├─ PngDecodeContext.init(reader)
  │   │   ├─ verify 8-byte PNG signature
  │   │   ├─ parse IHDR → width, height, bit depth, color type, interlace
  │   │   ├─ collect IDAT chunks
  │   │   ├─ decompress zlib → raw filtered scanlines
  │   │   └─ parse IEND
  │   ├─ reconstruct image (or reconstructInterlaced for Adam7)
  │   │   └─ for each scanline: apply inverse filter → pixel data
  │   └─ return Image
  │
  └─ JPEG path: jpeg.loadFromFile(io, allocator, path)
      ├─ read entire file into memory (Dir.readFileAlloc)
      └─ decodeMemory()
          ├─ verify SOI marker (FF D8)
          ├─ parse markers: DQT, DHT, SOF0/SOF2, SOS
          ├─ decode 8×8 MCU blocks
          │   ├─ Huffman decode DC/AC coefficients
          │   ├─ inverse zigzag → inverse quantization → IDCT
          │   └─ YCbCr → RGB conversion
          └─ return Image
```

### Encoding (Image → File)

```
zpix.saveFile(io, img, path)
  │
  ├─ detect format from file extension
  │
  ├─ PNG path: png.saveToFile(io, img, path)
  │   ├─ write PNG signature
  │   ├─ write IHDR chunk
  │   ├─ write IDAT chunk(s)
  │   │   ├─ prepend filter byte (None) to each scanline
  │   │   └─ compress with deflate (fixed Huffman codes)
  │   └─ write IEND chunk
  │
  └─ JPEG path: jpeg_encoder.saveToFile(io, img, path, quality)
      ├─ scale quantization tables by quality (IJG formula)
      ├─ write JFIF headers (SOI, APP0, DQT, SOF0, DHT, SOS)
      ├─ for each 8×8 block:
      │   ├─ RGB → YCbCr conversion
      │   ├─ forward DCT (AAN algorithm)
      │   ├─ quantize → zigzag reorder
      │   └─ Huffman encode (DC differential + AC run-length)
      └─ write EOI marker
```

## Key Types

### Image (`image.zig`)

The central data structure. A flat row-major pixel buffer with channel count.

| Field | Type | Description |
|-------|------|-------------|
| `width` | `u32` | Image width in pixels |
| `height` | `u32` | Image height in pixels |
| `channels` | `u8` | 1=gray, 2=gray+alpha, 3=RGB, 4=RGBA |
| `data` | `[]u8` | Pixel data, length = width × height × channels |
| `allocator` | `Allocator` | For memory management |

Operations: `crop`, `resize` (bilinear, fixed-point), `rotate90/180/270`, `flipHorizontal/Vertical`, `getPixel`, `setPixel`.

### PngDecodeContext (`decode_context.zig`)

Holds state during PNG decoding: parsed IHDR fields, decompressed zlib data, and methods for filter reconstruction. Supports Adam7 interlacing (7-pass progressive rendering).

### JPEG Decoder Internals (`jpeg.zig`)

- **Component** — one color component (Y, Cb, or Cr) with sampling factors, quantization table index, and Huffman table indices
- **HuffmanTable** — canonical Huffman codes with a 9-bit fast lookup path and slow fallback
- **BitReader** — reads the JPEG bitstream handling byte-stuffing (`0xFF 0x00`) and restart markers

### JPEG Encoder Internals (`jpeg_encoder.zig`)

- **Quantization** — standard JPEG luminance/chrominance tables, scaled by quality parameter using the IJG formula
- **DCT** — AAN (Arai-Agui-Nakajima) forward DCT, matching stb_image_write output
- **Huffman encoding** — standard DC/AC tables for luminance and chrominance
- **BitWriter** — packs variable-length Huffman codes with byte-stuffing

## Build Targets

| Command | What it builds | C dependency |
|---------|---------------|--------------|
| `zig build` | CLI executable | No |
| `zig build test` | Unit tests (src + test/test_jpeg_unit + test/test_error_handling) | No |
| `zig build integration-test` | Integration tests (test/test_png + test/test_jpeg + test/test_jpeg_encode) | stb_image |
| `zig build test-all` | All of the above | stb_image |
| `zig build bench` | Benchmarks (always ReleaseFast) | stb_image |
| `zig build test-bulk` | Bulk image loading test | No |
| `zig build docs` | API documentation → zig-out/docs/api | No |
| `zig build fmt` | Format source code | No |
| `zig build check` | Compile check (no codegen) | No |

## Testing Strategy

Unit tests (`zig build test`) run fast with no external dependencies. Integration tests (`zig build integration-test`) compile stb_image from `reference/ref_impl.c` and compare zpix output byte-for-byte against the C reference. Test fixtures in `test/fixtures/` cover RGB, RGBA, grayscale, interlaced PNG, progressive JPEG, and various chroma subsampling modes.
