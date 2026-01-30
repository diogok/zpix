const std = @import("std");
const stbz = @import("stbz");

const usage =
    \\Usage: stbz <command> [options]
    \\
    \\Commands:
    \\  crop <input> <output> <x> <y> <width> <height>
    \\      Crop a region from the image
    \\
    \\  resize <input> <output> <width> <height>
    \\      Resize image to specified dimensions
    \\
    \\  thumbnail <input> <output> <size>
    \\      Create a square thumbnail (crops to center, then resizes)
    \\
    \\  rotate <input> <output> <angle>
    \\      Rotate image (angle: 90, 180, or 270 degrees clockwise)
    \\
    \\  flip <input> <output> <direction>
    \\      Flip image (direction: h for horizontal, v for vertical)
    \\
    \\Examples:
    \\  stbz crop photo.png cropped.png 100 100 200 200
    \\  stbz resize photo.png small.png 640 480
    \\  stbz thumbnail photo.png thumb.png 128
    \\  stbz rotate photo.png rotated.png 90
    \\  stbz flip photo.png flipped.png h
    \\
;

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.fs.File.stdout().write(msg) catch {};
}

fn printErrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.fs.File.stderr().write(msg) catch {};
}

fn writeErr(msg: []const u8) void {
    _ = std.fs.File.stderr().write(msg) catch {};
}

fn writeOut(msg: []const u8) void {
    _ = std.fs.File.stdout().write(msg) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        writeErr(usage);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "crop")) {
        runCrop(allocator, args);
    } else if (std.mem.eql(u8, command, "resize")) {
        runResize(allocator, args);
    } else if (std.mem.eql(u8, command, "thumbnail")) {
        runThumbnail(allocator, args);
    } else if (std.mem.eql(u8, command, "rotate")) {
        runRotate(allocator, args);
    } else if (std.mem.eql(u8, command, "flip")) {
        runFlip(allocator, args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        writeOut(usage);
    } else {
        printErrFmt("Unknown command: {s}\n\n", .{command});
        writeErr(usage);
        std.process.exit(1);
    }
}

