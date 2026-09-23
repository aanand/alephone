//
//  MetalTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 12/09/2026.
//

#ifndef MetalTypes_h
#define MetalTypes_h

#import <Foundation/NSObject.h>
#import <simd/simd.h>

#import "Shaders/ShaderTypes.h"

#pragma mark - Texture-related types

@interface MetalImage : NSObject

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSData* data;

- (MetalImage*) initWithWidth:(NSUInteger)width height:(NSUInteger)height pixels:(const uint32*)pixels;

@end

@interface MetalSurface : NSObject

@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float3 emission;
@property (nonatomic, readonly) float reflectivity;
@property (nonatomic, readonly) simd_float3 normal;
@property (nonatomic, readonly) int32_t lightSourceIndex;

- (MetalSurface*) initWithTextureID:(NSString*)textureID
						   emission:(simd_float3)emission
					   reflectivity:(float)reflectivity
							 normal:(simd_float3)normal
				   lightSourceIndex:(int32_t)lightSourceIndex;

@end

#pragma mark - Geometry utilities

/**
 A triangle, used by the rasterizer pipeline and when building batches of static geometry.
 */
@interface Triangle : NSObject

@property (nonatomic, readonly) WorldVertex v0;
@property (nonatomic, readonly) WorldVertex v1;
@property (nonatomic, readonly) WorldVertex v2;
@property (nonatomic, readonly) MetalSurface *surface;

- (Triangle *) initWithV0:(WorldVertex)v0
					   v1:(WorldVertex)v1
					   v2:(WorldVertex)v2
				  surface:(MetalSurface*)surface;

@end

#pragma mark - Raytracing primitives

/**
 A protocol for exporting data from some game object to a Primitive Acceleration Structure
 */
@protocol ASTrianglePrimitive <NSObject>

- (NSUInteger) numTriangles;
- (simd_float3*) vertices;
- (void*) primitiveData;

@end

/**
 A raytracing primitive that's just an arbitrary batch of wall/floor/ceiling triangles, instanced once.
 */
@interface TriangleBatch : NSObject <ASTrianglePrimitive>
- (TriangleBatch*) initWithTriangles:(NSArray<Triangle*>*)triangles;
@end

/**
 A raytracing primitive that's a vertically-oriented unit square on the YZ plane with the center of its base at (0, 0, 0).
 Used for sprites and moving walls (static walls are shoved into TriangleBatches instead for efficiency).
 */
@interface VerticalQuad : NSObject <ASTrianglePrimitive>
@end

/**
 A raytracing primitive that's a convex polygon on the XY plane at Z=0.
 Used for the tops and bottoms of moving platforms (static floors/ceilings go into TriangleBatches).
 */
@interface MetalPolygonPrimitive : NSObject <ASTrianglePrimitive>

- (MetalPolygonPrimitive*) initWithVertexCount:(NSUInteger)vertexCount
									  vertices:(simd_int2*)vertices
									   surface:(MetalSurface*)surface;

@end

#pragma mark - World geometry types

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

- (void) eachTriangle:(void (^)(Triangle *triangle))callback;
- (id<ASTrianglePrimitive>) primitive;
- (simd_float4x3) instanceTransform;

@end

/**
 A vertical rectangle in the world.
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

- (void) eachTriangle:(void (^)(Triangle *triangle))callback;
- (simd_float4x3) instanceTransform;

@end

/**
 An object, e.g. an enemy, powerup or piece of furniture.
 */
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

- (void) eachTriangle:(void (^)(Triangle *triangle))callback forRotation:(float)theta;
- (simd_float4x3) instanceTransformForRotation:(float)theta;

@end


#endif /* MetalTypes_h */
