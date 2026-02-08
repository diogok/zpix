const std = @import("std");
const Allocator = std.mem.Allocator;
const image_mod = @import("image.zig");
const Image = image_mod.Image;

pub const JpegError = error{
    InvalidSignature,
    InvalidMarker,
    UnsupportedFormat,
    InvalidQuantizationTable,
    InvalidHuffmanTable,
    InvalidFrameHeader,
    InvalidScanHeader,
    InvalidData,
    HuffmanDecodeFailed,
    InvalidCoefficientIndex,
    UnsupportedSubsampling,
    UnexpectedEndOfData,
    OutOfMemory,
};

// JPEG marker codes
const Marker = struct {
    const SOI: u16 = 0xFFD8;
    const EOI: u16 = 0xFFD9;
    const SOF0: u16 = 0xFFC0; // Baseline DCT
    const SOF1: u16 = 0xFFC1; // Extended sequential DCT
    const SOF2: u16 = 0xFFC2; // Progressive DCT
    const DHT: u16 = 0xFFC4;
    const DQT: u16 = 0xFFDB;
    const DRI: u16 = 0xFFDD;
    const SOS: u16 = 0xFFDA;
    const APP0: u16 = 0xFFE0;
    const APP1: u16 = 0xFFE1;
    const COM: u16 = 0xFFFE;

    fn isAPP(m: u16) bool {
        return m >= 0xFFE0 and m <= 0xFFEF;
    }
};

// Zigzag order for 8x8 block
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

const Component = struct {
    id: u8,
    h_sample: u8, // horizontal sampling factor
    v_sample: u8, // vertical sampling factor
    qt_id: u8, // quantization table index
    dc_table: u8, // DC Huffman table index
    ac_table: u8, // AC Huffman table index
    dc_pred: i32, // DC predictor (reset at restart markers)
};

