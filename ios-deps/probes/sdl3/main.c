#include <SDL3/SDL.h>

int main(void)
{
	return SDL_GetVersion() < SDL_VERSIONNUM(3, 4, 10);
}

