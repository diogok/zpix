const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig");

// Standard JPEG quantization tables (ITU-T T.81 Annex K, Table K.1 and K.2)
const std_luminance_quant_table = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const std_chrominance_quant_table = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

// Zigzag order for 8x8 block (same as decoder)
const zigzag_order = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// Standard Huffman tables from JPEG spec Annex K

// DC luminance (Table K.3)
const dc_lum_bits = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_lum_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

// DC chrominance (Table K.4)
const dc_chrom_bits = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_chrom_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

// AC luminance (Table K.5)
const ac_lum_bits = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_lum_vals = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

// AC chrominance (Table K.6)
const ac_chrom_bits = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chrom_vals = [162]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
    0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
    0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
    0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

// Forward zigzag: maps natural position → zigzag index (inverse of decoder's zigzag_order)
const fwd_zigzag = blk: {
    var result: [64]u8 = undefined;
    for (0..64) |i| {
        result[zigzag_order[i]] = @intCast(i);
    }
    break :blk result;
};

// AAN DCT scaling factors (matching stb_image_write)
const aan_scales = [8]f32{
    1.0 * 2.828427125,
    1.387039845 * 2.828427125,
    1.306562965 * 2.828427125,
    1.175875602 * 2.828427125,
    1.0 * 2.828427125,
    0.785694958 * 2.828427125,
    0.541196100 * 2.828427125,
    0.275899379 * 2.828427125,
};

// Precomputed Huffman encoding table: for each symbol, stores the code and its bit length
const HuffCode = struct {
    code: u16,
    len: u8,
};

fn buildHuffCodes(bits: [16]u8, vals: []const u8) [256]HuffCode {
    var result: [256]HuffCode = [_]HuffCode{.{ .code = 0, .len = 0 }} ** 256;
    var code: u16 = 0;
    var symbol_index: usize = 0;

    for (0..16) |i| {
        const len: u8 = @intCast(i + 1);
        for (0..bits[i]) |_| {
            result[vals[symbol_index]] = .{ .code = code, .len = len };
            symbol_index += 1;
            code += 1;
        }
        code <<= 1;
    }
    return result;
}

const dc_lum_codes = buildHuffCodes(dc_lum_bits, &dc_lum_vals);
const dc_chrom_codes = buildHuffCodes(dc_chrom_bits, &dc_chrom_vals);
const ac_lum_codes = buildHuffCodes(ac_lum_bits, &ac_lum_vals);
const ac_chrom_codes = buildHuffCodes(ac_chrom_bits, &ac_chrom_vals);

// Bit writer for JPEG (MSB-first with byte-stuffing)
// Matches stb_image_write's approach: bits are stored with the "current" byte at
// positions 16-23 of bit_buf, extracted as (bit_buf >> 16) & 0xFF.
const JpegBitWriter = struct {
    writer: *std.Io.Writer,
    bit_buf: i32,
    bit_cnt: i32,

    fn init(writer: *std.Io.Writer) JpegBitWriter {
        return .{
            .writer = writer,
            .bit_buf = 0,
            .bit_cnt = 0,
        };
    }

    fn writeBits(self: *JpegBitWriter, code: u16, num_bits: u8) !void {
        if (num_bits == 0) return;
        self.bit_cnt += num_bits;
        self.bit_buf |= @as(i32, code) << @intCast(24 - @as(u5, @intCast(self.bit_cnt)));

        while (self.bit_cnt >= 8) {
            const c: u8 = @intCast((@as(u32, @bitCast(self.bit_buf)) >> 16) & 0xFF);
            try self.writer.writeAll(&[_]u8{c});
            if (c == 0xFF) {
                try self.writer.writeAll(&[_]u8{0x00});
            }
            self.bit_buf <<= 8;
            self.bit_cnt -= 8;
        }
    }

    fn flush(self: *JpegBitWriter) !void {
        if (self.bit_cnt > 0) {
            // Pad with 1-bits
            const c: u8 = @intCast((@as(u32, @bitCast(self.bit_buf)) >> 16) & 0xFF);
            const padded = c | ((@as(u8, 1) << @intCast(8 - @as(u4, @intCast(self.bit_cnt)))) - 1);
            try self.writer.writeAll(&[_]u8{padded});
            if (padded == 0xFF) {
                try self.writer.writeAll(&[_]u8{0x00});
            }
            self.bit_buf = 0;
            self.bit_cnt = 0;
        }
    }
};

// Compute the number of bits needed to represent a value, and the VLI code
fn computeVLI(value: i32) struct { num_bits: u8, bits: u16 } {
    if (value == 0) return .{ .num_bits = 0, .bits = 0 };

    const abs_val = if (value < 0) -value else value;
    var num_bits: u8 = 0;
    var remaining = abs_val;
    while (remaining > 0) {
        num_bits += 1;
        remaining >>= 1;
    }

    const bits: u16 = if (value < 0)
        @intCast(value + (@as(i32, 1) << @intCast(num_bits)) - 1)
    else
        @intCast(value);

    return .{ .num_bits = num_bits, .bits = bits };
}

