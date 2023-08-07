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
    sdl_example.linkLibrary(sdl);
    sdl_example.addIncludePath(.{ .path = root_path ++ "SDL/include" });

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

    const write_xml_step = sdk.build.addWriteFiles();
    var strings = write_xml_step.add("strings.xml", blk: {
        var buf = std.ArrayList(u8).init(sdk.build.allocator);
        defer buf.deinit();

        var writer = buf.writer();

        try writer.print(
            \\<?xml version="1.0" encoding="utf-8"?>
            \\
            \\<resources>
            \\    <string name="app_name">{s}</string>
            \\    <string name="lib_name">{s}</string>
            \\    <string name="package_name">{s}</string>
            \\</resources>
        , .{
            app_name,
            sdl_example.name,
            package_name,
        });

        break :blk try buf.toOwnedSlice();
    });

    const java_files_opt: ?[]const []const u8 = &.{
        "sdl-android/app/src/main/java/org/libsdl/app/SDL.java",
        "sdl-android/app/src/main/java/org/libsdl/app/SDLSurface.java",
        "sdl-android/app/src/main/java/org/libsdl/app/SDLActivity.java",
        "sdl-android/app/src/main/java/org/libsdl/app/SDLAudioManager.java",
        "sdl-android/app/src/main/java/org/libsdl/app/SDLControllerManager.java",
        "sdl-android/app/src/main/java/org/libsdl/app/HIDDevice.java",
        "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceManager.java",
        "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceUSB.java",
        "sdl-android/app/src/main/java/org/libsdl/app/HIDDeviceBLESteamController.java",
    };

    const fullscreen = false;
    _ = fullscreen;

    var application = b.fmt(
        \\<application android:label="@string/app_name"
        \\    android:icon="@mipmap/icon"
        \\    android:allowBackup="true"
        \\    android:theme="@android:style/Theme.NoTitleBar.Fullscreen"
        \\    android:hardwareAccelerated="true" >
        \\
        \\    <!-- Example of setting SDL hints from AndroidManifest.xml:
        \\    <meta-data android:name="SDL_ENV.SDL_ACCELEROMETER_AS_JOYSTICK" android:value="0"/>
        \\     -->
        \\ 
        \\    <activity android:name="org.libsdl.app.SDLActivity"
        \\        android:label="@string/app_name"
        \\        android:alwaysRetainTaskState="true"
        \\        android:launchMode="singleInstance"
        \\        android:configChanges="layoutDirection|locale|orientation|uiMode|screenLayout|screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation"
        \\        android:exported="true">
        \\        <intent-filter>
        \\            <action android:name="android.intent.action.MAIN" />
        \\            <category android:name="android.intent.category.LAUNCHER" />
        \\        </intent-filter>
        \\        <!-- Let Android know that we can handle some USB devices and should receive this event -->
        \\        <intent-filter>
        \\            <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
        \\        </intent-filter>
        \\        <!-- Drop file event -->
        \\        <!--
        \\        <intent-filter>
        \\            <action android:name="android.intent.action.VIEW" />
        \\            <category android:name="android.intent.category.DEFAULT" />
        \\            <data android:mimeType="*/*" />
        \\        </intent-filter>
        \\        -->
        \\    </activity>
        \\</application>
    , .{});

    var apk_install = try sdk.createApk(
        package_name,
        &.{
            "android.permission.VIBRATE",
        },
        &.{
            .{
                .name = "android.hardware.touchscreen",
                .required = true,
            },
            .{
                .name = "android.hardware.bluetooth",
                .required = false,
            },
            .{
                .name = "android.hardware.usb.host",
                .required = false,
            },
            .{
                .name = "android.hardware.type.pc",
                .required = false,
            },
        },
        java_files_opt,
        &.{
            .{
                .path = "mipmap/icon.png",
                .content = .{ .path = root_path ++ "icon.png" },
            },
            .{
                .path = "values/strings.xml",
                .content = strings,
            },
        },
        KeyStore{
            .file = "test.keystore",
            .alias = "default",
            .password = "password",
        },
        application,
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
