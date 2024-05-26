const c = @cImport({
    @cInclude("3ds.h");
});
const system = @import("3ds/system.zig");

pub export fn main(_: c_int, _: [*]const [*:0]const u8) void {
    c.gfxInitDefault();
    defer c.gfxExit();
    
    // printf is from portlibs :/
    // same as consoleInit

    while (c.aptMainLoop()) {
        c.gspWaitForVBlank(); // may require a c wrapper
        c.gfxSwapBuffers();
    }
}