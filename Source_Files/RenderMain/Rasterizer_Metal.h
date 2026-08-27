//
//  Rasterizer_Metal.h
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#ifndef Rasterizer_Metal_h
#define Rasterizer_Metal_h

#if defined(__MACH__) && defined(__APPLE__)
#define PREFER_METAL
#endif

#include "Rasterizer.h"
#include "RenderRasterize.h"

extern bool Metal_InitializeForWindow(SDL_Window* window);

bool Metal_Begin();

class Rasterizer_Metal_Class : public RasterizerClass {
	void Begin() {
		Metal_Begin();
	}
};

class RenderRasterize_Metal : public RenderRasterizerClass {
};

#endif /* Rasterizer_Metal_h */
