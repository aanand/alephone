//
//  MetalTypes.m
//  AlephOne
//
//  Created by Aanand Prasad on 12/09/2026.
//

#import <Foundation/Foundation.h>

#import "Shaders/ShaderTypes.h"
#import "MetalTypes.h"

simd_float3 VERTICAL_QUAD_VERTICES[4] = {
	{ 0.0, -0.5, 0.0 },
	{ 0.0, -0.5, 1.0 },
	{ 0.0,  0.5, 1.0 },
	{ 0.0,  0.5, 0.0 },
};

simd_float4 tangent(simd_float3 p0, simd_float3 p1, simd_float3 p2,
					simd_float2 uv0, simd_float2 uv1, simd_float2 uv2,
					simd_float3 N)
{
	simd_float3 dp1 = p1 - p0;
	simd_float3 dp2 = p2 - p0;
	simd_float2 duv1 = uv1 - uv0;
	simd_float2 duv2 = uv2 - uv0;
	
	float det = (duv1.x * duv2.y - duv2.x * duv1.y);
	float r = (fabs(det) > 1e-6f) ? (1.0f / det) : 0.0f;
	
	simd_float3 T = (dp1 * duv2.y - dp2 * duv1.y) * r;
	simd_float3 B = (dp2 * duv1.x - dp1 * duv2.x) * r;
	
	T = simd_normalize(T - N * simd_dot(N, T));
	float H = (simd_dot(simd_cross(N, T), B) < 0.0f) ? -1.0f : 1.0f;

	return simd_make_float4(T, H);
}

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

- (simd_float3) p0 {
	return simd_make_float3(_v0.position.x, _v0.position.y, _v0.position.z);
}

- (simd_float3) p1 {
	return simd_make_float3(_v1.position.x, _v1.position.y, _v1.position.z);
}

- (simd_float3) p2 {
	return simd_make_float3(_v2.position.x, _v2.position.y, _v2.position.z);
}

- (simd_float2) uv0 {
	return _v0.textureCoordinate;
}

- (simd_float2) uv1 {
	return _v1.textureCoordinate;
}

- (simd_float2) uv2 {
	return _v2.textureCoordinate;
}

