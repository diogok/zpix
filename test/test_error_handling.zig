const std = @import("std");
const zpix = @import("zpix");

// Error handling tests - verify proper error reporting for corrupt/invalid files

// === JPEG Error Handling ===

test "JPEG: empty file" {
    const allocator = std.testing.allocator;
    const empty = [_]u8{};

    const result = zpix.loadJpegMemory(allocator, &empty);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "JPEG: file with only SOI marker" {
    const allocator = std.testing.allocator;
    const only_soi = [_]u8{ 0xFF, 0xD8 }; // SOI only

    const result = zpix.loadJpegMemory(allocator, &only_soi);
    try std.testing.expectError(error.InvalidData, result);
}

test "JPEG: invalid marker after SOI" {
    const allocator = std.testing.allocator;
    const invalid_marker = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0x00, // Invalid marker (0xFF00 is not a valid JPEG marker)
    };

    const result = zpix.loadJpegMemory(allocator, &invalid_marker);
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

    const result = zpix.loadJpegMemory(allocator, &truncated_dqt);
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "JPEG: missing SOF marker" {
    const allocator = std.testing.allocator;
    // Valid SOI and EOI but no SOF in between
    const no_sof = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xD9, // EOI (immediate end)
    };

    const result = zpix.loadJpegMemory(allocator, &no_sof);
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

    const result = zpix.loadJpegMemory(allocator, &twelve_bit);
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

    const result = zpix.loadJpegMemory(allocator, &zero_components);
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

    const result = zpix.loadJpegMemory(allocator, &four_components);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

// === PNG Error Handling ===

test "PNG: empty file" {
    const allocator = std.testing.allocator;
    const empty = [_]u8{};

    const result = zpix.loadPngMemory(allocator, &empty);
    try std.testing.expectError(error.EndOfStream, result);
}

test "PNG: invalid signature" {
    const allocator = std.testing.allocator;
    // JPEG signature instead of PNG
    const invalid_sig = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46 };

    const result = zpix.loadPngMemory(allocator, &invalid_sig);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "PNG: truncated signature" {
    const allocator = std.testing.allocator;
    // Only first 4 bytes of PNG signature
    const truncated = [_]u8{ 0x89, 0x50, 0x4E, 0x47 };

    const result = zpix.loadPngMemory(allocator, &truncated);
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

    const result = zpix.loadPngMemory(allocator, &no_ihdr);
    try std.testing.expectError(error.InvalidChunk, result);
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

    const result = zpix.loadPngMemory(allocator, &truncated_ihdr);
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

    const result = zpix.loadPngMemory(allocator, &zero_width);
    try std.testing.expectError(error.InvalidImageData, result);
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

    const result = zpix.loadPngMemory(allocator, &zero_height);
    try std.testing.expectError(error.InvalidImageData, result);
}

// === File Access Error Handling ===

test "JPEG: nonexistent file" {
    const allocator = std.testing.allocator;

    const result = zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures/does_not_exist.jpg");
    try std.testing.expectError(error.FileNotFound, result);
}

test "PNG: nonexistent file" {
    const allocator = std.testing.allocator;

    const result = zpix.loadPngFile(std.testing.io, allocator, "test/fixtures/does_not_exist.png");
    try std.testing.expectError(error.FileNotFound, result);
}

test "JPEG: directory instead of file" {
    const allocator = std.testing.allocator;

    const result = zpix.loadJpegFile(std.testing.io, allocator, "test/fixtures");
    // Should fail (either IsDir or some read error)
    try std.testing.expect(std.meta.isError(result));
}

test "PNG: directory instead of file" {
    const allocator = std.testing.allocator;

    const result = zpix.loadPngFile(std.testing.io, allocator, "test/fixtures");
    // Should fail (either IsDir or some read error)
    try std.testing.expect(std.meta.isError(result));
}

// === JPEG Security Validation ===

test "JPEG: DQT with length < 2" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xDB, // DQT marker
        0x00, 0x01, // Length = 1 (invalid, must be >= 2)
    };
    try std.testing.expectError(error.InvalidQuantizationTable, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: DHT with total symbols > 256" {
    const allocator = std.testing.allocator;
    // DHT where the 16 count bytes sum to > 256
    var data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC4, // DHT marker
        0x01, 0x13, // Length = 275 (2 + 1 + 16 + 256... but counts sum to 272)
        0x00, // Class=0, ID=0
        // 16 count bytes summing to 272 (> 256)
        17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
    };
    _ = &data;
    try std.testing.expectError(error.InvalidHuffmanTable, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: SOF with zero sampling factor" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x01, // 1 component
        0x01, // Component ID
        0x00, // H=0, V=0 (invalid!)
        0x00, // QT ID
    };
    try std.testing.expectError(error.InvalidFrameHeader, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: SOF with sampling factor > 4" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x01, // 1 component
        0x01, // Component ID
        0x55, // H=5, V=5 (invalid, max is 4)
        0x00, // QT ID
    };
    try std.testing.expectError(error.InvalidFrameHeader, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: SOF with qt_id > 3" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0x00, 0x08, // Width = 8
        0x01, // 1 component
        0x01, // Component ID
        0x11, // H=1, V=1
        0x04, // QT ID = 4 (invalid, max is 3)
    };
    try std.testing.expectError(error.InvalidQuantizationTable, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: SOF with dimensions exceeding maximum" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision = 8
        0x00, 0x08, // Height = 8
        0xFF, 0xFF, // Width = 65535 (exceeds MAX_DIMENSION)
        0x01, // 1 component
        0x01, // Component ID
        0x11, // H=1, V=1
        0x00, // QT ID
    };
    try std.testing.expectError(error.InvalidFrameHeader, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: unknown marker with length past EOF" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE2, // APP2 (unknown marker)
        0xFF, 0xFF, // Length = 65535 (way past EOF)
        0x00, 0x00, // only 2 bytes of payload
    };
    try std.testing.expectError(error.UnexpectedEndOfData, zpix.loadJpegMemory(allocator, &data));
}

