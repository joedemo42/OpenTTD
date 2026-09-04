#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <openttd_ios.h>

#include <string.h>

static bool WatchLifecycle(void *userdata, SDL_Event *event)
{
	(void)userdata;
	switch (event->type) {
		case SDL_EVENT_TERMINATING:
		case SDL_EVENT_LOW_MEMORY:
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
		case SDL_EVENT_WILL_ENTER_FOREGROUND:
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			SDL_Log("IOS_PROBE lifecycle event=%u", event->type);
			break;
		default:
			break;
	}
	return true;
}

static void DrawProbe(SDL_Renderer *renderer)
{
	const Uint64 ticks = SDL_GetTicks();
	const float offset = (float)((ticks / 12) % 128);
	SDL_SetRenderDrawColor(renderer, 26, 44, 63, 255);
	SDL_RenderClear(renderer);

	SDL_SetRenderDrawColor(renderer, 36, 62, 86, 255);
	for (int x = -128; x < 1152; x += 128) {
		SDL_FRect stripe = {(float)x + offset, 0.0f, 64.0f, 768.0f};
		SDL_RenderFillRect(renderer, &stripe);
	}

	SDL_SetRenderDrawColor(renderer, 82, 165, 74, 255);
	SDL_FRect ground = {0.0f, 532.0f, 1024.0f, 236.0f};
	SDL_RenderFillRect(renderer, &ground);

	SDL_SetRenderDrawColor(renderer, 239, 191, 55, 255);
	SDL_FRect vehicle = {350.0f, 384.0f, 324.0f, 116.0f};
	SDL_RenderFillRect(renderer, &vehicle);
	SDL_SetRenderDrawColor(renderer, 176, 48, 48, 255);
	SDL_FRect cab = {566.0f, 332.0f, 108.0f, 168.0f};
	SDL_RenderFillRect(renderer, &cab);
	SDL_SetRenderDrawColor(renderer, 24, 31, 38, 255);
	SDL_FRect wheel_left = {390.0f, 478.0f, 72.0f, 72.0f};
	SDL_FRect wheel_right = {570.0f, 478.0f, 72.0f, 72.0f};
	SDL_RenderFillRect(renderer, &wheel_left);
	SDL_RenderFillRect(renderer, &wheel_right);

	SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
	SDL_RenderDebugText(renderer, 32.0f, 32.0f, "OpenTTD iOS / iPadOS");
	SDL_RenderDebugText(renderer, 32.0f, 48.0f, "SDL3 + Metal bring-up probe");
	SDL_RenderPresent(renderer);
}

int main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;
	SDL_SetAppMetadata("OpenTTD", "0.1", "com.example.openttd");
	SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
	SDL_SetEventFilter(WatchLifecycle, NULL);

	if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_EVENTS)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "IOS_PROBE SDL_Init failed: %s", SDL_GetError());
		return 1;
	}

	SDL_Window *window = NULL;
	SDL_Renderer *renderer = NULL;
	if (!SDL_CreateWindowAndRenderer("OpenTTD", 1024, 768,
			SDL_WINDOW_FULLSCREEN | SDL_WINDOW_HIGH_PIXEL_DENSITY,
			&window, &renderer)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "IOS_PROBE window creation failed: %s", SDL_GetError());
		SDL_Quit();
		return 2;
	}

	const char *renderer_name = SDL_GetRendererName(renderer);
	if (renderer_name == NULL || strcmp(renderer_name, "metal") != 0) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "IOS_PROBE expected Metal renderer, got %s",
			renderer_name == NULL ? "(null)" : renderer_name);
		SDL_DestroyRenderer(renderer);
		SDL_DestroyWindow(window);
		SDL_Quit();
		return 3;
	}

	SDL_SetRenderVSync(renderer, 1);
	SDL_SetRenderLogicalPresentation(renderer, 1024, 768, SDL_LOGICAL_PRESENTATION_LETTERBOX);
	int output_width = 0;
	int output_height = 0;
	SDL_GetCurrentRenderOutputSize(renderer, &output_width, &output_height);
	const char *documents = SDL_GetUserFolder(SDL_FOLDER_DOCUMENTS);
	SDL_Log("IOS_PROBE READY renderer=%s output=%dx%d documents=%s", renderer_name,
		output_width, output_height, documents == NULL ? "(unavailable)" : documents);
	SDL_Log("IOS_PROBE ENGINE revision=%s", OpenTTDIOSGetEngineRevision());

	bool running = true;
	while (running) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_TERMINATING) running = false;
		}
		DrawProbe(renderer);
		SDL_Delay(1);
	}

	SDL_Log("IOS_PROBE clean shutdown");
	SDL_DestroyRenderer(renderer);
	SDL_DestroyWindow(window);
	SDL_Quit();
	return 0;
}
