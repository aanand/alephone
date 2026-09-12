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

@interface MetalSurface : NSObject

@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float3 emission;
@property (nonatomic, readonly) simd_float3 normal;

- (MetalSurface*) initWithTextureID:(NSString*)textureID
						   emission:(simd_float3)emission
							 normal:(simd_float3)normal;

@end

/**
 A horizontal polygon (floor or ceiling).
 Vertices are in world-space, i.e. X=east, Y=south.
 */
@interface MetalPolygon : NSObject

@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) simd_int2* vertices;
@property (nonatomic, readonly) simd_float2* uv;
@property (nonatomic, readonly) int height;
@property (nonatomic, readonly) MetalSurface *surface;

- (MetalPolygon*) initWithVertexCount:(NSUInteger)vertexCount
							 vertices:(simd_int2*)vertices
								   uv:(simd_float2*)uv
							   height:(int)height
							  surface:(MetalSurface*)surface;

@end

/**
 A vertical rectangle.
 Vertices are in world-space, i.e. X=east, Y=south.
 Does not correspond 1-1 to Marathon map walls: where those can be "split-side" and have a high and low rect, this is always a single rect.
 */
@interface MetalWall : NSObject

@property (nonatomic, readonly) simd_int2 v0;
@property (nonatomic, readonly) simd_int2 v1;
@property (nonatomic, readonly) int bottom;
@property (nonatomic, readonly) int top;
@property (nonatomic, readonly) simd_float4x2 uv;
@property (nonatomic, readonly) MetalSurface *surface;

- (MetalWall*) initWithV0:(simd_int2)v0
					   v1:(simd_int2)v1
				   bottom:(int)bottom
					  top:(int)top
					   uv:(simd_float4x2)uv
				  surface:(MetalSurface*)surface;

@end

@interface MetalSprite : NSObject

@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) simd_float4x2 uv;
@property (nonatomic, readonly) simd_int2 size;
@property (nonatomic, readonly) simd_int3 position;
@property (nonatomic, readonly) MetalSurface *surface;

- (MetalSprite*) initWithIndex:(NSInteger)index
							uv:(simd_float4x2)uv
						  size:(simd_int2)size
					  position:(simd_int3)position
					   surface:(MetalSurface*)surface;

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
- (void) addStaticWall:(MetalWall*)wall;
- (void) updateSprite:(MetalSprite*)sprite;

/**
 Textures
 */

- (bool) hasTextureWithID:(NSString*)textureID;
- (void) addTextureWithID:(NSString*)textureID image:(MetalImage*)image;

@end

#endif /* MetalRenderer_h */
