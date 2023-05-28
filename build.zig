const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const android_target_version: AndroidVersion = .android_13;

    const example = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = .{ .path = "src/example.zig" },
        .target = target,
        .optimize = optimize,
    });

    var sdk_root = try std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME");

    //Get the android ndk root
    const ndk_root = std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK") catch |err| blk: {
        if (err != error.EnvironmentVariableNotFound) {
            return err;
        }

        break :blk try std.fs.path.resolve(b.allocator, &.{
            sdk_root,
            "ndk-bundle",
        });
    };

    const include_dir = try std.fs.path.resolve(b.allocator, &.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        comptime toolchainHostTag(),
        "sysroot",
        "usr",
        "include",
    });

    const sys_include_dir = try std.fs.path.resolve(b.allocator, &.{
        include_dir,
        try target.zigTriple(b.allocator),
    });

    const lib_dir = try std.fs.path.resolve(b.allocator, &.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        comptime toolchainHostTag(),
        "sysroot",
        "usr",
        "lib",
        try target.zigTriple(b.allocator),
        b.fmt("{d}", .{@enumToInt(android_target_version)}),
    });

    example.setLibCFile(try createLibCFile(
        b,
        android_target_version,
        "",
        include_dir,
        sys_include_dir,
        lib_dir,
    ));
    //Add the libc file step as a dependency of the example step
    example.libc_file.?.addStepDependencies(&example.step);

    //Link libc
    example.linkLibC();

    example.link_emit_relocs = true;
    example.link_eh_frame_hdr = true;
    example.force_pic = true;
    example.link_function_sections = true;
    example.bundle_compiler_rt = true;
    example.export_table = true;

    b.installArtifact(example);
}

pub const AndroidVersion = enum(u16) {
    android_4 = 19, // KitKat
    android_5 = 21, // Lollipop
    android_6 = 23, // Marshmallow
    android_7 = 24, // Nougat
    android_8 = 26, // Oreo
    android_9 = 28, // Pie
    android_10 = 29, // Quince Tart
    android_11 = 30, // Red Velvet Cake
    android_12 = 31, // Snow Cone
    android_13 = 33, // Tiramisu
};

fn createLibCFile(b: *std.Build, version: AndroidVersion, folder_name: []const u8, include_dir: []const u8, sys_include_dir: []const u8, crt_dir: []const u8) !std.build.FileSource {
    const fname = b.fmt("android-{d}-{s}.conf", .{ @enumToInt(version), folder_name });

    var contents = std.ArrayList(u8).init(b.allocator);
    errdefer contents.deinit();

    var writer = contents.writer();

    //  The directory that contains `stdlib.h`.
    //  On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null
    try writer.print("include_dir={s}\n", .{include_dir});

    // The system-specific include directory. May be the same as `include_dir`.
    // On Windows it's the directory that includes `vcruntime.h`.
    // On POSIX it's the directory that includes `sys/errno.h`.
    try writer.print("sys_include_dir={s}\n", .{sys_include_dir});

    try writer.print("crt_dir={s}\n", .{crt_dir});
    try writer.writeAll("msvc_lib_dir=\n");
    try writer.writeAll("kernel32_lib_dir=\n");
    try writer.writeAll("gcc_dir=\n");

    // const step = b.addWriteFile(fname, contents.items);
    const step = b.addWriteFiles();

    return step.add(fname, contents.items);
}

pub fn toolchainHostTag() []const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    return @tagName(os) ++ "-" ++ @tagName(arch);
}

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root() ++ "/";