fn runCrop(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len != 8) {
        writeErr("Error: crop requires 6 arguments: <input> <output> <x> <y> <width> <height>\n");
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];
    const x = std.fmt.parseInt(u32, args[4], 10) catch {
        writeErr("Error: invalid x coordinate\n");
        std.process.exit(1);
    };
    const y = std.fmt.parseInt(u32, args[5], 10) catch {
        writeErr("Error: invalid y coordinate\n");
        std.process.exit(1);
    };
    const width = std.fmt.parseInt(u32, args[6], 10) catch {
        writeErr("Error: invalid width\n");
        std.process.exit(1);
    };
    const height = std.fmt.parseInt(u32, args[7], 10) catch {
        writeErr("Error: invalid height\n");
        std.process.exit(1);
    };

    var img = stbz.loadPngFile(allocator, input_path) catch |err| {
        printErrFmt("Error loading {s}: {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    var cropped = img.crop(x, y, width, height) catch |err| {
        printErrFmt("Error cropping: {}\n", .{err});
        std.process.exit(1);
    };
    defer cropped.deinit();

    savePng(output_path, &cropped) catch |err| {
        printErrFmt("Error saving {s}: {}\n", .{ output_path, err });
        std.process.exit(1);
    };
    printFmt("Cropped {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, width, height });
}

fn runResize(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len != 6) {
        writeErr("Error: resize requires 4 arguments: <input> <output> <width> <height>\n");
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];
    const width = std.fmt.parseInt(u32, args[4], 10) catch {
        writeErr("Error: invalid width\n");
        std.process.exit(1);
    };
    const height = std.fmt.parseInt(u32, args[5], 10) catch {
        writeErr("Error: invalid height\n");
        std.process.exit(1);
    };

    var img = stbz.loadPngFile(allocator, input_path) catch |err| {
        printErrFmt("Error loading {s}: {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    var resized = img.resize(width, height) catch |err| {
        printErrFmt("Error resizing: {}\n", .{err});
        std.process.exit(1);
    };
    defer resized.deinit();

    savePng(output_path, &resized) catch |err| {
        printErrFmt("Error saving {s}: {}\n", .{ output_path, err });
        std.process.exit(1);
    };
    printFmt("Resized {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, width, height });
}

fn runThumbnail(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len != 5) {
        writeErr("Error: thumbnail requires 3 arguments: <input> <output> <size>\n");
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];
    const size = std.fmt.parseInt(u32, args[4], 10) catch {
        writeErr("Error: invalid size\n");
        std.process.exit(1);
    };

    var img = stbz.loadPngFile(allocator, input_path) catch |err| {
        printErrFmt("Error loading {s}: {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    // Crop to center square first
    const min_dim = @min(img.width, img.height);
    const crop_x = (img.width - min_dim) / 2;
    const crop_y = (img.height - min_dim) / 2;

    var cropped = img.crop(crop_x, crop_y, min_dim, min_dim) catch |err| {
        printErrFmt("Error cropping: {}\n", .{err});
        std.process.exit(1);
    };
    defer cropped.deinit();

    // Then resize to target size
    var thumbnail = cropped.resize(size, size) catch |err| {
        printErrFmt("Error resizing: {}\n", .{err});
        std.process.exit(1);
    };
    defer thumbnail.deinit();

    savePng(output_path, &thumbnail) catch |err| {
        printErrFmt("Error saving {s}: {}\n", .{ output_path, err });
        std.process.exit(1);
    };
    printFmt("Thumbnail {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, size, size });
}

fn runRotate(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len != 5) {
        writeErr("Error: rotate requires 3 arguments: <input> <output> <angle>\n");
        writeErr("       angle must be 90, 180, or 270\n");
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];
    const angle = std.fmt.parseInt(u32, args[4], 10) catch {
        writeErr("Error: invalid angle\n");
        std.process.exit(1);
    };

    var img = stbz.loadPngFile(allocator, input_path) catch |err| {
        printErrFmt("Error loading {s}: {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    var rotated = switch (angle) {
        90 => img.rotate90() catch |err| {
            printErrFmt("Error rotating: {}\n", .{err});
            std.process.exit(1);
        },
        180 => img.rotate180() catch |err| {
            printErrFmt("Error rotating: {}\n", .{err});
            std.process.exit(1);
        },
        270 => img.rotate270() catch |err| {
            printErrFmt("Error rotating: {}\n", .{err});
            std.process.exit(1);
        },
        else => {
            writeErr("Error: angle must be 90, 180, or 270\n");
            std.process.exit(1);
        },
    };
    defer rotated.deinit();

    savePng(output_path, &rotated) catch |err| {
        printErrFmt("Error saving {s}: {}\n", .{ output_path, err });
        std.process.exit(1);
    };
    printFmt("Rotated {s} -> {s} ({d}° clockwise)\n", .{ input_path, output_path, angle });
}

fn runFlip(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len != 5) {
        writeErr("Error: flip requires 3 arguments: <input> <output> <direction>\n");
        writeErr("       direction must be 'h' (horizontal) or 'v' (vertical)\n");
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];
    const direction = args[4];

    var img = stbz.loadPngFile(allocator, input_path) catch |err| {
        printErrFmt("Error loading {s}: {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    const dir_name: []const u8 = if (std.mem.eql(u8, direction, "h") or std.mem.eql(u8, direction, "horizontal"))
        "horizontally"
    else if (std.mem.eql(u8, direction, "v") or std.mem.eql(u8, direction, "vertical"))
        "vertically"
    else {
        writeErr("Error: direction must be 'h' (horizontal) or 'v' (vertical)\n");
        std.process.exit(1);
    };

    var flipped = if (std.mem.eql(u8, direction, "h") or std.mem.eql(u8, direction, "horizontal"))
        img.flipHorizontal() catch |err| {
            printErrFmt("Error flipping: {}\n", .{err});
            std.process.exit(1);
        }
    else
        img.flipVertical() catch |err| {
            printErrFmt("Error flipping: {}\n", .{err});
            std.process.exit(1);
        };
    defer flipped.deinit();

    savePng(output_path, &flipped) catch |err| {
        printErrFmt("Error saving {s}: {}\n", .{ output_path, err });
        std.process.exit(1);
    };
    printFmt("Flipped {s} -> {s} ({s})\n", .{ input_path, output_path, dir_name });
}

fn savePng(path: []const u8, img: *const stbz.Image) !void {
    try stbz.savePngFile(img, path);
}