test "JPEG: SOS with dc_table > 3" {
    const allocator = std.testing.allocator;

    // Build a minimal valid JPEG up to SOS with an invalid table selector.
    // We need: SOI + DQT + SOF + DHT (dc+ac) + SOS with bad table ID.
    var buf: [512]u8 = undefined;
    var i: usize = 0;

    // SOI
    buf[i] = 0xFF;
    buf[i + 1] = 0xD8;
    i += 2;

    // DQT (table 0, 8-bit, 64 values all = 1)
    buf[i] = 0xFF;
    buf[i + 1] = 0xDB;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x43; // length = 67
    i += 2;
    buf[i] = 0x00; // table ID 0, 8-bit precision
    i += 1;
    for (0..64) |j| {
        buf[i + j] = 1;
    }
    i += 64;

    // SOF0 (1 component, 8x8)
    buf[i] = 0xFF;
    buf[i + 1] = 0xC0;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x0B; // length = 11
    i += 2;
    buf[i] = 0x08; // precision
    i += 1;
    buf[i] = 0x00;
    buf[i + 1] = 0x08; // height = 8
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x08; // width = 8
    i += 2;
    buf[i] = 0x01; // 1 component
    i += 1;
    buf[i] = 0x01; // component ID
    buf[i + 1] = 0x11; // H=1, V=1
    buf[i + 2] = 0x00; // QT ID=0
    i += 3;

    // DHT for DC table 0 (1 symbol of length 1)
    buf[i] = 0xFF;
    buf[i + 1] = 0xC4;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x14; // length = 20 (2 + 1 + 16 + 1)
    i += 2;
    buf[i] = 0x00; // class=0 (DC), id=0
    i += 1;
    buf[i] = 0x01; // 1 symbol of length 1
    for (1..16) |j| {
        buf[i + j] = 0x00;
    }
    i += 16;
    buf[i] = 0x00; // symbol 0
    i += 1;

    // DHT for AC table 0 (1 symbol of length 1)
    buf[i] = 0xFF;
    buf[i + 1] = 0xC4;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x14; // length = 20 (2 + 1 + 16 + 1)
    i += 2;
    buf[i] = 0x10; // class=1 (AC), id=0
    i += 1;
    buf[i] = 0x01; // 1 symbol of length 1
    for (1..16) |j| {
        buf[i + j] = 0x00;
    }
    i += 16;
    buf[i] = 0x00; // EOB symbol
    i += 1;

    // SOS with invalid dc_table selector
    buf[i] = 0xFF;
    buf[i + 1] = 0xDA;
    i += 2;
    buf[i] = 0x00;
    buf[i + 1] = 0x08; // length = 8
    i += 2;
    buf[i] = 0x01; // 1 component in scan
    i += 1;
    buf[i] = 0x01; // component ID = 1
    i += 1;
    buf[i] = 0xF0; // DC table = 15 (invalid!), AC table = 0
    i += 1;
    buf[i] = 0x00; // Ss
    buf[i + 1] = 0x3F; // Se
    buf[i + 2] = 0x00; // Ah|Al
    i += 3;

    try std.testing.expectError(error.InvalidScanHeader, zpix.loadJpegMemory(allocator, buf[0..i]));
}

// === PNG Security Validation ===

test "PNG: dimensions exceeding maximum" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        // Valid PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR
        0x00, 0x00, 0x00, 0x0D, // Length = 13
        'I', 'H', 'D', 'R', // Type = IHDR
        0x00, 0x01, 0x00, 0x00, // Width = 65536 (exceeds MAX_DIMENSION)
        0x00, 0x00, 0x00, 0x04, // Height = 4
        0x08, // Bit depth = 8
        0x02, // Color type = RGB
        0x00, // Compression
        0x00, // Filter
        0x00, // Interlace = none
        0x00, 0x00, 0x00, 0x00, // CRC
    };
    try std.testing.expectError(error.InvalidImageData, zpix.loadPngMemory(allocator, &data));
}

// === JPEG Encoder Security Validation ===

test "JPEG encoder: rejects 2-channel image" {
    const allocator = std.testing.allocator;

    // Manually construct an Image with 2 channels using a raw buffer
    const width: u32 = 4;
    const height: u32 = 4;
    const channels: u8 = 2;
    const size = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    @memset(data, 128);

    const img = zpix.Image{
        .width = width,
        .height = height,
        .channels = channels,
        .data = data,
        .allocator = allocator,
    };

    try std.testing.expectError(error.UnsupportedChannelCount, zpix.saveJpegMemory(allocator, &img, 90));
}

test "JPEG encoder: rejects zero-dimension image" {
    const allocator = std.testing.allocator;

    // Construct an Image with width=0
    const data = try allocator.alloc(u8, 0);
    defer allocator.free(data);

    const img = zpix.Image{
        .width = 0,
        .height = 10,
        .channels = 3,
        .data = data,
        .allocator = allocator,
    };

    try std.testing.expectError(error.InvalidImageDimensions, zpix.saveJpegMemory(allocator, &img, 90));
}
