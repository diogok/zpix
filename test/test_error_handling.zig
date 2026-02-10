const std = @import("std");
const stbz = @import("stbz");

// Error handling tests - verify proper error reporting for corrupt/invalid files

// === JPEG Error Handling ===

test "JPEG: empty file" {
    const allocator = std.testing.allocator;
    const empty = [_]u8{};

    const result = stbz.loadJpegMemory(allocator, &empty);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "JPEG: file with only SOI marker" {
    const allocator = std.testing.allocator;
    const only_soi = [_]u8{ 0xFF, 0xD8 }; // SOI only

    const result = stbz.loadJpegMemory(allocator, &only_soi);
    try std.testing.expectError(error.InvalidData, result);
}

test "JPEG: invalid marker after SOI" {
    const allocator = std.testing.allocator;
    const invalid_marker = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0x00, // Invalid marker (0xFF00 is not a valid JPEG marker)
    };

    const result = stbz.loadJpegMemory(allocator, &invalid_marker);
    // Should fail - decoder returns InvalidData for malformed data
    try std.testing.expectError(error.InvalidData, result);
}

test "JPEG: truncated quantization table" {
    const allocator = std.testing.allocator;
    const truncated_dqt = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xDB, // DQT marker
        0x00, 0x43, // Length = 67 bytes (but we don't provide them all)
        0x00, // Table ID
        // Missing the actual 64 quantization values
    };

    const result = stbz.loadJpegMemory(allocator, &truncated_dqt);
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "JPEG: missing SOF marker" {
    const allocator = std.testing.allocator;
    // Valid SOI and EOI but no SOF in between
    const no_sof = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xD9, // EOI (immediate end)
    };

    const result = stbz.loadJpegMemory(allocator, &no_sof);
    try std.testing.expectError(error.InvalidData, result);
}

test "JPEG: unsupported precision (12-bit)" {
    const allocator = std.testing.allocator;
    const twelve_bit = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0 (baseline)
        0x00, 0x0B, // Length = 11
        0x0C, // Precision = 12 bits (unsupported)
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x01, // Components = 1
        0x00, // Component details...
    };

    const result = stbz.loadJpegMemory(allocator, &twelve_bit);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

test "JPEG: invalid component count (0)" {
    const allocator = std.testing.allocator;
    const zero_components = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x00, // Components = 0 (invalid!)
    };

    const result = stbz.loadJpegMemory(allocator, &zero_components);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

test "JPEG: invalid component count (4 - CMYK not supported)" {
    const allocator = std.testing.allocator;
    const four_components = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x11, // Length = 17
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x04, // Components = 4 (CMYK - not supported)
        // Would need component details here...
    };

    const result = stbz.loadJpegMemory(allocator, &four_components);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

// === PNG Error Handling ===

test "PNG: empty file" {
    const allocator = std.testing.allocator;
    const empty = [_]u8{};

    const result = stbz.loadPngMemory(allocator, &empty);
    try std.testing.expectError(error.EndOfStream, result);
}

test "PNG: invalid signature" {
    const allocator = std.testing.allocator;
    // JPEG signature instead of PNG
    const invalid_sig = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46 };

    const result = stbz.loadPngMemory(allocator, &invalid_sig);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "PNG: truncated signature" {
    const allocator = std.testing.allocator;
    // Only first 4 bytes of PNG signature
    const truncated = [_]u8{ 0x89, 0x50, 0x4E, 0x47 };

    const result = stbz.loadPngMemory(allocator, &truncated);
    try std.testing.expectError(error.EndOfStream, result);
}

test "PNG: missing IHDR chunk" {
    const allocator = std.testing.allocator;
    const no_ihdr = [_]u8{
        // Valid PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // But no IHDR chunk, just IEND
        0x00, 0x00, 0x00, 0x00, // Length = 0
        'I', 'E', 'N', 'D', // Type = IEND
        0xAE, 0x42, 0x60, 0x82, // CRC
    };

    const result = stbz.loadPngMemory(allocator, &no_ihdr);
    // Decoder tries to decompress IDAT before validating structure, gets decompression error
    try std.testing.expectError(error.DecompressionFailed, result);
}

test "PNG: truncated IHDR" {
    const allocator = std.testing.allocator;
    const truncated_ihdr = [_]u8{
        // Valid PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR with incorrect length
        0x00, 0x00, 0x00, 0x0D, // Length = 13 (correct)
        'I', 'H', 'D', 'R', // Type = IHDR
        // But not enough data (should be 13 bytes)
        0x00, 0x00, 0x00, 0x04, // Width = 4
        // Missing height and other fields
    };

    const result = stbz.loadPngMemory(allocator, &truncated_ihdr);
    try std.testing.expectError(error.EndOfStream, result);
}

test "PNG: zero width" {
    const allocator = std.testing.allocator;
    const zero_width = [_]u8{
        // Valid PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR
        0x00, 0x00, 0x00, 0x0D, // Length = 13
        'I', 'H', 'D', 'R', // Type = IHDR
        0x00, 0x00, 0x00, 0x00, // Width = 0 (invalid!)
        0x00, 0x00, 0x00, 0x04, // Height = 4
        0x08, // Bit depth = 8
        0x02, // Color type = RGB
        0x00, // Compression = deflate
        0x00, // Filter = adaptive
        0x00, // Interlace = none
        0x00, 0x00, 0x00, 0x00, // CRC (incorrect but doesn't matter for this test)
    };

    const result = stbz.loadPngMemory(allocator, &zero_width);
    // Decoder processes IHDR but fails during decompression due to invalid dimensions
    try std.testing.expectError(error.DecompressionFailed, result);
}

test "PNG: zero height" {
    const allocator = std.testing.allocator;
    const zero_height = [_]u8{
        // Valid PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR
        0x00, 0x00, 0x00, 0x0D, // Length = 13
        'I', 'H', 'D', 'R', // Type = IHDR
        0x00, 0x00, 0x00, 0x04, // Width = 4
        0x00, 0x00, 0x00, 0x00, // Height = 0 (invalid!)
        0x08, // Bit depth = 8
        0x02, // Color type = RGB
        0x00, // Compression = deflate
        0x00, // Filter = adaptive
        0x00, // Interlace = none
        0x00, 0x00, 0x00, 0x00, // CRC
    };

    const result = stbz.loadPngMemory(allocator, &zero_height);
    // Decoder processes IHDR but fails during decompression due to invalid dimensions
    try std.testing.expectError(error.DecompressionFailed, result);
}

// === File Access Error Handling ===

test "JPEG: nonexistent file" {
    const allocator = std.testing.allocator;

    const result = stbz.loadJpegFile(allocator, "test/fixtures/does_not_exist.jpg");
    try std.testing.expectError(error.FileNotFound, result);
}

test "PNG: nonexistent file" {
    const allocator = std.testing.allocator;

    const result = stbz.loadPngFile(allocator, "test/fixtures/does_not_exist.png");
    try std.testing.expectError(error.FileNotFound, result);
}

test "JPEG: directory instead of file" {
    const allocator = std.testing.allocator;

    const result = stbz.loadJpegFile(allocator, "test/fixtures");
    // Should fail (either IsDir or some read error)
    try std.testing.expect(std.meta.isError(result));
}

test "PNG: directory instead of file" {
    const allocator = std.testing.allocator;

    const result = stbz.loadPngFile(allocator, "test/fixtures");
    // Should fail (either IsDir or some read error)
    try std.testing.expect(std.meta.isError(result));
}
