const std = @import("std");
const game = @import("game");
const api = @import("api.zig");
const tools = @import("tools");

const Runtime = @import("Runtime.zig");

const TestGame = @import("TestGame.zig");

const CurrentPlatform = tools.Platform.Playdate;

pub const log_level: std.log.Level = .warn;

pub const std_options = .{
    .logFn = writeLog,
};

fn writeLog(
    comptime lvl: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (lvl == .warn) {
        var buffer = [_]u8{0} ** 128;
        _ = std.fmt.bufPrint(&buffer, format, args) catch |err|
            std.debug.panic("Error {any} on log {s}", .{ err, format });
        playdate_log_to_console("%s (%s) %s", @tagName(lvl), @tagName(scope), (&buffer).ptr);
    }
}

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
var playdate_log_to_console: *const fn (fmt: [*c]const u8, ...) callconv(.C) void = undefined;

const GlobalState = struct {
    runtime: Runtime,
    universe: TestGame.Universe,

    pub fn create(playdate: *api.PlaydateAPI) !*GlobalState {
        var state: *GlobalState = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(GlobalState))));
        state.runtime = Runtime.init(playdate);
        state.universe = try TestGame.init(try state.runtime.any());
        return state;
    }
};

pub export fn eventHandler(playdate: *api.PlaydateAPI, event: api.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            playdate_error_to_console = playdate.system.@"error";
            playdate_log_to_console = playdate.system.logToConsole;

            const global_state: *anyopaque = GlobalState.create(playdate) catch |err|
                std.debug.panic("Error {any} on init global state", .{err});
            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    const gst: *GlobalState = @ptrCast(@alignCast(userdata.?));
    gst.runtime.playdate.graphics.clear(@intFromEnum(api.LCDSolidColor.ColorBlack));
    gst.universe.tick() catch |err|
        std.debug.panic("Error {any} on game tick", .{err});

    //returning 1 signals to the OS to draw the frame.
    return 1;
}
