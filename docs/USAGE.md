# Usage

## Library

### Setup

Add zpix as a dependency in your `build.zig.zon`, then import the module:

```zig
const zpix = @import("zpix");
```

File-based APIs take an `io: std.Io` instance as their first argument. Get
one from "Juicy Main" (`init.io`) or, in tests, from `std.testing.io`.

### Loading Images

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Auto-detect format by magic bytes (PNG or JPEG)
    var image = try zpix.loadFile(io, allocator, "photo.jpg");
    defer image.deinit();

    // Or load a specific format
    var png = try zpix.loadPngFile(io, allocator, "image.png");
    defer png.deinit();

    var jpeg = try zpix.loadJpegFile(io, allocator, "photo.jpg");
    defer jpeg.deinit();

    // Load from memory buffers (no io needed)
    var from_mem = try zpix.loadPngMemory(allocator, png_bytes);
    defer from_mem.deinit();

    var from_jpeg = try zpix.loadJpegMemory(allocator, jpeg_bytes);
    defer from_jpeg.deinit();
}
```

### Saving Images

```zig
// Auto-detect format by file extension (.png, .jpg, .jpeg)
try zpix.saveFile(io, &image, "output.png");
try zpix.saveFile(io, &image, "output.jpg");  // JPEG quality defaults to 90

// Or save a specific format
try zpix.savePngFile(io, &image, "output.png");
try zpix.saveJpegFile(io, &image, "output.jpg", 85);  // quality 1-100

// Save to memory buffers (no io needed)
const png_buf = try zpix.savePngMemory(allocator, &image);
defer allocator.free(png_buf);

const jpeg_buf = try zpix.saveJpegMemory(allocator, &image, 90);
defer allocator.free(jpeg_buf);
```

### Image Operations

All operations return a new `Image` that must be freed with `deinit()`.

```zig
var image = try zpix.loadFile(io, allocator, "photo.jpg");
defer image.deinit();

// Crop a region (x, y, width, height)
var cropped = try image.crop(100, 100, 200, 200);
defer cropped.deinit();

// Resize with bilinear interpolation
var resized = try image.resize(640, 480);
defer resized.deinit();

// Rotate clockwise
var r90 = try image.rotate90();
defer r90.deinit();

var r180 = try image.rotate180();
defer r180.deinit();

var r270 = try image.rotate270();
defer r270.deinit();

// Flip
var flipped_h = try image.flipHorizontal();
defer flipped_h.deinit();

var flipped_v = try image.flipVertical();
defer flipped_v.deinit();
```

### Pixel Access

```zig
// Read a pixel (returns a slice of channel values)
const pixel = image.getPixel(x, y);
// pixel[0] = R, pixel[1] = G, pixel[2] = B (for 3-channel images)

// Write a pixel
image.setPixel(x, y, &[_]u8{ 255, 0, 0 });
```

### Image Struct

The `Image` type holds decoded pixel data in a flat row-major buffer:

```zig
const Image = struct {
    width: u32,
    height: u32,
    channels: u8,       // 1=gray, 2=gray+alpha, 3=RGB, 4=RGBA
    data: []u8,         // row-major pixel data
    allocator: Allocator,
};
```

### Format Detection

```zig
const format = zpix.detectFormat(first_8_bytes);
switch (format) {
    .png => // PNG signature found,
    .jpeg => // JPEG SOI marker found,
    .unknown => // unrecognized format,
}
```

## CLI

Build the CLI with `zig build`, producing `zig-out/bin/zpix`.

### Commands

```bash
# Crop a region (x, y, width, height)
zpix crop input.png output.png 100 100 200 200

# Resize to specific dimensions
zpix resize input.png output.png 640 480

# Create a square thumbnail (center-crops then resizes)
zpix thumbnail input.png thumb.png 128

# Rotate clockwise (90, 180, or 270 degrees)
zpix rotate input.png output.png 90

# Flip (h = horizontal, v = vertical)
zpix flip input.png output.png h

# Help
zpix help
```

Input and output formats are auto-detected. The CLI supports any combination of PNG and JPEG for input/output (e.g., load JPEG, save as PNG).
