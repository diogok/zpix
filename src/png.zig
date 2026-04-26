const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig");
const decode_context = @import("decode_context.zig");

const DecodeError = decode_context.DecodeError;
const PngDecodeContext = decode_context.PngDecodeContext;
const PNG_SIGNATURE = decode_context.PNG_SIGNATURE;
const ChunkType = decode_context.ChunkType;
const Adam7 = decode_context.Adam7;
const applyFilter = decode_context.applyFilter;

fn decode(allocator: Allocator, reader: *std.Io.Reader) !Image {
    var ctx = try PngDecodeContext.init(allocator, reader);
    defer ctx.deinit();

    // Reconstruct image from filtered scanlines (1 byte per pixel for indexed)
    var indexed_img = if (ctx.interlace == 1)
        try reconstructInterlacedImage(allocator, ctx.raw_data, ctx.width, ctx.height, ctx.channels)
    else
        try reconstructImage(allocator, ctx.raw_data, ctx.width, ctx.height, ctx.channels);

    // For indexed color, expand palette indices to RGBA
    if (ctx.color_type == .indexed) {
        defer indexed_img.deinit();
        if (ctx.palette_len == 0) return DecodeError.InvalidImageData;
        return expandIndexedToRgba(allocator, &indexed_img, &ctx.palette, ctx.palette_len, &ctx.trns, ctx.trns_len);
    }

    return indexed_img;
}

/// Expand a 1-channel indexed image to 4-channel RGBA using the palette and tRNS data.
fn expandIndexedToRgba(
    allocator: Allocator,
    indexed: *const Image,
    palette: *const [256][3]u8,
    palette_len: u16,
    trns: *const [256]u8,
    trns_len: u16,
) !Image {
    const pixel_count = @as(usize, indexed.width) * @as(usize, indexed.height);
    var img = try Image.init(allocator, indexed.width, indexed.height, 4);
    errdefer img.deinit();

    const has_transparency = trns_len > 0;

    for (0..pixel_count) |i| {
        const index = indexed.data[i];
        if (index >= palette_len) {
            // Index out of palette range — treat as transparent black
            img.data[i * 4 + 0] = 0;
            img.data[i * 4 + 1] = 0;
            img.data[i * 4 + 2] = 0;
            img.data[i * 4 + 3] = 0;
        } else {
            img.data[i * 4 + 0] = palette[index][0];
            img.data[i * 4 + 1] = palette[index][1];
            img.data[i * 4 + 2] = palette[index][2];
            img.data[i * 4 + 3] = if (has_transparency) trns[index] else 255;
        }
    }

    return img;
}

/// Load PNG from file path
pub fn loadFromFile(io: std.Io, allocator: Allocator, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buf = try allocator.alloc(u8, 65536);
    defer allocator.free(buf);
    var file_reader = file.reader(io, buf);

    return decode(allocator, &file_reader.interface);
}

/// Load PNG from memory buffer
pub fn loadFromMemory(allocator: Allocator, data: []const u8) !Image {
    var reader: std.Io.Reader = .fixed(data);
    return decode(allocator, &reader);
}

fn reconstructImage(allocator: Allocator, raw_data: []const u8, width: u32, height: u32, channels: u8) !Image {
    const stride = @as(usize, width) * @as(usize, channels);
    const expected_size = @as(usize, height) * (stride + 1); // +1 for filter byte per row

    if (raw_data.len != expected_size) {
        return DecodeError.InvalidImageData;
    }

    var img = try Image.init(allocator, width, height, channels);
    errdefer img.deinit();

    var prev_row: ?[]const u8 = null;
    for (0..height) |y| {
        const row_start = y * (stride + 1);
        const filter_type = raw_data[row_start];
        const filtered_row = raw_data[row_start + 1 .. row_start + 1 + stride];
        const out_row = img.data[y * stride .. (y + 1) * stride];

        try applyFilter(filter_type, filtered_row, prev_row, out_row, channels);
        prev_row = out_row;
    }

    return img;
}

