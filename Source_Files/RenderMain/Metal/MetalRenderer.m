//
//  MetalRenderer.m
//  libalephone
//
//  Created by Aanand Prasad on 28/08/2026.
//

#import <Foundation/Foundation.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <Cocoa/Cocoa.h>
#include <MetalKit/MetalKit.h>
#include <dispatch/dispatch.h>

#include "VertexTypes.h"
#include "MetalPipeline.h"
#include "IASManager.h"
#include "MetalRenderer.h"

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

@implementation MetalPolygon

- (MetalPolygon*) initWithVertices:(WorldVertex *)vertices vertexCount:(NSUInteger)vertexCount textureID:(NSString *)textureID emission:(simd_float3)emission {
	if (self = [super init]) {
		_vertices = malloc(sizeof(WorldVertex) * vertexCount);
		memcpy(_vertices, vertices, sizeof(WorldVertex) * vertexCount);
		_vertexCount = vertexCount;
		_textureID = textureID;
		_emission = emission;
	}
	return self;
}

- (void)dealloc {
	free(_vertices);
}

@end

@implementation MetalSprite

-(MetalSprite *)initWithIndex:(NSInteger)index
					textureID:(NSString *)textureID
						   uv:(simd_float4x2)uv
						 size:(simd_int2)size
					 position:(simd_int3)position
{
	if (self = [super init]) {
		_index = index;
		_textureID = textureID;
		_uv = uv;
		_size = size;
		_position = position;
	}
	return self;
}

@end

@interface Triangle : NSObject

@property (nonatomic, readonly) WorldVertex v0;
@property (nonatomic, readonly) WorldVertex v1;
@property (nonatomic, readonly) WorldVertex v2;
@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float3 emission;

- (Triangle *) initWithV0:(WorldVertex)v0
					   v1:(WorldVertex)v1
					   v2:(WorldVertex)v2
				textureID:(NSString*)textureID
				 emission:(simd_float3)emission;

@end

@implementation Triangle

- (Triangle *) initWithV0:(WorldVertex)v0
					   v1:(WorldVertex)v1
					   v2:(WorldVertex)v2
				textureID:(NSString *)textureID
				 emission:(simd_float3)emission{
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_v2 = v2;
		_textureID = textureID;
		_emission = emission;
	}
	return self;
}

@end

@interface TriangleBatch : NSObject <ASTrianglePrimitive>

- (TriangleBatch*) initWithTriangles:(NSArray<Triangle*>*)triangles;

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

			primitiveData[i].surfaceNormal = triangle.v0.surfaceNormal;
			primitiveData[i].emission = triangle.emission;
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

@interface SpriteQuad : NSObject <ASTrianglePrimitive>
@end

@implementation SpriteQuad
{
	simd_float3 vertices[6];
	TriangleRayTracingData primitiveData[2];
}