const HuffmanTable = struct {
    // Fast lookup: FAST_BITS index -> packed (code_length << 8 | symbol), 0xFFFF = slow
    fast: [FAST_SIZE]u16 = [_]u16{0xFFFF} ** FAST_SIZE,
    // For slow path: symbol and code length for all codes, sorted by code
    symbols: [256]u8 = [_]u8{0} ** 256,
    code_of: [256]u32 = [_]u32{0} ** 256, // The Huffman code for symbol index k
    size_of: [256]u8 = [_]u8{0} ** 256, // The code length for symbol index k
    num_symbols: usize = 0,
    // For fast slow path: first code and first symbol index at each bit length
    min_code: [17]u32 = [_]u32{0} ** 17,
    max_code_plus1: [17]u32 = [_]u32{0} ** 17, // maxcode + 1 to avoid signed
    val_offset: [17]usize = [_]usize{0} ** 17,
    valid: bool = false,

    const FAST_BITS = 9;
    const FAST_SIZE = 1 << FAST_BITS;

    fn build(counts: [16]u8, syms: []const u8) HuffmanTable {
        var ht = HuffmanTable{};
        ht.valid = true;

        var total: usize = 0;
        for (0..16) |i| total += counts[i];
        ht.num_symbols = total;
        @memcpy(ht.symbols[0..total], syms[0..total]);

        // Generate canonical Huffman codes
        var code: u32 = 0;
        var si: usize = 0;
        for (0..16) |i| {
            const len = i + 1;
            ht.min_code[len] = code;
            ht.val_offset[len] = si;
            for (0..counts[i]) |_| {
                ht.code_of[si] = code;
                ht.size_of[si] = @intCast(len);
                si += 1;
                code += 1;
            }
            ht.max_code_plus1[len] = code; // One past max code at this length
            code <<= 1;
        }

        // Build fast lookup table (MSB-first codes, padded to FAST_BITS)
        @memset(&ht.fast, 0xFFFF);
        for (0..total) |k| {
            const s = ht.size_of[k];
            if (s <= FAST_BITS) {
                const c = ht.code_of[k];
                // Shift code left to fill FAST_BITS, then fill all suffixes
                const base = c << @intCast(FAST_BITS - s);
                const count = @as(u32, 1) << @intCast(FAST_BITS - s);
                var entry = base;
                while (entry < base + count) : (entry += 1) {
                    ht.fast[entry] = (@as(u16, s) << 8) | @as(u16, ht.symbols[k]);
                }
            }
        }

        return ht;
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buf: u32,
    bits_left: u6, // 0..32

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .bit_buf = 0,
            .bits_left = 0,
        };
    }

    fn getNextByte(self: *BitReader) u8 {
        if (self.pos >= self.data.len) return 0;
        const byte = self.data[self.pos];
        self.pos += 1;
        if (byte == 0xFF) {
            // Skip stuffed zero byte
            if (self.pos < self.data.len and self.data[self.pos] == 0x00) {
                self.pos += 1;
            }
        }
        return byte;
    }

    fn ensureBits(self: *BitReader, n: u6) void {
        while (self.bits_left < n) {
            const byte = self.getNextByte();
            self.bit_buf |= @as(u32, byte) << @intCast(24 - self.bits_left);
            self.bits_left += 8;
        }
    }

    fn peekBits(self: *BitReader, n: u5) u32 {
        self.ensureBits(n);
        return self.bit_buf >> @intCast(32 - @as(u6, n));
    }

    fn consumeBits(self: *BitReader, n: u5) void {
        self.bit_buf <<= @intCast(n);
        self.bits_left -= n;
    }

    fn getBits(self: *BitReader, n: u5) u32 {
        const val = self.peekBits(n);
        self.consumeBits(n);
        return val;
    }

    fn decodeHuffman(self: *BitReader, ht: *const HuffmanTable) !u8 {
        self.ensureBits(16);

        // Fast path: look up first FAST_BITS
        const look = self.bit_buf >> @intCast(32 - HuffmanTable.FAST_BITS);
        const fast_val = ht.fast[@intCast(look)];
        if (fast_val != 0xFFFF) {
            const size: u5 = @intCast(fast_val >> 8);
            self.consumeBits(size);
            return @intCast(fast_val & 0xFF);
        }

        // Slow path: try each code length from FAST_BITS+1 to 16
        var len: usize = HuffmanTable.FAST_BITS + 1;
        while (len <= 16) : (len += 1) {
            const code: u32 = self.bit_buf >> @intCast(32 - @as(u6, @intCast(len)));
            if (code >= ht.min_code[len] and code < ht.max_code_plus1[len]) {
                const idx = ht.val_offset[len] + (code - ht.min_code[len]);
                self.consumeBits(@intCast(len));
                return ht.symbols[idx];
            }
        }
        return JpegError.HuffmanDecodeFailed;
    }

    fn receiveExtend(self: *BitReader, n: u5) i32 {
        if (n == 0) return 0;
        const val = self.getBits(n);
        // Extend sign
        const half = @as(u32, 1) << @intCast(n - 1);
        if (val < half) {
            return @as(i32, @intCast(val)) - @as(i32, @intCast((@as(u32, 1) << @intCast(n)) - 1));
        }
        return @as(i32, @intCast(val));
    }
};

/// Core decoder: reads JPEG from any std.Io.Reader
pub fn decode(allocator: Allocator, reader: *std.Io.Reader) !Image {
    // Read entire input into memory for bitstream processing
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        try buffer.appendSlice(allocator, read_buf[0..n]);
    }

    return decodeMemory(allocator, buffer.items);
}

/// Load JPEG from file path (convenience wrapper)
pub fn loadFromFile(allocator: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buf = try allocator.alloc(u8, 65536);
    defer allocator.free(buf);
    var file_reader = file.reader(buf);

    return decode(allocator, &file_reader.interface);
}

/// Load JPEG from memory buffer (convenience wrapper)
pub fn loadFromMemory(allocator: Allocator, data: []const u8) !Image {
    return decodeMemory(allocator, data);
}