// Scale quantization table by quality factor (IJG formula)
fn scaleQuantTable(base: [64]u8, quality: u8) [64]u8 {
    const q: u32 = if (quality == 0) 1 else if (quality > 100) 100 else quality;
    const scale: u32 = if (q < 50) 5000 / q else 200 - 2 * q;

    var result: [64]u8 = undefined;
    for (0..64) |i| {
        const val = (@as(u32, base[i]) * scale + 50) / 100;
        result[i] = @intCast(std.math.clamp(val, 1, 255));
    }
    return result;
}

// Build the combined FDCT+quantization table (1/(qtable * aanscale * 8))
fn buildFdtbl(qtable: [64]u8) [64]f32 {
    var fdtbl: [64]f32 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const k = row * 8 + col;
            fdtbl[k] = 1.0 / (@as(f32, @floatFromInt(qtable[k])) * aan_scales[row] * aan_scales[col]);
        }
    }
    return fdtbl;
}

// AAN-based forward DCT (matching stb_image_write)
fn fdct1d(d0p: *f32, d1p: *f32, d2p: *f32, d3p: *f32, d4p: *f32, d5p: *f32, d6p: *f32, d7p: *f32) void {
    var d0 = d0p.*;
    const d1 = d1p.*;
    var d2 = d2p.*;
    const d3 = d3p.*;
    var d4 = d4p.*;
    const d5 = d5p.*;
    var d6 = d6p.*;
    const d7 = d7p.*;

    const tmp0 = d0 + d7;
    const tmp7 = d0 - d7;
    const tmp1 = d1 + d6;
    const tmp6 = d1 - d6;
    const tmp2 = d2 + d5;
    const tmp5 = d2 - d5;
    const tmp3 = d3 + d4;
    const tmp4 = d3 - d4;

    // Even part
    var tmp10 = tmp0 + tmp3;
    const tmp13 = tmp0 - tmp3;
    var tmp11 = tmp1 + tmp2;
    const tmp12 = tmp1 - tmp2;

    d0 = tmp10 + tmp11;
    d4 = tmp10 - tmp11;

    const z1 = (tmp12 + tmp13) * 0.707106781;
    d2 = tmp13 + z1;
    d6 = tmp13 - z1;

    // Odd part
    tmp10 = tmp4 + tmp5;
    tmp11 = tmp5 + tmp6;
    const tmp12b = tmp6 + tmp7;

    const z5 = (tmp10 - tmp12b) * 0.382683433;
    const z2 = tmp10 * 0.541196100 + z5;
    const z4 = tmp12b * 1.306562965 + z5;
    const z3 = tmp11 * 0.707106781;

    const z11 = tmp7 + z3;
    const z13 = tmp7 - z3;

    d5p.* = z13 + z2;
    d3p.* = z13 - z2;
    d1p.* = z11 + z4;
    d7p.* = z11 - z4;
    d0p.* = d0;
    d2p.* = d2;
    d4p.* = d4;
    d6p.* = d6;
}

// Process a single 8x8 block: DCT, quantize, and Huffman encode
fn processDU(
    bw: *JpegBitWriter,
    cdu: *[64]f32,
    fdtbl: *const [64]f32,
    prev_dc: *i32,
    dc_codes: *const [256]HuffCode,
    ac_codes: *const [256]HuffCode,
) !void {
    // DCT rows
    for (0..8) |row| {
        const off = row * 8;
        fdct1d(&cdu[off], &cdu[off + 1], &cdu[off + 2], &cdu[off + 3], &cdu[off + 4], &cdu[off + 5], &cdu[off + 6], &cdu[off + 7]);
    }
    // DCT columns
    for (0..8) |col| {
        fdct1d(&cdu[col], &cdu[col + 8], &cdu[col + 16], &cdu[col + 24], &cdu[col + 32], &cdu[col + 40], &cdu[col + 48], &cdu[col + 56]);
    }

    // Quantize and zigzag reorder
    var du: [64]i32 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const j = row * 8 + col;
            const v = cdu[j] * fdtbl[j];
            du[fwd_zigzag[j]] = if (v < 0) @intFromFloat(v - 0.5) else @intFromFloat(v + 0.5);
        }
    }

    // Encode DC
    const dc_diff = du[0] - prev_dc.*;
    prev_dc.* = du[0];

    if (dc_diff == 0) {
        try bw.writeBits(dc_codes[0].code, dc_codes[0].len);
    } else {
        const vli = computeVLI(dc_diff);
        try bw.writeBits(dc_codes[vli.num_bits].code, dc_codes[vli.num_bits].len);
        try bw.writeBits(vli.bits, vli.num_bits);
    }

    // Encode AC
    // Find last non-zero coefficient
    var end0pos: usize = 63;
    while (end0pos > 0 and du[end0pos] == 0) {
        end0pos -= 1;
    }

    if (end0pos == 0) {
        // All ACs are zero
        try bw.writeBits(ac_codes[0x00].code, ac_codes[0x00].len);
        return;
    }

    var i: usize = 1;
    while (i <= end0pos) {
        var num_zeroes: usize = 0;
        while (i <= end0pos and du[i] == 0) {
            num_zeroes += 1;
            i += 1;
        }
        if (i > end0pos) break;

        while (num_zeroes >= 16) {
            try bw.writeBits(ac_codes[0xF0].code, ac_codes[0xF0].len);
            num_zeroes -= 16;
        }

        const vli = computeVLI(du[i]);
        const run_size: u8 = @intCast(num_zeroes * 16 + @as(usize, vli.num_bits));
        try bw.writeBits(ac_codes[run_size].code, ac_codes[run_size].len);
        try bw.writeBits(vli.bits, vli.num_bits);
        i += 1;
    }

    if (end0pos < 63) {
        try bw.writeBits(ac_codes[0x00].code, ac_codes[0x00].len);
    }
}

