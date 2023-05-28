export fn ANativeActivity_onCreate(activity: ?*anyopaque, saved_state: ?[*]u8, saved_state_size: usize) callconv(.C) void {
    _ = saved_state_size;
    _ = saved_state;
    _ = activity;
}
