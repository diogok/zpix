const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const Image = image.Image;

pub const PngError = error{
    InvalidSignature,
    InvalidChunk,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    InvalidFilter,
    DecompressionFailed,
    InvalidImageData,
    OutOfMemory,
    EndOfStream,
};

const PNG_SIGNATURE = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

// Adam7 interlacing parameters: start_x, start_y, x_spacing, y_spacing
const Adam7 = struct {
    const passes = [7][4]u32{
        .{ 0, 0, 8, 8 }, // Pass 1
        .{ 4, 0, 8, 8 }, // Pass 2
        .{ 0, 4, 4, 8 }, // Pass 3
        .{ 2, 0, 4, 4 }, // Pass 4
        .{ 0, 2, 2, 4 }, // Pass 5
        .{ 1, 0, 2, 2 }, // Pass 6
        .{ 0, 1, 1, 2 }, // Pass 7
    };

    fn passWidth(img_width: u32, pass: usize) u32 {
        const start_x = passes[pass][0];
        const spacing_x = passes[pass][2];
        if (img_width <= start_x) return 0;
        return (img_width - start_x + spacing_x - 1) / spacing_x;
    }

    fn passHeight(img_height: u32, pass: usize) u32 {
        const start_y = passes[pass][1];
        const spacing_y = passes[pass][3];
        if (img_height <= start_y) return 0;
        return (img_height - start_y + spacing_y - 1) / spacing_y;
    }
};

const ChunkType = struct {
    const IHDR = [4]u8{ 'I', 'H', 'D', 'R' };
    const IDAT = [4]u8{ 'I', 'D', 'A', 'T' };
    const IEND = [4]u8{ 'I', 'E', 'N', 'D' };
    const PLTE = [4]u8{ 'P', 'L', 'T', 'E' };
};

pub fn loadFromFile(allocator: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 64); // 64MB max
    defer allocator.free(data);

    return loadFromMemory(allocator, data);
}

