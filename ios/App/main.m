#include <stdlib.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <openttd_ios.h>

static NSString *const NOTICE_ACKNOWLEDGED_KEY = @"UnofficialPortNoticeAcknowledged";

/* Presents the unofficial-port notice over the engine's window once it is shown; the engine keeps starting behind it. */
static bool SDLCALL ShowNoticeOnWindowShown(void *userdata, SDL_Event *event)
{
	if (event->type != SDL_EVENT_WINDOW_SHOWN) return true;
	SDL_RemoveEventWatch(ShowNoticeOnWindowShown, userdata);

	SDL_PropertiesID properties = SDL_GetWindowProperties(SDL_GetWindowFromEvent(event));
	UIWindow *window = (__bridge UIWindow *)SDL_GetPointerProperty(properties, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
			message:@"This is an unofficial port of OpenTTD. Please don't bug the good people on the OpenTTD Forums about it."
			preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction *understood = [UIAlertAction actionWithTitle:@"I understand." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[NSUserDefaults.standardUserDefaults setBool:YES forKey:NOTICE_ACKNOWLEDGED_KEY];
			SDL_Log("IOS_NOTICE acknowledged");
		}];
		[alert addAction:understood];
		alert.preferredAction = understood;
		[window.rootViewController presentViewController:alert animated:YES completion:nil];
		SDL_Log("IOS_NOTICE shown");
	});
	return true;
}

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
	if (![NSUserDefaults.standardUserDefaults boolForKey:NOTICE_ACKNOWLEDGED_KEY]) SDL_AddEventWatch(ShowNoticeOnWindowShown, NULL);
	SDL_Log("IOS_ENGINE START revision=%s", OpenTTDIOSGetEngineRevision());
	OpenTTDIOSMain(argc, argv);
	/* SDL's UIKit run loop outlives main and would leave a black screen; quit like the desktop ports. */
	exit(0);
}