-(SpriteQuad*) init {
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

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

simd_float4x4 rotationMatrix(float angle, simd_float3 axis) {
	simd_quatf quat = simd_quaternion(radians(angle), axis);
	return simd_matrix4x4(quat);
}

// Assumes fov is the horizontal FOV, not the traditional vertical one
simd_float4x4 perspectiveProjection(float fov, float aspectRatio) {
	float xs = 1.0 / tanf(radians(fov) * 0.5);
	float ys = xs * aspectRatio;
	float nz = 0.01;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 1.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
}

uint MAX_TRIANGLES = 10000;

static const simd_float3 sunDirection    = { -1.0, 1.0, 0.0 }; // sun is to the northwest
static const simd_float3 sunRotationAxis = {  0.0, 1.0, 0.0 }; // sun rotates around the north-south axis
static const float sunIntensity = 50.0;
static const float sunDiameterDegrees = 30.0;

API_AVAILABLE(macos(26.0))
@implementation MetalRenderer
{
	// External dependencies

	SDL_Window *window;
	SDL_Renderer *renderer;
	CAMetalLayer *metalLayer;

	// Variables
	
	simd_uint2 viewportSize;
	float fov, pitch, yaw;
	simd_int3 origin;

	uint64_t frameNumber;
	
	// Metal pipeline internals
	
	MetalPipeline *pipeline;

	id<MTLRenderPipelineState> initialRenderPipeline;
	id<MTLComputePipelineState> rayTracingPipeline;
	id<MTLRenderPipelineState> finalRenderPipeline;
	id<MTLDepthStencilState> depthState;

	id<MTL4ArgumentTable> vertexArgumentTable;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTL4ArgumentTable> computeArgumentTable;

	id<MTLResidencySet> initialRenderResidencySet;
	id<MTLResidencySet> rayTracingResidencySet;
	id<MTLResidencySet> finalRenderResidencySet;
	
	id<MTLTexture> initialRenderOutputTexture;
	id<MTLTexture> rayTracingOutputTexture;

	// Shader inputs
	
	id<MTLBuffer> triangleBuffer;
	id<MTLBuffer> uniformsBuffer;

	NSMutableArray<MetalPolygon*> *staticPolygons;
	NSMutableDictionary<NSNumber*, MetalSprite*> *sprites;
	NSMutableDictionary<NSString *, id<MTLTexture>> *textures;

	// Static geometry (walls, floors, ceilings)
	IASManager *staticIASManager;

	// Dynamic geometry (sprites, doors, platforms)
	IASManager *dynamicIASManager;

	id<MTLBuffer> topLevelIASInstanceBuffer;
	id<MTLAccelerationStructure> topLevelIAS;
	MTL4InstanceAccelerationStructureDescriptor *topLevelIASDescriptor;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	fov = 90.0;
	viewportSize = simd_make_uint2(width, height) * ((uint) NSScreen.mainScreen.backingScaleFactor);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	pipeline = [[MetalPipeline alloc] init];
	pipeline.device = metalLayer.device;
	pipeline.commandQueue = [pipeline.device newMTL4CommandQueue];
	pipeline.commandBuffer = [pipeline.device newCommandBuffer];
	pipeline.defaultLibrary = [pipeline.device newDefaultLibrary];
	pipeline.commandAllocator = [pipeline.device newCommandAllocator];
	pipeline.sharedEvent = [pipeline.device newSharedEvent];

	initialRenderPipeline = [self compileInitialRenderPipeline:metalLayer.pixelFormat];
	if (!initialRenderPipeline) {
		return nil;
	}
	
	rayTracingPipeline = [self compileRayTracingPipeline];
	if (!rayTracingPipeline) {
		return nil;
	}
	
	finalRenderPipeline = [self compileFinalRenderPipeline:metalLayer.pixelFormat];
	if (!finalRenderPipeline) {
		return nil;
	}
	
	depthState = [self configureDepth];
	
	if (![self setupArgumentTables]) {
		return nil;
	}
	if (![self setupResidencySets]) {
		return nil;
	}

	[self setupIntermediateTextures];
	[self setupBuffers];
	
	NSError *error;
	staticIASManager = [[IASManager alloc] initWithPipeline:pipeline
								   primitiveDataElementSize:sizeof(TriangleRayTracingData)
													  error:&error];
	if (!staticIASManager) {
		NSLog(@"%@", error);
		return nil;
	}
	staticIASManager.label = @"staticIASManager";

	dynamicIASManager = [[IASManager alloc] initWithPipeline:pipeline
									primitiveDataElementSize:sizeof(TriangleRayTracingData)
													   error:&error];
	if (!dynamicIASManager) {
		NSLog(@"%@", error);
		return nil;
	}
	dynamicIASManager.label = @"dynamicIASManager";
	
	[initialRenderResidencySet commit];
	[rayTracingResidencySet commit];
	[finalRenderResidencySet commit];
	
	textures = [NSMutableDictionary dictionary];
	
	return self;
}

- (bool) setupArgumentTables {
	NSError *error;
	
	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderVertexShader_NumBuffers, FinalRenderVertexShader_NumBuffers);
	vertexArgumentTableDescriptor.label = @"Vertex argument table";
	vertexArgumentTable = [pipeline.device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = MAX(InitialRenderFragmentShader_NumTextures, FinalRenderFragmentShader_NumTextures);
	fragmentArgumentTableDescriptor.maxBufferBindCount = FinalRenderFragmentShader_NumBuffers;
	fragmentArgumentTableDescriptor.label = @"Fragment argument table";
	fragmentArgumentTable = [pipeline.device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *computeArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	computeArgumentTableDescriptor.maxBufferBindCount = RayTracingKernel_NumBuffers;
	computeArgumentTableDescriptor.maxTextureBindCount = RayTracingKernel_NumTextures;
	computeArgumentTableDescriptor.label = @"Compute argument table";
	computeArgumentTable = [pipeline.device newArgumentTableWithDescriptor:computeArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	return true;
}

- (bool) setupResidencySets {
	NSError *error;

	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	initialRenderResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
												   error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	rayTracingResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															 error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	finalRenderResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															  error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	[pipeline.commandQueue addResidencySet:initialRenderResidencySet];
	[pipeline.commandQueue addResidencySet:rayTracingResidencySet];
	[pipeline.commandQueue addResidencySet:finalRenderResidencySet];
	[pipeline.commandQueue addResidencySet:metalLayer.residencySet];

	return true;
}

- (void) setupBuffers {
	uniformsBuffer = [pipeline.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:uniformsBuffer];
	
	triangleBuffer = [pipeline.device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:triangleBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *initial = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalLayer.pixelFormat
																								 width:viewportSize.x
																								height:viewportSize.y
																							 mipmapped:NO];
	initial.storageMode = MTLStorageModePrivate;
	initial.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	initialRenderOutputTexture = [pipeline.device newTextureWithDescriptor:initial];

	MTLTextureDescriptor *raytrace = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalLayer.pixelFormat
																								 width:viewportSize.x
																								height:viewportSize.y
																							 mipmapped:NO];
	raytrace.storageMode = MTLStorageModePrivate;
	raytrace.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rayTracingOutputTexture = [pipeline.device newTextureWithDescriptor:raytrace];
	
	[rayTracingResidencySet addAllocation:rayTracingOutputTexture];
	[finalRenderResidencySet addAllocation:initialRenderOutputTexture];
	[finalRenderResidencySet addAllocation:rayTracingOutputTexture];
}

- (id<MTLRenderPipelineState>) compileInitialRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	NSError *error;
	id<MTL4Compiler> compiler = [pipeline.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];

	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = pipeline.defaultLibrary;
	vertexFunction.name = @"initialRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = pipeline.defaultLibrary;
	fragmentFunction.name = @"initialRenderFragmentShader";

	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Initial Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;

	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	colorAttachment.blendingState = MTL4BlendStateEnabled;
	colorAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	colorAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (id<MTLRenderPipelineState>) compileFinalRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	NSError *error;
	id<MTL4Compiler> compiler = [pipeline.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = pipeline.defaultLibrary;
	vertexFunction.name = @"finalRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = pipeline.defaultLibrary;
	fragmentFunction.name = @"finalRenderFragmentShader";
	
	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Final Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	
	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	return state;
}

- (id<MTLDepthStencilState>) configureDepth {
	MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
	depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
	depthDescriptor.depthWriteEnabled = YES;
	return [pipeline.device newDepthStencilStateWithDescriptor:depthDescriptor];
}

- (id<MTLComputePipelineState>) compileRayTracingPipeline {
	NSError *error;
	id<MTLFunction> function = [pipeline.defaultLibrary newFunctionWithName:@"rayTracingKernel"];
	
	id<MTLComputePipelineState> state = [pipeline.device newComputePipelineStateWithFunction:function
																			  error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (void) updateViewWithOrigin:(simd_int3)newOrigin pitch:(float)newPitch yaw:(float)newYaw FOV:(float)newFOV {
	origin = newOrigin;
	fov = newFOV;
	pitch = newPitch;
	yaw = newYaw;
}

simd_int3 transform(simd_int3 position, simd_float4x4 matrix) {
	simd_float4 transformed = simd_mul(matrix, simd_make_float4(position.x, position.y, position.z, 1.0));
	return simd_make_int3(transformed.x, transformed.y, transformed.z);
}

- (void) addTrianglesForPolygon:(MetalPolygon *)polygon
						toArray:(NSMutableArray<Triangle*>*)triangles
					 withOrigin:(simd_int3)origin
					   rotation:(float)rotation
{
	assert(polygon.vertexCount > 2);
	
	simd_float4x4 rotationMat = rotationMatrix(rotation, simd_make_float3(0.0, 0.0, 1.0));
	
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < polygon.vertexCount - 2; j++) {
		WorldVertex v0 = *(polygon.vertices);
		WorldVertex v1 = *(polygon.vertices+j+1);
		WorldVertex v2 = *(polygon.vertices+j+2);
		
		v0.position = transform(v0.position, rotationMat);
		v1.position = transform(v1.position, rotationMat);
		v2.position = transform(v2.position, rotationMat);

		v0.position += origin;
		v1.position += origin;
		v2.position += origin;

		[triangles addObject:[[Triangle alloc] initWithV0:v0
													   v1:v1
													   v2:v2
												textureID:polygon.textureID
												 emission:polygon.emission]];

		assert(triangles.count < MAX_TRIANGLES);
	}
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[staticPolygons addObject:polygon];
}

- (void) updateSprite:(MetalSprite *)sprite {
	[sprites setObject:sprite forKey:[NSNumber numberWithInteger:sprite.index]];
}

- (void) writeStaticPolygonsToStaticIAS {
	// TODO: make a primitive for each floor+ceiling, translated to the appropriate height
	// TODO: make a single vertical quad primitive, translated/rotated/scaled per-wall
	// (or don't, if this is good/fast enough)

	NSMutableArray *staticTriangles = [NSMutableArray array];
	for (MetalPolygon *polygon in staticPolygons) {
		[self addTrianglesForPolygon:polygon
							 toArray:staticTriangles
						  withOrigin:simd_make_int3(0, 0, 0)
							rotation:0.0];
	}

	NSUInteger numTriangles = staticTriangles.count;
	NSUInteger trianglesPerBatch = 100;
	
	for (int b = 0; b < numTriangles; b += trianglesPerBatch) {
		NSArray *triangles = [staticTriangles subarrayWithRange:NSMakeRange(b, MIN(trianglesPerBatch, numTriangles - b))];
		TriangleBatch *batch = [[TriangleBatch alloc] initWithTriangles:triangles];
		[staticIASManager addPrimitive:batch];
		MTLPackedFloat4x3 transform = {
			.columns = {
				{ 1.0, 0.0, 0.0 },
				{ 0.0, 1.0, 0.0 },
				{ 0.0, 0.0, 1.0 },
				{ 0.0, 0.0, 0.0 },
			}
		};
		[staticIASManager addInstanceOfPrimitive:batch withTransform:transform instanceID:0];
	}
	
	[staticIASManager commitGeometry];
}

- (void) writeSpritesToDynamicIAS {
	SpriteQuad *spriteQuad = [[SpriteQuad alloc] init];
	[dynamicIASManager addPrimitive:spriteQuad];

	float theta = radians(yaw);

	for (MetalSprite *sprite in [sprites allValues]) {
		float x = sprite.position.x, y = sprite.position.y, z = sprite.position.z;
		float w = sprite.size.x, h = sprite.size.y;

		MTLPackedFloat4x3 transform = {
			.columns = {
				{ w*cos(theta), w*sin(theta), 0.0 },
				{ -w*sin(theta),  w*cos(theta), 0.0 },
				{          0.0,           0.0,   h },
				{            x,             y,   z },
			}
		};

		[dynamicIASManager addInstanceOfPrimitive:spriteQuad
									withTransform:transform
									   instanceID:(uint32_t)sprite.index];
	}
	
	[dynamicIASManager commitGeometry];
}

- (void) initializeTopLevelIAS {
	NSArray<IASManager*> *IASes = @[staticIASManager, dynamicIASManager];

	MTLIndirectAccelerationStructureInstanceDescriptor descriptors[IASes.count];

	for (int i = 0; i < IASes.count; i++) {
		descriptors[i] = (MTLIndirectAccelerationStructureInstanceDescriptor){};
		descriptors[i].accelerationStructureID = [IASes objectAtIndex:i].IASResourceID;
		descriptors[i].options = MTLAccelerationStructureInstanceOptionNone;
		descriptors[i].intersectionFunctionTableOffset = 0;
		descriptors[i].mask = 0xFF;
		descriptors[i].transformationMatrix.columns[0] = MTLPackedFloat3Make(1.0, 0.0, 0.0);
		descriptors[i].transformationMatrix.columns[1] = MTLPackedFloat3Make(0.0, 1.0, 0.0);
		descriptors[i].transformationMatrix.columns[2] = MTLPackedFloat3Make(0.0, 0.0, 1.0);
		descriptors[i].transformationMatrix.columns[3] = MTLPackedFloat3Make(0.0, 0.0, 0.0);
	}
	
	topLevelIASInstanceBuffer = [pipeline.device newBufferWithBytes:&descriptors
													length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * IASes.count
												   options:MTLResourceStorageModeShared];
	topLevelIASInstanceBuffer.label = @"topLevelIASInstanceBuffer";
	
	topLevelIASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	topLevelIASDescriptor.instanceCount = IASes.count;
	topLevelIASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(topLevelIASInstanceBuffer.gpuAddress, topLevelIASInstanceBuffer.length);
	
	topLevelIAS = [pipeline.device newAccelerationStructureWithDescriptor:topLevelIASDescriptor];
	
	[rayTracingResidencySet addAllocation:topLevelIASInstanceBuffer];
	[rayTracingResidencySet addAllocation:topLevelIAS];
	[rayTracingResidencySet commit];
}

- (void) clearTopLevelIAS {
	if (topLevelIASInstanceBuffer) [rayTracingResidencySet removeAllocation:topLevelIASInstanceBuffer];
	if (topLevelIAS) [rayTracingResidencySet removeAllocation:topLevelIAS];
	topLevelIASInstanceBuffer = nil;
	topLevelIAS = nil;
}

- (void) startUpdatingAllGeometry {
	staticPolygons = [NSMutableArray array];
	sprites = [NSMutableDictionary dictionary];

	[staticIASManager clearGeometry];
	[dynamicIASManager clearGeometry];
	[self clearTopLevelIAS];
}

- (void) finishUpdatingAllGeometry {
	[self writeStaticPolygonsToStaticIAS];
	[self writeSpritesToDynamicIAS];
	[self initializeTopLevelIAS];
	
	[self buildAccelerationStructureWithChangesTo:@[staticIASManager, dynamicIASManager]
											label:@"Full IAS build"];
}

- (void) startUpdatingDynamicGeometry {
	sprites = [NSMutableDictionary dictionary];
	[dynamicIASManager clearGeometry];
	[self clearTopLevelIAS];
}

- (void) finishUpdatingDynamicGeometry {
	[self writeSpritesToDynamicIAS];
	[self initializeTopLevelIAS];
	[self buildAccelerationStructureWithChangesTo:@[dynamicIASManager]
											label:[NSString stringWithFormat:@"Dynamic IAS build (frame #%llu)", frameNumber]];
}

- (void) buildAccelerationStructureWithChangesTo:(NSArray<IASManager*>*)iasManagers label:(NSString*)label {
	// Calculate largest scratch size needed
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *allDescriptors = [NSMutableArray array];
	[allDescriptors addObject:topLevelIASDescriptor];
	for (IASManager *iasm in iasManagers) {
		[allDescriptors addObjectsFromArray:iasm.allASDescriptors];
	}
	
	NSUInteger scratchSize = 0;
	for (MTL4AccelerationStructureDescriptor *asd in allDescriptors) {
		NSUInteger primSize = [pipeline.device accelerationStructureSizesWithDescriptor:asd].buildScratchBufferSize;
		if (primSize > scratchSize) {
			scratchSize = primSize;
		}
	}
	
	// Build everything
	
	id<MTLBuffer> scratchBuffer = [pipeline.device newBufferWithLength:scratchSize options:MTLResourceStorageModePrivate];
	
	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = label;

	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	encoder.label = @"Build acceleration structures";
	
	for (IASManager *iasm in iasManagers) {
		[iasm encodeBuildCommandsForPASes:encoder
							scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	}
	
	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];
	
	for (IASManager *iasm in iasManagers) {
		[iasm encodeBuildCommandsForIAS:encoder
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	}

	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];

	[encoder buildAccelerationStructure:topLevelIAS
							 descriptor:topLevelIASDescriptor
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];

	[encoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	uint64_t buildSignalValue = pipeline.sharedEvent.signaledValue + 1;
	[pipeline.commandQueue commit:&commandBuffer count:1];
	[pipeline.commandQueue signalEvent:pipeline.sharedEvent value:buildSignalValue];
	[pipeline.sharedEvent waitUntilSignaledValue:buildSignalValue timeoutMS:5000];
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [textures objectForKey:textureID] != nil;
}

- (void) addTextureWithID:(NSString*)textureID image:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [pipeline.device newTextureWithDescriptor:descriptor];
	texture.label = textureID;
	[texture replaceRegion:region
			   mipmapLevel:0
				 withBytes:image.data.bytes
			   bytesPerRow:sizeof(uint32) * image.width];
	
	[textures setObject:texture forKey:textureID];
	[initialRenderResidencySet addAllocation:texture];
}

- (void) begin {
	frameNumber += 1;
}

- (void) end {
	simd_float4x4 sunRotation = rotationMatrix(fmod(frameNumber, 360.0), sunRotationAxis);
	simd_float3 rotatedSunDirection = simd_mul(sunRotation, simd_make_float4(sunDirection, 1.0)).xyz;

	Uniforms uniforms;
	uniforms.resolution = viewportSize;
	uniforms.frameNumber = frameNumber;
	uniforms.fov = fov;
	uniforms.origin = origin;
	uniforms.pitchMat = rotationMatrix(pitch, simd_make_float3(1.0, 0.0, 0.0));
	uniforms.yawMat = rotationMatrix(-yaw, simd_make_float3(0.0, 1.0, 0.0));
	uniforms.rotateDirectionMat = simd_mul(rotationMatrix(yaw, simd_make_float3(0.0, 1.0, 0.0)), rotationMatrix(-pitch, simd_make_float3(1.0, 0.0, 0.0)));
	uniforms.perspectiveMat = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	uniforms.sunDirection = simd_normalize(rotatedSunDirection);
	uniforms.sunIntensity = sunIntensity;
	uniforms.sunRadius = radians(sunDiameterDegrees/2);
	memcpy(uniformsBuffer.contents, &uniforms, sizeof(Uniforms));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (render)", frameNumber];
	
	id<MTLFence> initialPassFence = [pipeline.device newFence];
	id<MTLFence> computePassFence = [pipeline.device newFence];
	
	[self encodeInitialRenderToOutputTexture:initialRenderOutputTexture updatingFence:initialPassFence];
	[self encodeRayTracingPassToOutputTexture:rayTracingOutputTexture updatingFence:computePassFence];
	[self encodeFinalRenderFromInitialPassTexture:initialRenderOutputTexture
							rayTracingPassTexture:rayTracingOutputTexture
								  toOutputTexture:currentDrawable.texture
									  afterFences:@[initialPassFence, computePassFence]];
	
	[commandBuffer endCommandBuffer];
	
	// Block until rendering has completed. This is inefficient, but Marathon is locked to 30fps,
	// so it probably doesn't slow us down and it simplifies things to not have to worry about concurrent
	// reads/writes to buffers and textures
	uint64_t renderSignalValue = pipeline.sharedEvent.signaledValue + 1;
	
	[pipeline.commandQueue waitForDrawable:currentDrawable];
	[pipeline.commandQueue commit:&commandBuffer count:1];
	[pipeline.commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
	
	[pipeline.commandQueue signalEvent:pipeline.sharedEvent value:renderSignalValue];
	[pipeline.sharedEvent waitUntilSignaledValue:renderSignalValue timeoutMS:5000];
}

- (void) encodeInitialRenderToOutputTexture:(id<MTLTexture>)outputTexture updatingFence:(id<MTLFence>)fence {
	// Commit any textures that were added
	[initialRenderResidencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	// Render a white sky, which the raytracing pass will multiply down
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> renderPassEncoder = [pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	renderPassEncoder.label = @"Initial render";
	
	[renderPassEncoder setRenderPipelineState:initialRenderPipeline];
	[renderPassEncoder setDepthStencilState:depthState];
	[renderPassEncoder setViewport:[self getViewport]];
	
	[vertexArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:InitialRenderVertexShaderUniformsIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger offset = 0;

	@autoreleasepool {
		// FIXME: this should be built once in commitGeometry, not per-frame
		NSMutableArray *triangles = [NSMutableArray array];
		for (MetalPolygon *polygon in staticPolygons) {
			[self addTrianglesForPolygon:polygon
								 toArray:triangles
							  withOrigin:simd_make_int3(0, 0, 0)
								rotation:0.0];
		}

		for (MetalSprite *sprite in [sprites allValues]) {
			simd_float3 surfaceNormal = { 0.0, 0.0, -1.0 };

			WorldVertex vertices[] = {
				(WorldVertex){ .position = { 0, -sprite.size.x/2,             0 }, .textureCoordinate = sprite.uv.columns[0], .surfaceNormal = surfaceNormal },
				(WorldVertex){ .position = { 0, -sprite.size.x/2, sprite.size.y }, .textureCoordinate = sprite.uv.columns[1], .surfaceNormal = surfaceNormal },
				(WorldVertex){ .position = { 0,  sprite.size.x/2, sprite.size.y }, .textureCoordinate = sprite.uv.columns[2], .surfaceNormal = surfaceNormal },
				(WorldVertex){ .position = { 0,  sprite.size.x/2,             0 }, .textureCoordinate = sprite.uv.columns[3], .surfaceNormal = surfaceNormal },
			};

			MetalPolygon *spritePolygon = [[MetalPolygon alloc] initWithVertices:vertices
																	 vertexCount:4
																	   textureID:sprite.textureID
																		emission:simd_make_float3(0.0, 0.0, 0.0)];

			[self addTrianglesForPolygon:spritePolygon
								 toArray:triangles
							  withOrigin:sprite.position
								rotation:yaw];
		}
		
		for (Triangle *triangle in triangles) {
			target[offset] = triangle.v0;
			target[offset+1] = triangle.v1;
			target[offset+2] = triangle.v2;
			
			MTLGPUAddress address = triangleBuffer.gpuAddress + (offset * sizeof(WorldVertex));
			[vertexArgumentTable setAddress:address atIndex:InitialRenderVertexShaderVertexDataIndex];
			[renderPassEncoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];
			
			id<MTLTexture> texture = [textures objectForKey:triangle.textureID];
			[fragmentArgumentTable setTexture:texture.gpuResourceID atIndex:InitialRenderFragmentShaderColorTextureIndex];
			[renderPassEncoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
			
			[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			
			offset += 3;
		}
	}
	
	[renderPassEncoder updateFence:fence afterEncoderStages:MTLStageFragment];
	[renderPassEncoder endEncoding];
}

-(void) encodeRayTracingPassToOutputTexture:(id<MTLTexture>)outputTexture updatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:rayTracingPipeline];
	
	[computeArgumentTable setResource:topLevelIAS.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:RayTracingKernelCameraIndex];
	[computeArgumentTable setTexture:outputTexture.gpuResourceID atIndex:RayTracingKernelOutImageIndex];
	[encoder setArgumentTable:computeArgumentTable];
	
	NSUInteger w = rayTracingPipeline.threadExecutionWidth;
	NSUInteger h = rayTracingPipeline.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadsPerThreadgroup = MTLSizeMake( w, h, 1 );
	MTLSize threadsPerGrid = MTLSizeMake(outputTexture.width, outputTexture.height, 1);
	[encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
	
	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(void) encodeFinalRenderFromInitialPassTexture:(id<MTLTexture>)initialPassTexture
						  rayTracingPassTexture:(id<MTLTexture>)rayTracingPassTexture
								toOutputTexture:(id<MTLTexture>)outputTexture
									afterFences:(NSArray<id<MTLFence>>*)fences
{
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> encoder = [pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	for (id<MTLFence> fence in fences) {
		[encoder waitForFence:fence beforeEncoderStages:MTLStageVertex];
	}
	
	[encoder setRenderPipelineState:finalRenderPipeline];
	[encoder setViewport:[self getViewport]];

	[encoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:initialPassTexture.gpuResourceID atIndex:FinalRenderFragmentShaderInitialPassTextureIndex];
	[fragmentArgumentTable setTexture:rayTracingPassTexture.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingPassTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

- (MTLViewport) getViewport {
	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x;
	viewPort.height = (double)viewportSize.y;
	return viewPort;
}

@end
