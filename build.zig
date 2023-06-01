const std = @import("std");
const builtin = @import("builtin");
const Sdl = @import("SDL/build.zig");

const AndroidSdk = @import("sdk.zig");

const AndroidVersion = AndroidSdk.AndroidVersion;
const KeyStore = AndroidSdk.KeyStore;
const Resource = AndroidSdk.Resource;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_android_version: AndroidVersion = .android_10;

    const app_name = "Zig SDL Example";
    const package_name = "com.sdl.example";

    //Get the android sdk
    var sdk = try AndroidSdk.init(b, target_android_version);

    var android_target = try sdk.createTarget(target);

    const sdl = try Sdl.createSDL(b, target, optimize, Sdl.getDefaultOptionsForTarget(target));
    android_target.setupCompileStep(sdl);
    b.installArtifact(sdl);

    const sdl_example = b.addSharedLibrary(.{
        .name = "main",
        .root_source_file = .{ .path = root_path ++ "src/example.zig" },
        .target = target,
        .optimize = optimize,
    });

    //Setup the example code for the android target
    android_target.setupCompileStep(sdl_example);

    //Link libc
    sdl_example.linkLibC();

    sdl_example.linkSystemLibrary("android");
    // example.linkSystemLibrary("log");

    // TODO: is this needed? ReleaseSmall doesnt work with this enabled
    // example.link_emit_relocs = true;
    sdl_example.link_eh_frame_hdr = true;
    sdl_example.force_pic = true;
    sdl_example.link_function_sections = true;
    sdl_example.bundle_compiler_rt = true;
    sdl_example.export_table = true;

    // TODO: Remove when https://github.com/ziglang/zig/issues/7935 is resolved:
    if (sdl_example.target.getCpuArch() == .x86) {
        sdl_example.link_z_notext = true;
    }

    b.installArtifact(sdl_example);

    var apk_install = try sdk.createApk(
        app_name,
        sdl_example.name,
        package_name,
        &.{},
        &.{
            "sdl-android/app/src/main/java/org/libsdl/app/SDL.java",
            "sdl-android/app/src/main/java/org/libsdl/app/SDLSurface.java",
            "sdl-android/app/src/main/java/org/libsdl/app/SDLActivity.java",
            "sdl-android/app/src/main/java/org/libsdl/app/SDLAudioManager.java",
            "sdl-android/app/src/main/java/org/libsdl/app/SDLControllerManager.java",
            "sdl-android/app/src/main/java/org/libsdl/app/HIDDevice.java",
            "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceManager.java",
            "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceUSB.java",
            "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceBLESteamController.java",
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
        &.{
            sdl_example,
            sdl,
        },
    );

    b.getInstallStep().dependOn(&apk_install.step);
}

fn root_dir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root_dir() ++ "/";
