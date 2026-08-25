//
//  Rasterizer_Metal.h
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#ifndef Rasterizer_Metal_h
#define Rasterizer_Metal_h

extern bool Metal_InitializeForWindow(SDL_Window* window, int w, int h);
extern bool Metal_Shutdown();
extern void Metal_BeginFrame();
extern void Metal_EndFrameAndPresent();
extern void Metal_Resize(int w, int h);

#endif /* Rasterizer_Metal_h */
