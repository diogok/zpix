const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.zpix_png);

pub const PNG_SIGNATURE = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub const ChunkType = struct {
    pub const IHDR = [4]u8{ 'I', 'H', 'D', 'R' };
    pub const IDAT = [4]u8{ 'I', 'D', 'A', 'T' };
    pub const IEND = [4]u8{ 'I', 'E', 'N', 'D' };
    pub const PLTE = [4]u8{ 'P', 'L', 'T', 'E' };
};

pub const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

/// Decode-specific errors (excludes allocator/reader errors which are composed)
pub const DecodeError = error{
    InvalidSignature,
    InvalidChunk,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    InvalidFilter,
    DecompressionFailed,
    InvalidImageData,
    CropOutOfBounds,
    InvalidResizeDimensions,
};

/// Shared PNG decoding context - extracts header info and decompressed scanlines
/// from a PNG reader. Used by png.zig for decoding.
pub const PngDecodeContext = struct {

    width: u32,
    height: u32,
    channels: u8,
    interlace: u8,
    raw_data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, reader: *std.Io.Reader) (DecodeError || Allocator.Error || std.Io.Reader.Error)!@This() {
        // Verify PNG signature
        const signature = try reader.takeArray(8);
        if (!std.mem.eql(u8, signature, &PNG_SIGNATURE)) {
            log.debug("Invalid PNG signature: expected 89 50 4E 47 0D 0A 1A 0A, got {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{ signature[0], signature[1], signature[2], signature[3], signature[4], signature[5], signature[6], signature[7] });
            return DecodeError.InvalidSignature;
        }

        var width: u32 = 0;
        var height: u32 = 0;
        var channels: u8 = 3;
        var interlace: u8 = 0;
        var idat_data: std.ArrayList(u8) = .empty;
        defer idat_data.deinit(allocator);

        // Parse chunks
        while (true) {
            const length = reader.takeInt(u32, .big) catch break;
            const chunk_type = reader.takeArray(4) catch break;

            if (std.mem.eql(u8, chunk_type, &ChunkType.IHDR)) {
                width = try reader.takeInt(u32, .big);
                height = try reader.takeInt(u32, .big);
                const bit_depth = try reader.takeByte();
                const ct = try reader.takeByte();
                const color_type = std.meta.intToEnum(ColorType, ct) catch return DecodeError.UnsupportedColorType;
                _ = try reader.takeByte(); // compression
                _ = try reader.takeByte(); // filter
                interlace = try reader.takeByte();

                if (bit_depth != 8) {
                    return DecodeError.UnsupportedBitDepth;
                }
                if (interlace != 0 and interlace != 1) {
                    return DecodeError.UnsupportedInterlace;
                }

                channels = switch (color_type) {
                    .grayscale => 1,
                    .grayscale_alpha => 2,
                    .rgb => 3,
                    .rgba => 4,
                    else => return DecodeError.UnsupportedColorType,
                };

                // Skip CRC
                try reader.discardAll(4);
            } else if (std.mem.eql(u8, chunk_type, &ChunkType.IDAT)) {
                try idat_data.ensureUnusedCapacity(allocator, length);
                var remaining: usize = length;
                while (remaining > 0) {
                    const to_read = @min(remaining, 65536);
                    const chunk_data = try reader.take(to_read);
                    idat_data.appendSliceAssumeCapacity(chunk_data);
                    remaining -= to_read;
                }
                // Skip CRC
                try reader.discardAll(4);
            } else if (std.mem.eql(u8, chunk_type, &ChunkType.IEND)) {
                break;
            } else {
                // Skip unknown chunk
                try reader.discardAll(length + 4); // data + CRC
            }
        }

        // Decompress IDAT data (zlib)
        // For non-interlaced, we know the exact decompressed size
        const expected_size: usize = if (interlace == 0)
            @as(usize, height) * (@as(usize, width) * @as(usize, channels) + 1)
        else
            0;
        const raw_data = try decompressZlib(allocator, idat_data.items, expected_size);
        errdefer allocator.free(raw_data);

        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .interlace = interlace,
            .raw_data = raw_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.raw_data);
        self.* = undefined;
    }

    /// Returns stride (bytes per row of pixel data, excluding filter byte)
    pub fn stride(self: @This()) usize {
        return @as(usize, self.width) * @as(usize, self.channels);
    }
};

