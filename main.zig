const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").ui.windows_and_messaging;
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

pub fn fatalTrace(trace: ?*std.builtin.StackTrace, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    if (trace) |t| {
        std.debug.dumpStackTrace(t.*);
    } else {
        std.log.err("no error return trace", .{});
    }
    std.os.exit(0xff);
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = std.process.argsAlloc(arena) catch |e|
        fatalTrace(@errorReturnTrace(), "failed to get cmdline args with {s}", .{@errorName(e)});
    if (all_args.len <= 1)
        return try std.io.getStdErr().writer().writeAll(
            \\Usage:
            \\   winres list <FILE>
            \\
        );

    const cmd = all_args[1];
    const cmd_args = all_args[2..];

    if (std.mem.eql(u8, cmd, "list")) {
        try list(cmd_args);
    } else fatal("unknown command '{s}'", .{cmd});
}

pub fn resPtrAsInt(res_ptr: ?[*:0]const u16) ?u16 {
    const res_int: u16 = @intCast(0xffff & @intFromPtr(res_ptr));
    return if (res_int == @intFromPtr(res_ptr)) res_int else null;
}

const IntResType = enum (u16) {
    cursor        = 1,
    bitmap        = 2,
    icon          = 3,
    menu          = 4,
    dialog        = 5,
    string        = 6,
    fontdir       = 7,
    font          = 8,
    accelerator   = 9,
    rcdata        = 10,
    messagetable  = 11,
    group_cursor  = 12,
    group_icon    = 14,
    version       = 16,
    dlginclude    = 17,
    plugplay      = 19,
    vxd           = 20,
    anicursor     = 21,
    aniicon       = 22,
    html          = 23,
    manifest      = 24,
    _,

    pub fn tryFrom(res_type_ptr: ?[*:0]const u16) ?IntResType {
        return if (resPtrAsInt(res_type_ptr)) |int| @enumFromInt(int) else null;
    }

    pub fn str(self: IntResType) ?[]const u8 {
        return switch (self) {
            .cursor        => "cursor",
            .bitmap        => "bitmap",
            .icon          => "icon",
            .menu          => "menu",
            .dialog        => "dialog",
            .string        => "string",
            .fontdir       => "fontdir",
            .font          => "font",
            .accelerator   => "accelerator",
            .rcdata        => "rcdata",
            .messagetable  => "messagetable",
            .group_cursor  => "group_cursor",
            .group_icon    => "group_icon",
            .version       => "version",
            .dlginclude    => "dlginclude",
            .plugplay      => "plugplay",
            .vxd           => "vxd",
            .anicursor     => "anicursor",
            .aniicon       => "aniicon",
            .html          => "html",
            .manifest      => "manifest",
            else => null,
        };
    }
};

const ResTypeFormatter = struct {
    ptr: ?[*:0]const u16,
    pub fn format(
        self: ResTypeFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        if (IntResType.tryFrom(self.ptr)) |t| {
            const str: []const u8 = t.str() orelse "?";
            try writer.print("{}({s})", .{@intFromEnum(t), str});
        } else {
            const str = std.mem.span(self.ptr orelse unreachable);
            try writer.print("\"{}\"", .{std.unicode.fmtUtf16le(str)});
        }
    }
};

const ResNameFormatter = struct {
    ptr: ?[*:0]const u16,
    pub fn format(
        self: ResNameFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        if (resPtrAsInt(self.ptr)) |int| {
            try writer.print("{}", .{int});
        } else {
            const name_str = std.mem.span(self.ptr orelse unreachable);
            try writer.print("\"{}\"", .{std.unicode.fmtUtf16le(name_str)});
        }
    }
};

fn list(args: []const [:0]const u8) !void {
    if (args.len != 1)
        fatal("list requires 1 argument (a binary filename) but got {}", .{args.len});
    const filename = args[0];
    // NOTE: I had an issue trying to use LoadLibraryW
    const mod = win32.LoadLibraryA(filename) orelse
        fatal("LoadLibrary '{s}' failed, error={}", .{filename, win32.GetLastError()});
    // no need to free library, this is all temporary

    if (0 == win32.EnumResourceTypesW(mod, &listOnEnumTypeW, 0)) {
        const err = win32.GetLastError();
        if (err == .ERROR_RESOURCE_DATA_NOT_FOUND) {
            std.log.info("this file has no resources", .{});
            return;
        }
        fatal("EnumResourceTypes failed, error={}", .{win32.GetLastError()});
    }
}

fn listOnEnumTypeW(
    mod: ?win32.HINSTANCE,
    res_type_ptr: ?[*:0]u16,
    param: isize,
) callconv(@import("std").os.windows.WINAPI) win32.BOOL {
    _ = param;
    if (0 == win32.EnumResourceNamesExW(mod, res_type_ptr, &listOnEnumNameW, 0, 0, 0))
        fatal("EnumResourceNames failed, error={}", .{win32.GetLastError()});
    return 1; // continue enumeration
}

fn listOnEnumNameW(
    mod: ?win32.HINSTANCE,
    res_type: ?[*:0]const u16,
    name: ?[*:0]u16,
    param: isize,
) callconv(@import("std").os.windows.WINAPI) win32.BOOL {
    _ = mod;
    _ = param;
    // TODO: write to buffered writer instead
    std.io.getStdOut().writer().print("Type={} Name={}\n", .{
        ResTypeFormatter{ .ptr = res_type },
        ResNameFormatter{ .ptr = name },
    }) catch |e| fatalTrace(@errorReturnTrace(), "stdout print failed with {s}", .{@errorName(e)});
    return 1; // continue enumeration
}
