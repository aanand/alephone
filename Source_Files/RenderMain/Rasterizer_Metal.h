//
//  Rasterizer_Metal.h
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#ifndef Rasterizer_Metal_h
#define Rasterizer_Metal_h

#if defined(__MACH__) && defined(__APPLE__)
#define USE_METAL
#endif

extern bool Metal_InitializeForWindow(SDL_Window* window);
extern bool Metal_DrawFrame();

#endif /* Rasterizer_Metal_h */
