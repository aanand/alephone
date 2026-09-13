//
//  MetalTypes.m
//  AlephOne
//
//  Created by Aanand Prasad on 12/09/2026.
//

#import <Foundation/Foundation.h>

#import "Metal/VertexTypes.h"
#import "Metal/MetalTypes.h"

@implementation Triangle

-(Triangle *)initWithV0:(WorldVertex)v0 v1:(WorldVertex)v1 v2:(WorldVertex)v2 surface:(MetalSurface *)surface
{
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_v2 = v2;
		_surface = surface;
	}
	return self;
}

@end

@implementation MetalImage

- (MetalImage*) initWithWidth:(NSUInteger)width height:(NSUInteger)height pixels:(const uint32 *)pixels {
	if (self = [super init]) {
		_width = width;
		_height = height;
		_data = [NSData dataWithBytes:pixels length:sizeof(uint32) * width * height];
	}
	return self;
}

@end

@implementation MetalSurface

-(MetalSurface *)initWithTextureID:(NSString *)textureID emission:(simd_float3)emission normal:(simd_float3)normal {
	if (self = [super init]) {
		_textureID = textureID;
		_emission = emission;
		_normal = normal;
	}
	return self;
}

@end

@implementation MetalPolygonPrimitive
{
	NSUInteger numTriangles;
	simd_float3 *vertices;
	TriangleRayTracingData *primitiveData;
}

-(MetalPolygonPrimitive *)initWithVertexCount:(NSUInteger)vertexCount vertices:(simd_int2 *)vs surface:(MetalSurface *)surface {
	if (self = [super init]) {
		numTriangles = vertexCount - 2;
		
		vertices = malloc(sizeof(simd_float3) * numTriangles * 3);
		primitiveData = malloc(sizeof(TriangleRayTracingData) * numTriangles);
		
		// Triangle fan: 0-1-2, 0-2-3, 0-3-4, ...
		for (int i = 0; i < numTriangles; i++) {
			vertices[i*3]   = (simd_float3){ vs[  0].x, vs[  0].y, 0.0 };
			vertices[i*3+1] = (simd_float3){ vs[i+1].x, vs[i+1].y, 0.0 };
			vertices[i*3+2] = (simd_float3){ vs[i+2].x, vs[i+2].y, 0.0 };
			primitiveData[i] = (TriangleRayTracingData){ .surfaceNormal = surface.normal, .emission = surface.emission };
		}
	}
	return self;
}

-(void)dealloc {
	free(vertices);
	free(primitiveData);
}

- (NSUInteger)numTriangles { return numTriangles; }
- (void *)primitiveData { return primitiveData; }
- (simd_float3 *)vertices { return vertices; }

@end

@implementation MetalPolygon

-(MetalPolygon *)initWithVertexCount:(NSUInteger)vertexCount vertices:(simd_int2 *)vertices uv:(simd_float2 *)uv height:(int)height surface:(MetalSurface *)surface
{
	if (self = [super init]) {
		_vertexCount = vertexCount;
		_vertices = malloc(sizeof(simd_int2)*vertexCount); memcpy(_vertices, vertices, sizeof(simd_int2)*vertexCount);
		_uv = malloc(sizeof(simd_float2)*vertexCount); memcpy(_uv, uv, sizeof(simd_float2)*vertexCount);
		_height = height;
		_surface = surface;
	}
	return self;
}

- (void)dealloc {
	free(_vertices);
	free(_uv);
}

-(id<ASTrianglePrimitive>)primitive {
	return [[MetalPolygonPrimitive alloc] initWithVertexCount:_vertexCount vertices:_vertices surface:_surface];
}

- (simd_float4x3) instanceTransform {
	return (simd_float4x3){
		.columns = {
			{ 1.0, 0.0, 0.0 },
			{ 0.0, 1.0, 0.0 },
			{ 0.0, 0.0, 1.0 },
			{ 0.0, 0.0, (float)_height },
		}
	};
}

- (WorldVertex) getWorldVertexAtIndex:(NSUInteger)vertexIdx {
	simd_int2 pos = _vertices[vertexIdx];
	return (WorldVertex){
		.position = simd_make_int3(pos.x, pos.y, _height),
		.textureCoordinate = _uv[vertexIdx],
	};
}

- (void) addTrianglesToArray:(NSMutableArray<Triangle*>*)triangles
{
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < _vertexCount - 2; j++) {
		[triangles addObject:[[Triangle alloc] initWithV0:[self getWorldVertexAtIndex:0]
													   v1:[self getWorldVertexAtIndex:j+1]
													   v2:[self getWorldVertexAtIndex:j+2]
												  surface:_surface]];
	}
}
@end

@implementation MetalWall

-(MetalWall *)initWithV0:(simd_int2)v0 v1:(simd_int2)v1 bottom:(int)bottom top:(int)top uv:(simd_float4x2)uv surface:(MetalSurface *)surface
{
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_bottom = bottom;
		_top = top;
		_uv = uv;
		_surface = surface;
	}
	return self;
}