- (simd_float4) tangent {
	return tangent(self.p0, self.p1, self.p2,
				   self.uv0, self.uv1, self.uv2,
				   _surface.normal);
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

-(MetalSurface *)initWithTextureID:(NSString *)textureID material:(Material)material normal:(simd_float3)normal lightSourceIndex:(int32_t)lightSourceIndex
{
	if (self = [super init]) {
		_textureID = textureID;
		_material = material;
		_normal = normal;
		_lightSourceIndex = lightSourceIndex;
	}
	return self;
}

@end

@implementation MetalPolygonPrimitive
{
	NSUInteger numTriangles;
	simd_float3 *vertices;
	RayTracingData *primitiveData;
}

-(MetalPolygonPrimitive *)initWithVertexCount:(NSUInteger)vertexCount
									 vertices:(simd_int2 *)vs
										   uv:(simd_float2*)uv
									  surface:(MetalSurface *)surface
								   textureIDs:(NSOrderedSet*)textureIDs
{
	if (self = [super init]) {
		numTriangles = vertexCount - 2;
		
		vertices = malloc(sizeof(simd_float3) * numTriangles * 3);
		primitiveData = malloc(sizeof(RayTracingData) * numTriangles);
		
		// Triangle fan: 0-1-2, 0-2-3, 0-3-4, ...
		for (int i = 0; i < numTriangles; i++) {
			vertices[i*3]   = (simd_float3){ vs[  0].x, vs[  0].y, 0.0 };
			vertices[i*3+1] = (simd_float3){ vs[i+1].x, vs[i+1].y, 0.0 };
			vertices[i*3+2] = (simd_float3){ vs[i+2].x, vs[i+2].y, 0.0 };

			primitiveData[i] = (RayTracingData){
				.surfaceNormal = surface.normal,
				.material = surface.material,
				.lightSourceIndex = surface.lightSourceIndex,
			};

			NSUInteger textureIndex = [textureIDs indexOfObject:surface.textureID];
			NSAssert(textureIndex != NSNotFound, @"Missing dynamic polygon texture ID");
			primitiveData[i].textureIndex = (uint32_t)textureIndex;
			primitiveData[i].uv[0] = uv[0];
			primitiveData[i].uv[1] = uv[i+1];
			primitiveData[i].uv[2] = uv[i+2];
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

-(id<ASTrianglePrimitive>)primitiveForTextureIDs:(NSOrderedSet<NSString *> *)textureIDs {
	return [[MetalPolygonPrimitive alloc] initWithVertexCount:_vertexCount
													 vertices:_vertices
														   uv:_uv
													  surface:_surface
												   textureIDs:textureIDs];
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

- (WorldVertex) getWorldVertexAtIndex:(NSUInteger)vertexIdx surfaceTangent:(simd_float4)surfaceTangent {
	simd_int2 pos = _vertices[vertexIdx];
	return (WorldVertex){
		.position = simd_make_int3(pos.x, pos.y, _height),
		.textureCoordinate = _uv[vertexIdx],
		.surfaceNormal = _surface.normal,
		.surfaceTangent = surfaceTangent,
	};
}

- (void) eachTriangle:(void (^)(Triangle *))callback
{
	simd_float4 surfaceTangent = [self tangent];

	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < _vertexCount - 2; j++) {
		callback([[Triangle alloc] initWithV0:[self getWorldVertexAtIndex:0 surfaceTangent:surfaceTangent]
										   v1:[self getWorldVertexAtIndex:j+1 surfaceTangent:surfaceTangent]
										   v2:[self getWorldVertexAtIndex:j+2 surfaceTangent:surfaceTangent]
									  surface:_surface]);
	}
}

-(simd_float4)tangent {
	return tangent(simd_make_float3(_vertices[0].x, _vertices[0].y, _height),
				   simd_make_float3(_vertices[1].x, _vertices[1].y, _height),
				   simd_make_float3(_vertices[2].x, _vertices[2].y, _height),
				   _uv[0], _uv[1], _uv[2],
				   _surface.normal);
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

- (void) eachTriangle:(void (^)(Triangle *))callback
{
	simd_float4 surfaceTangent = [self tangent];

	WorldVertex v0 = {
		.position = { _v0.x, _v0.y, _bottom },
		.textureCoordinate = _uv.columns[0],
		.surfaceNormal = _surface.normal,
		.surfaceTangent = surfaceTangent,
	};
	WorldVertex v1 = {
		.position = { _v0.x, _v0.y, _top },
		.textureCoordinate = _uv.columns[1],
		.surfaceNormal = _surface.normal,
		.surfaceTangent = surfaceTangent,
	};
	WorldVertex v2 = {
		.position = { _v1.x, _v1.y, _top },
		.textureCoordinate = _uv.columns[2],
		.surfaceNormal = _surface.normal,
		.surfaceTangent = surfaceTangent,
	};
	WorldVertex v3 = {
		.position = { _v1.x, _v1.y, _bottom },
		.textureCoordinate = _uv.columns[3],
		.surfaceNormal = _surface.normal,
		.surfaceTangent = surfaceTangent,
	};
	
	Triangle *t0 = [[Triangle alloc] initWithV0:v0 v1:v1 v2:v2 surface:_surface];
	Triangle *t1 = [[Triangle alloc] initWithV0:v0 v1:v2 v2:v3 surface:_surface];
	
	callback(t0);
	callback(t1);
}

-(simd_float4)tangent {
	return tangent(simd_make_float3(_v0.x, _v0.y, _bottom),
				   simd_make_float3(_v0.x, _v0.y, _top),
				   simd_make_float3(_v1.x, _v1.y, _top),
				   _uv.columns[0], _uv.columns[1], _uv.columns[2],
				   _surface.normal);
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

-(MetalSprite *)initWithIndex:(NSInteger)index uv:(simd_float4x2)uv rect:(Rect)rect position:(simd_int3)position surface:(MetalSurface *)surface
{
	if (self = [super init]) {
		_index = index;
		_uv = uv;
		_rect = rect;
		_position = position;
		_surface = surface;
	}
	return self;
}

- (void) eachTriangle:(void (^)(Triangle *))callback forRotation:(float)theta {
	simd_float4x3 transform = [self instanceTransformForRotation:theta];

	WorldVertex v[4];
	for (int i=0; i<4; i++) {
		simd_float3 position = simd_mul(transform, simd_make_float4(VERTICAL_QUAD_VERTICES[i], 1.0)).xyz;
		simd_float3 normal = simd_make_float3(-cos(theta), -sin(theta), 0.0);
		v[i] = (WorldVertex){
			.position = simd_make_int3(position.x, position.y, position.z),
			.textureCoordinate = _uv.columns[i],
			.surfaceNormal = normal,
		};
	}
	
	Triangle *t0 = [[Triangle alloc] initWithV0:v[0] v1:v[1] v2:v[2] surface:_surface];
	Triangle *t1 = [[Triangle alloc] initWithV0:v[0] v1:v[2] v2:v[3] surface:_surface];
	
	callback(t0);
	callback(t1);
}

- (simd_float4x3)instanceTransformForRotation:(float)theta {
	float x = _position.x, y = _position.y, z = _position.z;
	float w = _rect.right - _rect.left;
	float h = _rect.top - _rect.bottom;

	return (simd_float4x3){
		.columns = {
			{  w*cos(theta), w*sin(theta), 0.0 },
			{ -w*sin(theta), w*cos(theta), 0.0 },
			{          0.0,           0.0,   h },
			{            x,             y,   z + _rect.bottom },
		}
	};
}

@end

@implementation TriangleBatch
{
	NSArray<Triangle*> *_triangles;
	simd_float3 *vertices;
	RayTracingData *primitiveData;
}

- (TriangleBatch*) initWithTriangles:(NSArray<Triangle *> *)triangles
						  textureIDs:(NSOrderedSet<NSString*>*)textureIDs
{
	if (self = [super init]) {
		_triangles = triangles;
		
		vertices = malloc(sizeof(simd_float3) * _triangles.count * 3);
		primitiveData = malloc(sizeof(RayTracingData) * _triangles.count);

		for (int i = 0; i < _triangles.count; i++) {
			Triangle *triangle = [_triangles objectAtIndex:i];

			vertices[i*3+0] = triangle.p0;
			vertices[i*3+1] = triangle.p1;
			vertices[i*3+2] = triangle.p2;

			primitiveData[i].surfaceNormal = triangle.surface.normal;
			primitiveData[i].surfaceTangent = triangle.tangent;
			primitiveData[i].material = triangle.surface.material;

			NSUInteger textureIndex = [textureIDs indexOfObject:triangle.surface.textureID];
			NSAssert(textureIndex != NSNotFound, @"Missing static triangle texture ID");
			primitiveData[i].textureIndex = (uint32_t)textureIndex;

			primitiveData[i].uv[0] = triangle.uv0;
			primitiveData[i].uv[1] = triangle.uv1;
			primitiveData[i].uv[2] = triangle.uv2;

			primitiveData[i].lightSourceIndex = triangle.surface.lightSourceIndex;
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
	RayTracingData primitiveData[2];
}

-(VerticalQuad*) init {
	if (self = [super init]) {
		vertices[0] = VERTICAL_QUAD_VERTICES[0];
		vertices[1] = VERTICAL_QUAD_VERTICES[1];
		vertices[2] = VERTICAL_QUAD_VERTICES[2];

		vertices[3] = VERTICAL_QUAD_VERTICES[0];
		vertices[4] = VERTICAL_QUAD_VERTICES[2];
		vertices[5] = VERTICAL_QUAD_VERTICES[3];
		
		// This should never be read from - the raytracer will get the data from the instance
		primitiveData[0] = (RayTracingData){};
		primitiveData[1] = (RayTracingData){};
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
