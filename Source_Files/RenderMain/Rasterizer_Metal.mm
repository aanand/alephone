//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include "Rasterizer_Metal.h"
#include "Logging.h"

#include "Metal/MetalRenderer.h"

#include <simd/simd.h>

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

void Rasterizer_Metal_Class::Begin() {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer begin];
		}
	}
}

void Rasterizer_Metal_Class::End() {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer end];
		}
	}
}

void RenderRasterize_Metal::render_node_side(
							  clipping_window_data *window, vertical_surface_data *surface,
							  bool void_present, RenderStep renderStep) {
	simd_long3 vertices[4];
	
	vertices[0] = simd_make_long3(surface->p0.i, surface->p0.j, surface->h0);
	vertices[1] = simd_make_long3(surface->p1.i, surface->p1.j, surface->h0);
	vertices[2] = simd_make_long3(surface->p1.i, surface->p1.j, surface->h1);
	vertices[3] = simd_make_long3(surface->p0.i, surface->p0.j, surface->h1);
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addQuadWithVertices:vertices];
		}
	}
}
