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

#include "Metal/VertexTypes.h"

@interface MetalImage : NSObject

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSData* data;

- (MetalImage*) initWithWidth:(NSUInteger)width height:(NSUInteger)height pixels:(const uint32*)pixels;

@end

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

- (void) updateViewWithOrigin:(simd_int3)origin
						pitch:(float)pitch
						  yaw:(float)yaw
						  FOV:(float)fov;

- (void) begin;
- (void) end;

/**
 Vertices should be in world-space, i.e. X=east, Y=north, Z=up (away from the ground).
 */
- (void) addPolygonWithVertices:(WorldVertex *)vertices
						  count:(NSUInteger)vertexCount
					  textureID:(NSString*)textureID
					   emission:(simd_float3)emission;

- (void) commitGeometry;
- (void) clearGeometry;

- (bool) hasTextureWithID:(NSString*)textureID;
- (void) addTextureWithID:(NSString*)textureID image:(MetalImage*)image;

@end

#endif /* MetalRenderer_h */
