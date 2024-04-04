const std = @import("std");
const game = @import("game");
const api = @import("api.zig");
const tools = @import("tools");

const Allocator = @import("Allocator.zig");
const Environment = @import("Environment.zig");

const CurrentPlatform = tools.Platform.Playdate;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = return_address;
    playdate_error_to_console("%s", msg.ptr);
    while (true) {}
}

var playdate_error_to_console: *const fn (fmt: [*c]const u8, ...) callconv(.C) void = undefined;

const GlobalState = struct {
    alloc: std.mem.Allocator,
    environment: Environment,
    game: game.ForgottenCatacomb(Environment).Game,

    pub fn create(playdate: *api.PlaydateAPI) *GlobalState {
        var state: *GlobalState = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(GlobalState))));
        state.alloc = Allocator.allocator(playdate);
        state.environment = Environment.init(playdate);
        state.game = game.ForgottenCatacomb(Environment).init(state.environment.runtime(), state.alloc);
        return state;
    }
};

pub export fn eventHandler(playdate: *api.PlaydateAPI, event: api.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            playdate_error_to_console = playdate.system.@"error";

            const global_state: *anyopaque = GlobalState.create(playdate);
            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    const gst: *GlobalState = @ptrCast(@alignCast(userdata.?));
    gst.environment.playdate.graphics.clear(@intFromEnum(api.LCDSolidColor.ColorWhite));
    gst.game.tick() catch |err|
        std.debug.panic("Error {any} on game tick", .{err});

    //returning 1 signals to the OS to draw the frame.
    return 1;
}
