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

@interface MetalPolygon : NSObject

/**
 Vertices should be in world-space, i.e. X=east, Y=north, Z=up (away from the ground).
 */
@property (nonatomic, readonly) WorldVertex* vertices;
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float3 emission;
@property (nonatomic, readonly) simd_float3 normal;

- (MetalPolygon*) initWithVertices:(WorldVertex *)vertices
					   vertexCount:(NSUInteger)vertexCount
						 textureID:(NSString*)textureID
						  emission:(simd_float3)emission
						  normal:(simd_float3)normal;

@end

@interface MetalSprite : NSObject

@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float4x2 uv;
@property (nonatomic, readonly) simd_int2 size;
@property (nonatomic, readonly) simd_int3 position;

- (MetalSprite*) initWithIndex:(NSInteger)index
					 textureID:(NSString*)textureID
							uv:(simd_float4x2)uv
						  size:(simd_int2)size
					  position:(simd_int3)position;

@end

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

/**
 Rendering
 */

- (void) updateViewWithOrigin:(simd_int3)origin
						pitch:(float)pitch
						  yaw:(float)yaw
						  FOV:(float)fov;

- (void) begin;
- (void) end;

/**
 Geometry
 */

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;

- (void) addStaticPolygon:(MetalPolygon*)polygon;
- (void) updateSprite:(MetalSprite*)sprite;

/**
 Textures
 */

- (bool) hasTextureWithID:(NSString*)textureID;
- (void) addTextureWithID:(NSString*)textureID image:(MetalImage*)image;

@end

#endif /* MetalRenderer_h */
