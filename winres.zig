const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").ui.windows_and_messaging;
};
const win32fix = struct {
    // workaround the unaligned pointer issue: https://github.com/marlersoft/zigwin32gen/issues/9
    pub extern "kernel32" fn FindResourceW(
        hModule: ?win32.HINSTANCE,
        lpName: ?[*:0]align(1) const u16,
        lpType: ?[*:0]align(1) const u16,
    ) callconv(@import("std").os.windows.WINAPI) ?win32.HRSRC;
    // workaround the unaligned pointer issue: https://github.com/marlersoft/zigwin32gen/issues/9
    // also: this adds "const" to lpData
    pub extern "kernel32" fn UpdateResourceW(
        hUpdate: ?win32.HANDLE,
        lpType: ?[*:0]align(1) const u16,
        lpName: ?[*:0]align(1) const u16,
        wLanguage: u16,
        lpData: ?*const anyopaque,
        cb: u32,
    ) callconv(@import("std").os.windows.WINAPI) win32.BOOL;
};

const global = struct {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn fatalTrace(trace: ?*std.builtin.StackTrace, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    if (trace) |t| {
        std.debug.dumpStackTrace(t.*);
    } else {
        std.log.err("no error return trace", .{});
    }
    std.process.exit(0xff);
}

const predefined_names_for_usage = blk: {
    var names: []const u8 = "";

    const line_prefix = "   ";
    var next_sep: []const u8 = line_prefix;
    var line_len: usize = 0;
    for (std.meta.fields(IntResType)) |field| {
        line_len += next_sep.len + 1 + field.name.len;
        if (line_len >= 80) {
            next_sep = "\n" ++ line_prefix;
            line_len = line_prefix.len + field.name.len;
        }
        names = names ++ next_sep ++ ":" ++ field.name;
        next_sep = " ";
    }
    break :blk names ++ "\n";
};

pub fn main() !void {
    const all_args = std.process.argsAlloc(global.arena) catch |e|
        fatalTrace(@errorReturnTrace(), "failed to get cmdline args with {s}", .{@errorName(e)});
    if (all_args.len <= 1)
        return try std.io.getStdErr().writer().writeAll(
            \\Usage:
            \\   winres list <FILE>
            \\   winres get <FILE> <TYPE> <NAME>
            \\   winres update <FILE> <TYPE> <NAME> [--file|--data] <FILE_OR_DATA>
            \\
            \\A resource <TYPE> or <NAME> can be one of:
            \\  * an unsigned integer
            \\  * a predefined name of the form ":name" (i.e. :cursor or :rcdata)
            \\  * otherwise, it'll be interpreted as a string name
            \\
            \\Predefined resource types:
            \\
            ++
            predefined_names_for_usage);

    const cmd = all_args[1];
    const cmd_args = all_args[2..];

    if (std.mem.eql(u8, cmd, "list")) {
        try list(cmd_args);
    } else if (std.mem.eql(u8, cmd, "get")) {
        try get(cmd_args);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try update(cmd_args);
    } else fatal("unknown command '{s}'", .{cmd});
}

pub fn sliceToFileW(path: []const u8) !std.os.windows.PathSpace {
    var temp_path: std.os.windows.PathSpace = undefined;
    temp_path.len = try std.unicode.utf8ToUtf16Le(&temp_path.data, path);
    temp_path.data[temp_path.len] = 0;
    return temp_path;
}

pub fn resPtrAsInt(res_ptr: ?[*:0]align(1) const u16) ?u16 {
    const res_int: u16 = @intCast(0xffff & @intFromPtr(res_ptr));
    return if (res_int == @intFromPtr(res_ptr)) res_int else null;
}

const IntResType = enum(u16) {
    cursor = 1,
    bitmap = 2,
    icon = 3,
    menu = 4,
    dialog = 5,
    string = 6,
    fontdir = 7,
    font = 8,
    accelerator = 9,
    rcdata = 10,
    messagetable = 11,
    group_cursor = 12,
    group_icon = 14,
    version = 16,
    dlginclude = 17,
    plugplay = 19,
    vxd = 20,
    anicursor = 21,
    aniicon = 22,
    html = 23,
    manifest = 24,
    _,

    pub fn tryFrom(res_type_ptr: ?[*:0]align(1) const u16) ?IntResType {
        return if (resPtrAsInt(res_type_ptr)) |int| @enumFromInt(int) else null;
    }

    pub fn asPtr(self: IntResType) ?[*:0]align(1) const u16 {
        return @ptrFromInt(@intFromEnum(self));
    }

    pub fn str(self: IntResType) ?[]const u8 {
        return switch (self) {
            .cursor => "cursor",
            .bitmap => "bitmap",
            .icon => "icon",
            .menu => "menu",
            .dialog => "dialog",
            .string => "string",
            .fontdir => "fontdir",
            .font => "font",
            .accelerator => "accelerator",
            .rcdata => "rcdata",
            .messagetable => "messagetable",
            .group_cursor => "group_cursor",
            .group_icon => "group_icon",
            .version => "version",
            .dlginclude => "dlginclude",
            .plugplay => "plugplay",
            .vxd => "vxd",
            .anicursor => "anicursor",
            .aniicon => "aniicon",
            .html => "html",
            .manifest => "manifest",
            else => null,
        };
    }
};

fn parseAllocResName(allocator: std.mem.Allocator, arg: []const u8) error{
    Overflow,
    OutOfMemory,
    InvalidUtf8,
}!?[*:0]align(1) const u16 {
    if (std.fmt.parseInt(u16, arg, 10)) |int_value| {
        return @ptrFromInt(int_value);
    } else |err| switch (err) {
        error.Overflow => |e| return e,
        error.InvalidCharacter => {},
    }
    return try std.unicode.utf8ToUtf16LeWithNull(allocator, arg);
}
fn parseAllocResType(allocator: std.mem.Allocator, arg: []const u8) error{
    NotPredefined,
    Overflow,
    OutOfMemory,
    InvalidUtf8,
}!?[*:0]align(1) const u16 {
    const predefined_prefix = ":";

    // TODO: allow use of "::" to specify a string that starts with a ":"
    if (std.mem.startsWith(u8, arg, predefined_prefix)) {
        const predefined_name = arg[predefined_prefix.len..];
        // TODO: a map might be better?
        inline for (std.meta.fields(IntResType)) |field| {
            if (std.mem.eql(u8, field.name, predefined_name))
                return @as(IntResType, @enumFromInt(field.value)).asPtr();
        }
        return error.NotPredefined;
    }

    return parseAllocResName(allocator, arg);
}
fn freeResPtr(allocator: std.mem.Allocator, ptr: ?[*:0]align(1) const u16) void {
    if (resPtrAsInt(ptr)) |_| return;
    allocator.free(std.mem.span(@as([*:0]const u16, @alignCast(ptr.?))));
}

const ResTypeFormatter = struct {
    ptr: ?[*:0]align(1) const u16,
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
            try writer.print("{}({s})", .{ @intFromEnum(t), str });
        } else {
            const ptr: [*:0]const u16 = @alignCast(self.ptr orelse unreachable);
            const str = std.mem.span(ptr);
            try writer.print("\"{}\"", .{std.unicode.fmtUtf16le(str)});
        }
    }
};