pub fn loadFromMemory(allocator: Allocator, data: []const u8) !Image {
    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    // Verify PNG signature
    var signature: [8]u8 = undefined;
    _ = try reader.readAll(&signature);
    if (!std.mem.eql(u8, &signature, &PNG_SIGNATURE)) {
        return PngError.InvalidSignature;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: ColorType = .rgb;
    var channels: u8 = 3;
    var interlace: u8 = 0;
    var idat_data: std.ArrayList(u8) = .empty;
    defer idat_data.deinit(allocator);

    // Parse chunks
    while (true) {
        const length = reader.readInt(u32, .big) catch break;
        var chunk_type: [4]u8 = undefined;
        _ = reader.readAll(&chunk_type) catch break;

        if (std.mem.eql(u8, &chunk_type, &ChunkType.IHDR)) {
            width = try reader.readInt(u32, .big);
            height = try reader.readInt(u32, .big);
            bit_depth = try reader.readByte();
            const ct = try reader.readByte();
            color_type = std.meta.intToEnum(ColorType, ct) catch return PngError.UnsupportedColorType;
            const compression = try reader.readByte();
            const filter = try reader.readByte();
            interlace = try reader.readByte();
            _ = compression;
            _ = filter;

            if (bit_depth != 8) {
                return PngError.UnsupportedBitDepth;
            }
            if (interlace != 0 and interlace != 1) {
                return PngError.UnsupportedInterlace;
            }

            channels = switch (color_type) {
                .grayscale => 1,
                .grayscale_alpha => 2,
                .rgb => 3,
                .rgba => 4,
                else => return PngError.UnsupportedColorType,
            };

            // Skip CRC
            try reader.skipBytes(4, .{});
        } else if (std.mem.eql(u8, &chunk_type, &ChunkType.IDAT)) {
            const chunk_data = try allocator.alloc(u8, length);
            defer allocator.free(chunk_data);
            _ = try reader.readAll(chunk_data);
            try idat_data.appendSlice(allocator, chunk_data);
            // Skip CRC
            try reader.skipBytes(4, .{});
        } else if (std.mem.eql(u8, &chunk_type, &ChunkType.IEND)) {
            break;
        } else {
            // Skip unknown chunk
            try reader.skipBytes(length + 4, .{}); // data + CRC
        }
    }

    // Decompress IDAT data (zlib)
    const raw_data = try decompressZlib(allocator, idat_data.items);
    defer allocator.free(raw_data);

    // Reconstruct image from filtered scanlines
    if (interlace == 1) {
        return reconstructInterlacedImage(allocator, raw_data, width, height, channels);
    } else {
        return reconstructImage(allocator, raw_data, width, height, channels);
    }
}

fn decompressZlib(allocator: Allocator, data: []const u8) ![]u8 {
    var input_reader: std.Io.Reader = .fixed(data);
    var decompress: std.compress.flate.Decompress = .init(&input_reader, .zlib, &.{});

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    decompress.reader.appendRemainingUnlimited(allocator, &result) catch {
        return PngError.DecompressionFailed;
    };

    return result.toOwnedSlice(allocator);
}

fn reconstructImage(allocator: Allocator, raw_data: []const u8, width: u32, height: u32, channels: u8) !Image {
    const stride = @as(usize, width) * @as(usize, channels);
    const expected_size = @as(usize, height) * (stride + 1); // +1 for filter byte per row

    if (raw_data.len != expected_size) {
        return PngError.InvalidImageData;
    }

    var img = try Image.init(allocator, width, height, channels);
    errdefer img.deinit();

    var prev_row: ?[]const u8 = null;
    var y: usize = 0;
    while (y < height) : (y += 1) {
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
            return PngError.InvalidImageData;
        }

        // Allocate temporary buffer for this pass
        const pass_pixels = try allocator.alloc(u8, @as(usize, pass_width) * @as(usize, pass_height) * channels);
        defer allocator.free(pass_pixels);

        // Decode the pass (apply filters)
        var prev_row: ?[]const u8 = null;
        var y: usize = 0;
        while (y < pass_height) : (y += 1) {
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

        var py: u32 = 0;
        while (py < pass_height) : (py += 1) {
            var px: u32 = 0;
            while (px < pass_width) : (px += 1) {
                const src_offset = (@as(usize, py) * pass_stride) + (@as(usize, px) * channels);
                const dst_x = start_x + px * spacing_x;
                const dst_y = start_y + py * spacing_y;
                const dst_offset = (@as(usize, dst_y) * img_stride) + (@as(usize, dst_x) * channels);

                @memcpy(img.data[dst_offset..][0..channels], pass_pixels[src_offset..][0..channels]);
            }
        }

        offset += pass_size;
    }

    return img;
}

fn applyFilter(filter_type: u8, filtered: []const u8, prev_row: ?[]const u8, output: []u8, bpp: u8) !void {
    const bytes_per_pixel = @as(usize, bpp);

    switch (filter_type) {
        0 => { // None
            @memcpy(output, filtered);
        },
        1 => { // Sub
            for (output, 0..) |*out, i| {
                const a: u8 = if (i >= bytes_per_pixel) output[i - bytes_per_pixel] else 0;
                out.* = filtered[i] +% a;
            }
        },
        2 => { // Up
            for (output, 0..) |*out, i| {
                const b: u8 = if (prev_row) |pr| pr[i] else 0;
                out.* = filtered[i] +% b;
            }
        },
        3 => { // Average
            for (output, 0..) |*out, i| {
                const a: u16 = if (i >= bytes_per_pixel) output[i - bytes_per_pixel] else 0;
                const b: u16 = if (prev_row) |pr| pr[i] else 0;
                out.* = filtered[i] +% @as(u8, @intCast((a + b) / 2));
            }
        },
        4 => { // Paeth
            for (output, 0..) |*out, i| {
                const a: i32 = if (i >= bytes_per_pixel) output[i - bytes_per_pixel] else 0;
                const b: i32 = if (prev_row) |pr| pr[i] else 0;
                const c: i32 = if (i >= bytes_per_pixel and prev_row != null) prev_row.?[i - bytes_per_pixel] else 0;
                out.* = filtered[i] +% paethPredictor(a, b, c);
            }
        },
        else => return PngError.InvalidFilter,
    }
}

fn paethPredictor(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @intCast(a);
    } else if (pb <= pc) {
        return @intCast(b);
    } else {
        return @intCast(c);
    }
}

// ============================================================================
// PNG Encoder
// ============================================================================

pub fn saveToFile(img: *const Image, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const data = try saveToMemory(img.allocator, img);
    defer img.allocator.free(data);

    try file.writeAll(data);
}

pub fn saveToMemory(allocator: Allocator, img: *const Image) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // Write PNG signature
    try output.appendSlice(allocator, &PNG_SIGNATURE);

    // Write IHDR chunk
    try writeIhdrChunk(allocator, &output, img.width, img.height, img.channels);

    // Write IDAT chunk(s)
    try writeIdatChunks(allocator, &output, img);

    // Write IEND chunk
    try writeIendChunk(allocator, &output);

    return output.toOwnedSlice(allocator);
}

