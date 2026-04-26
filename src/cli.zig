const std = @import("std");
const zpix = @import("zpix");

const usage =
    \\Usage: zpix <command> [options]
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
    \\  zpix crop photo.png cropped.png 100 100 200 200
    \\  zpix resize photo.png small.png 640 480
    \\  zpix thumbnail photo.png thumb.png 128
    \\  zpix rotate photo.png rotated.png 90
    \\  zpix flip photo.png flipped.png h
    \\
;

const Cli = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    fn fail(self: Cli, comptime fmt: []const u8, args: anytype) noreturn {
        self.err.print(fmt, args) catch {};
        self.err.flush() catch {};
        std.process.exit(1);
    }

    fn parseInt(self: Cli, value: []const u8, field_name: []const u8) u32 {
        return std.fmt.parseInt(u32, value, 10) catch
            self.fail("Error: invalid {s}\n", .{field_name});
    }

    fn loadImage(self: Cli, path: []const u8) zpix.Image {
        return zpix.loadFile(self.io, self.allocator, path) catch |err|
            self.fail("Error loading {s}: {}\n", .{ path, err });
    }

    fn saveImage(self: Cli, path: []const u8, img: *const zpix.Image) void {
        zpix.saveFile(self.io, img, path) catch |err|
            self.fail("Error saving {s}: {}\n", .{ path, err });
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    defer stdout_writer.flush() catch {};
    defer stderr_writer.flush() catch {};

    const cli: Cli = .{
        .io = io,
        .allocator = init.gpa,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
    };

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) cli.fail("{s}", .{usage});

    const command = args[1];

    if (std.mem.eql(u8, command, "crop")) {
        runCrop(cli, args);
    } else if (std.mem.eql(u8, command, "resize")) {
        runResize(cli, args);
    } else if (std.mem.eql(u8, command, "thumbnail")) {
        runThumbnail(cli, args);
    } else if (std.mem.eql(u8, command, "rotate")) {
        runRotate(cli, args);
    } else if (std.mem.eql(u8, command, "flip")) {
        runFlip(cli, args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try cli.out.writeAll(usage);
    } else {
        cli.fail("Unknown command: {s}\n\n{s}", .{ command, usage });
    }
}

fn runCrop(cli: Cli, args: []const [:0]const u8) void {
    if (args.len != 8)
        cli.fail("Error: crop requires 6 arguments: <input> <output> <x> <y> <width> <height>\n", .{});

    const input_path = args[2];
    const output_path = args[3];
    const x = cli.parseInt(args[4], "x coordinate");
    const y = cli.parseInt(args[5], "y coordinate");
    const width = cli.parseInt(args[6], "width");
    const height = cli.parseInt(args[7], "height");

    var img = cli.loadImage(input_path);
    defer img.deinit();

    var cropped = img.crop(x, y, width, height) catch |err|
        cli.fail("Error cropping: {}\n", .{err});
    defer cropped.deinit();

    cli.saveImage(output_path, &cropped);
    cli.out.print("Cropped {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, width, height }) catch {};
}

fn runResize(cli: Cli, args: []const [:0]const u8) void {
    if (args.len != 6)
        cli.fail("Error: resize requires 4 arguments: <input> <output> <width> <height>\n", .{});

    const input_path = args[2];
    const output_path = args[3];
    const width = cli.parseInt(args[4], "width");
    const height = cli.parseInt(args[5], "height");

    var img = cli.loadImage(input_path);
    defer img.deinit();

    var resized = img.resize(width, height) catch |err|
        cli.fail("Error resizing: {}\n", .{err});
    defer resized.deinit();

    cli.saveImage(output_path, &resized);
    cli.out.print("Resized {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, width, height }) catch {};
}

fn runThumbnail(cli: Cli, args: []const [:0]const u8) void {
    if (args.len != 5)
        cli.fail("Error: thumbnail requires 3 arguments: <input> <output> <size>\n", .{});

    const input_path = args[2];
    const output_path = args[3];
    const size = cli.parseInt(args[4], "size");

    var img = cli.loadImage(input_path);
    defer img.deinit();

    const min_dim = @min(img.width, img.height);
    const crop_x = (img.width - min_dim) / 2;
    const crop_y = (img.height - min_dim) / 2;

    var cropped = img.crop(crop_x, crop_y, min_dim, min_dim) catch |err|
        cli.fail("Error cropping: {}\n", .{err});
    defer cropped.deinit();

    var thumbnail = cropped.resize(size, size) catch |err|
        cli.fail("Error resizing: {}\n", .{err});
    defer thumbnail.deinit();

    cli.saveImage(output_path, &thumbnail);
    cli.out.print("Thumbnail {s} -> {s} ({d}x{d})\n", .{ input_path, output_path, size, size }) catch {};
}

fn runRotate(cli: Cli, args: []const [:0]const u8) void {
    if (args.len != 5)
        cli.fail("Error: rotate requires 3 arguments: <input> <output> <angle>\n       angle must be 90, 180, or 270\n", .{});

    const input_path = args[2];
    const output_path = args[3];
    const angle = cli.parseInt(args[4], "angle");

    var img = cli.loadImage(input_path);
    defer img.deinit();

    var rotated = switch (angle) {
        90 => img.rotate90(),
        180 => img.rotate180(),
        270 => img.rotate270(),
        else => cli.fail("Error: angle must be 90, 180, or 270\n", .{}),
    } catch |err| cli.fail("Error rotating: {}\n", .{err});
    defer rotated.deinit();

    cli.saveImage(output_path, &rotated);
    cli.out.print("Rotated {s} -> {s} ({d}° clockwise)\n", .{ input_path, output_path, angle }) catch {};
}

fn runFlip(cli: Cli, args: []const [:0]const u8) void {
    if (args.len != 5)
        cli.fail("Error: flip requires 3 arguments: <input> <output> <direction>\n       direction must be 'h' (horizontal) or 'v' (vertical)\n", .{});

    const input_path = args[2];
    const output_path = args[3];
    const direction = args[4];
    const horizontal = std.mem.eql(u8, direction, "h") or std.mem.eql(u8, direction, "horizontal");
    const vertical = std.mem.eql(u8, direction, "v") or std.mem.eql(u8, direction, "vertical");

    if (!horizontal and !vertical)
        cli.fail("Error: direction must be 'h' (horizontal) or 'v' (vertical)\n", .{});

    var img = cli.loadImage(input_path);
    defer img.deinit();

    var flipped = (if (horizontal) img.flipHorizontal() else img.flipVertical()) catch |err|
        cli.fail("Error flipping: {}\n", .{err});
    defer flipped.deinit();

    cli.saveImage(output_path, &flipped);
    const dir_name: []const u8 = if (horizontal) "horizontally" else "vertically";
    cli.out.print("Flipped {s} -> {s} ({s})\n", .{ input_path, output_path, dir_name }) catch {};
}
