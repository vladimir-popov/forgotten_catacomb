const std = @import("std");
const game = @import("game");
const api = @import("api.zig");
const tools = @import("tools");

const Runtime = @import("Runtime.zig");

pub const log_level: std.log.Level = .info;

pub const std_options = .{
    .logFn = writeLog,
};

fn writeLog(
    comptime lvl: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (lvl == log_level) {
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

pub const GlobalState = struct {
    runtime: *Runtime,
    session: *game.GameSession,
};

pub export fn eventHandler(playdate: *api.PlaydateAPI, event: api.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            playdate_error_to_console = playdate.system.@"error";
            playdate_log_to_console = playdate.system.logToConsole;

            var state: *GlobalState = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(GlobalState))));
            state.runtime = Runtime.create(playdate) catch
                @panic("Error on creating Runtime");
            state.session = game.GameSession.create(state.runtime.any()) catch
                @panic("Error on creating game session");

            playdate.display.setRefreshRate(0);
            playdate.system.setUpdateCallback(updateAndRender, state);
        },
        else => {},
    }
    return 0;
}

fn updateAndRender(userdata: ?*anyopaque) callconv(.C) c_int {
    const state: *GlobalState = @ptrCast(@alignCast(userdata.?));
    // state.runtime.playdate.graphics.clear(@intFromEnum(api.LCDSolidColor.ColorBlack));

    state.session.tick() catch |err|
        std.debug.panic("Error {any} on game tick", .{err});

    //returning 1 signals to the OS to draw the frame.
    return 1;
}
