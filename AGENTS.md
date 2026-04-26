# zpix Development Instructions

This file contains development instructions for AI agents, automated tools, and developers working on zpix. For project-specific Claude Code instructions, see [CLAUDE.md](CLAUDE.md).

## Build Commands

- `zig build` - Build the library
- `zig build test` - Run unit tests (fast, no C dependencies)
- `zig build integration-test` - Run integration tests (vs stb_image)
- `zig build test-all` - Run all tests (unit + integration)
- `zig build bench` - Run performance benchmarks
- `zig build docs` - Generate API documentation (outputs to zig-out/docs/api)
- `zig build -Doptimize=ReleaseFast` - Build optimized

## Development Approach

**Strict TDD**: Always write the test first, see it fail, then implement.

## Architecture

- `src/zpix.zig` - Main library entry point
- `src/jpeg.zig` - JPEG decoder (baseline + progressive)
- `src/jpeg_encoder.zig` - JPEG encoder (baseline)
- `src/png.zig` - PNG decoder/encoder
- `src/image.zig` - Image data structure
- `src/decode_context.zig` - Shared PNG decoding context
- `src/cli.zig` - Command-line interface

## Testing

### Test Organization

- **Unit tests** (`zig build test`): Fast tests with no C dependencies
  - Located in `src/*.zig` and `test/test_jpeg_unit.zig`, `test/test_error_handling.zig`
  - Tests behavior, edge cases, error handling

- **Integration tests** (`zig build integration-test`): Pixel-perfect comparison vs stb_image
  - Located in `test/test_png.zig` and `test/test_jpeg.zig`
  - Compares output byte-for-byte against C reference implementation

Test fixtures are in `test/fixtures/`.

### Coverage Requirements

- All new JPEG/PNG features must be tested against stb_image
- Error paths must have explicit error handling tests
- Behavioral changes require unit tests before implementation (TDD)

## Code Style

- Use Zig standard library conventions
- Explicit error handling
- Support custom allocators
- Prefer `*const` for read-only pointer parameters
- Use `@This()` directly (see docs/CODING_CONVENTIONS.md)

### Io threading (Zig 0.16)

Public APIs that touch the filesystem take an `io: std.Io` parameter as the
**first** argument, before the allocator. Memory-only variants don't need it.

```zig
// File-based (needs io)
pub fn loadFromFile(io: std.Io, allocator: Allocator, path: []const u8) !Image
pub fn saveToFile(io: std.Io, img: *const Image, path: []const u8) !void

// Memory-based (unchanged)
pub fn loadFromMemory(allocator: Allocator, data: []const u8) !Image
pub fn saveToMemory(allocator: Allocator, img: *const Image) ![]u8
```

- Executables get `io` from "Juicy Main": `pub fn main(init: std.process.Init) !void`
  → `init.io`, `init.gpa`, `init.arena`, `init.minimal.args`.
- Tests use `std.testing.io`.
- Library code never constructs its own `Io` — always thread it through from
  the entry point.

When opening files inside the library, use the new APIs:

```zig
const file = try std.Io.Dir.cwd().openFile(io, path, .{});
defer file.close(io);
var file_reader = file.reader(io, buf);
```

### Variable Naming

**Use descriptive full names by default:**
```zig
// Good
const bytes_read = try reader.read(buffer);
const component_width = width * channels;
const interpolated_value = (top * weight_y + bottom * (1 - weight_y));

// Avoid
const n = try reader.read(buffer);
const cw = width * channels;
const val = (top * weight_y + bottom * (1 - weight_y));
```

**Exceptions - well-established abbreviations:**
- Loop counters in small scopes: `i`, `j`, `x`, `y`
- Coordinates: `x`, `y`, `w`, `h` (when obvious from context)
- Image processing standards: `r`, `g`, `b`, `a` (RGBA), `cb`, `cr` (chroma)
- Format-specific: `qt` (quantization table), `ht` (Huffman table), `mcu` (minimum coded unit)
- Common: `img` for Image parameter, `buf` for buffer in very short scopes

**When in doubt, prefer clarity over brevity.**

### Logging

Use scoped logging for debugging and diagnostics:

```zig
const log = std.log.scoped(.zpix_modulename);

// Use sparingly - libraries should minimize logging
log.debug("Failed to parse header: offset={}, marker=0x{X:0>4}", .{offset, marker});
log.debug("Processing component {}/{}", .{i + 1, total});
```

**Guidelines:**
- Use scoped logs with `.zpix_<modulename>` (e.g., `.zpix_jpeg`, `.zpix_png`)
- Prefer returning errors over logging in library code
- Use `log.debug()` for error context and diagnostics (only visible with debug logging enabled)
- Avoid `log.err()`, `log.info()`, and `log.warn()` in library code - let applications control logging
- Debug logs help troubleshoot issues without polluting application logs
