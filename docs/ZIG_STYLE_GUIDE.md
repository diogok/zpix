# Zig Style Guide

A practical guide for writing idiomatic Zig code, based on Zig 0.15+ patterns and standard library conventions.

## Table of Contents

1. [Error Handling](#error-handling)
2. [Loop Patterns](#loop-patterns)
3. [Type Patterns](#type-patterns)
4. [Memory Management](#memory-management)
5. [Interfaces and Generics](#interfaces-and-generics)
6. [Testing Practices](#testing-practices)
7. [Code Organization](#code-organization)
8. [Variable Naming](#variable-naming)

---

## Error Handling

### Use Typed Error Sets

Define specific error sets for your domain, don't include errors already in standard types:

```zig
// Bad: Redundant errors
pub const MyError = error{
    InvalidFormat,
    OutOfMemory,     // Already in Allocator.Error
    EndOfStream,     // Already in Reader.Error
};

// Good: Domain-specific errors only
pub const DecodeError = error{
    InvalidSignature,
    InvalidFormat,
    UnsupportedFeature,
};

// Compose in function signatures
pub fn decode(allocator: Allocator, reader: *std.Io.Reader) (DecodeError || Allocator.Error || std.Io.Reader.Error)!Result
```

### Error Union Composition

Let error sets flow naturally through the type system:

```zig
// Good: Explicit about what can fail
pub fn process(data: []const u8) ParseError!Result { ... }

// Function that calls process inherits its errors
pub fn processFile(path: []const u8) (ParseError || std.fs.File.OpenError)!Result {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return process(file.reader());
}
```

### Use errdefer for Cleanup

```zig
pub fn init(allocator: Allocator) !Self {
    const buffer = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buffer);  // Only runs on error

    const other = try allocator.alloc(u8, 512);
    errdefer allocator.free(other);

    return .{ .buffer = buffer, .other = other };
}
```

---

## Loop Patterns

### Prefer for-range Over while with Counter

```zig
// Bad: Manual counter management
var y: u32 = 0;
while (y < height) : (y += 1) {
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        // ...
    }
}

// Good: Range-based iteration
for (0..height) |y| {
    for (0..width) |x| {
        // ...
    }
}
```

### Use Slice Iteration When Possible

```zig
// Bad: Index-based when not needed
for (0..items.len) |i| {
    process(items[i]);
}

// Good: Direct iteration
for (items) |item| {
    process(item);
}

// Good: With index when needed
for (items, 0..) |item, i| {
    processWithIndex(item, i);
}
```

### Iterate with Pointers for Mutation

```zig
// Good: Mutate in place
for (&pixels) |*pixel| {
    pixel.* = transform(pixel.*);
}

// With enumeration
for (output, 0..) |*out, i| {
    out.* = compute(i);
}
```

---

## Type Patterns

### Use @This() for Self-Reference

```zig
pub const Image = struct {
    const Self = @This();

    width: u32,
    height: u32,
    data: []u8,

    pub fn clone(self: *const Self) !Self {
        // ...
    }
};
```

### Extern Structs for Binary Layout

```zig
// Good: Guaranteed memory layout for file formats/FFI
pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const PngHeader = extern struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
};
```

### Options Structs for Complex Parameters

```zig
// Bad: Many parameters
pub fn resize(img: Image, width: u32, height: u32, filter: Filter, preserve_aspect: bool) !Image

// Good: Options struct with defaults
pub const ResizeOptions = struct {
    width: u32,
    height: u32,
    filter: Filter = .bilinear,
    preserve_aspect: bool = false,
};

pub fn resize(img: Image, options: ResizeOptions) !Image
```

### Tagged Unions for Variants

```zig
pub const ColorType = union(enum) {
    grayscale: void,
    grayscale_alpha: void,
    rgb: void,
    rgba: void,
    indexed: []const Rgba,  // Palette data

    pub fn channels(self: ColorType) u8 {
        return switch (self) {
            .grayscale => 1,
            .grayscale_alpha => 2,
            .rgb => 3,
            .rgba => 4,
            .indexed => 1,
        };
    }
};
```

---

## Memory Management

### Always Accept Allocator Parameter

```zig
// Bad: Hidden allocation
pub fn process() ![]u8 {
    return std.heap.page_allocator.alloc(u8, 1024);
}

// Good: Explicit allocator
pub fn process(allocator: Allocator) ![]u8 {
    return allocator.alloc(u8, 1024);
}
```

### Store Allocator for deinit

```zig
pub const Buffer = struct {
    data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, size: usize) !Buffer {
        return .{
            .data = try allocator.alloc(u8, size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.* = undefined;  // Prevent use-after-free
    }
};
```

### ArrayList Patterns

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, value);
```

### Use defer for Cleanup

```zig
pub fn process(allocator: Allocator) !void {
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    const file = try std.fs.cwd().openFile("data.bin", .{});
    defer file.close();

    // Use buffer and file...
}
```

---

## Interfaces and Generics

### Use std.Io.Reader/Writer

```zig
// Good: Accept interface, not concrete type
pub fn decode(allocator: Allocator, reader: *std.Io.Reader) !Image {
    const signature = try reader.takeArray(8);
    const length = try reader.takeInt(u32, .big);
    // ...
}

// Callers can use any reader implementation
var file_reader = file.reader(&buffer);
const img = try decode(allocator, &file_reader.interface);

var mem_reader: std.Io.Reader = .fixed(data);
const img2 = try decode(allocator, &mem_reader);
```

### Comptime Generic Types

```zig
pub fn Image(comptime Pixel: type) type {
    return struct {
        const Self = @This();

        width: u32,
        height: u32,
        pixels: []Pixel,
        allocator: Allocator,

        pub fn getPixel(self: Self, x: u32, y: u32) Pixel {
            return self.pixels[y * self.width + x];
        }

        pub fn setPixel(self: *Self, x: u32, y: u32, pixel: Pixel) void {
            self.pixels[y * self.width + x] = pixel;
        }
    };
}

// Usage
const RgbaImage = Image(Rgba);
const GrayImage = Image(u8);
```

### Duck-Typed Interfaces

```zig
pub fn process(comptime T: type, img: T) void {
    // T must have getPixel and setPixel
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(x, y);
            // ...
        }
    }
}
```

---

## Testing Practices

### Use std.testing.allocator

```zig
test "memory is freed" {
    const allocator = std.testing.allocator;  // Detects leaks

    var img = try Image.init(allocator, 100, 100, 4);
    defer img.deinit();

    // Test operations...
}
```

### Avoid Writing to Filesystem

```zig
// Bad: Writes to /tmp
test "encode produces valid output" {
    const path = "/tmp/test_output.png";
    try saveToFile(path);
    // ...
}

// Good: Use in-memory buffer
test "encode produces valid output" {
    const allocator = std.testing.allocator;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var writer: std.Io.Writer = .fromArrayList(&output, allocator);
    try encode(&img, &writer);

    // Verify output.items...
}
```

### Test Error Conditions

```zig
test "rejects invalid input" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidSignature, decode(allocator, &bad_reader));
    try std.testing.expectError(error.CropOutOfBounds, img.crop(100, 100, 50, 50));
}
```

### Use expectEqual with Type Coercion

```zig
// Explicit type coercion for clarity
try std.testing.expectEqual(@as(u32, 100), img.width);
try std.testing.expectEqual(@as(u8, 4), img.channels);

// For slices
try std.testing.expectEqualSlices(u8, expected, actual);
```

---

## Code Organization

### Module Structure

```
src/
  lib.zig          # Public API re-exports
  types.zig        # Shared types and constants
  decoder.zig      # Decoding implementation
  encoder.zig      # Encoding implementation
  internal/        # Private implementation details
    filters.zig
    compression.zig
```

### Public API in Root Module

```zig
// src/lib.zig
pub const Image = @import("image.zig").Image;
pub const decode = @import("decoder.zig").decode;
pub const encode = @import("encoder.zig").encode;

// Re-export types users need
pub const DecodeError = @import("decoder.zig").DecodeError;
pub const EncodeError = @import("encoder.zig").EncodeError;

test {
    std.testing.refAllDecls(@This());
}
```

### Avoid Code Duplication

Extract shared logic into helper functions or types:

```zig
// Bad: Duplicate decoding logic in multiple functions
pub fn processImageA(...) { /* decode PNG header */ }
pub fn processImageB(...) { /* decode PNG header again */ }

// Good: Shared decoder
const PngStreamingDecoder = struct {
    width: u32,
    height: u32,
    channels: u8,
    raw_data: []u8,

    pub fn init(allocator: Allocator, reader: *std.Io.Reader) !PngStreamingDecoder { ... }
    pub fn deinit(self: *PngStreamingDecoder) void { ... }
    pub fn readRow(self: *PngStreamingDecoder) !?[]const u8 { ... }
};

pub fn processImageA(allocator: Allocator, reader: *std.Io.Reader, ...) !void {
    var decoder = try PngStreamingDecoder.init(allocator, reader);
    defer decoder.deinit();
    while (try decoder.readRow()) |row| {
        // Process row...
    }
}
```

---

## Variable Naming

### Use Descriptive Full Names

Choose variable names that clearly communicate intent and purpose:

```zig
// Bad: Abbreviated, unclear
const n = try reader.read(buf);
const cw = width * channels;
const val = (t * wy + b * (1 - wy));

// Good: Clear, self-documenting
const bytes_read = try reader.read(buffer);
const component_width = width * channels;
const interpolated_value = (top * weight_y + bottom * (1 - weight_y));
```

### When Abbreviations Are Acceptable

**Loop counters in small scopes:**
```zig
// Good: Universal conventions
for (0..height) |y| {
    for (0..width) |x| {
        const pixel = getPixel(x, y);
    }
}

for (items, 0..) |item, i| {
    process(item, i);
}
```

**Coordinate and dimension variables:**
```zig
// Good: Clear from context
pub fn crop(self: *const Image, x: u32, y: u32, w: u32, h: u32) !Image {
    // x, y, w, h are obvious in geometry context
}
```

**Well-established domain abbreviations:**
```zig
// Image processing standards
const r = pixel[0];  // Red channel
const g = pixel[1];  // Green channel
const b = pixel[2];  // Blue channel
const a = pixel[3];  // Alpha channel

const cb = chroma_blue;   // YCbCr color space
const cr = chroma_red;    // YCbCr color space

// Format-specific (JPEG)
const qt = quantization_table;
const ht = huffman_table;
const mcu = minimum_coded_unit;

// Format-specific (PNG)
const crc = cyclic_redundancy_check;
const idat = image_data_chunk;
```

**Very short-lived temporaries:**
```zig
// Acceptable: Used immediately, scope < 5 lines
for (chunks) |chunk| {
    const len = chunk.length;
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);
    try reader.readAll(buf);
}
```

### Guidelines

1. **Default to clarity over brevity** - Code is read more than written
2. **Avoid single-letter variables** except for universal conventions (i, j, x, y in loops)
3. **Use full words for struct fields** - They're referenced throughout the codebase
4. **Context matters** - `img` might be fine in a 10-line function, but `image` is better in a large file
5. **Domain expertise** - Standard abbreviations like `rgba`, `yuv`, `dct` are clearer to domain experts than spelled out versions

### Examples from stbz

```zig
// Good: Descriptive function parameters
pub fn resize(
    self: *const Image,
    new_width: u32,
    new_height: u32,
) !Image

// Good: Clear struct fields
pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8,
    data: []u8,
    allocator: Allocator,
};

// Good: Domain-appropriate naming
fn idct(coefficients: *const [64]i32, output: *[64]u8) void {
    // IDCT = Inverse Discrete Cosine Transform
    // This abbreviation is standard in image/video compression
}

// Good: Descriptive locals in complex logic
const horizontal_scale = max_horizontal_sampling / component.h_sample;
const vertical_scale = max_vertical_sampling / component.v_sample;
const component_width = ((width + 7) / 8) * component.h_sample;
```

### Anti-Patterns to Avoid

```zig
// Bad: Unclear abbreviations
const tmp = allocate();
const res = process(tmp);
const val = compute(res);

// Bad: Meaningless names
const x1 = data[0];
const x2 = data[1];
const x3 = calculate(x1, x2);

// Bad: Inconsistent naming
const buffer_size = 1024;
const buf_data = allocator.alloc(u8, buffer_size);  // Mix of buffer/buf
const buff_len = buf_data.len;                       // Now it's buff?

// Good: Consistent, clear naming
const buffer_size = 1024;
const buffer_data = try allocator.alloc(u8, buffer_size);
const buffer_length = buffer_data.len;
```

---

## Additional Tips

### Prefer Explicit Over Implicit

```zig
// Bad: Magic numbers
const size = width * height * 4;

// Good: Named constant or computed
const bytes_per_pixel = @sizeOf(Rgba);
const size = width * height * bytes_per_pixel;
```

### Use Sentinel-Terminated Strings Carefully

```zig
// File paths need null termination for C interop
const path: [:0]const u8 = "file.txt";

// Internal strings don't need it
const name: []const u8 = "internal";
```

### Debug Assertions for Invariants

```zig
pub fn getPixel(self: Self, x: u32, y: u32) Pixel {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    return self.pixels[y * self.width + x];
}
```

### Use comptime for Compile-Time Validation

```zig
pub fn Image(comptime Pixel: type) type {
    comptime {
        if (@sizeOf(Pixel) == 0) {
            @compileError("Pixel type must have non-zero size");
        }
    }
    return struct { ... };
}
```
