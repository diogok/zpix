const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig");

const log = std.log.scoped(.zpix_jpeg);

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
    coeff: ?[]i16 = null, // Coefficient buffer for progressive JPEG (64 per block)
    coeff_w: usize = 0, // Width in 8x8 blocks
    coeff_h: usize = 0, // Height in 8x8 blocks
    raw_coeff: ?[]u8 = null, // Raw allocation (for cleanup)
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
    marker: u8, // non-zero if a marker was encountered during reading
    nomore: bool, // true once a marker is hit; stops feeding data

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .bit_buf = 0,
            .bits_left = 0,
            .marker = 0,
            .nomore = false,
        };
    }

    fn getNextByte(self: *BitReader) u8 {
        if (self.nomore) return 0;
        if (self.pos >= self.data.len) return 0;
        const byte = self.data[self.pos];
        self.pos += 1;
        if (byte == 0xFF) {
            if (self.pos < self.data.len) {
                const next = self.data[self.pos];
                if (next == 0x00) {
                    // Byte-stuffed zero — skip it
                    self.pos += 1;
                } else {
                    // Real marker found — save it and stop feeding data
                    self.marker = next;
                    self.nomore = true;
                    self.pos += 1;
                    return 0;
                }
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
        log.debug("Huffman decode failed: no valid code found in table", .{});
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

/// Load JPEG from file path
pub fn loadFromFile(allocator: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);

    _ = try file.readAll(data);
    return decodeMemory(allocator, data);
}

/// Load JPEG from memory buffer
pub fn loadFromMemory(allocator: Allocator, data: []const u8) !Image {
    return decodeMemory(allocator, data);
}

fn decodeMemory(allocator: Allocator, data: []const u8) !Image {
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        log.debug("Invalid JPEG signature: expected FF D8, got {X:0>2} {X:0>2}", .{ if (data.len > 0) data[0] else 0, if (data.len > 1) data[1] else 0 });
        return JpegError.InvalidSignature;
    }

    var quantization_tables: [4][64]u16 = [_][64]u16{[_]u16{0} ** 64} ** 4;
    var dc_huffman_tables: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4;
    var ac_huffman_tables: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4;
    var components: [4]Component = undefined;
    var num_components: u8 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var restart_interval: u16 = 0;
    var max_h: u8 = 1;
    var max_v: u8 = 1;
    var progressive: bool = false;
    var spectral_start: u8 = 0;
    var spectral_end: u8 = 63;
    var successive_approx_high: u8 = 0;
    var successive_approx_low: u8 = 0;

    var pos: usize = 2;

    // Cleanup coefficient buffers on error
    errdefer {
        if (progressive) {
            for (0..num_components) |component_index| {
                if (components[component_index].raw_coeff) |raw_allocation| {
                    allocator.free(raw_allocation);
                }
            }
        }
    }

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
            Marker.EOI => {
                // For progressive JPEG, finalize after all scans
                if (progressive) {
                    return try finalizeProgressive(
                        allocator,
                        width,
                        height,
                        num_components,
                        &components,
                        &quantization_tables,
                        max_h,
                        max_v,
                    );
                }
                break;
            },

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
                    if (table_id > 3) {
                        log.debug("Invalid quantization table ID: {}, max is 3", .{table_id});
                        return JpegError.InvalidQuantizationTable;
                    }

                    if (precision == 0) {
                        // 8-bit quantization values, stored in zigzag order
                        // Convert to spatial order using dezigzag table
                        if (pos + 64 > data.len) return JpegError.UnexpectedEndOfData;
                        for (0..64) |i| {
                            quantization_tables[table_id][zigzag_order[i]] = data[pos];
                            pos += 1;
                        }
                        remaining -= 64;
                    } else {
                        // 16-bit quantization values, stored in zigzag order
                        if (pos + 128 > data.len) return JpegError.UnexpectedEndOfData;
                        for (0..64) |i| {
                            quantization_tables[table_id][zigzag_order[i]] = @intCast(readU16(data, pos));
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
                        dc_huffman_tables[table_id] = table;
                    } else {
                        ac_huffman_tables[table_id] = table;
                    }
                }
            },

            Marker.SOF0, Marker.SOF1, Marker.SOF2 => {
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

                // Set progressive flag for SOF2
                if (marker == Marker.SOF2) {
                    progressive = true;
                    log.debug("Progressive JPEG detected: SOF2 marker", .{});
                }

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
                _ = readU16(data, pos); // length
                pos += 2;

                if (pos >= data.len) return JpegError.UnexpectedEndOfData;
                const num_scan_components = data[pos];
                pos += 1;

                // Track which components are in this scan (for non-interleaved scans)
                var scan_component_indices: [4]u8 = undefined;
                var scan_components_count: u8 = 0;

                for (0..num_scan_components) |_| {
                    if (pos + 2 > data.len) return JpegError.UnexpectedEndOfData;
                    const component_id = data[pos];
                    pos += 1;
                    const huffman_table_selectors = data[pos];
                    pos += 1;

                    // Find matching component
                    for (0..num_components) |component_index| {
                        if (components[component_index].id == component_id) {
                            components[component_index].dc_table = huffman_table_selectors >> 4;
                            components[component_index].ac_table = huffman_table_selectors & 0x0F;
                            scan_component_indices[scan_components_count] = @intCast(component_index);
                            scan_components_count += 1;
                            break;
                        }
                    }
                }

                // Parse spectral selection and successive approximation
                if (pos + 3 > data.len) return JpegError.UnexpectedEndOfData;
                spectral_start = data[pos];
                pos += 1;
                spectral_end = data[pos];
                pos += 1;
                const successive_approx = data[pos];
                pos += 1;
                successive_approx_high = successive_approx >> 4;
                successive_approx_low = successive_approx & 0x0F;

                if (progressive) {
                    log.debug("Scan: Ss={} Se={} Ah={} Al={}", .{ spectral_start, spectral_end, successive_approx_high, successive_approx_low });

                    // Allocate coefficient buffers on first scan
                    if (components[0].coeff == null) {
                        const mcu_width: u32 = @as(u32, max_h) * 8;
                        const mcu_height: u32 = @as(u32, max_v) * 8;
                        const mcus_horizontal = (width + mcu_width - 1) / mcu_width;
                        const mcus_vertical = (height + mcu_height - 1) / mcu_height;

                        var num_allocated: u8 = 0;
                        errdefer for (0..num_allocated) |component_index| {
                            if (components[component_index].raw_coeff) |raw_allocation| {
                                allocator.free(raw_allocation);
                                components[component_index].raw_coeff = null;
                                components[component_index].coeff = null;
                            }
                        };

                        for (0..num_components) |component_index| {
                            const horizontal_scale: u32 = if (num_components == 1) 1 else @as(u32, components[component_index].h_sample);
                            const vertical_scale: u32 = if (num_components == 1) 1 else @as(u32, components[component_index].v_sample);
                            components[component_index].coeff_w = @as(usize, mcus_horizontal) * horizontal_scale;
                            components[component_index].coeff_h = @as(usize, mcus_vertical) * vertical_scale;
                            const num_blocks = components[component_index].coeff_w * components[component_index].coeff_h;
                            const coefficient_buffer_bytes = num_blocks * 64 * @sizeOf(i16);
                            // Allocation for coefficient buffer
                            const raw_allocation = try allocator.alloc(u8, coefficient_buffer_bytes);
                            components[component_index].raw_coeff = raw_allocation;
                            num_allocated += 1;
                            components[component_index].coeff = @as([*]i16, @ptrCast(@alignCast(raw_allocation.ptr)))[0 .. num_blocks * 64];
                            // Zero the coefficient buffer
                            @memset(components[component_index].coeff.?, 0);
                        }
                        log.debug("Allocated coefficient buffers for progressive JPEG", .{});
                    }

                    // Decode progressive scan into coefficient buffers
                    try decodeScanProgressive(
                        data,
                        pos,
                        width,
                        height,
                        num_components,
                        &components,
                        &dc_huffman_tables,
                        &ac_huffman_tables,
                        max_h,
                        max_v,
                        restart_interval,
                        spectral_start,
                        spectral_end,
                        successive_approx_high,
                        successive_approx_low,
                        scan_component_indices[0..scan_components_count],
                    );

                    // Continue parsing markers (don't return yet)
                } else {
                    // Baseline JPEG: decode and return immediately
                    return decodeScanData(
                        allocator,
                        data,
                        pos,
                        width,
                        height,
                        num_components,
                        &components,
                        &quantization_tables,
                        &dc_huffman_tables,
                        &ac_huffman_tables,
                        max_h,
                        max_v,
                        restart_interval,
                    );
                }
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
    quantization_tables: *const [4][64]u16,
    dc_huffman_tables: *const [4]HuffmanTable,
    ac_huffman_tables: *const [4]HuffmanTable,
    max_h: u8,
    max_v: u8,
    restart_interval: u16,
) !Image {
    if (width == 0 or height == 0) return JpegError.InvalidFrameHeader;

    const mcu_width: u32 = @as(u32, max_h) * 8;
    const mcu_height: u32 = @as(u32, max_v) * 8;
    const mcus_x = (width + mcu_width - 1) / mcu_width;
    const mcus_y = (height + mcu_height - 1) / mcu_height;

    // Allocate separate component buffers at native resolution
    var comp_bufs: [4][]u8 = undefined;
    var comp_stride: [4]usize = undefined;
    var comp_rows: [4]usize = undefined;
    var num_allocated: u8 = 0;
    errdefer for (0..num_allocated) |ci| allocator.free(comp_bufs[ci]);

    for (0..num_components) |ci| {
        const h_scale: u32 = if (num_components == 1) 1 else @as(u32, components[ci].h_sample);
        const v_scale: u32 = if (num_components == 1) 1 else @as(u32, components[ci].v_sample);
        comp_stride[ci] = @as(usize, mcus_x) * h_scale * 8;
        comp_rows[ci] = @as(usize, mcus_y) * v_scale * 8;
        comp_bufs[ci] = try allocator.alloc(u8, comp_stride[ci] * comp_rows[ci]);
        num_allocated += 1;
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

                        const dc_ht = &dc_huffman_tables[comp.dc_table];
                        const dc_cat = try bits.decodeHuffman(dc_ht);
                        if (dc_cat > 0) {
                            comp.dc_pred += bits.receiveExtend(@intCast(dc_cat));
                        }
                        block[0] = comp.dc_pred;

                        const ac_ht = &ac_huffman_tables[comp.ac_table];
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

                        const qtable = &quantization_tables[comp.qt_id];
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

    for (0..num_allocated) |ci| allocator.free(comp_bufs[ci]);

    return img;
}

fn skipRestartMarker(bits: *BitReader) void {
    if (bits.marker != 0) {
        // Marker was already found by getNextByte during bit reading
        if (bits.marker >= 0xD0 and bits.marker <= 0xD7) {
            bits.marker = 0;
            bits.nomore = false;
            return;
        }
    }
    // Fallback: scan for restart marker in raw data (shouldn't normally be needed)
    while (bits.pos < bits.data.len) {
        if (bits.data[bits.pos] == 0xFF) {
            if (bits.pos + 1 < bits.data.len) {
                const next = bits.data[bits.pos + 1];
                if (next >= 0xD0 and next <= 0xD7) {
                    bits.pos += 2;
                    bits.marker = 0;
                    bits.nomore = false;
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

/// Decode DC coefficient for progressive JPEG (first scan and refinement)
fn decodeBlockProgDc(
    bits: *BitReader,
    coefficients: []i16,
    dc_huffman_table: *const HuffmanTable,
    dc_predictor: *i32,
    successive_approx_high: u8,
    successive_approx_low: u8,
) !void {
    if (successive_approx_high == 0) {
        // DC first scan: decode differential DC coefficient
        const dc_category = try bits.decodeHuffman(dc_huffman_table);
        if (dc_category > 0) {
            dc_predictor.* += bits.receiveExtend(@intCast(dc_category));
        }
        // Store DC coefficient shifted by successive_approx_low bits
        coefficients[0] = @intCast(dc_predictor.* << @intCast(successive_approx_low));
    } else {
        // DC refinement scan: read one bit and add precision
        const bit = bits.getBits(1);
        coefficients[0] += @as(i16, @intCast(bit)) << @intCast(successive_approx_low);
    }
}

/// Decode AC coefficients for progressive JPEG (first scan and refinement)
fn decodeBlockProgAc(
    bits: *BitReader,
    coefficients: []i16,
    ac_huffman_table: *const HuffmanTable,
    spectral_start: u8,
    spectral_end: u8,
    successive_approx_high: u8,
    successive_approx_low: u8,
    end_of_block_run: *u16,
) !void {
    const bit_position_shift: u4 = @intCast(successive_approx_low);

    if (successive_approx_high == 0) {
        // AC first scan: decode new coefficients
        if (end_of_block_run.* > 0) {
            end_of_block_run.* -= 1;
            return;
        }

        var coefficient_index: usize = spectral_start;
        while (coefficient_index <= spectral_end) {
            const huffman_symbol = try bits.decodeHuffman(ac_huffman_table);
            const zero_run_length = huffman_symbol >> 4;
            const coefficient_category: u5 = @intCast(huffman_symbol & 0x0F);

            if (coefficient_category == 0) {
                if (zero_run_length == 15) {
                    // ZRL: skip 16 zeros
                    coefficient_index += 16;
                } else {
                    // EOB: rest of block is zeros, handle run extension
                    end_of_block_run.* = @as(u16, 1) << @intCast(zero_run_length);
                    if (zero_run_length > 0) {
                        end_of_block_run.* += @intCast(bits.getBits(@intCast(zero_run_length)));
                    }
                    end_of_block_run.* -= 1;
                    break;
                }
            } else {
                // Skip zero_run_length zeros, then store coefficient
                coefficient_index += zero_run_length;
                if (coefficient_index > spectral_end) break;
                const coefficient_value = bits.receiveExtend(coefficient_category);
                coefficients[zigzag_order[coefficient_index]] = @intCast(coefficient_value << bit_position_shift);
                coefficient_index += 1;
            }
        }
    } else {
        // AC refinement scan: refine existing coefficients and place new ones
        var coefficient_index: usize = spectral_start;

        // If we have an EOB run from previous block, refine existing non-zeros and decrement
        if (end_of_block_run.* > 0) {
            const bit_mask: i16 = @as(i16, 1) << bit_position_shift;
            while (coefficient_index <= spectral_end) : (coefficient_index += 1) {
                const pos = zigzag_order[coefficient_index];
                if (coefficients[pos] != 0) {
                    // Refine existing non-zero coefficient
                    const refine_bit = bits.getBits(1);
                    if (refine_bit != 0) {
                        // Only modify if bit at this position isn't already set
                        if ((coefficients[pos] & bit_mask) == 0) {
                            if (coefficients[pos] > 0) {
                                coefficients[pos] += bit_mask;
                            } else {
                                coefficients[pos] -= bit_mask;
                            }
                        }
                    }
                }
            }
            end_of_block_run.* -= 1;
            return;
        }

        // No EOB run: decode symbols
        while (coefficient_index <= spectral_end) {
            const huffman_symbol = try bits.decodeHuffman(ac_huffman_table);
            var zero_run_length: i32 = @intCast(huffman_symbol >> 4);
            const coefficient_category: u5 = @intCast(huffman_symbol & 0x0F);

            var new_coeff_value: i16 = 0;
            if (coefficient_category != 0) {
                // In AC refinement, coefficient category must be 1
                if (coefficient_category != 1) return JpegError.InvalidScanHeader;
                // There's a new coefficient to place after the run
                const sign_bit = bits.getBits(1);
                new_coeff_value = if (sign_bit != 0) @as(i16, 1) << bit_position_shift else -(@as(i16, 1) << bit_position_shift);
            }

            // Special case: r=15, s=0 means skip 16 coefficients (ZRL)
            if (coefficient_category == 0 and zero_run_length == 15) {
                // Skip 16 coefficients (refining any non-zeros along the way)
                const bit_mask: i16 = @as(i16, 1) << bit_position_shift;
                var skip_count: i32 = 0;
                while (skip_count < 16 and coefficient_index <= spectral_end) {
                    const pos = zigzag_order[coefficient_index];
                    if (coefficients[pos] != 0) {
                        // Refine this coefficient
                        const refine_bit = bits.getBits(1);
                        if (refine_bit != 0) {
                            if ((coefficients[pos] & bit_mask) == 0) {
                                if (coefficients[pos] > 0) {
                                    coefficients[pos] += bit_mask;
                                } else {
                                    coefficients[pos] -= bit_mask;
                                }
                            }
                        }
                    } else {
                        skip_count += 1;
                    }
                    coefficient_index += 1;
                }
                continue;
            }

            // EOB with possible run
            if (coefficient_category == 0 and zero_run_length < 15) {
                // In refinement scans, EOB run calculation is: (1 << r) - 1 + extra_bits
                end_of_block_run.* = (@as(u16, 1) << @intCast(zero_run_length)) - 1;
                if (zero_run_length > 0) {
                    end_of_block_run.* += @intCast(bits.getBits(@intCast(zero_run_length)));
                }
                // Refine remaining coefficients in this block before EOB
                const bit_mask: i16 = @as(i16, 1) << bit_position_shift;
                while (coefficient_index <= spectral_end) : (coefficient_index += 1) {
                    const pos = zigzag_order[coefficient_index];
                    if (coefficients[pos] != 0) {
                        const refine_bit = bits.getBits(1);
                        if (refine_bit != 0) {
                            if ((coefficients[pos] & bit_mask) == 0) {
                                if (coefficients[pos] > 0) {
                                    coefficients[pos] += bit_mask;
                                } else {
                                    coefficients[pos] -= bit_mask;
                                }
                            }
                        }
                    }
                }
                break;
            }

            // Regular case: advance by zero_run_length zeros, place new coefficient
            // While advancing, refine any non-zeros encountered
            const bit_mask: i16 = @as(i16, 1) << bit_position_shift;
            while (coefficient_index <= spectral_end) {
                const pos = zigzag_order[coefficient_index];
                coefficient_index += 1;

                if (coefficients[pos] != 0) {
                    // Refine existing non-zero coefficient
                    const refine_bit = bits.getBits(1);
                    if (refine_bit != 0) {
                        if ((coefficients[pos] & bit_mask) == 0) {
                            if (coefficients[pos] > 0) {
                                coefficients[pos] += bit_mask;
                            } else {
                                coefficients[pos] -= bit_mask;
                            }
                        }
                    }
                } else {
                    // Found a zero - check if we should place new coefficient here
                    if (zero_run_length == 0) {
                        coefficients[pos] = new_coeff_value;
                        break;
                    }
                    zero_run_length -= 1;
                }
            }
        }
    }
}

/// Decode a progressive JPEG scan into coefficient buffers
fn decodeScanProgressive(
    data: []const u8,
    scan_start: usize,
    width: u32,
    height: u32,
    num_components: u8,
    components: *[4]Component,
    dc_huffman_tables: *const [4]HuffmanTable,
    ac_huffman_tables: *const [4]HuffmanTable,
    max_horizontal_sampling: u8,
    max_vertical_sampling: u8,
    restart_interval: u16,
    spectral_start: u8,
    spectral_end: u8,
    successive_approx_high: u8,
    successive_approx_low: u8,
    scan_component_indices: []const u8,
) !void {
    if (width == 0 or height == 0) return JpegError.InvalidFrameHeader;

    const mcu_width: u32 = @as(u32, max_horizontal_sampling) * 8;
    const mcu_height: u32 = @as(u32, max_vertical_sampling) * 8;
    const mcus_horizontal = (width + mcu_width - 1) / mcu_width;
    const mcus_vertical = (height + mcu_height - 1) / mcu_height;

    var bits = BitReader.init(data[scan_start..]);
    var mcu_count: u32 = 0;
    var end_of_block_run: u16 = 0;

    const is_dc_scan = (spectral_start == 0);
    const is_interleaved = scan_component_indices.len > 1;

    // For non-interleaved scans (typically AC scans with single component),
    // process blocks sequentially for that component only
    if (!is_interleaved) {
        const component_index = scan_component_indices[0];
        const component = &components[component_index];
        const total_blocks = component.coeff_w * component.coeff_h;

        for (0..total_blocks) |block_index| {
            if (restart_interval > 0 and block_index > 0 and block_index % restart_interval == 0) {
                component.dc_pred = 0;
                end_of_block_run = 0;
                bits.bits_left = 0;
                bits.bit_buf = 0;
                skipRestartMarker(&bits);
            }

            const coefficient_offset = block_index * 64;
            if (component.coeff == null) return JpegError.InvalidData;
            const coefficients = component.coeff.?[coefficient_offset..][0..64];

            if (is_dc_scan) {
                const dc_huffman_table = &dc_huffman_tables[component.dc_table];
                try decodeBlockProgDc(&bits, coefficients, dc_huffman_table, &component.dc_pred, successive_approx_high, successive_approx_low);
            } else {
                const ac_huffman_table = &ac_huffman_tables[component.ac_table];
                try decodeBlockProgAc(&bits, coefficients, ac_huffman_table, spectral_start, spectral_end, successive_approx_high, successive_approx_low, &end_of_block_run);
            }
        }
    } else {
        // Interleaved scan: process MCUs with multiple components
        for (0..mcus_vertical) |mcu_row| {
            for (0..mcus_horizontal) |mcu_col| {
                if (restart_interval > 0 and mcu_count > 0 and mcu_count % restart_interval == 0) {
                    for (scan_component_indices) |component_index| {
                        components[component_index].dc_pred = 0;
                    }
                    end_of_block_run = 0;
                    bits.bits_left = 0;
                    bits.bit_buf = 0;
                    skipRestartMarker(&bits);
                }

                for (scan_component_indices) |component_index| {
                    const component = &components[component_index];
                    const horizontal_blocks: usize = if (num_components == 1) 1 else @as(usize, component.h_sample);
                    const vertical_blocks: usize = if (num_components == 1) 1 else @as(usize, component.v_sample);

                    for (0..vertical_blocks) |vertical_block_index| {
                        for (0..horizontal_blocks) |horizontal_block_index| {
                            const block_x = @as(usize, @intCast(mcu_col)) * horizontal_blocks + horizontal_block_index;
                            const block_y = @as(usize, @intCast(mcu_row)) * vertical_blocks + vertical_block_index;
                            const block_index = block_y * component.coeff_w + block_x;
                            const coefficient_offset = block_index * 64;

                            if (component.coeff == null) return JpegError.InvalidData;
                            const coefficients = component.coeff.?[coefficient_offset..][0..64];

                            if (is_dc_scan) {
                                const dc_huffman_table = &dc_huffman_tables[component.dc_table];
                                try decodeBlockProgDc(&bits, coefficients, dc_huffman_table, &component.dc_pred, successive_approx_high, successive_approx_low);
                            } else {
                                const ac_huffman_table = &ac_huffman_tables[component.ac_table];
                                try decodeBlockProgAc(&bits, coefficients, ac_huffman_table, spectral_start, spectral_end, successive_approx_high, successive_approx_low, &end_of_block_run);
                            }
                        }
                    }
                }

                mcu_count += 1;
            }
        }
    }
}

/// Finalize progressive JPEG: dequantize and IDCT all blocks, assemble image
fn finalizeProgressive(
    allocator: Allocator,
    width: u32,
    height: u32,
    num_components: u8,
    components: *[4]Component,
    quantization_tables: *const [4][64]u16,
    max_horizontal_sampling: u8,
    max_vertical_sampling: u8,
) !Image {
    const mcu_width: u32 = @as(u32, max_horizontal_sampling) * 8;
    const mcu_height: u32 = @as(u32, max_vertical_sampling) * 8;
    const mcus_horizontal = (width + mcu_width - 1) / mcu_width;
    const mcus_vertical = (height + mcu_height - 1) / mcu_height;

    // Allocate component buffers at native resolution
    var component_buffers: [4][]u8 = undefined;
    var component_stride: [4]usize = undefined;
    var component_rows: [4]usize = undefined;
    var num_allocated: u8 = 0;
    errdefer for (0..num_allocated) |component_index| allocator.free(component_buffers[component_index]);

    for (0..num_components) |component_index| {
        const horizontal_scale: u32 = if (num_components == 1) 1 else @as(u32, components[component_index].h_sample);
        const vertical_scale: u32 = if (num_components == 1) 1 else @as(u32, components[component_index].v_sample);
        component_stride[component_index] = @as(usize, mcus_horizontal) * horizontal_scale * 8;
        component_rows[component_index] = @as(usize, mcus_vertical) * vertical_scale * 8;
        component_buffers[component_index] = try allocator.alloc(u8, component_stride[component_index] * component_rows[component_index]);
        num_allocated += 1;
    }

    // Dequantize and IDCT all blocks
    for (0..num_components) |component_index| {
        const component = &components[component_index];
        const quantization_table = &quantization_tables[component.qt_id];

        if (component.coeff == null) return JpegError.InvalidData;

        for (0..component.coeff_h) |block_y| {
            for (0..component.coeff_w) |block_x| {
                const block_index = block_y * component.coeff_w + block_x;
                const coefficient_offset = block_index * 64;
                const coefficients = component.coeff.?[coefficient_offset..][0..64];

                // Dequantize: multiply by quantization table
                var dequantized_block: [64]i32 = undefined;
                for (0..64) |i| {
                    dequantized_block[i] = @as(i32, coefficients[i]) * @as(i32, @intCast(quantization_table[i]));
                }

                // IDCT
                var output: [64]u8 = undefined;
                idct(&dequantized_block, &output);

                // Write to component buffer
                const stride = component_stride[component_index];
                for (0..8) |row| {
                    const destination_offset = (block_y * 8 + row) * stride + block_x * 8;
                    for (0..8) |col| {
                        component_buffers[component_index][destination_offset + col] = output[row * 8 + col];
                    }
                }
            }
        }
    }

    // Assemble output image with chroma resampling + YCbCr→RGB
    var img = try Image.init(allocator, width, height, num_components);
    errdefer img.deinit();

    if (num_components == 1) {
        for (0..@as(usize, height)) |y| {
            const source = component_buffers[0][y * component_stride[0] ..][0..width];
            const destination = img.data[y * @as(usize, width) ..][0..width];
            @memcpy(destination, source);
        }
    } else {
        try resampleAndConvert(allocator, &img, &component_buffers, &component_stride, &component_rows, max_horizontal_sampling, max_vertical_sampling, components, num_components);
    }

    // Free component buffers and coefficient buffers
    for (0..num_allocated) |component_index| allocator.free(component_buffers[component_index]);
    for (0..num_components) |component_index| {
        if (components[component_index].raw_coeff) |raw| {
            allocator.free(raw);
            components[component_index].raw_coeff = null;
            components[component_index].coeff = null;
        }
    }

    return img;
}

fn readU16(data: []const u8, pos: usize) u32 {
    return (@as(u32, data[pos]) << 8) | @as(u32, data[pos + 1]);
}

/// Convert YCbCr image data to RGB in-place
/// stbi__float2fixed equivalent: (int)(x * 4096.0 + 0.5) << 8
fn f2fixed(comptime x: f64) i32 {
    return @as(i32, @intFromFloat(x * 4096.0 + 0.5)) << 8;
}
