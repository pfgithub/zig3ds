#include <3ds.h>
#include <stdio.h>

int main(int argc, char **argv)
{
	gfxInitDefault();

	consoleInit(GFX_TOP, NULL);

	printf("\x1b[16;20HHello World!");

	printf("\x1b[30;16HPress Start to exit.");

	// Main loop
	while (aptMainLoop())
	{
		hidScanInput();
		u32 kDown = hidKeysDown();

		if (kDown & KEY_START) break;

		gfxFlushBuffers();
		gfxSwapBuffers();

		gspWaitForVBlank();
	}

	gfxExit();
	return 0;
}
