const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const android_target_version: AndroidVersion = .android_13;

    const example = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = .{ .path = root_path ++ "src/example.zig" },
        .target = target,
        .optimize = optimize,
    });

    //The root folder of the Android SDK
    var sdk_root = try std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME");

    //Get the Android NDK root, try first from the env var, then try `sdk_root/ndk-bundle` (is ndk-bundle cross platform?)
    const ndk_root = std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK") catch |err| blk: {
        if (err != error.EnvironmentVariableNotFound) {
            return err;
        }

        break :blk try std.fs.path.resolve(b.allocator, &.{
            sdk_root,
            "ndk-bundle",
        });
    };

    //Path that contains the main android headers
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

    //Path that contains the system headers
    const sys_include_dir = try std.fs.path.resolve(b.allocator, &.{
        include_dir,
        androidTriple(b, target),
    });

    //Path that contains all the native libraries
    const lib_dir = try std.fs.path.resolve(b.allocator, &.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        comptime toolchainHostTag(),
        "sysroot",
        "usr",
        "lib",
        androidTriple(b, target),
        b.fmt("{d}", .{@enumToInt(android_target_version)}),
    });

    //Set the libc file we are using, this is needed since Zig does not package the Android SDK/NDK
    example.setLibCFile(try createLibCFile(
        b,
        android_target_version,
        @tagName(target.getCpuArch()),
        include_dir,
        sys_include_dir,
        lib_dir,
    ));
    //Add the libc file step as a dependency of the example step
    example.libc_file.?.addStepDependencies(&example.step);

    //Link libc
    example.linkLibC();

    // TODO: is this needed? ReleaseSmall doesnt work with this enabled
    // example.link_emit_relocs = true;
    example.link_eh_frame_hdr = true;
    example.force_pic = true;
    example.link_function_sections = true;
    example.bundle_compiler_rt = true;
    example.export_table = true;

    // TODO: Remove when https://github.com/ziglang/zig/issues/7935 is resolved:
    if (example.target.getCpuArch() == .x86) {
        example.link_z_notext = true;
    }

    b.installArtifact(example);
}

pub const AndroidVersion = enum(u16) {
    /// KitKat
    android_4 = 19,
    /// Lollipop
    android_5 = 21,
    /// Marshmallow
    android_6 = 23,
    /// Nougat
    android_7 = 24,
    /// Oreo
    android_8 = 26,
    /// Pie
    android_9 = 28,
    /// Quince Tart
    android_10 = 29,
    /// Red Velvet Cake
    android_11 = 30,
    /// Snow Cone
    android_12 = 31,
    /// Tiramisu
    android_13 = 33,
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

///Get the path for the Android NDK host toolchain
pub fn toolchainHostTag() []const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    return @tagName(os) ++ "-" ++ @tagName(arch);
}

pub fn androidTriple(b: *std.Build, target: std.zig.CrossTarget) []const u8 {
    //x86 is different from zig to android, we need to change x86 -> i686
    if (target.getCpuArch() == .x86) {
        return b.fmt("i686-{s}-{s}", .{
            @tagName(target.getOsTag()),
            @tagName(target.getAbi()),
        });
    }

    //Arm is special and wants androideabi instead of just android
    if (target.getCpuArch() == .arm and target.getAbi() == .android) {
        return b.fmt("{s}-{s}-androideabi", .{
            @tagName(target.getCpuArch()),
            @tagName(target.getOsTag()),
        });
    }

    return b.fmt("{s}-{s}-{s}", .{
        @tagName(target.getCpuArch()),
        @tagName(target.getOsTag()),
        @tagName(target.getAbi()),
    });
}

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root() ++ "/";