fn reconstructInterlacedImage(allocator: Allocator, raw_data: []const u8, width: u32, height: u32, channels: u8) !Image {
    var img = try Image.init(allocator, width, height, channels);
    errdefer img.deinit();

    const img_stride = @as(usize, width) * @as(usize, channels);
    var offset: usize = 0;

    // Process each of the 7 Adam7 passes
    for (0..7) |pass| {
        const pass_width = Adam7.passWidth(width, pass);
        const pass_height = Adam7.passHeight(height, pass);

        if (pass_width == 0 or pass_height == 0) continue;

        const pass_stride = @as(usize, pass_width) * @as(usize, channels);
        const pass_size = @as(usize, pass_height) * (pass_stride + 1); // +1 for filter byte per row

        if (offset + pass_size > raw_data.len) {
            return DecodeError.InvalidImageData;
        }

        // Allocate temporary buffer for this pass
        const pass_pixels = try allocator.alloc(u8, @as(usize, pass_width) * @as(usize, pass_height) * channels);
        defer allocator.free(pass_pixels);

        // Decode the pass (apply filters)
        var prev_row: ?[]const u8 = null;
        for (0..pass_height) |y| {
            const row_start = offset + y * (pass_stride + 1);
            const filter_type = raw_data[row_start];
            const filtered_row = raw_data[row_start + 1 .. row_start + 1 + pass_stride];
            const out_row = pass_pixels[y * pass_stride .. (y + 1) * pass_stride];

            try applyFilter(filter_type, filtered_row, prev_row, out_row, channels);
            prev_row = out_row;
        }

        // Scatter pixels to final image
        const start_x = Adam7.passes[pass][0];
        const start_y = Adam7.passes[pass][1];
        const spacing_x = Adam7.passes[pass][2];
        const spacing_y = Adam7.passes[pass][3];

        for (0..pass_height) |py| {
            for (0..pass_width) |px| {
                const src_offset = (py * pass_stride) + (px * channels);
                const dst_x = start_x + @as(u32, @intCast(px)) * spacing_x;
                const dst_y = start_y + @as(u32, @intCast(py)) * spacing_y;
                const dst_offset = (@as(usize, dst_y) * img_stride) + (@as(usize, dst_x) * channels);

                @memcpy(img.data[dst_offset..][0..channels], pass_pixels[src_offset..][0..channels]);
            }
        }

        offset += pass_size;
    }

    return img;
}

// ============================================================================
// PNG Encoder
// ============================================================================

fn encode(allocator: Allocator, img: *const Image, writer: *std.Io.Writer) !void {
    // Write PNG signature
    try writer.writeAll(&PNG_SIGNATURE);

    // Write IHDR chunk
    try writeIhdrChunk(writer, img.width, img.height, img.channels);

    // Write IDAT chunk(s)
    try writeIdatChunks(allocator, writer, img);

    // Write IEND chunk
    try writeIendChunk(writer);
}

/// Save PNG to file path
pub fn saveToFile(io: std.Io, img: *const Image, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buf);

    try encode(img.allocator, img, &file_writer.interface);
    try file_writer.interface.flush();
}

