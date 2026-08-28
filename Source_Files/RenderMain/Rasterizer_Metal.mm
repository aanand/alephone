//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include "Logging.h"

#include "Metal/MetalRenderer.h"

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;

bool Metal_InitializeForWindow(SDL_Window* window, int width, int height) {
    logWarning("Metal_InitializeForWindow(window, %d, %d)", width, height);

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			return true;
		}
		
		MetalRenderer *r = [[MetalRenderer alloc] initializeWithWindow:window width:width height:height];
		if (!r) {
			logWarning("Failed to initialize MetalRenderer");
			return false;
		}
		renderer = r;

		logWarning("Initialized MetalRenderer");
		return true;
	}

	logWarning("Metal 4 not supported");
	return false;
}

void Metal_Begin() {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer drawFrame];
		}
	}
}
