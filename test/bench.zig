const std = @import("std");
const zpix = @import("zpix");

// C reference implementation bindings (translated by build.zig)
const c = @import("c");

// Wrappers defined in ref_impl.c (stbi_write_png_to_mem and stbir are static,
// so we call through our own extern wrappers instead of translate-c).
extern fn stb_write_png_to_mem(pixels: [*]const u8, w: c_int, h: c_int, channels: c_int, out_len: *c_int) ?[*]u8;
extern fn stb_write_free(data: *anyopaque) void;
extern fn stb_resize(input: [*]const u8, in_w: c_int, in_h: c_int, out_w: c_int, out_h: c_int, channels: c_int) ?[*]u8;
extern fn stb_free(data: [*]u8) void;

const png_path = "test/fixtures/landscape_600x400.png";
const jpg_path = "test/fixtures/landscape_600x400.jpg";
const iterations = 10;

const print = std.debug.print;

// ---------------------------------------------------------------------------
// Timing helpers
// ---------------------------------------------------------------------------

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn median(times: []u64) f64 {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const mid = times.len / 2;
    if (times.len % 2 == 0) {
        return nsToMs(times[mid - 1] / 2 + times[mid] / 2);
    }
    return nsToMs(times[mid]);
}

fn mean(times: []const u64) f64 {
    var sum: u64 = 0;
    for (times) |t| sum += t;
    return nsToMs(sum / times.len);
}

fn minVal(times: []const u64) f64 {
    var m: u64 = std.math.maxInt(u64);
    for (times) |t| if (t < m) {
        m = t;
    };
    return nsToMs(m);
}

// ---------------------------------------------------------------------------
// Individual benchmarks
// ---------------------------------------------------------------------------

fn benchPngDecodeZig(io: std.Io) f64 {
    const allocator = std.heap.smp_allocator;
    var times: [iterations]u64 = undefined;

    // warmup
    {
        var img = zpix.loadPngFile(io, allocator, png_path) catch @panic("zig png load failed");
        img.deinit();
    }

    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io);
        var img = zpix.loadPngFile(io, allocator, png_path) catch @panic("zig png load failed");
        t.* = elapsedNs(io, start);
        img.deinit();
    }

    printResult("zpix", &times);
    return mean(&times);
}

fn benchPngDecodeC(io: std.Io) f64 {
    var times: [iterations]u64 = undefined;

    // warmup
    {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const data = c.stbi_load(png_path, &w, &h, &ch, 0) orelse @panic("c png load failed");
        c.stbi_image_free(data);
    }

    for (&times) |*t| {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const start = std.Io.Clock.now(.awake, io);
        const data = c.stbi_load(png_path, &w, &h, &ch, 0) orelse @panic("c png load failed");
        t.* = elapsedNs(io, start);
        c.stbi_image_free(data);
    }

    printResult("stb_c", &times);
    return mean(&times);
}

fn benchJpegDecodeZig(io: std.Io) f64 {
    const allocator = std.heap.smp_allocator;
    var times: [iterations]u64 = undefined;

    // warmup
    {
        var img = zpix.loadJpegFile(io, allocator, jpg_path) catch @panic("zig jpeg load failed");
        img.deinit();
    }

    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io);
        var img = zpix.loadJpegFile(io, allocator, jpg_path) catch @panic("zig jpeg load failed");
        t.* = elapsedNs(io, start);
        img.deinit();
    }

    printResult("zpix", &times);
    return mean(&times);
}

fn benchJpegDecodeC(io: std.Io) f64 {
    var times: [iterations]u64 = undefined;

    // warmup
    {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const data = c.stbi_load(jpg_path, &w, &h, &ch, 0) orelse @panic("c jpeg load failed");
        c.stbi_image_free(data);
    }

    for (&times) |*t| {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const start = std.Io.Clock.now(.awake, io);
        const data = c.stbi_load(jpg_path, &w, &h, &ch, 0) orelse @panic("c jpeg load failed");
        t.* = elapsedNs(io, start);
        c.stbi_image_free(data);
    }

    printResult("stb_c", &times);
    return mean(&times);
}

fn benchPngEncodeZig(io: std.Io) f64 {
    const allocator = std.heap.smp_allocator;
    var times: [iterations]u64 = undefined;

    // Load source image once
    var img = zpix.loadPngFile(io, allocator, png_path) catch @panic("zig png load failed");
    defer img.deinit();

    // warmup
    {
        const data = zpix.savePngMemory(allocator, &img) catch @panic("zig png encode failed");
        allocator.free(data);
    }

    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io);
        const data = zpix.savePngMemory(allocator, &img) catch @panic("zig png encode failed");
        t.* = elapsedNs(io, start);
        allocator.free(data);
    }

    printResult("zpix", &times);
    return mean(&times);
}

