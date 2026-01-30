# stbz

A Zig port of stb_image focusing on PNG support with thumbnail and tiling capabilities.

## Features

- Pure Zig PNG decoder and encoder (no C dependencies for core functionality)
- Crop operations
- Resize operations (bilinear interpolation)
- Thumbnail generation (center crop + resize)
- Rotate (90°, 180°, 270°)
- Flip (horizontal, vertical)
- CLI tool for image processing

## PNG Support

### Supported

| Feature | Decode | Encode |
|---------|--------|--------|
| RGB (8-bit) | Yes | Yes |
| RGBA (8-bit) | Yes | Yes |
| Grayscale (8-bit) | Yes | Yes |
| Grayscale+Alpha (8-bit) | Yes | Yes |
| Adam7 interlacing | Yes | No |
| All filter types (None, Sub, Up, Average, Paeth) | Yes | None only |

### Not Supported

- Palette/indexed color (color type 3)
- 16-bit depth
- 1/2/4-bit depth
- Ancillary chunks (gAMA, cHRM, sRGB, iCCP, tRNS)

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

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

// Load a PNG image
var image = try stbz.loadPngFile(allocator, "image.png");
defer image.deinit();

// Crop
var cropped = try image.crop(x, y, width, height);
defer cropped.deinit();

// Resize
var resized = try image.resize(new_width, new_height);
defer resized.deinit();

// Save
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

### Streaming Operations

Process images through Reader/Writer (loads full image):

```zig
// Crop: read PNG -> crop -> write PNG
try stbz.cropStream(allocator, &reader, &writer, x, y, width, height);

// Resize: read PNG -> resize -> write PNG
try stbz.resizeStream(allocator, &reader, &writer, new_width, new_height);

// Thumbnail: read PNG -> center crop -> resize -> write PNG
try stbz.thumbnailStream(allocator, &reader, &writer, size);
```

### Low-Memory Streaming (Row-by-Row)

For large images, use row-by-row processing with O(width) memory instead of O(width × height):

```zig
// Crop with minimal memory (only row buffers allocated)
try stbz.streamingCrop(allocator, &reader, &writer, x, y, width, height);

// Resize with minimal memory
try stbz.streamingResize(allocator, &reader, &writer, new_width, new_height);

// Thumbnail with minimal memory
try stbz.streamingThumbnail(allocator, &reader, &writer, size);
```

**Memory comparison (10000×10000 RGB image):**
| API | Memory Usage |
|-----|--------------|
| `loadPngFile` + `crop` | ~300 MB |
| `streamingCrop` | ~120 KB |

## Test Images

The test fixture `landscape_600x400.png` is a photo of Cinque Terre, Italy, sourced from W3Schools and used for testing purposes.

## License

Public domain (same as stb libraries)
