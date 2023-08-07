// const std = @import("std");

pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

export fn SDL_main() callconv(.C) void {
    main() catch {
        @panic("Error!");
    };
}

pub fn main() !void {
    //Initialize SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        // std.debug.print("SDL init failed! err:{s}\n", .{c.SDL_GetError()});
        return error.InitSdlFailure;
    }
    defer c.SDL_Quit();
    // std.debug.print("Init SDL\n", .{});

    //Create the window
    const window = c.SDL_CreateWindow("test", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, 640, 480, c.SDL_WINDOW_SHOWN) orelse {
        // std.debug.print("SDL window creation failed! err:{s}\n", .{c.SDL_GetError()});
        return error.CreateWindowFailure;
    };
    defer c.SDL_DestroyWindow(window);
    // std.debug.print("Created SDL window\n", .{});

    var renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse {
        // std.debug.print("SDL renderer creation failed! err:{s}\n", .{c.SDL_GetError()});
        return error.CreateRendereFailure;
    };
    defer c.SDL_DestroyRenderer(renderer);

    var run = true;
    while (run) {
        var ev: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => {
                    run = false;
                },
                else => {},
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 0, 100, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255);
        _ = c.SDL_RenderDrawRect(renderer, &c.SDL_Rect{
            .x = 10,
            .y = 10,
            .w = 30,
            .h = 40,
        });

        c.SDL_RenderPresent(renderer);
    }
}
