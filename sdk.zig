const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

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

/// A resource that will be packed into the appliation.
pub const Resource = struct {
    /// This is the relative path to the resource root
    path: []const u8,
    /// This is the content of the file.
    content: std.build.FileSource,
};

const CreateResourceDirectory = struct {
    builder: *std.build.Builder,
    step: std.build.Step,

    resources: std.ArrayList(Resource),
    directory: std.build.GeneratedFile,

    pub fn create(b: *std.build.Builder) *CreateResourceDirectory {
        const self = b.allocator.create(CreateResourceDirectory) catch @panic("out of memory");
        self.* = CreateResourceDirectory{
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

    pub fn add(self: *CreateResourceDirectory, resource: Resource) void {
        self.resources.append(Resource{
            .path = self.builder.dupe(resource.path),
            .content = resource.content.dupe(self.builder),
        }) catch @panic("out of memory");
        resource.content.addStepDependencies(&self.step);
    }

    pub fn getOutputDirectory(self: *CreateResourceDirectory) std.build.FileSource {
        return .{ .generated = &self.directory };
    }

    fn make(step: *std.Build.Step, progress: *std.Progress.Node) !void {
        _ = progress;
        const self = @fieldParentPtr(CreateResourceDirectory, "step", step);

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
    builder: *std.build.Builder,
    hasher: std.crypto.hash.Sha1,
    subdir: ?[]const u8,

    pub fn init(builder: *std.build.Builder, subdir: ?[]const u8) CacheBuilder {
        return CacheBuilder{
            .builder = builder,
            .hasher = std.crypto.hash.Sha1.init(.{}),
            .subdir = if (subdir) |s|
                builder.dupe(s)
            else
                null,
        };
    }

    pub fn addBytes(self: *CacheBuilder, bytes: []const u8) void {
        self.hasher.update(bytes);
    }

    pub fn addFile(self: *CacheBuilder, file: std.build.FileSource) !void {
        const path = file.getPath(self.builder);

        const data = try std.fs.cwd().readFileAlloc(self.builder.allocator, path, 1 << 32); // 4 GB
        defer self.builder.allocator.free(data);

        self.addBytes(data);
    }

    fn createPath(self: *CacheBuilder) ![]const u8 {
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
    pub fn createAndGetDir(self: *CacheBuilder) !DirAndPath {
        const path = try self.createPath();
        return DirAndPath{
            .path = path,
            .dir = try std.fs.cwd().makeOpenPath(path, .{}),
        };
    }

    pub fn createAndGetPath(self: *CacheBuilder) ![]const u8 {
        const path = try self.createPath();
        try std.fs.cwd().makePath(path);
        return path;
    }
};

pub const KeyStore = struct {
    file: []const u8,
    alias: []const u8,
    password: []const u8,
};

fn semanticCompare(context: void, lhs: std.SemanticVersion, rhs: std.SemanticVersion) bool {
    _ = context;
    std.debug.assert(lhs.order(rhs) != .eq);
    return lhs.order(rhs) == .gt;
}

const AndroidTools = struct {
    aapt: []const u8,
    zipalign: []const u8,
    apksigner: []const u8,
    d8: []const u8,
    javac: []const u8,

    pub fn findTools(b: *std.Build, sdk_root: []const u8) !AndroidTools {
        var exe_append = if (builtin.os.tag == .windows) ".exe" else "";
        var bat_append = if (builtin.os.tag == .windows) ".bat" else "";

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
                next = try iterator.next();

                var version = try std.SemanticVersion.parse(name);

                try versions.append(version);
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
        self.apksigner = try std.fs.path.join(b.allocator, &.{
            sdk_root,
            "build-tools",
            latest_sdk_version,
            "apksigner" ++ bat_append,
        });
        self.d8 = try std.fs.path.join(b.allocator, &.{
            sdk_root,
            "build-tools",
            latest_sdk_version,
            "lib", //we put lib here because calling `d8` directly seems to be borked, idk blame google
            "d8.jar",
        });
        //TODO: find java folder manually, dont rely on it being in the path
        self.javac = try std.fs.path.join(b.allocator, &.{
            "javac" ++ exe_append,
        });

        return self;
    }
};

///Get the tag for the Android NDK host toolchain
pub fn toolchainHostTag() []const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    return @tagName(os) ++ "-" ++ @tagName(arch);
}

///Get the android target triple
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

fn glob_class_files(allocator: std.mem.Allocator, starting_dir: []const u8) ![]const u8 {
    var class_list = std.ArrayList([]const u8).init(allocator);

    var dir = try std.fs.openIterableDirAbsolute(starting_dir, .{});
    defer dir.close();

    var walker: std.fs.IterableDir.Walker = try dir.walk(allocator);
    defer walker.deinit();

    var itr_next: ?std.fs.IterableDir.Walker.WalkerEntry = try walker.next();
    while (itr_next != null) {
        var next: std.fs.IterableDir.Walker.WalkerEntry = itr_next.?;

        //if the file is a class file
        if (std.mem.endsWith(u8, next.path, ".class")) {
            var item = try allocator.alloc(u8, next.path.len + starting_dir.len);

            //copy the root first
            std.mem.copy(u8, item, starting_dir);

            //copy the filepath next
            std.mem.copy(u8, item[starting_dir.len..], next.path);

            try class_list.append(item);
        }

        itr_next = try walker.next();
    }

    return class_list.toOwnedSlice();
}

target_android_version: AndroidVersion,
sdk_version: u16,
sdk_root: []const u8,
ndk_root: []const u8,
root_jar: []const u8,
include_dir: []const u8,
tools: AndroidTools,
build: *std.Build,

///Create an APK file, and packs in all `shared_objects` into their respective folders
pub fn createApk(
    sdk: Self,
    app_name: []const u8,
    lib_name: []const u8,
    package_name: []const u8,
    permissions: []const []const u8,
    java_files_opt: ?[]const []const u8,
    resources: []const Resource,
    fullscreen: bool,
    key_store: KeyStore,
    apk_filename: []const u8,
    shared_objects: []const *std.Build.Step.Compile,
) !*std.Build.Step.InstallFile {
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
            lib_name,
            package_name,
        });

        break :blk try buf.toOwnedSlice();
    });
    var manifest = write_xml_step.add("AndroidManifest.xml", blk: {
        var buf = std.ArrayList(u8).init(sdk.build.allocator);
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
                var perm_buf = std.ArrayList(u8).init(sdk.build.allocator);
                defer perm_buf.deinit();
                var perm_writer = perm_buf.writer();
                for (permissions) |permission| {
                    try perm_writer.print(
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

    const resource_dir_step = CreateResourceDirectory.create(sdk.build);
    for (resources) |resource| {
        resource_dir_step.add(resource);
    }
    //Add the strings.xml file as a resource
    resource_dir_step.add(Resource{
        .path = "values/strings.xml",
        .content = strings,
    });

    const unaligned_apk_name = sdk.build.fmt("unaligned-{s}", .{std.fs.path.basename(apk_filename)});

    const make_unsigned_apk = sdk.build.addSystemCommand(&.{
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
        sdk.build.fmt("{d}", .{sdk.sdk_version}),
    });

    //todo: asset directories
    // for (app_config.asset_directories) |dir| {
    //     make_unsigned_apk.addArg("-A"); // additional directory in which to find raw asset files
    //     make_unsigned_apk.addArg(sdk.sdk.build.pathFromRoot(dir));
    // }

    //NOTE: align happens *AFTER* adding the shared objects, but we have it before in the function so that the copy shared object tasks can be depended on!
    const align_step = sdk.build.addSystemCommand(&.{
        sdk.tools.zipalign,
        "-p", // ensure shared libraries are aligned to 4KiB boundaries
        "-f", // overwrite existing files
        "-v", // enable verbose output
        "-z", // recompress output
        "4",
    });
    // align_step.addFileSourceArg(copy_to_zip_output);
    align_step.addFileSourceArg(unaligned_apk_file);
    // align_step.step.dependOn(&make_unsigned_apk.step);
    const apk_file = align_step.addOutputFileArg(apk_filename);

    for (shared_objects) |shared_object| {
        // https://developer.android.com/ndk/guides/abis#native-code-in-app-packages
        const so_dir = switch (shared_object.target.getCpuArch()) {
            .aarch64 => "lib/arm64-v8a",
            .arm => "lib/armeabi-v7a",
            .x86_64 => "lib/x86_64",
            .x86 => "lib/x86",
            else => @panic("Unknown arch!"),
        };

        if (shared_object.target.getAbi() != .android) {
            @panic("Non-android shared object added");
        }

        const target_filename = sdk.build.fmt("lib{s}.so", .{app_name});
        const target_path = sdk.build.fmt("{s}/{s}", .{ so_dir, target_filename });

        const delete_old_so = sdk.build.addSystemCommand(&.{
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
        const add_to_zip_root = sdk.build.addSystemCommand(&.{
            "zip",
            "-j",
        });
        //The target zip file
        add_to_zip_root.addFileSourceArg(unaligned_apk_file);
        //The .so file
        add_to_zip_root.addFileSourceArg(shared_object.getOutputSource());

        add_to_zip_root.step.dependOn(&delete_old_so.step);

        //Run 7z to move the file to the right folder
        const move_so_to_folder = sdk.build.addSystemCommand(&.{
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

        align_step.step.dependOn(&move_so_to_folder.step);
    }

    const java_dir = sdk.build.getInstallPath(.lib, "java");
    std.fs.makeDirAbsolute(java_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    if (java_files_opt) |java_files| {
        if (java_files.len == 0) {
            return error.NoJavaFilesPassedPassNullPlease;
        }

        //HACK: this should be done LITERALLY ANY OTHER WAY,
        //      but im too lazy to write the 50 lines of code, so this will do for now :)
        const d8_cmd = sdk.build.addSystemCommand(&.{
            "zsh",
            "-c",
        });

        var final_command = std.ArrayList(u8).init(sdk.build.allocator);

        try final_command.appendSlice("java ");
        try final_command.appendSlice("-jar ");
        try final_command.appendSlice(sdk.tools.d8);
        try final_command.append(' ');
        try final_command.appendSlice("--lib ");
        try final_command.appendSlice(sdk.root_jar);
        try final_command.append(' ');

        const javac_cmd = sdk.build.addSystemCommand(&.{
            sdk.tools.javac,
            //The classpath
            "-cp",
            sdk.root_jar,
            //The directory
            "-d",
            java_dir,
        });
        d8_cmd.step.dependOn(&javac_cmd.step);

        for (java_files) |java_file| {
            //The java file source
            javac_cmd.addFileSourceArg(std.build.FileSource.relative(java_file));
        }

        try final_command.appendSlice(java_dir);
        try final_command.appendSlice("/**/*.class ");

        try final_command.appendSlice("--classpath ");
        try final_command.appendSlice(java_dir);
        try final_command.append(' ');
        try final_command.appendSlice("--output ");
        try final_command.appendSlice(java_dir);

        d8_cmd.addArg(try final_command.toOwnedSlice());

        d8_cmd.step.dependOn(&make_unsigned_apk.step);

        const dex_file = try std.fs.path.resolve(sdk.build.allocator, &.{ java_dir, "classes.dex" });

        //Run zip with the -j flag, to copy the so file to the root of the apk
        const add_dex_to_zip = sdk.build.addSystemCommand(&.{
            "zip",
            "-j",
        });
        //The target zip file
        add_dex_to_zip.addFileSourceArg(unaligned_apk_file);
        //The .so file
        add_dex_to_zip.addFileSourceArg(.{ .path = dex_file });

        //Make the add dex step run after d8
        add_dex_to_zip.step.dependOn(&d8_cmd.step);

        //Make align depend on adding dex
        align_step.step.dependOn(&add_dex_to_zip.step);
    }

    const sign_step = sdk.build.addSystemCommand(&[_][]const u8{
        sdk.tools.apksigner,
        "sign",
        "--ks", // keystore
        key_store.file,
    });
    sign_step.step.dependOn(&align_step.step);
    {
        const pass = sdk.build.fmt("pass:{s}", .{key_store.password});
        sign_step.addArgs(&.{ "--ks-pass", pass });
        sign_step.addFileSourceArg(apk_file);
    }

    const apk_install = sdk.build.addInstallBinFile(apk_file, apk_filename);
    apk_install.step.dependOn(&sign_step.step);

    return apk_install;
}

pub const AndroidTarget = struct {
    sdk: Self,
    sys_include_dir: []const u8,
    lib_dir: []const u8,
    libc_file: std.build.FileSource,
    target: std.zig.CrossTarget,

    pub fn setupCompileStep(self: AndroidTarget, step: *std.Build.Step.Compile) void {
        //Set the libc file
        step.setLibCFile(self.libc_file);
        //Make the compile step depend on the libc file
        self.libc_file.addStepDependencies(&step.step);

        step.addIncludePath(self.sdk.include_dir);
        step.addLibraryPath(self.lib_dir);
    }
};

pub fn createTarget(sdk: Self, target: std.zig.CrossTarget) !AndroidTarget {
    //Path that contains the system headers
    const sys_include_dir = try std.fs.path.resolve(sdk.build.allocator, &.{
        sdk.include_dir,
        androidTriple(sdk.build, target),
    });

    //Path that contains all the native libraries
    const lib_dir = try std.fs.path.resolve(sdk.build.allocator, &.{
        sdk.ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        comptime toolchainHostTag(),
        "sysroot",
        "usr",
        "lib",
        androidTriple(sdk.build, target),
        sdk.build.fmt("{d}", .{@enumToInt(sdk.target_android_version)}),
    });

    var libc_file = try createAndroidLibCFile(
        sdk.build,
        sdk.target_android_version,
        @tagName(target.getCpuArch()),
        sdk.include_dir,
        sys_include_dir,
        lib_dir,
    );

    return AndroidTarget{
        .sys_include_dir = sys_include_dir,
        .libc_file = libc_file,
        .lib_dir = lib_dir,
        .target = target,
        .sdk = sdk,
    };
}

pub fn init(b: *std.Build, target_android_version: AndroidVersion) !Self {
    const sdk_version: u16 = @enumToInt(target_android_version);

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

    //The root jar for the android platform
    const root_jar = try std.fs.path.resolve(b.allocator, &.{
        sdk_root,
        "platforms",
        b.fmt("android-{d}", .{sdk_version}),
        "android.jar",
    });

    //The android tools
    var tools = try AndroidTools.findTools(b, sdk_root);

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

    return Self{
        .target_android_version = target_android_version,
        .sdk_version = sdk_version,
        .sdk_root = sdk_root,
        .ndk_root = ndk_root,
        .root_jar = root_jar,
        .include_dir = include_dir,
        .tools = tools,
        .build = b,
    };
}

fn createAndroidLibCFile(b: *std.Build, version: AndroidVersion, folder_name: []const u8, include_dir: []const u8, sys_include_dir: []const u8, crt_dir: []const u8) !std.build.FileSource {
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

fn root_dir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root_dir() ++ "/";
