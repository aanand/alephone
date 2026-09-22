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

#include "Shaders/ShaderTypes.h"
#include "MetalPipeline.h"
#include "IASManager.h"
#include "MetalRenderer.h"
#include "MetalTypes.h"

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
uint MAX_INSTANCES = 1000;

static const NSString* PLACEHOLDER_TEXTURE_ID = @"PLACEHOLDER";

const MTLPixelFormat AlbedoPixelFormat = MTLPixelFormatRGBA8Unorm;
const MTLPixelFormat DepthPixelFormat = MTLPixelFormatR32Float;
const MTLPixelFormat NormalPixelFormat = MTLPixelFormatRGBA16Float;
const MTLPixelFormat RayTracingPixelFormat = MTLPixelFormatRGBA16Float;


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
	float weaponFlare;
	Sky sky;

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
	id<MTLArgumentEncoder> spriteTextureArgumentEncoder;

	id<MTLResidencySet> initialRenderResidencySet;
	id<MTLResidencySet> rayTracingResidencySet;
	id<MTLResidencySet> finalRenderResidencySet;
	
	id<MTLTexture> initialRenderGBufferAlbedo;
	id<MTLTexture> initialRenderGBufferDepth;
	id<MTLTexture> initialRenderGBufferNormal;
	id<MTLTexture> rayTracingOutputTexture;

	// Constants shared across all pipelines
	id<MTLBuffer> uniformsBuffer;

	// Triangles for rasterization (static + dynamic)
	id<MTLBuffer> triangleBuffer;

	// Normals, UVs etc. for dynamic geometry
	id<MTLBuffer> perInstanceDataBuffer;
	uint32_t numInstances;

	// Sprite textures are passed into the raytracer for alpha testing
	NSMutableOrderedSet<NSString*> *spriteTextureIDs;
	id<MTLBuffer> spriteTextureArgumentBuffer;

	NSMutableDictionary<NSString *, id<MTLTexture>> *textures;

	// Geometry primitives that get reused across levels
	VerticalQuad *verticalQuadPrimitive;
	
	// Static geometry (walls, floors, ceilings)
	IASManager *staticIASManager;
	NSMutableArray<Triangle*> *staticTriangles;

	// Dynamic geometry (sprites, doors, platforms)
	IASManager *dynamicIASManager;
	NSMutableDictionary<NSNumber*, id<ASTrianglePrimitive>> *dynamicPolygonPrimitives;
	NSMutableArray<Triangle*> *dynamicTriangles;

	// Light sources
	NSArray<NSNumber*> *lightSourceIntensities;
	id<MTLBuffer> lightSourcesBuffer;

	id<MTLBuffer> topLevelIASInstanceBuffer;
	id<MTLAccelerationStructure> topLevelIAS;
	MTL4InstanceAccelerationStructureDescriptor *topLevelIASDescriptor;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	fov = 90.0;
	viewportSize = simd_make_uint2(width, height);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	pipeline = [[MetalPipeline alloc] init];
	pipeline.device = metalLayer.device;
	pipeline.commandQueue = [pipeline.device newMTL4CommandQueue];
	pipeline.commandBuffer = [pipeline.device newCommandBuffer];
	pipeline.defaultLibrary = [pipeline.device newDefaultLibrary];
	pipeline.commandAllocator = [pipeline.device newCommandAllocator];
	pipeline.sharedEvent = [pipeline.device newSharedEvent];

	if (![self setupResidencySets]) {
		return nil;
	}

	initialRenderPipeline = [self compileInitialRenderPipeline];
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

	[self setupIntermediateTextures];
	[self setupBuffers];
	
	NSError *error;
	staticIASManager = [[IASManager alloc] initWithPipeline:pipeline
								   primitiveDataElementSize:sizeof(PrimitiveRayTracingData)
													  error:&error];
	if (!staticIASManager) {
		NSLog(@"%@", error);
		return nil;
	}
	staticIASManager.label = @"staticIASManager";

	dynamicIASManager = [[IASManager alloc] initWithPipeline:pipeline
									primitiveDataElementSize:sizeof(PrimitiveRayTracingData)
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
	[textures setObject:[self makeTextureFromImage:[self makePlaceholderTextureImage]] forKey:PLACEHOLDER_TEXTURE_ID];
	
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
	
	perInstanceDataBuffer = [pipeline.device newBufferWithLength:(sizeof(InstanceRayTracingData) * MAX_INSTANCES) options:MTLResourceStorageModeShared];
	[rayTracingResidencySet addAllocation:perInstanceDataBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *initial = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:AlbedoPixelFormat
																					   width:viewportSize.x
																					  height:viewportSize.y
																				   mipmapped:NO];
	initial.storageMode = MTLStorageModePrivate;
	initial.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	initialRenderGBufferAlbedo = [pipeline.device newTextureWithDescriptor:initial];
	
	initial.pixelFormat = DepthPixelFormat;
	initialRenderGBufferDepth = [pipeline.device newTextureWithDescriptor:initial];
	
	initial.pixelFormat = NormalPixelFormat;
	initialRenderGBufferNormal = [pipeline.device newTextureWithDescriptor:initial];

	MTLTextureDescriptor *raytrace = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																						width:viewportSize.x
																					   height:viewportSize.y
																					mipmapped:NO];
	raytrace.storageMode = MTLStorageModePrivate;
	raytrace.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rayTracingOutputTexture = [pipeline.device newTextureWithDescriptor:raytrace];
	
	[initialRenderResidencySet addAllocation:initialRenderGBufferAlbedo];
	[initialRenderResidencySet addAllocation:initialRenderGBufferDepth];
	[initialRenderResidencySet addAllocation:initialRenderGBufferNormal];

	[rayTracingResidencySet addAllocation:rayTracingOutputTexture];

	[finalRenderResidencySet addAllocation:initialRenderGBufferAlbedo];
	[finalRenderResidencySet addAllocation:rayTracingOutputTexture];
}