- (void) addTrianglesToArray:(NSMutableArray<Triangle*>*)triangles
{
	WorldVertex v0 = {
		.position = { _v0.x, _v0.y, _bottom },
		.textureCoordinate = _uv.columns[0],
	};
	WorldVertex v1 = {
		.position = { _v0.x, _v0.y, _top },
		.textureCoordinate = _uv.columns[1],
	};
	WorldVertex v2 = {
		.position = { _v1.x, _v1.y, _top },
		.textureCoordinate = _uv.columns[2],
	};
	WorldVertex v3 = {
		.position = { _v1.x, _v1.y, _bottom },
		.textureCoordinate = _uv.columns[3],
	};
	
	Triangle *t0 = [[Triangle alloc] initWithV0:v0 v1:v1 v2:v2 surface:_surface];
	Triangle *t1 = [[Triangle alloc] initWithV0:v0 v1:v2 v2:v3 surface:_surface];
	
	[triangles addObject:t0];
	[triangles addObject:t1];
}

- (simd_float4x3) instanceTransform {
	// We need to take VerticalQuad and:
	// - translate and rotate it so that the (y = -0.5) side is at `v0` and (y = +0.5) is at `v1`
	// - translate it so the (z = 0) side is at `bottom`
	// - scale it so the (z = 1) side is at `top`
	
	simd_float2 v0 = simd_make_float2(_v0.x, _v0.y);
	simd_float2 v1 = simd_make_float2(_v1.x, _v1.y);
	simd_float2 d = v1 - v0;
	simd_float2 midpoint = v0 + d/2;
	
	float h = _top - _bottom;

	return (simd_float4x3){
		.columns = {
			{        d.y,        -d.x,     0.0 },
			{        d.x,         d.y,     0.0 },
			{        0.0,         0.0,       h },
			{ midpoint.x,  midpoint.y, _bottom },
		},
	};
}

@end

@implementation MetalSprite

- (MetalSprite *)initWithIndex:(NSInteger)index uv:(simd_float4x2)uv size:(simd_int2)size position:(simd_int3)position surface:(MetalSurface *)surface
{
	if (self = [super init]) {
		_index = index;
		_uv = uv;
		_size = size;
		_position = position;
		_surface = surface;
	}
	return self;
}

- (simd_float4x3)instanceTransformForRotation:(float)theta {
	float x = _position.x, y = _position.y, z = _position.z;
	float w = _size.x, h = _size.y;

	return (simd_float4x3){
		.columns = {
			{  w*cos(theta), w*sin(theta), 0.0 },
			{ -w*sin(theta), w*cos(theta), 0.0 },
			{          0.0,           0.0,   h },
			{            x,             y,   z },
		}
	};
}

@end

@implementation TriangleBatch
{
	NSArray<Triangle*> *_triangles;
	simd_float3 *vertices;
	TriangleRayTracingData *primitiveData;
}

- (TriangleBatch*) initWithTriangles:(NSArray<Triangle *> *)triangles {
	if (self = [super init]) {
		_triangles = triangles;
		
		vertices = malloc(sizeof(simd_float3) * _triangles.count * 3);
		primitiveData = malloc(sizeof(TriangleRayTracingData) * _triangles.count);

		for (int i = 0; i < _triangles.count; i++) {
			Triangle *triangle = [_triangles objectAtIndex:i];

			vertices[i*3+0] = simd_make_float3(triangle.v0.position.x, triangle.v0.position.y, triangle.v0.position.z);
			vertices[i*3+1] = simd_make_float3(triangle.v1.position.x, triangle.v1.position.y, triangle.v1.position.z);
			vertices[i*3+2] = simd_make_float3(triangle.v2.position.x, triangle.v2.position.y, triangle.v2.position.z);

			primitiveData[i].surfaceNormal = triangle.surface.normal;
			primitiveData[i].emission = triangle.surface.emission;
		}
	}
	return self;
}

- (void) dealloc {
	free(vertices);
	free(primitiveData);
}

- (NSUInteger) numTriangles {
	return _triangles.count;
}

- (void *)primitiveData {
	return primitiveData;
}

- (simd_float3 *)vertices {
	return vertices;
}

@end

// A 1x1 square on the YZ plane with its bottom center at (0,0,0)
// Triangles are drawn clockwise when looking in the positive-X direction
@implementation VerticalQuad
{
	simd_float3 vertices[6];
	TriangleRayTracingData primitiveData[2];
}

-(VerticalQuad*) init {
	if (self = [super init]) {
		vertices[0] = (simd_float3){ 0.0, -0.5, 0.0 };
		vertices[1] = (simd_float3){ 0.0, -0.5, 1.0 };
		vertices[2] = (simd_float3){ 0.0,  0.5, 1.0 };

		vertices[3] = (simd_float3){ 0.0, -0.5, 0.0 };
		vertices[4] = (simd_float3){ 0.0,  0.5, 1.0 };
		vertices[5] = (simd_float3){ 0.0,  0.5, 0.0 };
		
		// Normals here are wrong, because rotation is applied to instances, but this needs to go away anyway
		primitiveData[0] = (TriangleRayTracingData){ .surfaceNormal = { -1.0, 0.0, 0.0 }, .emission = { 0.0, 0.0, 0.0 } };
		primitiveData[1] = (TriangleRayTracingData){ .surfaceNormal = { -1.0, 0.0, 0.0 }, .emission = { 0.0, 0.0, 0.0 } };
	}
	return self;
}

-(NSUInteger) numTriangles {
	return 2;
}

-(simd_float3 *) vertices {
	return vertices;
}

-(void *) primitiveData {
	return primitiveData;
}

@end
