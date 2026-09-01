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

- (void) updateViewWithFOV:(float)fov pitch:(float)pitch yaw:(float)yaw;

- (void) begin;

- (void) addPolygonWithVertices:(Vertex *)vertices count:(NSUInteger)vertexCount;
- (void) addPolygonWithVertices:(Vertex *)vertices count:(NSUInteger)vertexCount textureID:(NSNumber*)textureID;

- (bool) hasTextureWithID:(NSNumber*)textureID;
- (void) addTextureWithID:(NSNumber*)textureID image:(MetalImage*)image;

- (void) end;

@end

#endif /* MetalRenderer_h */