- (id<MTLRenderPipelineState>) compileInitialRenderPipeline {
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

	MTL4RenderPipelineColorAttachmentDescriptor *albedoAttachment = descriptor.colorAttachments[InitialRenderAttachmentAlbedo];
	albedoAttachment.pixelFormat = AlbedoPixelFormat;
	albedoAttachment.blendingState = MTL4BlendStateEnabled;
	albedoAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	albedoAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	albedoAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	albedoAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	
	MTL4RenderPipelineColorAttachmentDescriptor *depthAttachment = descriptor.colorAttachments[InitialRenderAttachmentDepth];
	depthAttachment.pixelFormat = DepthPixelFormat;
	
	MTL4RenderPipelineColorAttachmentDescriptor *normalAttachment = descriptor.colorAttachments[InitialRenderAttachmentNormal];
	normalAttachment.pixelFormat = NormalPixelFormat;

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
	
	spriteTextureArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelSpriteTexturesIndex];
	spriteTextureArgumentEncoder.label = @"spriteTextureArgumentEncoder";

	spriteTextureArgumentBuffer = [pipeline.device newBufferWithLength:spriteTextureArgumentEncoder.encodedLength
															   options:MTLResourceStorageModeShared];
	spriteTextureArgumentBuffer.label = @"spriteTextureArgumentBuffer";
	
	[spriteTextureArgumentEncoder setArgumentBuffer:spriteTextureArgumentBuffer offset:0];
	[rayTracingResidencySet addAllocation:spriteTextureArgumentBuffer];
	
	id<MTLComputePipelineState> state = [pipeline.device newComputePipelineStateWithFunction:function
																			  error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (void) shutdown {
	[initialRenderResidencySet removeAllAllocations];
	[rayTracingResidencySet removeAllAllocations];
	[finalRenderResidencySet removeAllAllocations];
	[pipeline.commandQueue removeResidencySet:initialRenderResidencySet];
	[pipeline.commandQueue removeResidencySet:rayTracingResidencySet];
	[pipeline.commandQueue removeResidencySet:finalRenderResidencySet];
	
	staticIASManager = nil;
	dynamicIASManager = nil;
	pipeline = nil;
	
	textures = nil;
	staticTriangles = nil;
	dynamicTriangles = nil;
	dynamicPolygonPrimitives = nil;
	spriteTextureIDs = nil;
	
	metalLayer = nil;
	
	if (renderer) {
		SDL_DestroyRenderer(renderer);
		renderer = nil;
	}
	
	window = nil;
}

- (void) updateViewWithOrigin:(simd_int3)newOrigin pitch:(float)newPitch yaw:(float)newYaw FOV:(float)newFOV weaponFlare:(float)newWeaponFlare {
	origin = newOrigin;
	fov = newFOV;
	pitch = newPitch;
	yaw = newYaw;
	weaponFlare = newWeaponFlare;
}

- (void) updateSky:(Sky)newSky {
	sky = newSky;
}

simd_int3 transform(simd_int3 position, simd_float4x4 matrix) {
	simd_float4 transformed = simd_mul(matrix, simd_make_float4(position.x, position.y, position.z, 1.0));
	return simd_make_int3(transformed.x, transformed.y, transformed.z);
}

- (void)addPolygon:(MetalPolygon *)polygon withID:(int)ID dynamic:(BOOL)isDynamic {
	if (isDynamic) {
		[self addDynamicPolygon:polygon withID:ID];
	} else {
		[self addStaticPolygon:polygon];
	}
}

- (void)addWall:(MetalWall *)wall dynamic:(BOOL)isDynamic {
	if (isDynamic) {
		[self addDynamicWall:wall];
	} else {
		[self addStaticWall:wall];
	}
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[polygon eachTriangle:^(Triangle *triangle) {
		[self->staticTriangles addObject:triangle];
	}];
	assert(staticTriangles.count < MAX_TRIANGLES);
}

- (void)addStaticWall:(MetalWall *)wall {
	[wall eachTriangle:^(Triangle *triangle) {
		[self->staticTriangles addObject:triangle];
	}];
	assert(staticTriangles.count < MAX_TRIANGLES);
}

- (uint32_t) addSpriteTexture:(NSString*)textureID {
	[spriteTextureIDs addObject:textureID];
	return (uint32_t)[spriteTextureIDs indexOfObject:textureID];
}

- (uint32_t)addInstanceData:(InstanceRayTracingData)instanceData {
	// Purposefully skip index 0, which is shorthand for "use the per-primitive data"
	uint32_t instanceID = ++numInstances;
	assert(numInstances < MAX_INSTANCES);
	*(InstanceRayTracingData*)(perInstanceDataBuffer.contents + sizeof(InstanceRayTracingData)*instanceID) = instanceData;
	return instanceID;
}

- (void)addDynamicPolygon:(MetalPolygon *)polygon withID:(int)ID {
	[polygon eachTriangle:^(Triangle *triangle) {
		[self->dynamicTriangles addObject:triangle];
	}];
	assert(dynamicTriangles.count < MAX_TRIANGLES);

	id<ASTrianglePrimitive> primitive = [dynamicPolygonPrimitives objectForKey:[NSNumber numberWithInt:ID]];
	if (primitive == nil) {
		primitive = polygon.primitive;
		[dynamicIASManager addPrimitive:primitive];
		[dynamicPolygonPrimitives setObject:primitive forKey:[NSNumber numberWithInt:ID]];
	}
	
	uint32_t instanceID = [self addInstanceData:(InstanceRayTracingData){
		.surfaceNormal = polygon.surface.normal,
		.emission = polygon.surface.emission,
		// TODO: figure out how to pass in UV data for polygons
		.textureIndex = 0,
	}];

	[dynamicIASManager addInstanceOfPrimitive:primitive
								withTransform:polygon.instanceTransform
								   instanceID:instanceID];
}

- (void)addDynamicWall:(MetalWall *)wall {
	[wall eachTriangle:^(Triangle *triangle) {
		[self->dynamicTriangles addObject:triangle];
	}];
	assert(dynamicTriangles.count < MAX_TRIANGLES);
	
	uint32_t instanceID = [self addInstanceData:(InstanceRayTracingData){
		.surfaceNormal = wall.surface.normal,
		.emission = wall.surface.emission,
		.uv = wall.uv,
		.textureIndex = 0,
	}];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:wall.instanceTransform
								   instanceID:instanceID];
}