const ResNameFormatter = struct {
    ptr: ?[*:0]align(1) const u16,
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
            const ptr: [*:0]const u16 = @alignCast(self.ptr orelse unreachable);
            const str = std.mem.span(ptr);
            try writer.print("\"{}\"", .{std.unicode.fmtUtf16le(str)});
        }
    }
};

fn list(args: []const [:0]const u8) !void {
    if (args.len != 1)
        fatal("list requires 1 argument (a binary filename) but got {}", .{args.len});
    const filename = args[0];
    const mod = blk: {
        const filename_w = try sliceToFileW(filename);
        break :blk win32.LoadLibraryW(filename_w.span()) orelse
            fatal("LoadLibrary '{s}' failed, error={}", .{ filename, win32.GetLastError() });
    };
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
    res_type: ?[*:0]align(1) const u16,
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

fn get(args: []const [:0]const u8) !void {
    if (args.len != 3)
        fatal("get requires 3 arguments (file/type/name) but got {}", .{args.len});
    const filename = args[0];
    const type_arg = args[1];
    const name_arg = args[2];

    const type_ptr = parseAllocResType(global.arena, type_arg) catch |e|
        fatal("invalid resource type '{s}': {s}", .{ type_arg, @errorName(e) });
    defer freeResPtr(global.arena, type_ptr);
    const name_ptr = parseAllocResName(global.arena, name_arg) catch |e|
        fatal("invalid resource name '{s}': {s}", .{ name_arg, @errorName(e) });
    defer freeResPtr(global.arena, name_ptr);

    const mod = blk: {
        const filename_w = try sliceToFileW(filename);
        break :blk win32.LoadLibraryW(filename_w.span()) orelse
            fatal("LoadLibrary '{s}' failed, error={}", .{ filename, win32.GetLastError() });
    };
    // no need to free library, this is all temporary

    const loc = win32fix.FindResourceW(mod, name_ptr, type_ptr) orelse
        fatal("FindResource failed with {s}", .{@tagName(win32.GetLastError())});

    const len = win32.SizeofResource(mod, loc);
    if (len == 0)
        fatal("SizeofResource failed with {s}", .{@tagName(win32.GetLastError())});

    const res = win32.LoadResource(mod, loc);
    if (res == 0)
        fatal("LoadResource failed with {s}", .{@tagName(win32.GetLastError())});

    const ptr: [*]u8 = @ptrCast(win32.LockResource(res) orelse
        fatal("LockResource failed with {s}", .{@tagName(win32.GetLastError())}));
    try std.io.getStdOut().writer().writeAll(ptr[0..len]);
}

fn update(args: []const [:0]const u8) !void {
    if (args.len != 5)
        fatal("update requires 5 arguments (file/type/name/data_kind/data_arg) but got {}", .{args.len});

    const filename = args[0];
    const type_arg = args[1];
    const name_arg = args[2];

    const DataKind = enum { content, file };
    const data: struct { kind: DataKind, arg: []const u8 } = blk: {
        const data_kind = args[3];
        if (std.mem.eql(u8, data_kind, "--data"))
            break :blk .{ .kind = .content, .arg = args[4] };
        if (std.mem.eql(u8, data_kind, "--file"))
            break :blk .{ .kind = .file, .arg = args[4] };
        fatal("unknown data option '{s}' (expected '--data' or '--file')", .{data_kind});
    };

    const type_ptr = parseAllocResType(global.arena, type_arg) catch |e|
        fatal("invalid resource type '{s}': {s}", .{ type_arg, @errorName(e) });
    defer freeResPtr(global.arena, type_ptr);
    const name_ptr = parseAllocResName(global.arena, name_arg) catch |e|
        fatal("invalid resource name '{s}': {s}", .{ name_arg, @errorName(e) });
    defer freeResPtr(global.arena, name_ptr);

    const update_bin = blk: {
        const filename_w = try sliceToFileW(filename);
        break :blk win32.BeginUpdateResourceW(filename_w.span(), 0) orelse
            fatal("BeginUpdateResource '{s}' failed with {s}", .{ filename, @tagName(win32.GetLastError()) });
    };

    const content = blk: {
        switch (data.kind) {
            .content => break :blk data.arg,
            .file => {
                var file = std.fs.cwd().openFile(data.arg, .{}) catch |err|
                    fatal("open '{s}' failed with {s}", .{ data.arg, @errorName(err) });
                defer file.close();
                // TODO: use mmap instead, should be faster
                break :blk try file.readToEndAlloc(global.arena, std.math.maxInt(usize));
            },
        }
    };

    if (0 == win32fix.UpdateResourceW(
        update_bin,
        type_ptr,
        name_ptr,
        0, // language, is this neutral?
        @ptrCast(content.ptr),
        @intCast(content.len),
    ))
        fatal("UpdateResource failed with {s}", .{@tagName(win32.GetLastError())});

    if (0 == win32.EndUpdateResourceW(update_bin, 0))
        fatal("EndUpdateResource failed with {s}", .{@tagName(win32.GetLastError())});

    std.log.info("Success", .{});
}