fn writeChunk(allocator: Allocator, output: *std.ArrayList(u8), chunk_type: [4]u8, data: []const u8) !void {
    // Length (4 bytes, big endian)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try output.appendSlice(allocator, &len_buf);

    // Chunk type (4 bytes)
    try output.appendSlice(allocator, &chunk_type);

    // Data
    try output.appendSlice(allocator, data);

    // CRC32 (of chunk type + data)
    var crc = std.hash.Crc32.init();
    crc.update(&chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try output.appendSlice(allocator, &crc_buf);
}

fn writeIhdrChunk(allocator: Allocator, output: *std.ArrayList(u8), width: u32, height: u32, channels: u8) !void {
    var ihdr_data: [13]u8 = undefined;

    // Width (4 bytes)
    std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
    // Height (4 bytes)
    std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
    // Bit depth (1 byte) - always 8
    ihdr_data[8] = 8;
    // Color type (1 byte) - 0 for grayscale, 2 for RGB, 4 for grayscale+alpha, 6 for RGBA
    ihdr_data[9] = switch (channels) {
        1 => 0, // grayscale
        2 => 4, // grayscale + alpha
        3 => 2, // RGB
        4 => 6, // RGBA
        else => 2,
    };
    // Compression method (1 byte) - always 0
    ihdr_data[10] = 0;
    // Filter method (1 byte) - always 0
    ihdr_data[11] = 0;
    // Interlace method (1 byte) - 0 for no interlace
    ihdr_data[12] = 0;

    try writeChunk(allocator, output, ChunkType.IHDR, &ihdr_data);
}

fn writeIdatChunks(allocator: Allocator, output: *std.ArrayList(u8), img: *const Image) !void {
    const stride = @as(usize, img.width) * @as(usize, img.channels);

    // Prepare filtered data (add filter byte 0 = None for each row)
    const filtered_size = @as(usize, img.height) * (stride + 1);
    const filtered = try allocator.alloc(u8, filtered_size);
    defer allocator.free(filtered);

    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        const out_start = y * (stride + 1);
        const in_start = y * stride;

        // Filter type 0 (None) for simplicity
        filtered[out_start] = 0;
        @memcpy(filtered[out_start + 1 ..][0..stride], img.data[in_start..][0..stride]);
    }

    // Compress with zlib
    const compressed = try compressZlib(allocator, filtered);
    defer allocator.free(compressed);

    // Write as single IDAT chunk (could split for large images)
    try writeChunk(allocator, output, ChunkType.IDAT, compressed);
}

fn writeIendChunk(allocator: Allocator, output: *std.ArrayList(u8)) !void {
    try writeChunk(allocator, output, ChunkType.IEND, &.{});
}

fn compressZlib(allocator: Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // Write zlib header (CMF, FLG)
    // CMF = 0x78 (deflate, 32K window)
    // FLG = 0x01 (fastest compression, no dict, checksum valid)
    // Note: 0x78 0x01 is valid zlib header (FCHECK makes checksum valid)
    try output.appendSlice(allocator, &[_]u8{ 0x78, 0x01 });

    // Write deflate stored blocks (no compression, but valid deflate format)
    // Stored blocks are limited to 65535 bytes each
    const max_block_size: usize = 65535;
    var offset: usize = 0;

    while (offset < data.len) {
        const remaining = data.len - offset;
        const block_size = @min(remaining, max_block_size);
        const is_final = (offset + block_size >= data.len);

        // Block header: 1 byte
        // bit 0: BFINAL (1 if this is the last block)
        // bits 1-2: BTYPE (00 = stored/uncompressed)
        const header_byte: u8 = if (is_final) 0x01 else 0x00;
        try output.append(allocator, header_byte);

        // LEN: 2 bytes (little endian)
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(block_size), .little);
        try output.appendSlice(allocator, &len_buf);

        // NLEN: 2 bytes (one's complement of LEN, little endian)
        var nlen_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &nlen_buf, @intCast(~@as(u16, @intCast(block_size))), .little);
        try output.appendSlice(allocator, &nlen_buf);

        // Data
        try output.appendSlice(allocator, data[offset..][0..block_size]);

        offset += block_size;
    }

    // Handle empty data case
    if (data.len == 0) {
        // Empty final stored block
        try output.append(allocator, 0x01); // BFINAL=1, BTYPE=00
        try output.appendSlice(allocator, &[_]u8{ 0x00, 0x00 }); // LEN=0
        try output.appendSlice(allocator, &[_]u8{ 0xFF, 0xFF }); // NLEN=~0
    }

    // Write Adler-32 checksum (big endian)
    const adler_checksum = std.hash.Adler32.hash(data);
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler_checksum, .big);
    try output.appendSlice(allocator, &adler_buf);

    return output.toOwnedSlice(allocator);
}

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
