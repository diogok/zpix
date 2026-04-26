const std = @import("std");
const zpix = @import("zpix");

const images_dir = "/home/diogo/RPG/Eberron/Images";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const stdout = std.Io.File.stdout();

    var total: u32 = 0;
    var loaded: u32 = 0;
    var thumbnailed: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;

    var dir = std.Io.Dir.openAbsolute(io, images_dir, .{ .iterate = true }) catch |err| {
        printErr(io, "Error: cannot open {s}: {}\n", .{ images_dir, err });
        std.process.exit(1);
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.Io.Dir.path.extension(entry.basename);
        const is_image = std.ascii.eqlIgnoreCase(ext, ".jpg") or
            std.ascii.eqlIgnoreCase(ext, ".jpeg") or
            std.ascii.eqlIgnoreCase(ext, ".png");
        if (!is_image) continue;

        total += 1;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ images_dir, entry.path }) catch continue;

        // Try to load
        var img = zpix.loadFile(io, allocator, full_path) catch |err| {
            if (err == zpix.FormatError.UnsupportedFormat) {
                skipped += 1;
                continue;
            }
            failed += 1;
            printTo(io, stdout, "  FAIL [load] {s}: {}\n", .{ entry.path, err });
            continue;
        };
        defer img.deinit();

        loaded += 1;

        // Try thumbnail (128x128)
        const min_dim = @min(img.width, img.height);
        if (min_dim == 0) continue;

        const crop_x = (img.width - min_dim) / 2;
        const crop_y = (img.height - min_dim) / 2;

        var cropped = img.crop(crop_x, crop_y, min_dim, min_dim) catch |err| {
            failed += 1;
            printTo(io, stdout, "  FAIL [crop] {s}: {}\n", .{ entry.path, err });
            continue;
        };
        defer cropped.deinit();

        var thumb = cropped.resize(128, 128) catch |err| {
            failed += 1;
            printTo(io, stdout, "  FAIL [resize] {s}: {}\n", .{ entry.path, err });
            continue;
        };
        defer thumb.deinit();

        thumbnailed += 1;

        // Progress every 100 files
        if (total % 100 == 0) {
            printTo(io, stdout, "  ... processed {d} files\n", .{total});
        }
    }

    // Summary
    printTo(io, stdout, "\n=== Bulk Load Test Results ===\n", .{});
    printTo(io, stdout, "Total image files found: {d}\n", .{total});
    printTo(io, stdout, "Successfully loaded:     {d}/{d}\n", .{ loaded, total });
    printTo(io, stdout, "Successfully thumbnailed: {d}/{d}\n", .{ thumbnailed, loaded });
    printTo(io, stdout, "Skipped (unsupported):   {d}\n", .{skipped});
    printTo(io, stdout, "Failed:                  {d}\n", .{failed});

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn printTo(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeStreamingAll(io, msg) catch {};
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    printTo(io, std.Io.File.stderr(), fmt, args);
}
