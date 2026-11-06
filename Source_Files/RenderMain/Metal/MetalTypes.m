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

bool isValidTangent(simd_float4 t) {
	return !isnan(t.x) && !isnan(t.y) && !isnan(t.z);
}

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

@implementation MetalPolygonPrimitive
{
	NSUInteger numTriangles;
	simd_float3 *vertices;
	RayTracingData *primitiveData;
}

-(MetalPolygonPrimitive *)initWithVertexCount:(NSUInteger)vertexCount
									 vertices:(simd_int2 *)vs
										   uv:(simd_float2*)uv
									  surface:(Surface)surface
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
				.numVertices = vertexCount,
				.surface = surface,
			};
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

-(MetalPolygon *)initWithVertexCount:(NSUInteger)vertexCount vertices:(simd_int2 *)vertices uv:(simd_float2 *)uv height:(int)height surface:(Surface)surface
{
	if (self = [super init]) {
		_vertexCount = vertexCount;
		_vertices = malloc(sizeof(simd_int2)*vertexCount); memcpy(_vertices, vertices, sizeof(simd_int2)*vertexCount);
		_uv = malloc(sizeof(simd_float2)*vertexCount); memcpy(_uv, uv, sizeof(simd_float2)*vertexCount);
		_height = height;
		_surface = surface;
		_surface.tangent = [self tangent];
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
													  surface:_surface];
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
		.surface = _surface,
	};
}

- (void) eachTriangle:(void (^)(Triangle))callback
{
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < _vertexCount - 2; j++) {
		callback((Triangle){
			.v0 = [self getWorldVertexAtIndex:0],
			.v1 = [self getWorldVertexAtIndex:j+1],
			.v2 = [self getWorldVertexAtIndex:j+2],
			.surface = _surface,
		});
	}
}

-(simd_float4)tangent {
	// Some triangles will be invalid, e.g. if points 0, 1 and 2 happen to be in a straight line.
	// Iterate until we find a triangle with a valid tangent.
	for (int j = 0; j < _vertexCount -2; j++) {
		simd_float4 t = tangent(simd_make_float3(_vertices[0].x, _vertices[0].y, _height),
								simd_make_float3(_vertices[j+1].x, _vertices[j+1].y, _height),
								simd_make_float3(_vertices[j+2].x, _vertices[j+2].y, _height),
								_uv[0], _uv[j+1], _uv[j+2],
								_surface.normal);
		
		if (isValidTangent(t)) {
			return t;
		}
	}
	
	NSAssert(false, @"Failed to calculate tangent for MetalPolygon");
	return simd_make_float4(0.0, 0.0, 0.0, 0.0);
}

@end

@implementation MetalWall

-(MetalWall *)initWithV0:(simd_int2)v0 v1:(simd_int2)v1 bottom:(int)bottom top:(int)top uv:(simd_float4x2)uv surface:(Surface)surface
{
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_bottom = bottom;
		_top = top;
		_uv = uv;
		_surface = surface;
		_surface.tangent = [self tangent];
	}
	return self;
}

- (void) eachTriangle:(void (^)(Triangle))callback
{
	WorldVertex v0 = {
		.position = { _v0.x, _v0.y, _bottom },
		.textureCoordinate = _uv.columns[0],
		.surface = _surface,
	};
	WorldVertex v1 = {
		.position = { _v0.x, _v0.y, _top },
		.textureCoordinate = _uv.columns[1],
		.surface = _surface,
	};
	WorldVertex v2 = {
		.position = { _v1.x, _v1.y, _top },
		.textureCoordinate = _uv.columns[2],
		.surface = _surface,
	};
	WorldVertex v3 = {
		.position = { _v1.x, _v1.y, _bottom },
		.textureCoordinate = _uv.columns[3],
		.surface = _surface,
	};
	
	callback((Triangle){ .v0 = v0, .v1 = v1, .v2 = v2, .surface = _surface });
	callback((Triangle){ .v0 = v0, .v1 = v2, .v2 = v3, .surface = _surface });
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

-(MetalSprite *)initWithIndex:(NSInteger)index uv:(simd_float4x2)uv rect:(Rect)rect position:(simd_int3)position rotation:(float)rotation surface:(Surface)surface
{
	if (self = [super init]) {
		_index = index;
		_uv = uv;
		_rect = rect;
		_position = position;
		_rotation = rotation;
		_surface = surface;
	}
	return self;
}

- (void) eachTriangle:(void (^)(Triangle))callback {
	simd_float4x3 transform = [self instanceTransform];

	WorldVertex v[4];
	for (int i=0; i<4; i++) {
		simd_float3 position = simd_mul(transform, simd_make_float4(VERTICAL_QUAD_VERTICES[i], 1.0)).xyz;
		v[i] = (WorldVertex){
			.position = simd_make_int3(position.x, position.y, position.z),
			.textureCoordinate = _uv.columns[i],
			.surface = _surface,
		};
	}
	
	callback((Triangle){ .v0 = v[0], .v1 = v[1], .v2 = v[2], .surface = _surface });
	callback((Triangle){ .v0 = v[0], .v1 = v[2], .v2 = v[3], .surface = _surface });
}

- (simd_float4x3)instanceTransform {
	float x = _position.x, y = _position.y, z = _position.z;
	float w = _rect.right - _rect.left;
	float h = _rect.top - _rect.bottom;
	
	float cosTheta = cos(_rotation);
	float sinTheta = sin(_rotation);

	return (simd_float4x3){
		.columns = {
			{  w*cosTheta, w*sinTheta, 0.0                },
			{ -w*sinTheta, w*cosTheta, 0.0                },
			{         0.0,        0.0,   h                },
			{           x,          y,   z + _rect.bottom },
		}
	};
}

@end

@implementation TriangleBatch
{
	NSUInteger numTriangles;
	simd_float3 *vertices;
	RayTracingData *primitiveData;
}

-(TriangleBatch *)initWithTriangles:(Triangle *)triangles triangleCount:(NSUInteger)triangleCount
{
	if (self = [super init]) {
		numTriangles = triangleCount;
		vertices = malloc(sizeof(simd_float3) * triangleCount * 3);
		primitiveData = malloc(sizeof(RayTracingData) * triangleCount);

		for (int i = 0; i < triangleCount; i++) {
			Triangle triangle = triangles[i];

			vertices[i*3+0] = simd_make_float3(triangle.v0.position.x, triangle.v0.position.y, triangle.v0.position.z);
			vertices[i*3+1] = simd_make_float3(triangle.v1.position.x, triangle.v1.position.y, triangle.v1.position.z);
			vertices[i*3+2] = simd_make_float3(triangle.v2.position.x, triangle.v2.position.y, triangle.v2.position.z);

			primitiveData[i].surface = triangle.surface;
			primitiveData[i].uv[0] = triangle.v0.textureCoordinate;
			primitiveData[i].uv[1] = triangle.v1.textureCoordinate;
			primitiveData[i].uv[2] = triangle.v2.textureCoordinate;
		}
	}
	return self;
}

- (void) dealloc {
	free(vertices);
	free(primitiveData);
}

- (NSUInteger) numTriangles {
	return numTriangles;
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
