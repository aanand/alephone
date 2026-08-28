//
//  MetalRenderer.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef MetalRenderer_h
#define MetalRenderer_h

#import <Foundation/NSObject.h>
#include <simd/simd.h>

#include <SDL2/SDL.h>

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

- (void) updateViewWithFOV:(float)fov;

- (void) begin;
- (void) addQuadWithVertices:(simd_long3*)vertices;
- (void) addPolygonWithVertices:(simd_long3*)vertices count:(int)vertexCount;
- (void) end;

@end

#endif /* MetalRenderer_h */