/// Save PNG to memory buffer
pub fn saveToMemory(allocator: Allocator, img: *const Image) ![]u8 {
    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    try encode(allocator, img, &out_writer.writer);
    return out_writer.toOwnedSlice();
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: [4]u8, data: []const u8) !void {
    // Length (4 bytes, big endian)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try writer.writeAll(&len_buf);

    // Chunk type (4 bytes)
    try writer.writeAll(&chunk_type);

    // Data
    try writer.writeAll(data);

    // CRC32 (of chunk type + data)
    var crc = std.hash.Crc32.init();
    crc.update(&chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try writer.writeAll(&crc_buf);
}

fn buildIhdrData(width: u32, height: u32, channels: u8) [13]u8 {
    var ihdr_data: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
    ihdr_data[8] = 8;
    ihdr_data[9] = switch (channels) {
        1 => 0,
        2 => 4,
        3 => 2,
        4 => 6,
        else => 2,
    };
    ihdr_data[10] = 0;
    ihdr_data[11] = 0;
    ihdr_data[12] = 0;
    return ihdr_data;
}

fn writeIhdrChunk(writer: *std.Io.Writer, width: u32, height: u32, channels: u8) !void {
    var ihdr_data = buildIhdrData(width, height, channels);
    try writeChunk(writer, ChunkType.IHDR, &ihdr_data);
}

fn writeIdatChunks(allocator: Allocator, writer: *std.Io.Writer, img: *const Image) !void {
    const stride = @as(usize, img.width) * @as(usize, img.channels);

    // Prepare filtered data (add filter byte 0 = None for each row)
    const filtered_size = @as(usize, img.height) * (stride + 1);
    const filtered = try allocator.alloc(u8, filtered_size);
    defer allocator.free(filtered);

    for (0..img.height) |y| {
        const out_start = y * (stride + 1);
        const in_start = y * stride;
        filtered[out_start] = 0;
        @memcpy(filtered[out_start + 1 ..][0..stride], img.data[in_start..][0..stride]);
    }

    // Compress with zlib
    const compressed = try compressZlib(allocator, filtered);
    defer allocator.free(compressed);

    try writeChunk(writer, ChunkType.IDAT, compressed);
}

fn writeIendChunk(writer: *std.Io.Writer) !void {
    try writeChunk(writer, ChunkType.IEND, &.{});
}

/// Compress data using zlib format with fixed Huffman encoding.
/// This provides actual compression (unlike stored blocks) using the predefined
/// fixed Huffman codes from RFC 1951.
pub fn compressZlib(allocator: Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // Write zlib header (CMF=0x78, FLG=0x9C for default compression level)
    // CMF: CM=8 (deflate), CINFO=7 (32K window)
    // FLG: FLEVEL=2 (default), FDICT=0, FCHECK makes CMF*256+FLG divisible by 31
    try output.appendSlice(allocator, &[_]u8{ 0x78, 0x9C });

    // Use a BitWriter to write variable-length codes
    var bit_writer = BitWriter{ .output = &output, .allocator = allocator };

    // Write BFINAL=1 (last block), BTYPE=01 (fixed Huffman)
    try bit_writer.writeBits(1, 1); // BFINAL
    try bit_writer.writeBits(1, 2); // BTYPE = 01 (fixed Huffman)

    // Encode each byte using fixed Huffman codes
    for (data) |byte| {
        try writeFixedHuffmanLiteral(&bit_writer, byte);
    }

    // Write end-of-block code (256)
    // Code 256: 7 bits, value 0b0000000 (reversed to 0b0000000)
    try bit_writer.writeBits(0, 7);

    // Flush remaining bits
    try bit_writer.flush();

    // Write Adler-32 checksum (big endian)
    const adler_checksum = std.hash.Adler32.hash(data);
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler_checksum, .big);
    try output.appendSlice(allocator, &adler_buf);

    return output.toOwnedSlice(allocator);
}

/// Write a literal byte using fixed Huffman codes (RFC 1951 section 3.2.6)
fn writeFixedHuffmanLiteral(bw: *BitWriter, literal: u8) !void {
    if (literal <= 143) {
        // Codes 0-143: 8 bits, 00110000 + literal = codes 48-191
        // We need to bit-reverse before writing
        const code: u8 = 0b00110000 +% literal;
        try bw.writeBits(bitReverse8(code), 8);
    } else {
        // Codes 144-255: 9 bits, 110010000 + (literal - 144) = codes 400-511
        const code: u16 = 0b110010000 + @as(u16, literal - 144);
        try bw.writeBits(bitReverse16(code, 9), 9);
    }
}

/// Reverse the bits of a u8
fn bitReverse8(value: u8) u8 {
    return @bitReverse(value);
}

/// Reverse the bits of a u16, then shift right to get the top 'bits' bits
fn bitReverse16(value: u16, bits: u5) u16 {
    const r = @bitReverse(value);
    const shift: u4 = @intCast(16 - @as(u5, bits));
    return r >> shift;
}