fn decodeMemory(allocator: Allocator, data: []const u8) !Image {
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        return JpegError.InvalidSignature;
    }

    var qt: [4][64]u16 = [_][64]u16{[_]u16{0} ** 64} ** 4;
    var dc_tables: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4;
    var ac_tables: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4;
    var components: [4]Component = undefined;
    var num_components: u8 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var restart_interval: u16 = 0;
    var max_h: u8 = 1;
    var max_v: u8 = 1;

    var pos: usize = 2;

    // Parse markers
    while (pos < data.len - 1) {
        // Find next marker
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }

        while (pos < data.len - 1 and data[pos] == 0xFF) {
            pos += 1;
        }
        if (pos >= data.len) break;

        const marker_byte = data[pos];
        pos += 1;

        if (marker_byte == 0) continue; // Stuffed byte, skip

        const marker: u16 = 0xFF00 | @as(u16, marker_byte);

        switch (marker) {
            Marker.SOI => {},
            Marker.EOI => break,

            Marker.DQT => {
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                const length = readU16(data, pos);
                pos += 2;
                var remaining = @as(usize, length) - 2;
                while (remaining > 0) {
                    if (pos >= data.len) return JpegError.UnexpectedEndOfData;
                    const info = data[pos];
                    pos += 1;
                    remaining -= 1;
                    const precision = info >> 4;
                    const table_id = info & 0x0F;
                    if (table_id > 3) return JpegError.InvalidQuantizationTable;

                    if (precision == 0) {
                        // 8-bit quantization values, stored in zigzag order
                        // Convert to spatial order using dezigzag table
                        if (pos + 64 > data.len) return JpegError.UnexpectedEndOfData;
                        for (0..64) |i| {
                            qt[table_id][zigzag_order[i]] = data[pos];
                            pos += 1;
                        }
                        remaining -= 64;
                    } else {
                        // 16-bit quantization values, stored in zigzag order
                        if (pos + 128 > data.len) return JpegError.UnexpectedEndOfData;
                        for (0..64) |i| {
                            qt[table_id][zigzag_order[i]] = @intCast(readU16(data, pos));
                            pos += 2;
                        }
                        remaining -= 128;
                    }
                }
            },

            Marker.DHT => {
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                const length = readU16(data, pos);
                pos += 2;
                var remaining = @as(usize, length) - 2;

                while (remaining > 0) {
                    if (pos >= data.len) return JpegError.UnexpectedEndOfData;
                    const info = data[pos];
                    pos += 1;
                    remaining -= 1;

                    const table_class = info >> 4; // 0 = DC, 1 = AC
                    const table_id = info & 0x0F;
                    if (table_id > 3) return JpegError.InvalidHuffmanTable;

                    if (pos + 16 > data.len) return JpegError.UnexpectedEndOfData;
                    var counts: [16]u8 = undefined;
                    var total: usize = 0;
                    for (0..16) |i| {
                        counts[i] = data[pos + i];
                        total += counts[i];
                    }
                    pos += 16;
                    remaining -= 16;

                    if (pos + total > data.len) return JpegError.UnexpectedEndOfData;
                    const symbols = data[pos .. pos + total];
                    pos += total;
                    remaining -= total;

                    const table = HuffmanTable.build(counts, symbols);
                    if (table_class == 0) {
                        dc_tables[table_id] = table;
                    } else {
                        ac_tables[table_id] = table;
                    }
                }
            },

            Marker.SOF0, Marker.SOF1 => {
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                const length = readU16(data, pos);
                _ = length;
                pos += 2;

                if (pos + 6 > data.len) return JpegError.UnexpectedEndOfData;
                const precision = data[pos];
                if (precision != 8) return JpegError.UnsupportedFormat;
                pos += 1;
                height = readU16(data, pos);
                pos += 2;
                width = readU16(data, pos);
                pos += 2;
                num_components = data[pos];
                pos += 1;

                if (num_components != 1 and num_components != 3) return JpegError.UnsupportedFormat;

                for (0..num_components) |i| {
                    if (pos + 3 > data.len) return JpegError.UnexpectedEndOfData;
                    components[i] = .{
                        .id = data[pos],
                        .h_sample = data[pos + 1] >> 4,
                        .v_sample = data[pos + 1] & 0x0F,
                        .qt_id = data[pos + 2],
                        .dc_table = 0,
                        .ac_table = 0,
                        .dc_pred = 0,
                    };
                    if (components[i].h_sample > max_h) max_h = components[i].h_sample;
                    if (components[i].v_sample > max_v) max_v = components[i].v_sample;
                    pos += 3;
                }
            },

            Marker.SOF2 => return JpegError.UnsupportedFormat, // Progressive not supported

            Marker.DRI => {
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                const length = readU16(data, pos);
                _ = length;
                pos += 2;
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                restart_interval = @intCast(readU16(data, pos));
                pos += 2;
            },

            Marker.SOS => {
                if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                const length = readU16(data, pos);
                pos += 2;

                if (pos >= data.len) return JpegError.UnexpectedEndOfData;
                const ns = data[pos];
                pos += 1;

                for (0..ns) |_| {
                    if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                    const comp_id = data[pos];
                    pos += 1;
                    const tables = data[pos];
                    pos += 1;

                    // Find matching component
                    for (0..num_components) |ci| {
                        if (components[ci].id == comp_id) {
                            components[ci].dc_table = tables >> 4;
                            components[ci].ac_table = tables & 0x0F;
                            break;
                        }
                    }
                }

                // Skip spectral selection and successive approximation
                const skip_bytes = @as(usize, length) - 2 - 1 - @as(usize, ns) * 2;
                pos += skip_bytes;

                // Now decode the entropy-coded scan data
                return decodeScanData(
                    allocator,
                    data,
                    pos,
                    width,
                    height,
                    num_components,
                    &components,
                    &qt,
                    &dc_tables,
                    &ac_tables,
                    max_h,
                    max_v,
                    restart_interval,
                );
            },

            else => {
                // Skip unknown marker segment
                if (Marker.isAPP(marker) or marker == Marker.COM or (marker >= 0xFFC0 and marker <= 0xFFFF)) {
                    if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                    const length = readU16(data, pos);
                    pos += @as(usize, length);
                }
            },
        }
    }

    return JpegError.InvalidData;
}

