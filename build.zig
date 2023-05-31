const std = @import("std");
const builtin = @import("builtin");

const AndroidSdk = @import("sdk.zig");

const AndroidVersion = AndroidSdk.AndroidVersion;

/// A resource that will be packed into the appliation.
pub const Resource = struct {
    /// This is the relative path to the resource root
    path: []const u8,
    /// This is the content of the file.
    content: std.build.FileSource,
};

const CreateResourceDirectory = struct {
    const Self = @This();
    builder: *std.build.Builder,
    step: std.build.Step,

    resources: std.ArrayList(Resource),
    directory: std.build.GeneratedFile,

    pub fn create(b: *std.build.Builder) *Self {
        const self = b.allocator.create(Self) catch @panic("out of memory");
        self.* = Self{
            .builder = b,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "populate resource directory",
                .owner = b,
                .makeFn = CreateResourceDirectory.make,
            }),
            .directory = .{ .step = &self.step },
            .resources = std.ArrayList(Resource).init(b.allocator),
        };
        return self;
    }

    pub fn add(self: *Self, resource: Resource) void {
        self.resources.append(Resource{
            .path = self.builder.dupe(resource.path),
            .content = resource.content.dupe(self.builder),
        }) catch @panic("out of memory");
        resource.content.addStepDependencies(&self.step);
    }

    pub fn getOutputDirectory(self: *Self) std.build.FileSource {
        return .{ .generated = &self.directory };
    }

    fn make(step: *std.Build.Step, progress: *std.Progress.Node) !void {
        _ = progress;
        const self = @fieldParentPtr(Self, "step", step);

        // if (std.fs.path.dirname(strings_xml)) |dir| {
        //     std.fs.cwd().makePath(dir) catch unreachable;
        // }

        var cacher = createCacheBuilder(self.builder);
        for (self.resources.items) |res| {
            cacher.addBytes(res.path);
            try cacher.addFile(res.content);
        }

        const root = try cacher.createAndGetDir();
        for (self.resources.items) |res| {
            if (std.fs.path.dirname(res.path)) |folder| {
                try root.dir.makePath(folder);
            }

            const src_path = res.content.getPath(self.builder);
            try std.fs.Dir.copyFile(
                std.fs.cwd(),
                src_path,
                root.dir,
                res.path,
                .{},
            );
        }

        self.directory.path = root.path;
    }
};

fn createCacheBuilder(b: *std.build.Builder) CacheBuilder {
    return CacheBuilder.init(b, "android-sdk");
}

const CacheBuilder = struct {
    const Self = @This();

    builder: *std.build.Builder,
    hasher: std.crypto.hash.Sha1,
    subdir: ?[]const u8,

    pub fn init(builder: *std.build.Builder, subdir: ?[]const u8) Self {
        return Self{
            .builder = builder,
            .hasher = std.crypto.hash.Sha1.init(.{}),
            .subdir = if (subdir) |s|
                builder.dupe(s)
            else
                null,
        };
    }

    pub fn addBytes(self: *Self, bytes: []const u8) void {
        self.hasher.update(bytes);
    }

    pub fn addFile(self: *Self, file: std.build.FileSource) !void {
        const path = file.getPath(self.builder);

        const data = try std.fs.cwd().readFileAlloc(self.builder.allocator, path, 1 << 32); // 4 GB
        defer self.builder.allocator.free(data);

        self.addBytes(data);
    }

    fn createPath(self: *Self) ![]const u8 {
        var hash: [20]u8 = undefined;
        self.hasher.final(&hash);

        const path = if (self.subdir) |subdir|
            try std.fmt.allocPrint(
                self.builder.allocator,
                "{s}/{s}/o/{}",
                .{
                    self.builder.cache_root.path.?,
                    subdir,
                    std.fmt.fmtSliceHexLower(&hash),
                },
            )
        else
            try std.fmt.allocPrint(
                self.builder.allocator,
                "{s}/o/{}",
                .{
                    self.builder.cache_root.path.?,
                    std.fmt.fmtSliceHexLower(&hash),
                },
            );

        return path;
    }

    pub const DirAndPath = struct {
        dir: std.fs.Dir,
        path: []const u8,
    };
    pub fn createAndGetDir(self: *Self) !DirAndPath {
        const path = try self.createPath();
        return DirAndPath{
            .path = path,
            .dir = try std.fs.cwd().makeOpenPath(path, .{}),
        };
    }

    pub fn createAndGetPath(self: *Self) ![]const u8 {
        const path = try self.createPath();
        try std.fs.cwd().makePath(path);
        return path;
    }
};