- (void) updateSprite:(MetalSprite *)sprite {
	float theta = radians(yaw);

	[sprite eachTriangle:^(Triangle *triangle) {
		[self->dynamicTriangles addObject:triangle];
	} forRotation:theta];
	assert(dynamicTriangles.count < MAX_TRIANGLES);

	uint32_t textureIndex = [self addSpriteTexture:sprite.surface.textureID];
	uint32_t instanceID = [self addInstanceData:(InstanceRayTracingData){
		.surfaceNormal = simd_make_float3(-cos(theta), -sin(theta), 0.0),
		.emission = sprite.surface.emission,
		.uv = sprite.uv,
		.textureIndex = textureIndex,
	}];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:[sprite instanceTransformForRotation:theta]
								   instanceID:instanceID];
}

- (void) updateLightSourceIntensities:(NSArray<NSNumber *> *)intensities {
	lightSourceIntensities = intensities;
}

- (void) writeStaticTrianglesToIAS {
	NSUInteger numTriangles = staticTriangles.count;
	NSUInteger trianglesPerBatch = 100;
	
	for (int b = 0; b < numTriangles; b += trianglesPerBatch) {
		NSArray *triangles = [staticTriangles subarrayWithRange:NSMakeRange(b, MIN(trianglesPerBatch, numTriangles - b))];
		TriangleBatch *batch = [[TriangleBatch alloc] initWithTriangles:triangles];
		[staticIASManager addPrimitive:batch];
		simd_float4x3 transform = {
			.columns = {
				{ 1.0, 0.0, 0.0 },
				{ 0.0, 1.0, 0.0 },
				{ 0.0, 0.0, 1.0 },
				{ 0.0, 0.0, 0.0 },
			}
		};
		[staticIASManager addInstanceOfPrimitive:batch withTransform:transform instanceID:0];
	}
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

- (void) clearLightSources {
	lightSourceIntensities = nil;
	if (lightSourcesBuffer) {
		[rayTracingResidencySet removeAllocation:lightSourcesBuffer];
		lightSourcesBuffer = nil;
	}
}

- (void) writeLightSources {
	if (lightSourceIntensities.count == 0) {
		return;
	}

	lightSourcesBuffer = [pipeline.device newBufferWithLength:sizeof(LightSource) * lightSourceIntensities.count
													  options:MTLResourceStorageModeShared];
	lightSourcesBuffer.label = @"lightSourcesBuffer";
	
	LightSource *lightSources = (LightSource*)lightSourcesBuffer.contents;
	
	for (NSUInteger i = 0; i < lightSourceIntensities.count; i++) {
		lightSources[i].intensity = lightSourceIntensities[i].floatValue;
	}
	
	[rayTracingResidencySet addAllocation:lightSourcesBuffer];
}

- (void) startUpdatingAllGeometry {
	staticTriangles = [NSMutableArray array];
	dynamicTriangles = [NSMutableArray array];
	dynamicPolygonPrimitives = [NSMutableDictionary dictionary];
	numInstances = 0;
	spriteTextureIDs = [NSMutableOrderedSet orderedSetWithObject:PLACEHOLDER_TEXTURE_ID];
	if (!verticalQuadPrimitive) {
		// spriteQuad initializes exactly once and is reused across frames + level changes
		verticalQuadPrimitive = [[VerticalQuad alloc] init];
	}

	[staticIASManager clearGeometry];
	[dynamicIASManager clearGeometry];
	[dynamicIASManager addPrimitive:verticalQuadPrimitive];
	[self clearLightSources];

	[self clearTopLevelIAS];
}

- (void) finishUpdatingAllGeometry {
	[self writeStaticTrianglesToIAS];
	[staticIASManager commitGeometry];
	[dynamicIASManager commitGeometry];
	[self writeLightSources];

	[self initializeTopLevelIAS];
	
	[self buildAccelerationStructureWithChangesTo:@[staticIASManager, dynamicIASManager]
						  primitiveDataHasChanged:YES
											label:@"Full IAS build"];
}

- (void) startUpdatingDynamicGeometry {
	dynamicTriangles = [NSMutableArray array];
	numInstances = 0;
	spriteTextureIDs = [NSMutableOrderedSet orderedSetWithObject:PLACEHOLDER_TEXTURE_ID];
	[dynamicIASManager clearInstances];
	[self clearLightSources];
	[self clearTopLevelIAS];
}

- (void) finishUpdatingDynamicGeometry {
	[dynamicIASManager commitInstances];
	[self writeLightSources];

	[self initializeTopLevelIAS];
	[self buildAccelerationStructureWithChangesTo:@[dynamicIASManager]
						  primitiveDataHasChanged:NO
											label:[NSString stringWithFormat:@"Dynamic IAS build (frame #%llu)", frameNumber]];
}

- (void) buildAccelerationStructureWithChangesTo:(NSArray<IASManager*>*)iasManagers
						 primitiveDataHasChanged:(BOOL)primitiveDataHasChanged
										   label:(NSString*)label {
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
	[rayTracingResidencySet addAllocation:scratchBuffer];
	[rayTracingResidencySet commit];
	
	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = label;

	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	encoder.label = @"Build acceleration structures";
	
	if (primitiveDataHasChanged) {
		for (IASManager *iasm in iasManagers) {
			[iasm encodeBuildCommandsForPASes:encoder
								scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
		}
		
		[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
					   beforeEncoderStages:MTLStageAccelerationStructure
						 visibilityOptions:MTL4VisibilityOptionDevice];
	}
	
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
	bool didFinish = [pipeline.sharedEvent waitUntilSignaledValue:buildSignalValue timeoutMS:50];
	
	if (!didFinish) {
		NSLog(@"Timed out waiting for AS build at frameNumber=%llu", frameNumber);
	}
	
	[pipeline.commandAllocator reset];

	[rayTracingResidencySet removeAllocation:scratchBuffer];
	[rayTracingResidencySet commit];
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [textures objectForKey:textureID] != nil;
}

- (void) addTextureWithID:(NSString*)textureID image:(MetalImage *)image {
	id<MTLTexture> texture = [self makeTextureFromImage:image];
	texture.label = textureID;
	[textures setObject:texture forKey:textureID];
	[initialRenderResidencySet addAllocation:texture];
}

- (void) addPlaceholderTextureWithID:(NSString *)textureID {
	[self addTextureWithID:textureID image:[self makePlaceholderTextureImage]];
}

- (id<MTLTexture>) makeTextureFromImage:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [pipeline.device newTextureWithDescriptor:descriptor];
	[texture replaceRegion:region
			   mipmapLevel:0
				 withBytes:image.data.bytes
			   bytesPerRow:sizeof(uint32) * image.width];

	return texture;
}

- (MetalImage*) makePlaceholderTextureImage {
	uint32 pixels[1] = { 255u | (0u << 8) | (255u << 16) | (255u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:pixels];
}

- (void) begin {
	frameNumber += 1;
}

- (void) end {
	// Rotate sun and ensure position is a unit vector
	Sky adjustedSky = sky;
	simd_quatf sunRotation = simd_quaternion(fmod(frameNumber * sky.sunRotationSpeed, 2*M_PI), sky.sunRotationAxis);
	adjustedSky.sunPosition = simd_normalize(simd_mul(simd_matrix4x4(sunRotation), simd_make_float4(sky.sunPosition, 1.0)).xyz);

	Uniforms uniforms;
	uniforms.resolution = viewportSize;
	uniforms.frameNumber = frameNumber;
	uniforms.fov = fov;
	uniforms.origin = origin;
	uniforms.pitchMat = rotationMatrix(pitch, simd_make_float3(1.0, 0.0, 0.0));
	uniforms.yawMat = rotationMatrix(-yaw, simd_make_float3(0.0, 1.0, 0.0));
	uniforms.rotateDirectionMat = simd_mul(rotationMatrix(yaw, simd_make_float3(0.0, 1.0, 0.0)), rotationMatrix(-pitch, simd_make_float3(1.0, 0.0, 0.0)));
	uniforms.perspectiveMat = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	uniforms.sky = adjustedSky;
	uniforms.weaponFlare = weaponFlare;
	memcpy(uniformsBuffer.contents, &uniforms, sizeof(Uniforms));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (render)", frameNumber];
	
	id<MTLFence> initialPassFence = [pipeline.device newFence];
	id<MTLFence> computePassFence = [pipeline.device newFence];
	
	[self encodeInitialRenderToAlbedoTexture:initialRenderGBufferAlbedo
								depthTexture:initialRenderGBufferDepth
							   normalTexture:initialRenderGBufferNormal
							   updatingFence:initialPassFence];

	[self encodeRayTracingPassToOutputTexture:rayTracingOutputTexture updatingFence:computePassFence];

	[self encodeFinalRenderFromAlbedoTexture:initialRenderGBufferAlbedo
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
	[pipeline.commandAllocator reset];
}

- (void) encodeInitialRenderToAlbedoTexture:(id<MTLTexture>)albedoTexture
							   depthTexture:(id<MTLTexture>)depthTexture
							  normalTexture:(id<MTLTexture>)normalTexture
							  updatingFence:(id<MTLFence>)fence
{
	// Commit any textures that were added
	[initialRenderResidencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];

	MTLRenderPassColorAttachmentDescriptor *albedo = configuration.colorAttachments[InitialRenderAttachmentAlbedo];
	albedo.texture = albedoTexture;
	albedo.loadAction = MTLLoadActionClear;
	// Render a white sky, which the raytracing pass will multiply down
	albedo.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
	albedo.storeAction = MTLStoreActionStore;

	MTLRenderPassColorAttachmentDescriptor *depth = configuration.colorAttachments[InitialRenderAttachmentDepth];
	depth.texture = depthTexture;
	depth.loadAction = MTLLoadActionClear;
	depth.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	depth.storeAction = MTLStoreActionStore;
	
	MTLRenderPassColorAttachmentDescriptor *normal = configuration.colorAttachments[InitialRenderAttachmentNormal];
	normal.texture = normalTexture;
	normal.loadAction = MTLLoadActionClear;
	normal.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	normal.storeAction = MTLStoreActionStore;
	
	id<MTL4RenderCommandEncoder> renderPassEncoder = [pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	renderPassEncoder.label = @"Initial render";
	
	[renderPassEncoder setRenderPipelineState:initialRenderPipeline];
	[renderPassEncoder setDepthStencilState:depthState];
	[renderPassEncoder setViewport:[self getViewportWithPixelScaling:NO]];
	
	[vertexArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:InitialRenderVertexShaderUniformsIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger __block offset = 0;

	void (^drawTriangle)(Triangle*) = ^(Triangle *triangle){
		target[offset] = triangle.v0;
		target[offset+1] = triangle.v1;
		target[offset+2] = triangle.v2;
		
		MTLGPUAddress address = self->triangleBuffer.gpuAddress + (offset * sizeof(WorldVertex));
		[self->vertexArgumentTable setAddress:address atIndex:InitialRenderVertexShaderVertexDataIndex];
		[renderPassEncoder setArgumentTable:self->vertexArgumentTable atStages:MTLRenderStageVertex];
		
		id<MTLTexture> texture = [self->textures objectForKey:triangle.surface.textureID];
		[self->fragmentArgumentTable setTexture:texture.gpuResourceID atIndex:InitialRenderFragmentShaderColorTextureIndex];
		[renderPassEncoder setArgumentTable:self->fragmentArgumentTable atStages:MTLRenderStageFragment];
		
		[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		
		offset += 3;
	};
	
	for (Triangle *triangle in staticTriangles) drawTriangle(triangle);
	for (Triangle *triangle in dynamicTriangles) drawTriangle(triangle);
	
	[renderPassEncoder updateFence:fence afterEncoderStages:MTLStageFragment];
	[renderPassEncoder endEncoding];
}

-(void) encodeRayTracingPassToOutputTexture:(id<MTLTexture>)outputTexture
							  updatingFence:(id<MTLFence>)fence
{
	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:rayTracingPipeline];

	[spriteTextureArgumentEncoder setArgumentBuffer:spriteTextureArgumentBuffer offset:0];
	
	for (NSUInteger i = 0; i < spriteTextureIDs.count; i++) {
		id<MTLTexture> texture = textures[spriteTextureIDs[i]];
		[spriteTextureArgumentEncoder setTexture:texture atIndex:i];
		[rayTracingResidencySet addAllocation:texture];
	}
	
	[computeArgumentTable setResource:topLevelIAS.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:RayTracingKernelUniformsIndex];
	[computeArgumentTable setAddress:perInstanceDataBuffer.gpuAddress atIndex:RayTracingKernelPerInstanceDataIndex];
	[computeArgumentTable setAddress:spriteTextureArgumentBuffer.gpuAddress atIndex:RayTracingKernelSpriteTexturesIndex];
	[computeArgumentTable setAddress:lightSourcesBuffer.gpuAddress atIndex:RayTracingKernelLightSourcesIndex];
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

-(void) encodeFinalRenderFromAlbedoTexture:(id<MTLTexture>)albedoTexture
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
	[encoder setViewport:[self getViewportWithPixelScaling:YES]];

	[encoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:albedoTexture.gpuResourceID atIndex:FinalRenderFragmentShaderInitialPassTextureIndex];
	[fragmentArgumentTable setTexture:rayTracingPassTexture.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingPassTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

- (MTLViewport) getViewportWithPixelScaling:(bool)scale {
	float multiplier = scale ? ((float) NSScreen.mainScreen.backingScaleFactor) : 1.0;

	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x * multiplier;
	viewPort.height = (double)viewportSize.y * multiplier;
	return viewPort;
}

@end