fn decodeScanData(
    allocator: Allocator,
    data: []const u8,
    scan_start: usize,
    width: u32,
    height: u32,
    num_components: u8,
    components: *[4]Component,
    qt: *const [4][64]u16,
    dc_tables: *const [4]HuffmanTable,
    ac_tables: *const [4]HuffmanTable,
    max_h: u8,
    max_v: u8,
    restart_interval: u16,
) !Image {
    if (width == 0 or height == 0) return JpegError.InvalidFrameHeader;

    const mcu_w: u32 = @as(u32, max_h) * 8;
    const mcu_h: u32 = @as(u32, max_v) * 8;
    const mcus_x = (width + mcu_w - 1) / mcu_w;
    const mcus_y = (height + mcu_h - 1) / mcu_h;

    // Allocate separate component buffers at native resolution
    var comp_bufs: [4][]u8 = undefined;
    var comp_stride: [4]usize = undefined;
    var comp_rows: [4]usize = undefined;
    var num_alloc: u8 = 0;
    errdefer for (0..num_alloc) |ci| allocator.free(comp_bufs[ci]);

    for (0..num_components) |ci| {
        const hs: u32 = if (num_components == 1) 1 else @as(u32, components[ci].h_sample);
        const vs: u32 = if (num_components == 1) 1 else @as(u32, components[ci].v_sample);
        comp_stride[ci] = @as(usize, mcus_x) * hs * 8;
        comp_rows[ci] = @as(usize, mcus_y) * vs * 8;
        comp_bufs[ci] = try allocator.alloc(u8, comp_stride[ci] * comp_rows[ci]);
        num_alloc += 1;
    }

    var bits = BitReader.init(data[scan_start..]);
    var mcu_count: u32 = 0;

    for (0..mcus_y) |mcu_y| {
        for (0..mcus_x) |mcu_x| {
            if (restart_interval > 0 and mcu_count > 0 and mcu_count % restart_interval == 0) {
                for (0..num_components) |ci| {
                    components[ci].dc_pred = 0;
                }
                bits.bits_left = 0;
                bits.bit_buf = 0;
                skipRestartMarker(&bits);
            }

            for (0..num_components) |ci| {
                const comp = &components[ci];
                const h_blocks: usize = if (num_components == 1) 1 else @as(usize, comp.h_sample);
                const v_blocks: usize = if (num_components == 1) 1 else @as(usize, comp.v_sample);

                for (0..v_blocks) |bv| {
                    for (0..h_blocks) |bh| {
                        var block: [64]i32 = [_]i32{0} ** 64;

                        const dc_ht = &dc_tables[comp.dc_table];
                        const dc_cat = try bits.decodeHuffman(dc_ht);
                        if (dc_cat > 0) {
                            comp.dc_pred += bits.receiveExtend(@intCast(dc_cat));
                        }
                        block[0] = comp.dc_pred;

                        const ac_ht = &ac_tables[comp.ac_table];
                        var k: usize = 1;
                        while (k < 64) {
                            const rs = try bits.decodeHuffman(ac_ht);
                            if (rs == 0) break;
                            const run = rs >> 4;
                            const cat: u5 = @intCast(rs & 0x0F);
                            k += run;
                            if (k >= 64) break;
                            if (cat > 0) {
                                block[zigzag_order[k]] = bits.receiveExtend(cat);
                            }
                            k += 1;
                        }

                        const qtable = &qt[comp.qt_id];
                        for (0..64) |i| {
                            block[i] *= @as(i32, @intCast(qtable[i]));
                        }

                        var output: [64]u8 = undefined;
                        idct(&block, &output);

                        // Write to component buffer at native resolution
                        const bx = @as(usize, @intCast(mcu_x)) * h_blocks * 8 + bh * 8;
                        const by = @as(usize, @intCast(mcu_y)) * v_blocks * 8 + bv * 8;
                        const stride = comp_stride[ci];
                        for (0..8) |row| {
                            const dst_off = (by + row) * stride + bx;
                            for (0..8) |col| {
                                comp_bufs[ci][dst_off + col] = output[row * 8 + col];
                            }
                        }
                    }
                }
            }

            mcu_count += 1;
        }
    }

    // Assemble output image with chroma resampling + YCbCr→RGB
    var img = try Image.init(allocator, width, height, num_components);
    errdefer img.deinit();

    if (num_components == 1) {
        for (0..@as(usize, height)) |y| {
            const src = comp_bufs[0][y * comp_stride[0] ..][0..width];
            const dst = img.data[y * @as(usize, width) ..][0..width];
            @memcpy(dst, src);
        }
    } else {
        try resampleAndConvert(allocator, &img, &comp_bufs, &comp_stride, &comp_rows, max_h, max_v, components, num_components);
    }

    for (0..num_alloc) |ci| allocator.free(comp_bufs[ci]);

    return img;
}

