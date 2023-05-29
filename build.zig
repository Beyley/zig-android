const std = @import("std");
const builtin = @import("builtin");

fn semanticCompare(context: void, lhs: std.SemanticVersion, rhs: std.SemanticVersion) bool {
    _ = context;
    std.debug.assert(lhs.order(rhs) != .eq);
    return lhs.order(rhs) == .gt;
}

const AndroidTools = struct {
    aapt: []const u8,
    zipalign: []const u8,

    pub fn findTools(b: *std.Build, sdk_root: []const u8) !AndroidTools {
        var exe_append = if (builtin.os.tag == .windows) ".exe" else "";
        var bat_append = if (builtin.os.tag == .windows) ".bat" else "";
        _ = bat_append;

        var self: AndroidTools = undefined;

        //Get the newest version of the build tools
        var latest_sdk_version = blk: {
            var build_tools_dir = try std.fs.openIterableDirAbsolute(
                try std.fs.path.join(b.allocator, &.{
                    sdk_root,
                    "build-tools",
                }),
                .{},
            );
            defer build_tools_dir.close();

            var iterator = build_tools_dir.iterate();

            var versions = std.ArrayList(std.SemanticVersion).init(b.allocator);
            defer versions.deinit();

            var next: ?std.fs.IterableDir.Entry = try iterator.next();
            while (next != null) {
                var name = next.?.name;
                var version = try std.SemanticVersion.parse(name);

                try versions.append(version);

                next = try iterator.next();
            }

            std.sort.block(std.SemanticVersion, versions.items, {}, semanticCompare);

            break :blk b.fmt("{any}", .{versions.items[0]});
        };

        self.aapt = try std.fs.path.join(b.allocator, &.{
            sdk_root,
            "build-tools",
            latest_sdk_version,
            "aapt" ++ exe_append,
        });
        self.zipalign = try std.fs.path.join(b.allocator, &.{
            sdk_root,
            "build-tools",
            latest_sdk_version,
            "zipalign" ++ exe_append,
        });

        return self;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const example_name = "example";

    const android_target_version: AndroidVersion = .android_13;
    const sdk_version: u16 = @enumToInt(android_target_version);

    const app_name = example_name;
    const lib_name = example_name;
    const package_name = example_name;

    const permissions: []const []const u8 = &.{};

    const fullscreen = false;

    const java_files_opt: ?[]const []const u8 = null;

    //The root folder of the Android SDK
    const sdk_root = try std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME");

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

    const root_jar = try std.fs.path.resolve(b.allocator, &.{
        sdk_root,
        "platforms",
        b.fmt("android-{d}", .{sdk_version}),
        "android.jar",
    });
    _ = root_jar;

    var tools = try AndroidTools.findTools(b, sdk_root);
    _ = tools;

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

    const write_xml_step = b.addWriteFiles();
    var strings = write_xml_step.add("strings.xml", blk: {
        var buf = std.ArrayList(u8).init(b.allocator);
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
            lib_name,
            package_name,
        });

        break :blk try buf.toOwnedSlice();
    });
    var manifest = write_xml_step.add("AndroidManifest.xml", blk: {
        var buf = std.ArrayList(u8).init(b.allocator);
        defer buf.deinit();

        var writer = buf.writer();

        try writer.print(
            \\<?xml version="1.0" encoding="utf-8" standalone="no"?>
            \\<manifest xmlns:tools="http://schemas.android.com/tools" xmlns:android="http://schemas.android.com/apk/res/android" package="{s}">
            \\    {s}
            \\
            \\    <application android:debuggable="true" android:hasCode="{}" android:label="@string/app_name" {s} tools:replace="android:icon,android:theme,android:allowBackup,label" android:icon="@mipmap/icon" >
            \\        <activity android:configChanges="keyboardHidden|orientation" android:name="android.app.NativeActivity">
            \\            <meta-data android:name="android.app.lib_name" android:value="@string/lib_name"/>
            \\            <intent-filter>
            \\                <action android:name="android.intent.action.MAIN"/>
            \\                <category android:name="android.intent.category.LAUNCHER"/>
            \\            </intent-filter>
            \\        </activity>
            \\    </application>
            \\</manifest>
        , .{
            package_name,
            perm_blk: {
                var perm_buf = std.ArrayList(u8).init(b.allocator);
                defer perm_buf.deinit();
                var perm_writer = perm_buf.writer();
                for (permissions) |permission| {
                    perm_writer.print(
                        \\<uses-permission android:name="{s}"/>\n
                    , .{
                        permission,
                    });
                }
                break :perm_blk try perm_buf.toOwnedSlice();
            },
            java_files_opt != null,
            if (fullscreen) "android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\"" else "",
        });

        break :blk try buf.toOwnedSlice();
    });
    _ = manifest;
    _ = strings;

    const example = b.addSharedLibrary(.{
        .name = example_name,
        .root_source_file = .{ .path = root_path ++ "src/example.zig" },
        .target = target,
        .optimize = optimize,
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

    const step = b.addWriteFiles();

    return step.add(fname, contents.items);
}

///Get the tag for the Android NDK host toolchain
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