fn decompressZlib(allocator: Allocator, data: []const u8, expected_size: usize) (DecodeError || Allocator.Error)![]u8 {
    var input_reader: std.Io.Reader = .fixed(data);
    const decompress_buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(decompress_buffer);
    var decompress: std.compress.flate.Decompress = .init(&input_reader, .zlib, decompress_buffer);

    // Pre-allocate exact expected size and read directly into it
    if (expected_size > 0) {
        const result = try allocator.alloc(u8, expected_size);
        errdefer allocator.free(result);
        decompress.reader.readSliceAll(result) catch {
            return DecodeError.DecompressionFailed;
        };
        return result;
    }

    // Fallback for unknown size
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    decompress.reader.appendRemainingUnlimited(allocator, &result) catch {
        return DecodeError.DecompressionFailed;
    };

    return result.toOwnedSlice(allocator);
}

// Adam7 interlacing parameters: start_x, start_y, x_spacing, y_spacing
pub const Adam7 = struct {
    pub const passes = [7][4]u32{
        .{ 0, 0, 8, 8 }, // Pass 1
        .{ 4, 0, 8, 8 }, // Pass 2
        .{ 0, 4, 4, 8 }, // Pass 3
        .{ 2, 0, 4, 4 }, // Pass 4
        .{ 0, 2, 2, 4 }, // Pass 5
        .{ 1, 0, 2, 2 }, // Pass 6
        .{ 0, 1, 1, 2 }, // Pass 7
    };

    pub fn passWidth(img_width: u32, pass: usize) u32 {
        const start_x = passes[pass][0];
        const spacing_x = passes[pass][2];
        if (img_width <= start_x) return 0;
        return (img_width - start_x + spacing_x - 1) / spacing_x;
    }

    pub fn passHeight(img_height: u32, pass: usize) u32 {
        const start_y = passes[pass][1];
        const spacing_y = passes[pass][3];
        if (img_height <= start_y) return 0;
        return (img_height - start_y + spacing_y - 1) / spacing_y;
    }
};

/// Apply PNG filter to reconstruct pixel data
pub fn applyFilter(filter_type: u8, filtered: []const u8, prev_row: ?[]const u8, output: []u8, bpp: u8) DecodeError!void {
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
        else => return DecodeError.InvalidFilter,
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

test "PngDecodeContext parses valid PNG" {
    const allocator = std.testing.allocator;

    // Create a minimal valid PNG in memory
    const png = @import("png.zig");
    const Image = @import("image.zig");

    var img = try Image.init(allocator, 4, 4, 3);
    defer img.deinit();

    const red = [_]u8{ 255, 0, 0 };
    img.setPixel(0, 0, &red);

    const png_data = try png.saveToMemory(allocator, &img);
    defer allocator.free(png_data);

    var reader: std.Io.Reader = .fixed(png_data);
    var ctx = try PngDecodeContext.init(allocator, &reader);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 4), ctx.width);
    try std.testing.expectEqual(@as(u32, 4), ctx.height);
    try std.testing.expectEqual(@as(u8, 3), ctx.channels);
    try std.testing.expectEqual(@as(u8, 0), ctx.interlace);
}

test "PngDecodeContext rejects invalid signature" {
    const allocator = std.testing.allocator;

    const bad_data = "not a PNG file at all";
    var reader: std.Io.Reader = .fixed(bad_data);

    try std.testing.expectError(DecodeError.InvalidSignature, PngDecodeContext.init(allocator, &reader));
}

test "applyFilter handles all filter types" {
    // Filter 0: None
    {
        var output: [4]u8 = undefined;
        try applyFilter(0, &[_]u8{ 1, 2, 3, 4 }, null, &output, 1);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &output);
    }

    // Filter 1: Sub
    {
        var output: [4]u8 = undefined;
        try applyFilter(1, &[_]u8{ 1, 1, 1, 1 }, null, &output, 1);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &output);
    }

    // Filter 2: Up
    {
        var output: [4]u8 = undefined;
        const prev = [_]u8{ 10, 20, 30, 40 };
        try applyFilter(2, &[_]u8{ 1, 2, 3, 4 }, &prev, &output, 1);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 11, 22, 33, 44 }, &output);
    }
}