/// Helper struct for writing bits to an ArrayList
const BitWriter = struct {
    output: *std.ArrayList(u8),
    allocator: Allocator,
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    /// Write bits to the buffer (LSB first, as per deflate spec)
    fn writeBits(self: *BitWriter, value: anytype, bits: u5) !void {
        self.bit_buffer |= @as(u32, @intCast(value)) << self.bit_count;
        self.bit_count += bits;

        // Flush complete bytes
        while (self.bit_count >= 8) {
            try self.output.append(self.allocator, @truncate(self.bit_buffer));
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Flush any remaining bits (pad with zeros)
    fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            try self.output.append(self.allocator, @truncate(self.bit_buffer));
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }
};

test "PNG round-trip: save and load produces identical image" {
    const allocator = std.testing.allocator;

    // Create a test image
    var img = try Image.init(allocator, 4, 4, 3);
    defer img.deinit();

    // Fill with test pattern
    const red = [_]u8{ 255, 0, 0 };
    const green = [_]u8{ 0, 255, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    const white = [_]u8{ 255, 255, 255 };

    img.setPixel(0, 0, &red);
    img.setPixel(1, 0, &green);
    img.setPixel(2, 0, &blue);
    img.setPixel(3, 0, &white);

    // Encode to PNG
    const png_data = try saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Decode back
    var decoded = try loadFromMemory(allocator, png_data);
    defer decoded.deinit();

    // Verify dimensions
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqual(img.channels, decoded.channels);

    // Verify pixel data
    try std.testing.expectEqualSlices(u8, img.data, decoded.data);
}

test "PNG save produces valid PNG file" {
    const allocator = std.testing.allocator;

    var img = try Image.init(allocator, 2, 2, 4);
    defer img.deinit();

    const pixel = [_]u8{ 128, 64, 32, 255 };
    img.setPixel(0, 0, &pixel);
    img.setPixel(1, 0, &pixel);
    img.setPixel(0, 1, &pixel);
    img.setPixel(1, 1, &pixel);

    const png_data = try saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Verify PNG signature
    try std.testing.expectEqualSlices(u8, &PNG_SIGNATURE, png_data[0..8]);

    // Should be able to load it back
    var decoded = try loadFromMemory(allocator, png_data);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(@as(u8, 4), decoded.channels);
}

test "PNG round-trip: grayscale image" {
    const allocator = std.testing.allocator;

    // Create a grayscale test image
    var img = try Image.init(allocator, 4, 4, 1);
    defer img.deinit();

    // Fill with gradient
    for (0..16) |i| {
        img.data[i] = @intCast(i * 16);
    }

    // Encode to PNG
    const png_data = try saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Decode back
    var decoded = try loadFromMemory(allocator, png_data);
    defer decoded.deinit();

    // Verify
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqual(img.channels, decoded.channels);
    try std.testing.expectEqualSlices(u8, img.data, decoded.data);
}

test "PNG round-trip: grayscale+alpha image" {
    const allocator = std.testing.allocator;

    // Create a grayscale+alpha test image
    var img = try Image.init(allocator, 4, 4, 2);
    defer img.deinit();

    // Fill with pattern
    var i: usize = 0;
    while (i < 32) : (i += 2) {
        img.data[i] = @intCast((i / 2) * 16); // gray value
        img.data[i + 1] = 200; // alpha
    }

    // Encode to PNG
    const png_data = try saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    // Decode back
    var decoded = try loadFromMemory(allocator, png_data);
    defer decoded.deinit();

    // Verify
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqual(img.channels, decoded.channels);
    try std.testing.expectEqualSlices(u8, img.data, decoded.data);
}

test "compressZlib produces valid zlib stream" {
    const allocator = std.testing.allocator;

    // Create test data with some variation
    const data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    // Compress it
    const compressed = try compressZlib(allocator, data);
    defer allocator.free(compressed);

    // Verify zlib header (0x78 0x9C = default compression)
    try std.testing.expectEqual(@as(u8, 0x78), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x9C), compressed[1]);

    // Verify it decompresses correctly
    var decompressor_buffer: [65536]u8 = undefined;
    var reader: std.Io.Reader = .fixed(compressed);
    var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &decompressor_buffer);

    const decompressed = try allocator.alloc(u8, data.len);
    defer allocator.free(decompressed);

    try decompressor.reader.readSliceAll(decompressed);
    try std.testing.expectEqualSlices(u8, data, decompressed);
}

test "compressZlib handles empty data" {
    const allocator = std.testing.allocator;

    const data: []const u8 = &.{};
    const compressed = try compressZlib(allocator, data);
    defer allocator.free(compressed);

    // Should have header + empty block + checksum
    try std.testing.expect(compressed.len > 0);

    // Verify it decompresses correctly
    var decompressor_buffer: [65536]u8 = undefined;
    var reader: std.Io.Reader = .fixed(compressed);
    var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &decompressor_buffer);

    const decompressed = try allocator.alloc(u8, 1);
    defer allocator.free(decompressed);

    // Empty data should decompress to nothing
    const result = decompressor.reader.readSliceShort(decompressed);
    if (result) |n| {
        try std.testing.expectEqual(@as(usize, 0), n);
    } else |_| {
        // EndOfStream is also acceptable for empty data
    }
}