fn benchPngEncodeC(io: std.Io) f64 {
    var times: [iterations]u64 = undefined;

    // Load source image once via C
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const pixels = c.stbi_load(png_path, &w, &h, &ch, 0) orelse @panic("c png load failed");
    defer c.stbi_image_free(pixels);

    // warmup
    {
        var out_len: c_int = 0;
        const data = stb_write_png_to_mem(pixels, w, h, ch, &out_len) orelse @panic("c png encode failed");
        stb_write_free(data);
    }

    for (&times) |*t| {
        var out_len: c_int = 0;
        const start = std.Io.Clock.now(.awake, io);
        const data = stb_write_png_to_mem(pixels, w, h, ch, &out_len) orelse @panic("c png encode failed");
        t.* = elapsedNs(io, start);
        stb_write_free(data);
    }

    printResult("stb_c", &times);
    return mean(&times);
}

fn benchResizeZig(io: std.Io) f64 {
    const allocator = std.heap.smp_allocator;
    var times: [iterations]u64 = undefined;

    // Load source image once
    var img = zpix.loadPngFile(io, allocator, png_path) catch @panic("zig png load failed");
    defer img.deinit();

    const new_w: u32 = 300;
    const new_h: u32 = 200;

    // warmup
    {
        var resized = img.resize(new_w, new_h) catch @panic("zig resize failed");
        resized.deinit();
    }

    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io);
        var resized = img.resize(new_w, new_h) catch @panic("zig resize failed");
        t.* = elapsedNs(io, start);
        resized.deinit();
    }

    printResult("zpix", &times);
    return mean(&times);
}

fn benchResizeC(io: std.Io) f64 {
    var times: [iterations]u64 = undefined;

    // Load source image once via C
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const pixels = c.stbi_load(png_path, &w, &h, &ch, 0) orelse @panic("c png load failed");
    defer c.stbi_image_free(pixels);

    const new_w: c_int = 300;
    const new_h: c_int = 200;

    // warmup
    {
        const out = stb_resize(pixels, w, h, new_w, new_h, ch) orelse @panic("c resize failed");
        stb_free(out);
    }

    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io);
        const out = stb_resize(pixels, w, h, new_w, new_h, ch) orelse @panic("c resize failed");
        t.* = elapsedNs(io, start);
        stb_free(out);
    }

    printResult("stb_c", &times);
    return mean(&times);
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn printResult(label: []const u8, times: []u64) void {
    const min_v = minVal(times);
    const mean_v = mean(times);
    const med_v = median(times);
    print("  {s:<5}: {d:>7.2} ms (min {d:.2}, median {d:.2})\n", .{ label, mean_v, min_v, med_v });
}

fn printRatio(zig_mean: f64, c_mean: f64) void {
    const ratio = zig_mean / c_mean;
    if (ratio > 1.0) {
        print("  ratio: {d:.2}x slower\n\n", .{ratio});
    } else {
        print("  ratio: {d:.2}x faster\n\n", .{1.0 / ratio});
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1) {
        const cmd = args[1];

        if (std.mem.eql(u8, cmd, "png-decode-zig")) {
            _ = benchPngDecodeZig(io);
        } else if (std.mem.eql(u8, cmd, "png-decode-c")) {
            _ = benchPngDecodeC(io);
        } else if (std.mem.eql(u8, cmd, "jpeg-decode-zig")) {
            _ = benchJpegDecodeZig(io);
        } else if (std.mem.eql(u8, cmd, "jpeg-decode-c")) {
            _ = benchJpegDecodeC(io);
        } else if (std.mem.eql(u8, cmd, "png-encode-zig")) {
            _ = benchPngEncodeZig(io);
        } else if (std.mem.eql(u8, cmd, "png-encode-c")) {
            _ = benchPngEncodeC(io);
        } else if (std.mem.eql(u8, cmd, "resize-zig")) {
            _ = benchResizeZig(io);
        } else if (std.mem.eql(u8, cmd, "resize-c")) {
            _ = benchResizeC(io);
        } else {
            print("Unknown benchmark: {s}\n", .{cmd});
            print("Available: png-decode-zig png-decode-c jpeg-decode-zig jpeg-decode-c png-encode-zig png-encode-c resize-zig resize-c\n", .{});
            std.process.exit(1);
        }
        return;
    }

    // Full comparison mode
    print("=== zpix benchmark (ReleaseFast) ===\n\n", .{});

    print("PNG decode (landscape_600x400.png, 600x400 RGB):\n", .{});
    const png_zig = benchPngDecodeZig(io);
    const png_c = benchPngDecodeC(io);
    printRatio(png_zig, png_c);

    print("JPEG decode (landscape_600x400.jpg, 600x400 RGB):\n", .{});
    const jpg_zig = benchJpegDecodeZig(io);
    const jpg_c = benchJpegDecodeC(io);
    printRatio(jpg_zig, jpg_c);

    print("PNG encode (600x400 RGB -> PNG):\n", .{});
    const enc_zig = benchPngEncodeZig(io);
    const enc_c = benchPngEncodeC(io);
    printRatio(enc_zig, enc_c);

    print("Resize (600x400 -> 300x200 RGB):\n", .{});
    const rsz_zig = benchResizeZig(io);
    const rsz_c = benchResizeC(io);
    printRatio(rsz_zig, rsz_c);

    print("\nFor memory profiling, run individual benchmarks with:\n", .{});
    print("  /usr/bin/time -v zig-out/bin/bench png-decode-zig\n", .{});
}
