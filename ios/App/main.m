#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <openttd_ios.h>

int main(int argc, char *argv[])
{
	char data_error[512] = "";
	if (!OpenTTDIOSPrepareDocuments(data_error, sizeof(data_error))) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "IOS_ENGINE data preparation failed: %s", data_error);
		return 1;
	}
	if (!OpenTTDIOSValidateDocuments(data_error, sizeof(data_error))) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "IOS_ENGINE data validation failed: %s", data_error);
		return 1;
	}
	SDL_Log("IOS_ENGINE DATA root=%s", OpenTTDIOSGetDocumentsPath());

	SDL_SetAppMetadata("OpenTTD", "0.1", "com.example.openttd");
	SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
	SDL_Log("IOS_ENGINE START revision=%s", OpenTTDIOSGetEngineRevision());
	return OpenTTDIOSMain(argc, argv);
}