fn skipRestartMarker(bits: *BitReader) void {
    // Look for 0xFF followed by 0xDn (restart marker)
    while (bits.pos < bits.data.len) {
        if (bits.data[bits.pos] == 0xFF) {
            if (bits.pos + 1 < bits.data.len) {
                const next = bits.data[bits.pos + 1];
                if (next >= 0xD0 and next <= 0xD7) {
                    bits.pos += 2;
                    return;
                }
            }
        }
        bits.pos += 1;
    }
}

/// Resample chroma components and convert YCbCr→RGB, matching stb_image's approach.
fn resampleAndConvert(
    allocator: Allocator,
    img: *Image,
    comp_bufs: *const [4][]u8,
    comp_stride: *const [4]usize,
    comp_rows: *const [4]usize,
    max_h: u8,
    max_v: u8,
    components: *const [4]Component,
    num_components: u8,
) !void {
    const out_w = @as(usize, img.width);
    const out_h = @as(usize, img.height);

    var h_scale: [4]u8 = undefined;
    var v_scale: [4]u8 = undefined;
    for (0..num_components) |ci| {
        h_scale[ci] = max_h / components[ci].h_sample;
        v_scale[ci] = max_v / components[ci].v_sample;
    }

    // Allocate temp row buffers for components that need resampling
    var row_bufs: [4][]u8 = undefined;
    var needs_buf: [4]bool = .{false} ** 4;
    errdefer for (0..num_components) |ci| {
        if (needs_buf[ci]) allocator.free(row_bufs[ci]);
    };

    for (0..num_components) |ci| {
        if (h_scale[ci] > 1 or v_scale[ci] > 1) {
            const resample_w = comp_stride[ci] * @as(usize, h_scale[ci]);
            row_bufs[ci] = try allocator.alloc(u8, resample_w);
            needs_buf[ci] = true;
        }
    }

    // Vertical resampling state (matching stb_image's ystep/line0/line1)
    var ystep: [4]usize = undefined;
    var ypos: [4]usize = undefined;
    var line0_off: [4]usize = undefined;
    var line1_off: [4]usize = undefined;
    for (0..num_components) |ci| {
        ystep[ci] = @as(usize, v_scale[ci]) >> 1;
        ypos[ci] = 0;
        line0_off[ci] = 0;
        line1_off[ci] = 0;
    }

    // YCbCr constants (positive only, negate via subtraction)
    const cr_r = comptime f2fixed(1.40200);
    const cr_g_pos = comptime f2fixed(0.71414);
    const cb_g_pos = comptime f2fixed(0.34414);
    const cb_b = comptime f2fixed(1.77200);

    for (0..out_h) |y| {
        var current_rows: [4][]const u8 = undefined;

        for (0..num_components) |ci| {
            const hs = h_scale[ci];
            const vs = @as(usize, v_scale[ci]);

            if (hs == 1 and vs == 1) {
                current_rows[ci] = comp_bufs[ci][y * comp_stride[ci] ..][0..out_w];
            } else {
                const y_bot: bool = ystep[ci] >= (vs >> 1);
                const near_off = if (y_bot) line1_off[ci] else line0_off[ci];
                const far_off = if (y_bot) line0_off[ci] else line1_off[ci];
                const cw = comp_stride[ci];
                const near = comp_bufs[ci][near_off..][0..cw];
                const far = comp_bufs[ci][far_off..][0..cw];

                if (hs == 2 and vs == 2) {
                    resampleRowHV2(row_bufs[ci], near, far, cw);
                } else if (hs == 2) {
                    resampleRowH2(row_bufs[ci], near, cw);
                } else {
                    resampleRowV2(row_bufs[ci], near, far, cw);
                }
                current_rows[ci] = row_bufs[ci][0..out_w];

                ystep[ci] += 1;
                if (ystep[ci] >= vs) {
                    ystep[ci] = 0;
                    line0_off[ci] = line1_off[ci];
                    ypos[ci] += 1;
                    if (ypos[ci] < comp_rows[ci]) {
                        line1_off[ci] += cw;
                    }
                }
            }
        }

        // Convert YCbCr→RGB for this row
        for (0..out_w) |x| {
            const idx = (y * out_w + x) * 3;
            const y_val = @as(i32, current_rows[0][x]);
            const cb = @as(i32, current_rows[1][x]) - 128;
            const cr = @as(i32, current_rows[2][x]) - 128;

            const y_fixed = (y_val << 20) + (1 << 19);

            const r = (y_fixed + cr * cr_r) >> 20;
            const cb_g_term = (-(cb * cb_g_pos)) & @as(i32, @bitCast(@as(u32, 0xffff0000)));
            const g = (y_fixed - cr * cr_g_pos + cb_g_term) >> 20;
            const b = (y_fixed + cb * cb_b) >> 20;

            img.data[idx] = clampByte(r);
            img.data[idx + 1] = clampByte(g);
            img.data[idx + 2] = clampByte(b);
        }
    }

    for (0..num_components) |ci| {
        if (needs_buf[ci]) allocator.free(row_bufs[ci]);
    }
}