fn writeU16(writer: *std.Io.Writer, val: u16) !void {
    const buf = [2]u8{ @intCast(val >> 8), @intCast(val & 0xFF) };
    try writer.writeAll(&buf);
}

fn writeMarker(writer: *std.Io.Writer, marker: u16) !void {
    try writeU16(writer, marker);
}

fn writeAPP0(writer: *std.Io.Writer) !void {
    try writeMarker(writer, 0xFFE0);
    try writeU16(writer, 16);
    try writer.writeAll("JFIF\x00");
    try writer.writeAll(&[_]u8{ 1, 1 }); // Version 1.1
    try writer.writeAll(&[_]u8{0}); // No units
    try writeU16(writer, 1); // X density
    try writeU16(writer, 1); // Y density
    try writer.writeAll(&[_]u8{ 0, 0 }); // No thumbnail
}

fn writeDQT(writer: *std.Io.Writer, table_id: u8, qtable: *const [64]u8) !void {
    try writeMarker(writer, 0xFFDB);
    try writeU16(writer, 67); // Length: 2 + 1 + 64
    try writer.writeAll(&[_]u8{table_id});

    // Write in zigzag order (JPEG spec stores DQT values in zigzag order)
    var zigzag_data: [64]u8 = undefined;
    for (0..64) |i| {
        zigzag_data[i] = qtable[zigzag_order[i]];
    }
    try writer.writeAll(&zigzag_data);
}

fn writeSOF0(writer: *std.Io.Writer, width: u16, height: u16, num_components: u8) !void {
    try writeMarker(writer, 0xFFC0);
    const length: u16 = 8 + 3 * @as(u16, num_components);
    try writeU16(writer, length);
    try writer.writeAll(&[_]u8{8}); // 8-bit precision
    try writeU16(writer, height);
    try writeU16(writer, width);
    try writer.writeAll(&[_]u8{num_components});

    if (num_components == 1) {
        try writer.writeAll(&[_]u8{ 1, 0x11, 0 });
    } else {
        try writer.writeAll(&[_]u8{ 1, 0x11, 0 }); // Y
        try writer.writeAll(&[_]u8{ 2, 0x11, 1 }); // Cb
        try writer.writeAll(&[_]u8{ 3, 0x11, 1 }); // Cr
    }
}

fn writeDHT(writer: *std.Io.Writer, class_id: u8, bits: [16]u8, vals: []const u8) !void {
    var total: u16 = 0;
    for (bits) |b| total += b;

    try writeMarker(writer, 0xFFC4);
    try writeU16(writer, 2 + 1 + 16 + total);
    try writer.writeAll(&[_]u8{class_id});
    try writer.writeAll(&bits);
    try writer.writeAll(vals[0..total]);
}

fn writeSOS(writer: *std.Io.Writer, num_components: u8) !void {
    try writeMarker(writer, 0xFFDA);
    const length: u16 = 6 + 2 * @as(u16, num_components);
    try writeU16(writer, length);
    try writer.writeAll(&[_]u8{num_components});

    if (num_components == 1) {
        try writer.writeAll(&[_]u8{ 1, 0x00 });
    } else {
        try writer.writeAll(&[_]u8{ 1, 0x00 }); // Y: DC0, AC0
        try writer.writeAll(&[_]u8{ 2, 0x11 }); // Cb: DC1, AC1
        try writer.writeAll(&[_]u8{ 3, 0x11 }); // Cr: DC1, AC1
    }
    try writer.writeAll(&[_]u8{ 0, 63, 0 }); // Ss=0, Se=63, Ah=0|Al=0
}

