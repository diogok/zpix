# Coding conventions

Zig conventions used across zpix modules.

## Naming

| Kind              | Style        | Examples                                     |
|-------------------|--------------|----------------------------------------------|
| Types / structs   | `PascalCase` | `Image`, `PngDecodeContext`, `BitReader`      |
| Functions         | `camelCase`  | `setPixel`, `getPixel`, `loadFromMemory`      |
| Variables / fields| `snake_case` | `bit_depth`, `line_width`, `pixel_buffer`    |
| Tagged union tags | `snake_case` | `move_to`, `line_to`, `key_pressed`          |
| Type aliases      | `PascalCase` | `ImageFormat`, `DecodeError`, `ColorType`    |

### Spell out names

Avoid single-letter and cryptic abbreviations. Loop variables should say what
they iterate over.

```zig
// Bad
for (0..n) |i| { ... }

// Good
for (0..config.layers) |layer| { ... }
```

Exception: `i` is fine for pure index iteration in tight arithmetic
(e.g. `for (0..half_dim) |i|`).

## File-as-struct

When a file defines a single primary type, the file _is_ the struct — bare
fields at the top, methods below, no wrapping `pub const Foo = struct { ... }`.

```zig
// image.zig — the file IS the Image struct
width: u32,
height: u32,
channels: u8,
data: []u8,
allocator: Allocator,

pub fn init(allocator: Allocator, width: u32, height: u32, channels: u8) @This() {
    return .{ .width = width, .height = height, .channels = channels, ... };
}

pub fn deinit(self: *@This()) void { ... }
```

Callers get the type name from the import:
```zig
const Image = @import("image.zig");
```

When a file exports multiple types (e.g. `decode_context.zig`), use named `pub const`
structs instead.

## @This() usage

Use `@This()` directly in method signatures for file-as-struct modules.
Use `const Self = @This()` when inside a returned generic struct (e.g. from a
`fn Foo(comptime T: type) type` function).

```zig
// File-as-struct — use @This() directly
pub fn init(allocator: std.mem.Allocator) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Generic returned struct — Self alias is clearer
pub fn ThreadSafeQueue(Type: type) type {
    return struct {
        const Self = @This();
        pub fn push(self: *Self, item: Type) void { ... }
    };
}
```

For named structs in multi-type files, use `@This()` directly as well:
```zig
pub const PngDecodeContext = struct {
    pub fn init(allocator: Allocator) !@This() { ... }
    pub fn deinit(self: *@This()) void { ... }
};
```

## Struct organization

1. Fields (with default values where sensible)
2. `init` / `deinit`
3. Public methods
4. Private helpers

```zig
// Fields
width: u32,
height: u32,
channels: u8,

// Lifecycle
pub fn init(...) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Public API
pub fn setPixel(self: *@This(), x: u32, y: u32, pixel: []const u8) void { ... }
pub fn getPixel(self: *const @This(), x: u32, y: u32) []const u8 { ... }

// Private
fn bilinearInterpolateRow(...) void { ... }
```

## Self parameter conventions

Use `*@This()` for methods that mutate, `*const @This()` or `@This()` (by value) for pure queries.

```zig
pub fn setPixel(self: *@This(), x: u32, y: u32, pixel: []const u8) void { ... }
pub fn getPixel(self: *const @This(), x: u32, y: u32) []const u8 { ... }
```

Use `_:` for unused self parameters instead of `_ = self`:

```zig
// Bad
pub fn encode(allocator: Allocator, ...) !void {
    _ = allocator;
    ...
}

// Good
pub fn encode(_: Allocator, ...) !void {
    ...
}
```

## Imports

Imports go at the **bottom** of the file (Zig convention for file-as-struct
modules — fields must come first).

```zig
// At the bottom of image.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
```

For multi-type files (like `decode_context.zig`), imports at the top are fine.

## Return values

Prefer `.{}` anonymous struct literal returns:

```zig
pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator, .width = 0 };
}
```

## Error handling

- Propagate errors with `!` return types and `try`.
- Use `errdefer` for cleanup on error paths.
- Use `catch |err| switch (err) { ... }` for selective error handling.

```zig
pub fn crop(self: *const @This(), x: u32, y: u32, crop_width: u32, crop_height: u32) !@This() {
    var result = try @This().init(self.allocator, crop_width, crop_height, self.channels);
    errdefer result.deinit();
    // ... copy pixel data ...
    return result;
}
```

## Memory management

- Always pass `std.mem.Allocator` explicitly — no globals.
- Pair every `init` with a `deinit`, every `create` with a `destroy`.
- Use `defer`/`errdefer` at the call site.

```zig
var img = try Image.init(allocator, 100, 100, 4);
defer img.deinit();
```

## Tagged unions and enums

Use tagged unions for event systems and command types:

```zig
pub const ImageFormat = enum { png, jpeg, unknown };

pub const DecodeError = error{
    InvalidSignature,
    InvalidChunk,
    UnsupportedColorType,
    UnsupportedBitDepth,
};
```

## Comptime and generics

Use `anytype` for duck-typed parameters. Use comptime functions that return
`type` for generic containers.

```zig
// anytype for simple generics
pub fn applyScaling(v: anytype, scaling: f32) @TypeOf(v) { ... }

// Comptime function returning a type
pub fn ThreadSafeQueue(Type: type) type {
    return struct { ... };
}
```

Use `inline for` when iterating comptime-known fields:

```zig
inline for (0..4) |ch| {
    if (ch < channels) {
        dst_row[dst_x * channels + ch] = @intCast(value);
    }
}
```

## Comments

- `//!` for module-level doc comments (top of file).
- `///` for public API doc comments.
- `//` for inline explanations. Only where the code isn't self-evident.

```zig
//! JPEG decoder supporting baseline and progressive modes.

/// Resize image using bilinear interpolation (fixed-point integer math)
pub fn resize(self: *const @This(), new_width: u32, new_height: u32) !@This() { ... }

// Fixed-point with 16 fractional bits
const SHIFT = 16;
```

## Tests

Tests live at the bottom of the file they test, after a `test` block:

```zig
test "resize produces correct dimensions" {
    const Image = @This();
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    var resized = try img.resize(20, 20);
    defer resized.deinit();
    try std.testing.expectEqual(@as(u32, 20), resized.width);
}
```

Use `testing.allocator` (detects leaks) and `std.testing.expect*` assertions.

## Code hygiene

- Remove dead code, unused imports, and unused struct fields — version control
  has them.
- Name magic numbers when the meaning isn't obvious from context.
- Don't keep code "just in case".
