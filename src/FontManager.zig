const std = @import("std");
const freetype = @import("mach-freetype");
const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

const Self = @This();

const Font = struct {
    ft_face: freetype.Face,
};

ft_library: freetype.Library,
fc_config: *c.FcConfig,
loaded_fonts: std.StringArrayHashMap(Font),

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .ft_library = try freetype.Library.init(),
        .fc_config = c.FcInitLoadConfigAndFonts() orelse
            return error.FcInitFailed,
        .loaded_fonts = std.StringArrayHashMap(Font).init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    c.FcConfigDestroy(self.fc_config);
    c.FcFini();
    self.ft_library.deinit();
    self.loaded_fonts.deinit();

    self.* = undefined;
}

pub fn getFontIndex(self: *const Self, name: []const u8) ?u16 {
    if (self.loaded_fonts.getIndex(name)) |idx|
        return @as(u16, @intCast(idx));
    return null;
}

pub fn loadFont(self: *Self, name: [:0]const u8) !u16 {
    const pat = c.FcNameParse(name) orelse return error.FcNameParseFailed;
    if (c.FcConfigSubstitute(self.fc_config, pat, c.FcMatchPattern) != c.FcTrue)
        return error.OutOfMemory;
    c.FcDefaultSubstitute(pat);

    var result: c.FcResult = undefined;
    const font = c.FcFontMatch(self.fc_config, pat, &result) orelse {
        return error.FcNoFontFound;
    };

    // The filename holding the font relative to the config's sysroot
    var path: ?[*:0]u8 = undefined;
    if (c.FcPatternGetString(font, c.FC_FILE, 0, &path) != c.FcResultMatch) {
        return error.FcPatternGetFailed;
    }

    // The index of the font within the file
    var index: c_int = undefined;
    if (c.FcPatternGetInteger(font, c.FC_INDEX, 0, &index) != c.FcResultMatch) {
        return error.FcPatternGetFailed;
    }

    const ft_face = try self.ft_library.createFace(path orelse unreachable, index);

    // TODO: find better value to use as key here. The fontconfig search pattern
    //       string is not reliable as it implies certain default values and is
    //       not portable across other font matching libs we'll eventually have
    //       to option to use.
    const gop = try self.loaded_fonts.getOrPut(name);
    if (gop.found_existing)
        @panic("TODO");
    gop.value_ptr.* = .{
        .ft_face = ft_face,
    };
    return @as(u16, @intCast(gop.index));
}

pub fn getOrLoadFont(self: *Self, name: [:0]const u8) !u16 {
    if (self.getFontIndex(name)) |idx| {
        return idx;
    }
    return self.loadFont(name);
}

pub fn getFont(self: *const Self, idx: u16) *Font {
    return &self.loaded_fonts.values()[idx];
}