fn encode(_: Allocator, img: *const Image, writer: *std.Io.Writer, quality: u8) !void {

    const clamped_quality = if (quality == 0) @as(u8, 1) else quality;

    // Scale quantization tables
    const lum_qtable = scaleQuantTable(std_luminance_quant_table, clamped_quality);
    const chrom_qtable = scaleQuantTable(std_chrominance_quant_table, clamped_quality);

    // Build combined FDCT+quantization tables
    const fdtbl_y = buildFdtbl(lum_qtable);
    const fdtbl_uv = buildFdtbl(chrom_qtable);

    const jpeg_components: u8 = if (img.channels == 1) 1 else 3;

    // Write JFIF structure
    try writeMarker(writer, 0xFFD8); // SOI
    try writeAPP0(writer);
    try writeDQT(writer, 0, &lum_qtable);
    if (jpeg_components == 3) {
        try writeDQT(writer, 1, &chrom_qtable);
    }
    try writeSOF0(writer, @intCast(img.width), @intCast(img.height), jpeg_components);

    // Write Huffman tables
    try writeDHT(writer, 0x00, dc_lum_bits, &dc_lum_vals);
    try writeDHT(writer, 0x10, ac_lum_bits, &ac_lum_vals);
    if (jpeg_components == 3) {
        try writeDHT(writer, 0x01, dc_chrom_bits, &dc_chrom_vals);
        try writeDHT(writer, 0x11, ac_chrom_bits, &ac_chrom_vals);
    }

    try writeSOS(writer, jpeg_components);

    // Encode image data
    var bw = JpegBitWriter.init(writer);

    const width: usize = img.width;
    const height: usize = img.height;
    const blocks_x = (width + 7) / 8;
    const blocks_y = (height + 7) / 8;

    var prev_dc_y: i32 = 0;
    var prev_dc_cb: i32 = 0;
    var prev_dc_cr: i32 = 0;

    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            if (jpeg_components == 1) {
                var cdu: [64]f32 = undefined;
                for (0..8) |row| {
                    for (0..8) |col| {
                        const px = @min(bx * 8 + col, width - 1);
                        const py = @min(by * 8 + row, height - 1);
                        const idx = py * width * @as(usize, img.channels) + px * @as(usize, img.channels);
                        cdu[row * 8 + col] = @as(f32, @floatFromInt(img.data[idx])) - 128.0;
                    }
                }
                try processDU(&bw, &cdu, &fdtbl_y, &prev_dc_y, &dc_lum_codes, &ac_lum_codes);
            } else {
                var y_cdu: [64]f32 = undefined;
                var cb_cdu: [64]f32 = undefined;
                var cr_cdu: [64]f32 = undefined;

                for (0..8) |row| {
                    for (0..8) |col| {
                        const px = @min(bx * 8 + col, width - 1);
                        const py = @min(by * 8 + row, height - 1);
                        const idx = py * width * @as(usize, img.channels) + px * @as(usize, img.channels);
                        const r: f32 = @floatFromInt(img.data[idx]);
                        const g: f32 = @floatFromInt(img.data[idx + 1]);
                        const b: f32 = @floatFromInt(img.data[idx + 2]);

                        const bi = row * 8 + col;
                        y_cdu[bi] = 0.29900 * r + 0.58700 * g + 0.11400 * b - 128.0;
                        cb_cdu[bi] = -0.16874 * r - 0.33126 * g + 0.50000 * b;
                        cr_cdu[bi] = 0.50000 * r - 0.41869 * g - 0.08131 * b;
                    }
                }

                try processDU(&bw, &y_cdu, &fdtbl_y, &prev_dc_y, &dc_lum_codes, &ac_lum_codes);
                try processDU(&bw, &cb_cdu, &fdtbl_uv, &prev_dc_cb, &dc_chrom_codes, &ac_chrom_codes);
                try processDU(&bw, &cr_cdu, &fdtbl_uv, &prev_dc_cr, &dc_chrom_codes, &ac_chrom_codes);
            }
        }
    }

    try bw.flush();
    try writeMarker(writer, 0xFFD9); // EOI
}

/// Save JPEG to file path
pub fn saveToFile(img: *const Image, path: []const u8, quality: u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);

    try encode(img.allocator, img, &file_writer.interface, quality);
    try file_writer.interface.flush();
}

/// Save JPEG to memory buffer
pub fn saveToMemory(allocator: Allocator, img: *const Image, quality: u8) ![]u8 {
    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    try encode(allocator, img, &out_writer.writer, quality);
    return out_writer.toOwnedSlice();
}
