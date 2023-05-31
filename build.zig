const std = @import("std");
const builtin = @import("builtin");

const AndroidSdk = @import("sdk.zig");

const AndroidVersion = AndroidSdk.AndroidVersion;
const KeyStore = AndroidSdk.KeyStore;
const Resource = AndroidSdk.Resource;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const example_name = "com.example";

    const target_android_version: AndroidVersion = .android_10;

    const app_name = example_name;
    const lib_name = example_name;
    const package_name = example_name;

    //Get the android sdk
    var sdk = try AndroidSdk.init(b, target_android_version);

    var android_target = try sdk.createTarget(target);

    const example = b.addSharedLibrary(.{
        .name = example_name,
        .root_source_file = .{ .path = root_path ++ "src/example.zig" },
        .target = target,
        .optimize = optimize,
    });

    //Setup the example code for the android target
    android_target.setupCompileStep(example);

    //Link libc
    example.linkLibC();

    example.linkSystemLibrary("android");
    // example.linkSystemLibrary("log");

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

    var apk_install = try sdk.createApk(
        app_name,
        lib_name,
        package_name,
        &.{},
        &.{
            "SDL/android-project/app/src/main/java/org/libsdl/app/SDL.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/SDLSurface.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/SDLActivity.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/SDLAudioManager.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/SDLControllerManager.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/HIDDevice.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/HIDDeviceManager.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/HIDDeviceUSB.java",
            "SDL/android-project/app/src/main/java/org/libsdl/app/HIDDeviceBLESteamController.java",
        },
        &.{
            .{
                .path = "mipmap/icon.png",
                .content = .{ .path = root_path ++ "icon.png" },
            },
        },
        false,
        KeyStore{
            .file = "test.keystore",
            .alias = "default",
            .password = "password",
        },
        "example.apk",
        &.{example},
    );

    b.getInstallStep().dependOn(&apk_install.step);
}

fn root_dir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root_dir() ++ "/";