/// Bilinear 2x2 chroma upsampling matching stb_image's stbi__resample_row_hv_2
fn resampleRowHV2(out: []u8, in_near: []const u8, in_far: []const u8, w: usize) void {
    if (w == 1) {
        const val: u8 = @intCast((@as(u32, in_near[0]) * 3 + @as(u32, in_far[0]) + 2) >> 2);
        out[0] = val;
        out[1] = val;
        return;
    }

    var t1: u32 = @as(u32, in_near[0]) * 3 + @as(u32, in_far[0]);
    out[0] = @intCast((t1 + 2) >> 2);

    for (1..w) |i| {
        const t0 = t1;
        t1 = @as(u32, in_near[i]) * 3 + @as(u32, in_far[i]);
        out[i * 2 - 1] = @intCast((3 * t0 + t1 + 8) >> 4);
        out[i * 2] = @intCast((3 * t1 + t0 + 8) >> 4);
    }
    out[w * 2 - 1] = @intCast((t1 + 2) >> 2);
}

/// Horizontal 2x chroma upsampling matching stb_image's stbi__resample_row_h_2
fn resampleRowH2(out: []u8, input: []const u8, w: usize) void {
    if (w == 1) {
        out[0] = input[0];
        out[1] = input[0];
        return;
    }

    out[0] = input[0];
    out[1] = @intCast((@as(u16, input[0]) * 3 + @as(u16, input[1]) + 2) >> 2);

    var i: usize = 1;
    while (i < w - 1) : (i += 1) {
        const n: u16 = @as(u16, input[i]) * 3 + 2;
        out[i * 2] = @intCast((n + @as(u16, input[i - 1])) >> 2);
        out[i * 2 + 1] = @intCast((n + @as(u16, input[i + 1])) >> 2);
    }
    out[i * 2] = @intCast((@as(u16, input[w - 2]) * 3 + @as(u16, input[w - 1]) + 2) >> 2);
    out[i * 2 + 1] = input[w - 1];
}

