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

fn semanticCompare(context: void, lhs: std.SemanticVersion, rhs: std.SemanticVersion) bool {
    _ = context;
    std.debug.assert(lhs.order(rhs) != .eq);
    return lhs.order(rhs) == .gt;
}

const AndroidTools = struct {
    aapt: []const u8,
    zipalign: []const u8,
    apksigner: []const u8,

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

target_android_version: AndroidVersion,
sdk_version: u16,
sdk_root: []const u8,
ndk_root: []const u8,
root_jar: []const u8,
include_dir: []const u8,
tools: AndroidTools,

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
    };
}

fn root_dir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root_dir() ++ "/";