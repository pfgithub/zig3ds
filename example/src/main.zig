const c = @cImport({
    @cInclude("3ds.h");
    @cInclude("stdio.h");
});

export fn main(argc: c_int, argv: [*][*]u8) c_int {
    _ = argc;
    _ = argv;

    c.gfxInitDefault();
    defer c.gfxExit();

    _ = c.consoleInit(c.GFX_TOP, null);
    _ = c.printf("\x1b[16;20HHello World!");
    _ = c.printf("\x1b[30;16HPress Start to exit.");

    while (c.aptMainLoop()) {
        c.hidScanInput();
        const k_down: u32 = c.hidKeysDown();

        if (k_down & c.KEY_START != 0) break;

        c.gfxFlushBuffers();
        c.gfxSwapBuffers();

        // c.gspWaitForVBlank();
        c.gspWaitForEvent(c.GSPGPU_EVENT_VBlank0, true);
    }

    return 0;
}