/// Vertical 2x chroma upsampling matching stb_image's stbi__resample_row_v_2
fn resampleRowV2(out: []u8, in_near: []const u8, in_far: []const u8, w: usize) void {
    for (0..w) |i| {
        out[i] = @intCast((@as(u16, in_near[i]) * 3 + @as(u16, in_far[i]) + 2) >> 2);
    }
}

/// Integer IDCT matching stb_image's approach
/// Uses fixed-point arithmetic with the same constants as stb_image
fn idct(coefficients: *const [64]i32, output: *[64]u8) void {
    var temp: [64]i32 = undefined;

    // stb_image IDCT constants: stbi__f2f(x) = (int)(x * 4096 + 0.5)
    // All stored as POSITIVE values. Negation is done via subtraction in formulas
    // to work around a Zig 0.15.2 codegen bug with runtime * negative constant.
    const k054: i32 = 2217; // f2f(0.5411961)
    const k184: i32 = 7567; // |f2f(-1.847759065)|
    const k076: i32 = 3135; // f2f(0.765366865)
    const k117: i32 = 4816; // f2f(1.175875602)
    const k029: i32 = 1223; // f2f(0.298631336)
    const k205: i32 = 8410; // f2f(2.053119869)
    const k307: i32 = 12586; // f2f(3.072711026)
    const k150: i32 = 6149; // f2f(1.501321110)
    const k089: i32 = 3685; // |f2f(-0.899976223)|
    const k256: i32 = 10497; // |f2f(-2.562915447)|
    const k196: i32 = 8034; // |f2f(-1.961570560)|
    const k039: i32 = 1597; // |f2f(-0.390180644)|

    // Column pass
    for (0..8) |col| {
        const s0 = coefficients[0 * 8 + col];
        const s1 = coefficients[1 * 8 + col];
        const s2 = coefficients[2 * 8 + col];
        const s3 = coefficients[3 * 8 + col];
        const s4 = coefficients[4 * 8 + col];
        const s5 = coefficients[5 * 8 + col];
        const s6 = coefficients[6 * 8 + col];
        const s7 = coefficients[7 * 8 + col];

        // All zeros shortcut
        if (s1 == 0 and s2 == 0 and s3 == 0 and s4 == 0 and s5 == 0 and s6 == 0 and s7 == 0) {
            const dc = s0 << 2;
            temp[0 * 8 + col] = dc;
            temp[1 * 8 + col] = dc;
            temp[2 * 8 + col] = dc;
            temp[3 * 8 + col] = dc;
            temp[4 * 8 + col] = dc;
            temp[5 * 8 + col] = dc;
            temp[6 * 8 + col] = dc;
            temp[7 * 8 + col] = dc;
            continue;
        }

        // Even part
        const cp1 = (s2 + s6) * k054;
        const ct2 = cp1 - s6 * k184;
        const ct3 = cp1 + s2 * k076;
        const ct0 = (s0 + s4) << 12;
        const ct1 = (s0 - s4) << 12;

        const cx0 = ct0 + ct3 + 512;
        const cx3 = ct0 - ct3 + 512;
        const cx1 = ct1 + ct2 + 512;
        const cx2 = ct1 - ct2 + 512;

        // Odd part
        const op3 = s7 + s3;
        const op4 = s5 + s1;
        const op1 = s7 + s1;
        const op2 = s5 + s3;
        const op5 = (op3 + op4) * k117;
        const ot0 = s7 * k029 + op5 - op1 * k089 - op3 * k196;
        const ot1 = s5 * k205 + op5 - op2 * k256 - op4 * k039;
        const ot2 = s3 * k307 + op5 - op2 * k256 - op3 * k196;
        const ot3 = s1 * k150 + op5 - op1 * k089 - op4 * k039;

        temp[0 * 8 + col] = (cx0 + ot3) >> 10;
        temp[7 * 8 + col] = (cx0 - ot3) >> 10;
        temp[1 * 8 + col] = (cx1 + ot2) >> 10;
        temp[6 * 8 + col] = (cx1 - ot2) >> 10;
        temp[2 * 8 + col] = (cx2 + ot1) >> 10;
        temp[5 * 8 + col] = (cx2 - ot1) >> 10;
        temp[3 * 8 + col] = (cx3 + ot0) >> 10;
        temp[4 * 8 + col] = (cx3 - ot0) >> 10;
    }

    // Row pass
    for (0..8) |row| {
        const s0 = temp[row * 8 + 0];
        const s1 = temp[row * 8 + 1];
        const s2 = temp[row * 8 + 2];
        const s3 = temp[row * 8 + 3];
        const s4 = temp[row * 8 + 4];
        const s5 = temp[row * 8 + 5];
        const s6 = temp[row * 8 + 6];
        const s7 = temp[row * 8 + 7];

        // Even part
        const rp1 = (s2 + s6) * k054;
        const ret2 = rp1 - s6 * k184;
        const ret3 = rp1 + s2 * k076;
        const rt0 = (s0 + s4) << 12;
        const rt1 = (s0 - s4) << 12;

        // Add rounding and level shift
        const rt0r = rt0 + 65536 + (128 << 17);
        const rt1r = rt1 + 65536 + (128 << 17);

        const rx0 = rt0r + ret3;
        const rx3 = rt0r - ret3;
        const rx1 = rt1r + ret2;
        const rx2 = rt1r - ret2;

        // Odd part
        const rp3 = s7 + s3;
        const rp4 = s5 + s1;
        const rp1b = s7 + s1;
        const rp2 = s5 + s3;
        const rp5 = (rp3 + rp4) * k117;
        const rot0 = s7 * k029 + rp5 - rp1b * k089 - rp3 * k196;
        const rot1 = s5 * k205 + rp5 - rp2 * k256 - rp4 * k039;
        const rot2 = s3 * k307 + rp5 - rp2 * k256 - rp3 * k196;
        const rot3 = s1 * k150 + rp5 - rp1b * k089 - rp4 * k039;

        output[row * 8 + 0] = clampByte((rx0 + rot3) >> 17);
        output[row * 8 + 7] = clampByte((rx0 - rot3) >> 17);
        output[row * 8 + 1] = clampByte((rx1 + rot2) >> 17);
        output[row * 8 + 6] = clampByte((rx1 - rot2) >> 17);
        output[row * 8 + 2] = clampByte((rx2 + rot1) >> 17);
        output[row * 8 + 5] = clampByte((rx2 - rot1) >> 17);
        output[row * 8 + 3] = clampByte((rx3 + rot0) >> 17);
        output[row * 8 + 4] = clampByte((rx3 - rot0) >> 17);
    }
}

fn clampByte(val: i32) u8 {
    if (val < 0) return 0;
    if (val > 255) return 255;
    return @intCast(val);
}

fn readU16(data: []const u8, pos: usize) u32 {
    return (@as(u32, data[pos]) << 8) | @as(u32, data[pos + 1]);
}

/// Convert YCbCr image data to RGB in-place
/// stbi__float2fixed equivalent: (int)(x * 4096.0 + 0.5) << 8
fn f2fixed(comptime x: f64) i32 {
    return @as(i32, @intFromFloat(x * 4096.0 + 0.5)) << 8;
}

test "JPEG module compiles" {
    // Placeholder test to verify module compiles
    const ht = HuffmanTable{};
    _ = ht;
    try std.testing.expect(true);
}