const KeyStore = struct {
    file: []const u8,
    alias: []const u8,
    password: []const u8,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const example_name = "com.example";

    const target_android_version: AndroidVersion = .android_10;
    const sdk_version: u16 = @enumToInt(target_android_version);

    const app_name = example_name;
    const lib_name = example_name;
    const package_name = example_name;

    const permissions: []const []const u8 = &.{};

    const fullscreen = false;

    const java_files_opt: ?[]const []const u8 = null;

    const apk_filename = "example.apk";

    const key_store = KeyStore{
        .file = "test.keystore",
        .alias = "default",
        .password = "password",
    };

    const resources: []const Resource = &.{Resource{
        .path = "mipmap/icon.png",
        .content = .{ .path = root_path ++ "icon.png" },
    }};

    //Get the android sdk
    var sdk = try AndroidSdk.init(b, target_android_version);

    var android_target = try sdk.createTarget(target);

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
            \\        <activity android:configChanges="keyboardHidden|orientation" android:name="android.app.NativeActivity" android:exported="true">
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

    const resource_dir_step = CreateResourceDirectory.create(b);
    for (resources) |resource| {
        resource_dir_step.add(resource);
    }
    //Add the strings.xml file as a resource
    resource_dir_step.add(Resource{
        .path = "values/strings.xml",
        .content = strings,
    });

    const example = b.addSharedLibrary(.{
        .name = example_name,
        .root_source_file = .{ .path = root_path ++ "src/example.zig" },
        .target = target,
        .optimize = optimize,
    });

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

    const unaligned_apk_name = b.fmt("unaligned-{s}", .{std.fs.path.basename(apk_filename)});

    const make_unsigned_apk = b.addSystemCommand(&.{
        sdk.tools.aapt,
        "package",
        "-f", //overwrite existing files
        "-I", sdk.root_jar, //add an existing package to base include set
        "-F", //specify the apk file output
    });
    const unaligned_apk_file = make_unsigned_apk.addOutputFileArg(unaligned_apk_name);

    //Specify the full path to the manifest file
    make_unsigned_apk.addArg("-M");
    make_unsigned_apk.addFileSourceArg(manifest);

    //Specify the full path to the resource directory
    make_unsigned_apk.addArg("-S");
    make_unsigned_apk.addDirectorySourceArg(resource_dir_step.getOutputDirectory());

    //Specify verbose output and the target android SDK version
    make_unsigned_apk.addArgs(&.{
        "-v",
        "--target-sdk-version",
        b.fmt("{d}", .{sdk_version}),
    });

    //todo: asset directories
    // for (app_config.asset_directories) |dir| {
    //     make_unsigned_apk.addArg("-A"); // additional directory in which to find raw asset files
    //     make_unsigned_apk.addArg(sdk.b.pathFromRoot(dir));
    // }

    // https://developer.android.com/ndk/guides/abis#native-code-in-app-packages
    const so_dir = switch (target.getCpuArch()) {
        .aarch64 => "lib/arm64-v8a",
        .arm => "lib/armeabi-v7a",
        .x86_64 => "lib/x86_64",
        .x86 => "lib/x86",
        else => @panic("Unknown arch!"),
    };

    const target_filename = b.fmt("lib{s}.so", .{app_name});
    const target_path = b.fmt("{s}/{s}", .{ so_dir, target_filename });

    const delete_old_so = b.addSystemCommand(&.{
        "7z",
        "d",
        "-ba",
    });
    //The archive
    delete_old_so.addFileSourceArg(unaligned_apk_file);

    //The path to delete
    delete_old_so.addArg(target_path);

    delete_old_so.step.dependOn(&make_unsigned_apk.step);

    //Run zip with the -j flag, to copy the so file to the root of the apk
    const add_to_zip_root = b.addSystemCommand(&.{
        "zip",
        "-j",
    });
    //The target zip file
    add_to_zip_root.addFileSourceArg(unaligned_apk_file);
    //The .so file
    add_to_zip_root.addFileSourceArg(example.getOutputSource());

    add_to_zip_root.step.dependOn(&delete_old_so.step);

    //Run 7z to move the file to the right folder
    const move_so_to_folder = b.addSystemCommand(&.{
        "7z",
        "-tzip",
        "-ba",
        "-aou",
        "rn",
    });
    //The archive
    move_so_to_folder.addFileSourceArg(unaligned_apk_file);

    move_so_to_folder.addArgs(&.{
        target_filename, //the source path
        target_path, //the destination path
    });

    move_so_to_folder.step.dependOn(&add_to_zip_root.step);

    const align_step = b.addSystemCommand(&.{
        sdk.tools.zipalign,
        "-p", // ensure shared libraries are aligned to 4KiB boundaries
        "-f", // overwrite existing files
        "-v", // enable verbose output
        "-z", // recompress output
        "4",
    });
    // align_step.addFileSourceArg(copy_to_zip_output);
    align_step.addFileSourceArg(unaligned_apk_file);
    align_step.step.dependOn(&move_so_to_folder.step);
    // align_step.step.dependOn(&make_unsigned_apk.step);
    const apk_file = align_step.addOutputFileArg(apk_filename);

    // const apk_install = b.addInstallBinFile(apk_file, apk_filename);
    // b.getInstallStep().dependOn(&apk_install.step);

    // const java_dir = b.getInstallPath(.lib, "java");
    //todo: java file building https://github.com/MasterQ32/ZigAndroidTemplate/blob/a7907838e0db655097ef912dd575fee9b8cb3bec/Sdk.zig#L604

    const sign_step = b.addSystemCommand(&[_][]const u8{
        sdk.tools.apksigner,
        "sign",
        "--ks", // keystore
        key_store.file,
    });
    sign_step.step.dependOn(&align_step.step);
    {
        const pass = b.fmt("pass:{s}", .{key_store.password});
        sign_step.addArgs(&.{ "--ks-pass", pass });
        sign_step.addFileSourceArg(apk_file);
    }

    const apk_install = b.addInstallBinFile(apk_file, apk_filename);
    apk_install.step.dependOn(&sign_step.step);
    b.getInstallStep().dependOn(&apk_install.step);
}

fn root_dir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root_dir() ++ "/";
